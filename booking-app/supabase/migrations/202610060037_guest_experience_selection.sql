-- Guest-selected experience packages. The server is the source of truth for
-- availability, price calculations and the immutable reservation snapshot.

alter table public.reservation_request_inputs
  add column if not exists experience_selections jsonb not null default '[]'::jsonb;

create or replace function public.get_public_experience_catalog()
returns table (
  id uuid,
  name text,
  description text,
  pricing_unit text,
  amount_paise integer,
  max_quantity integer,
  display_order integer
)
language sql security definer set search_path = public stable as $$
  select a.id, a.name, a.description, a.pricing_unit, a.amount_paise,
    coalesce(a.max_quantity, 1), a.display_order
  from public.add_ons a
  join public.properties p on p.id = a.property_id
  where p.name = 'Breathe Woods'
    and a.active
    and coalesce((a.configuration ->> 'catalog_item')::boolean, false)
    and coalesce((a.configuration ->> 'guest_visible')::boolean, false)
  order by a.display_order, a.name;
$$;

create or replace function public.get_booking_quote_with_experiences(
  p_product_id uuid,
  p_check_in date,
  p_check_out date,
  p_adults integer,
  p_children_7_to_12 integer,
  p_children_0_to_6 integer,
  p_pets integer,
  p_meal_plan text,
  p_bonfire_sessions integer,
  p_lake_outings integer,
  p_lake_trip_guests integer,
  p_experience_selections jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_quote jsonb;
  v_product bookable_products%rowtype;
  v_selection jsonb;
  v_add_on add_ons%rowtype;
  v_quantity integer;
  v_nights integer;
  v_chargeable_guests integer;
  v_amount integer;
  v_items jsonb := '[]'::jsonb;
  v_total integer;
begin
  if p_experience_selections is null then p_experience_selections := '[]'::jsonb; end if;
  if jsonb_typeof(p_experience_selections) <> 'array' then
    raise exception 'Experience selections must be a list';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_experience_selections) value
    group by value ->> 'id'
    having count(*) > 1
  ) then
    raise exception 'Each experience can be selected only once';
  end if;

  v_quote := public.get_booking_quote_bundle_aware(
    p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12,
    p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions,
    p_lake_outings, p_lake_trip_guests
  );
  select * into v_product from public.bookable_products where id = p_product_id;
  if not found then raise exception 'This stay is no longer available'; end if;
  v_nights := p_check_out - p_check_in;
  v_chargeable_guests := p_adults + p_children_7_to_12;
  v_total := (v_quote ->> 'total_paise')::integer;

  for v_selection in select value from jsonb_array_elements(p_experience_selections) loop
    if nullif(v_selection ->> 'id', '') is null then raise exception 'An experience selection is missing its package'; end if;
    v_quantity := coalesce(nullif(v_selection ->> 'quantity', '')::integer, 0);
    if v_quantity < 1 then raise exception 'Choose a valid quantity for each experience'; end if;
    select * into v_add_on
    from public.add_ons
    where id = (v_selection ->> 'id')::uuid
      and property_id = v_product.property_id
      and active
      and coalesce((configuration ->> 'catalog_item')::boolean, false)
      and coalesce((configuration ->> 'guest_visible')::boolean, false);
    if not found then raise exception 'One of the selected experiences is no longer available'; end if;
    if v_quantity > coalesce(v_add_on.max_quantity, 1) then
      raise exception 'The selected quantity exceeds the limit for %', v_add_on.name;
    end if;
    v_amount := case v_add_on.pricing_unit
      when 'per_guest' then v_add_on.amount_paise * v_chargeable_guests * v_quantity
      when 'per_night' then v_add_on.amount_paise * v_nights * v_quantity
      else v_add_on.amount_paise * v_quantity
    end;
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'label', v_add_on.name,
      'quantity', v_quantity,
      'amount_paise', v_amount,
      'item_type', 'add_on',
      'experience_id', v_add_on.id,
      'pricing_unit', v_add_on.pricing_unit
    ));
    v_total := v_total + v_amount;
  end loop;

  return jsonb_set(
    jsonb_set(v_quote, '{total_paise}', to_jsonb(v_total)),
    '{items}', coalesce(v_quote -> 'items', '[]'::jsonb) || v_items
  );
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
  v_product bookable_products%rowtype; v_quote jsonb; v_guest_id uuid;
  v_reservation_id uuid; v_reference text; v_item jsonb; v_consent_version text := '2026-10-05';
