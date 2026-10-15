-- Let guests and owners confirm a reservation with either email or phone,
-- keep email notifications best-effort, and expose booking pricing controls.

create or replace function public.queue_reservation_email_notification(
  p_reservation_id uuid,
  p_event_type text,
  p_recipient_role text
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid;
  v_payload jsonb;
  v_guest_email text;
begin
  select property_id into v_property_id from public.reservations where id = p_reservation_id;
  if v_property_id is null then raise exception 'Reservation not found'; end if;

  v_payload := public.build_reservation_notification_payload(p_reservation_id);
  v_guest_email := nullif(trim(v_payload #>> '{guest,email}'), '');
  -- Confirmation must not depend on email. Owners can contact a guest by phone,
  -- and a missing email simply means there is no guest-email notification.
  if p_recipient_role = 'guest' and v_guest_email is null then return; end if;

  insert into public.notification_outbox (
    property_id, reservation_id, event_type, recipient_role, recipient_email, payload
  ) values (
    v_property_id, p_reservation_id, p_event_type, p_recipient_role,
    case when p_recipient_role = 'guest' then v_guest_email else null end,
    v_payload
  ) on conflict (reservation_id, event_type, recipient_role) do nothing;
end;
$$;

create or replace function public.create_reservation_request_bundle_aware(
  p_product_id uuid, p_check_in date, p_check_out date, p_adults integer,
  p_children_7_to_12 integer, p_children_0_to_6 integer, p_pets integer,
  p_meal_plan text, p_bonfire_sessions integer, p_lake_outings integer,
  p_lake_trip_guests integer, p_guest_name text, p_guest_email text,
  p_guest_phone text, p_marketing_opt_in boolean, p_experience_selections jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_product public.bookable_products%rowtype; v_quote jsonb; v_guest_id uuid;
  v_reservation_id uuid; v_reference text; v_item jsonb;
  v_email text := nullif(lower(trim(coalesce(p_guest_email, ''))), '');
  v_phone text := nullif(trim(coalesce(p_guest_phone, '')), '');
  v_consent_version text := '2026-10-05';
begin
  select * into v_product from public.bookable_products where id = p_product_id and active;
  if not found then raise exception 'This stay is no longer available'; end if;
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Please enter the lead guest name'; end if;
  if v_email is null and v_phone is null then raise exception 'Enter either an email address or mobile number'; end if;
  if v_email is not null and v_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Please enter a valid email address'; end if;
  if v_phone is not null and v_phone !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Please enter a valid mobile number with country code'; end if;
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then raise exception 'Choose valid stay dates'; end if;
  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then raise exception 'This stay is not currently available. Please choose other dates.'; end if;
  v_quote := public.get_booking_quote_with_experiences(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests, p_experience_selections);
  v_reference := 'BW-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  insert into public.guests (property_id, full_name, email, phone_e164, email_marketing_opt_in, whatsapp_opt_in, marketing_consent_at, marketing_consent_version)
  values (v_product.property_id, trim(p_guest_name), v_email, v_phone, p_marketing_opt_in, p_marketing_opt_in, case when p_marketing_opt_in then now() else null end, case when p_marketing_opt_in then v_consent_version else null end) returning id into v_guest_id;
  if p_marketing_opt_in then
    insert into public.guest_consents (property_id, guest_id, channel, purpose, action, consent_version, source)
    values (v_product.property_id, v_guest_id, 'email', 'marketing', 'granted', v_consent_version, 'website'),
      (v_product.property_id, v_guest_id, 'whatsapp', 'marketing', 'granted', v_consent_version, 'website');
  end if;
  insert into public.reservations (property_id, reference, guest_id, product_id, check_in, check_out, adults, children_7_to_12, children_0_to_6, pets, source, status)
  values (v_product.property_id, v_reference, v_guest_id, v_product.id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, 'website', 'requested') returning id into v_reservation_id;
  insert into public.price_snapshots (reservation_id, total_paise, calculation) values (v_reservation_id, (v_quote ->> 'total_paise')::integer, v_quote);
  insert into public.reservation_request_inputs (reservation_id, meal_plan, bonfire_sessions, lake_outings, lake_trip_guests, experience_selections)
  values (v_reservation_id, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests, coalesce(p_experience_selections, '[]'::jsonb));
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into public.reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (v_reservation_id, coalesce(v_item ->> 'item_type', case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end), v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into public.audit_log (property_id, entity_type, entity_id, action, data)
  values (v_product.property_id, 'reservation', v_reservation_id, 'request_submitted', jsonb_build_object('reference', v_reference));
  return jsonb_build_object('reservation_id', v_reservation_id, 'reference', v_reference, 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

-- New overload accepts the same meal and experience selections as the guest form.
drop function if exists public.owner_create_assisted_booking(uuid, date, date, integer, integer, integer, integer, text, text, text, text, integer, text, text, text);

create or replace function public.owner_create_assisted_booking(
  p_product_id uuid,
  p_check_in date,
  p_check_out date,
  p_adults integer,
  p_children_7_to_12 integer default 0,
  p_children_0_to_6 integer default 0,
  p_pets integer default 0,
  p_guest_name text default null,
  p_guest_email text default null,
  p_guest_phone text default null,
  p_source text default 'owner_dashboard',
  p_total_paise integer default null,
  p_payment_state text default 'not_recorded',
  p_payment_reference text default null,
  p_internal_note text default null,
  p_meal_plan text default 'breakfast',
  p_bonfire_sessions integer default 0,
  p_lake_trip_guests integer default 0,
  p_experience_selections jsonb default '[]'::jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_product public.bookable_products%rowtype; v_guest_id uuid;
  v_reservation_id uuid; v_reference text; v_item jsonb; v_quote jsonb; v_total integer;
  v_email text := nullif(lower(trim(coalesce(p_guest_email, ''))), '');
  v_phone text := nullif(trim(coalesce(p_guest_phone, '')), '');
  v_meal_plan text := p_meal_plan;
begin
  select property_id into v_property_id from public.owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from public.owner_profiles where user_id = auth.uid()) = 'viewer' then
    raise exception 'You do not have permission to create a guest booking';
  end if;
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then raise exception 'Check-out must be after check-in'; end if;
  if p_adults is null or p_adults < 1 or p_children_7_to_12 < 0 or p_children_0_to_6 < 0 or p_pets < 0 then raise exception 'Guest counts are invalid'; end if;
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Enter the guest''s full name'; end if;
  if v_email is null and v_phone is null then raise exception 'Enter either an email address or phone number for the guest'; end if;
  if v_email is not null and v_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid email address'; end if;
  if v_phone is not null and v_phone !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Enter a valid phone number with country code'; end if;
  if p_source not in ('owner_dashboard', 'phone', 'email', 'whatsapp', 'walk_in', 'owner_referral') then raise exception 'Unsupported booking source'; end if;
  if p_payment_state not in ('not_recorded', 'pending', 'paid') then raise exception 'Unsupported payment state'; end if;
  if p_bonfire_sessions < 0 or p_lake_trip_guests < 0 then raise exception 'Experience quantities cannot be negative'; end if;
  if p_total_paise is not null and p_total_paise < 0 then raise exception 'Total amount cannot be negative'; end if;

  select * into v_product from public.bookable_products where id = p_product_id and property_id = v_property_id and active;
  if not found then raise exception 'This stay option is not available'; end if;
  if v_product.sellable_kind = 'entire_property' then v_meal_plan := 'all_meals'; end if;
  perform public.lock_property_inventory(v_property_id);
  v_quote := public.get_booking_quote_with_experiences(
    p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12,
    p_children_0_to_6, p_pets, v_meal_plan, p_bonfire_sessions, 0,
    p_lake_trip_guests, coalesce(p_experience_selections, '[]'::jsonb)
  );
  v_total := coalesce((v_quote ->> 'total_paise')::integer, 0);
  if p_total_paise is not null then
    v_total := p_total_paise;
    v_quote := jsonb_set(v_quote, '{calculated_total_paise}', to_jsonb((v_quote ->> 'total_paise')::integer), true);
    v_quote := jsonb_set(v_quote, '{total_paise}', to_jsonb(v_total), true);
    v_quote := jsonb_set(v_quote, '{owner_price_override}', 'true'::jsonb, true);
  end if;

  v_reference := 'BW-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-M' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 5));
  insert into public.guests (property_id, full_name, email, phone_e164)
  values (v_property_id, trim(p_guest_name), v_email, v_phone) returning id into v_guest_id;
  insert into public.reservations (property_id, reference, guest_id, product_id, check_in, check_out, adults, children_7_to_12, children_0_to_6, pets, source, status, internal_note)
  values (v_property_id, v_reference, v_guest_id, v_product.id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_source::public.booking_source, 'requested', nullif(trim(p_internal_note), ''))
  returning id into v_reservation_id;
  insert into public.reservation_request_inputs (reservation_id, meal_plan, bonfire_sessions, lake_outings, lake_trip_guests, owner_payment_state, owner_payment_reference, experience_selections)
  values (v_reservation_id, v_meal_plan, p_bonfire_sessions, 0, p_lake_trip_guests, p_payment_state, nullif(trim(p_payment_reference), ''), coalesce(p_experience_selections, '[]'::jsonb));
  insert into public.price_snapshots (reservation_id, total_paise, calculation, accepted_at)
  values (v_reservation_id, v_total, v_quote, now());
  for v_item in select value from jsonb_array_elements(coalesce(v_quote -> 'items', '[]'::jsonb)) loop
    insert into public.reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (v_reservation_id, coalesce(v_item ->> 'item_type', case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end), v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into public.audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'reservation', v_reservation_id, 'owner_assisted_request_created',
    jsonb_build_object('reference', v_reference, 'source', p_source, 'meal_plan', v_meal_plan, 'payment_state', p_payment_state, 'payment_reference', p_payment_reference, 'total_paise', v_total));
  return jsonb_build_object('reservation_id', v_reservation_id, 'reference', v_reference, 'total_paise', v_total);
end;
$$;

create or replace function public.owner_update_meal_pricing(
  p_breakfast_plus_one_adult_paise integer,
  p_breakfast_plus_one_child_7_to_12_paise integer,
  p_all_meals_adult_paise integer,
  p_all_meals_child_7_to_12_paise integer
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_role public.dashboard_role; v_current jsonb; v_meal_rates jsonb;
begin
  select property_id, role into v_property_id, v_role from public.owner_profiles where user_id = auth.uid();
  if v_property_id is null or v_role = 'viewer' then raise exception 'You do not have permission to change meal pricing'; end if;
  if p_breakfast_plus_one_adult_paise < 0 or p_breakfast_plus_one_child_7_to_12_paise < 0
    or p_all_meals_adult_paise < 0 or p_all_meals_child_7_to_12_paise < 0 then
    raise exception 'Meal prices cannot be negative';
  end if;
  v_meal_rates := jsonb_build_object(
    'breakfast_plus_one', jsonb_build_object('adult', p_breakfast_plus_one_adult_paise, 'child_7_to_12', p_breakfast_plus_one_child_7_to_12_paise),
    'all_meals', jsonb_build_object('adult', p_all_meals_adult_paise, 'child_7_to_12', p_all_meals_child_7_to_12_paise)
  );
  select value into v_current from public.property_settings where property_id = v_property_id and setting_key = 'daily_pricing_calendar' for update;
  insert into public.property_settings as existing_setting (property_id, setting_key, value)
  values (v_property_id, 'daily_pricing_calendar', jsonb_set(coalesce(v_current, '{}'::jsonb), '{meal_upgrade_paise_per_night}', v_meal_rates, true))
  on conflict (property_id, setting_key) do update
    set value = jsonb_set(coalesce(existing_setting.value, '{}'::jsonb), '{meal_upgrade_paise_per_night}', excluded.value -> 'meal_upgrade_paise_per_night', true), updated_at = now();
  insert into public.audit_log (property_id, actor_id, entity_type, action, data)
  values (v_property_id, auth.uid(), 'meal_pricing', 'meal_pricing_updated', v_meal_rates);
end;
$$;

revoke all on function public.queue_reservation_email_notification(uuid, text, text) from public;
revoke all on function public.create_reservation_request_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean, jsonb) from public;
revoke all on function public.owner_create_assisted_booking(uuid, date, date, integer, integer, integer, integer, text, text, text, text, integer, text, text, text, text, integer, integer, jsonb) from public;
revoke all on function public.owner_update_meal_pricing(integer, integer, integer, integer) from public;
grant execute on function public.create_reservation_request_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean, jsonb) to anon, authenticated;
grant execute on function public.owner_create_assisted_booking(uuid, date, date, integer, integer, integer, integer, text, text, text, text, integer, text, text, text, text, integer, integer, jsonb) to authenticated;
grant execute on function public.owner_update_meal_pricing(integer, integer, integer, integer) to authenticated;