begin
  select * into v_product from public.bookable_products where id = p_product_id and active;
  if not found then raise exception 'This stay is no longer available'; end if;
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Please enter the lead guest name'; end if;
  if position('@' in coalesce(p_guest_email, '')) < 2 then raise exception 'Please enter a valid email address'; end if;
  if coalesce(p_guest_phone, '') !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Please enter a valid mobile number with country code'; end if;
  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then raise exception 'This stay is not currently available. Please choose other dates.'; end if;
  v_quote := public.get_booking_quote_with_experiences(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests, p_experience_selections);
  v_reference := 'BW-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  insert into public.guests (property_id, full_name, email, phone_e164, email_marketing_opt_in, whatsapp_opt_in, marketing_consent_at, marketing_consent_version)
  values (v_product.property_id, trim(p_guest_name), lower(trim(p_guest_email)), trim(p_guest_phone), p_marketing_opt_in, p_marketing_opt_in, case when p_marketing_opt_in then now() else null end, case when p_marketing_opt_in then v_consent_version else null end) returning id into v_guest_id;
  if p_marketing_opt_in then insert into public.guest_consents (property_id, guest_id, channel, purpose, action, consent_version, source)
  values (v_product.property_id, v_guest_id, 'email', 'marketing', 'granted', v_consent_version, 'website'), (v_product.property_id, v_guest_id, 'whatsapp', 'marketing', 'granted', v_consent_version, 'website'); end if;
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

-- Preserve package choices if an owner reprices, moves, or offers a different stay.
create or replace function public.owner_reprice_reservation_request(
  p_reservation_id uuid, p_check_in date, p_check_out date, p_note text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype; v_inputs reservation_request_inputs%rowtype; v_quote jsonb; v_item jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to change this reservation'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') then raise exception 'Only an open reservation request can be re-priced'; end if;
  if p_check_out <= p_check_in then raise exception 'Check-out must be after check-in'; end if;
  perform public.lock_property_inventory(v_property_id);
  if not public.is_product_inventory_available(v_reservation.product_id, p_check_in, p_check_out) then raise exception 'Those dates are no longer available'; end if;
  select * into v_inputs from reservation_request_inputs where reservation_id = p_reservation_id;
  if not found then raise exception 'The original request inputs are unavailable'; end if;
  v_quote := public.get_booking_quote_with_experiences(v_reservation.product_id, p_check_in, p_check_out, v_reservation.adults, v_reservation.children_7_to_12, v_reservation.children_0_to_6, v_reservation.pets, v_inputs.meal_plan, v_inputs.bonfire_sessions, v_inputs.lake_outings, v_inputs.lake_trip_guests, v_inputs.experience_selections);
  update reservations set check_in = p_check_in, check_out = p_check_out, status = 'alternative_offered', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
  update price_snapshots set total_paise = (v_quote ->> 'total_paise')::integer, calculation = v_quote, accepted_at = null where reservation_id = p_reservation_id;
  delete from reservation_items where reservation_id = p_reservation_id;
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (p_reservation_id, coalesce(v_item ->> 'item_type', case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end), v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data) values (v_property_id, auth.uid(), 'reservation', p_reservation_id, 'alternative_dates_offered', jsonb_build_object('check_in', p_check_in, 'check_out', p_check_out, 'note', p_note));
  return jsonb_build_object('status', 'alternative_offered', 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

create or replace function public.get_owner_reservation_alternatives(p_reservation_id uuid)
returns table (
  product_id uuid, product_code text, product_name text, sellable_kind text, total_paise integer
)
language plpgsql security definer set search_path = public stable as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype;
  v_inputs reservation_request_inputs%rowtype; v_candidate record; v_quote jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id;
  if not found then raise exception 'Reservation not found'; end if;
  if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') then raise exception 'Alternatives are available only for an open reservation request'; end if;
  select * into v_inputs from reservation_request_inputs where reservation_id = p_reservation_id;
  if not found then raise exception 'The original request inputs are unavailable'; end if;
  for v_candidate in select available.* from public.get_available_products(v_reservation.check_in, v_reservation.check_out, v_reservation.adults + v_reservation.children_7_to_12 + v_reservation.children_0_to_6) available where available.product_id <> v_reservation.product_id order by available.product_name loop
    v_quote := public.get_booking_quote_with_experiences(v_candidate.product_id, v_reservation.check_in, v_reservation.check_out, v_reservation.adults, v_reservation.children_7_to_12, v_reservation.children_0_to_6, v_reservation.pets, v_inputs.meal_plan, v_inputs.bonfire_sessions, v_inputs.lake_outings, v_inputs.lake_trip_guests, v_inputs.experience_selections);
    product_id := v_candidate.product_id; product_code := v_candidate.product_code; product_name := v_candidate.product_name; sellable_kind := v_candidate.sellable_kind; total_paise := (v_quote ->> 'total_paise')::integer;
    return next;
  end loop;
end;
$$;

create or replace function public.owner_offer_alternative_stay(
  p_reservation_id uuid, p_product_id uuid, p_note text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype; v_product bookable_products%rowtype;
  v_inputs reservation_request_inputs%rowtype; v_quote jsonb; v_item jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to change this reservation'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') then raise exception 'Only an open reservation request can be changed'; end if;
  select * into v_product from bookable_products where id = p_product_id and property_id = v_property_id and active;
  if not found then raise exception 'That alternative stay is unavailable'; end if;
  select * into v_inputs from reservation_request_inputs where reservation_id = p_reservation_id;
  if not found then raise exception 'The original request inputs are unavailable'; end if;
  perform public.lock_property_inventory(v_property_id);
  if not public.is_product_inventory_available(v_product.id, v_reservation.check_in, v_reservation.check_out) then raise exception 'That alternative was just booked or blocked. Please choose another stay.'; end if;
  v_quote := public.get_booking_quote_with_experiences(v_product.id, v_reservation.check_in, v_reservation.check_out, v_reservation.adults, v_reservation.children_7_to_12, v_reservation.children_0_to_6, v_reservation.pets, v_inputs.meal_plan, v_inputs.bonfire_sessions, v_inputs.lake_outings, v_inputs.lake_trip_guests, v_inputs.experience_selections);
  update reservations set product_id = v_product.id, status = 'alternative_offered', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
  update price_snapshots set total_paise = (v_quote ->> 'total_paise')::integer, calculation = v_quote, accepted_at = null where reservation_id = p_reservation_id;
  delete from reservation_items where reservation_id = p_reservation_id;
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (p_reservation_id, coalesce(v_item ->> 'item_type', case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end), v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data) values (v_property_id, auth.uid(), 'reservation', p_reservation_id, 'alternative_stay_offered', jsonb_build_object('product_id', v_product.id, 'product_name', v_product.name, 'note', p_note));
  return jsonb_build_object('status', 'alternative_offered', 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

revoke all on function public.get_public_experience_catalog() from public;
revoke all on function public.get_booking_quote_with_experiences(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, jsonb) from public;
revoke all on function public.create_reservation_request_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean, jsonb) from public;
grant execute on function public.get_public_experience_catalog() to anon, authenticated;
grant execute on function public.get_booking_quote_with_experiences(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, jsonb) to anon, authenticated;
grant execute on function public.create_reservation_request_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean, jsonb) to anon, authenticated;
grant execute on function public.owner_reprice_reservation_request(uuid, date, date, text) to authenticated;
grant execute on function public.get_owner_reservation_alternatives(uuid) to authenticated;
grant execute on function public.owner_offer_alternative_stay(uuid, uuid, text) to authenticated;
