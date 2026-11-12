-- Let an owner correct or revise website and owner-assisted reservations.
-- Payment ledger rows are retained; inventory, quote and reservation edits are
-- applied in one transaction so a failed availability check changes nothing.

create or replace function public.get_owner_reservation_edit_details(p_reservation_id uuid)
returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare v_property_id uuid; v_result jsonb;
begin
  select property_id into v_property_id from public.owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from public.owner_profiles where user_id = auth.uid()) = 'viewer' then
    raise exception 'You do not have permission to edit bookings';
  end if;
  select jsonb_build_object(
    'product_id', r.product_id,
    'meal_plan', coalesce(i.meal_plan, 'breakfast'),
    'bonfire_sessions', coalesce(i.bonfire_sessions, 0),
    'lake_trip_guests', coalesce(i.lake_trip_guests, 0),
    'experience_selections', coalesce(i.experience_selections, '[]'::jsonb)
  ) into v_result
  from public.reservations r
  left join public.reservation_request_inputs i on i.reservation_id = r.id
  where r.id = p_reservation_id and r.property_id = v_property_id
    and r.status not in ('cancelled', 'declined');
  if v_result is null then raise exception 'Active booking not found'; end if;
  return v_result;
end;
$$;

create or replace function public.owner_update_reservation_details(
  p_reservation_id uuid,
  p_product_id uuid,
  p_check_in date,
  p_check_out date,
  p_adults integer,
  p_children_7_to_12 integer,
  p_children_0_to_6 integer,
  p_pets integer,
  p_guest_name text,
  p_guest_email text,
  p_guest_phone text,
  p_internal_note text,
  p_meal_plan text,
  p_bonfire_sessions integer,
  p_lake_trip_guests integer,
  p_experience_selections jsonb,
  p_total_paise integer
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_role public.dashboard_role; v_reservation public.reservations%rowtype;
  v_product public.bookable_products%rowtype; v_guest_id uuid; v_inputs public.reservation_request_inputs%rowtype;
  v_quote jsonb; v_item jsonb; v_paid integer := 0; v_expiry timestamptz;
  v_stay_changed boolean; v_allocated integer := 0; v_email text; v_phone text;
begin
  select property_id, role into v_property_id, v_role from public.owner_profiles where user_id = auth.uid();
  if v_property_id is null or v_role = 'viewer' then raise exception 'You do not have permission to edit bookings'; end if;
  select * into v_reservation from public.reservations
   where id = p_reservation_id and property_id = v_property_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if v_reservation.status in ('cancelled', 'declined') then raise exception 'Cancelled bookings cannot be edited'; end if;
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then raise exception 'Check-out must be after check-in'; end if;
  if p_adults is null or p_adults < 1 or p_children_7_to_12 < 0 or p_children_0_to_6 < 0 or p_pets < 0 then raise exception 'Guest counts are invalid'; end if;
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Enter the guest name'; end if;
  v_email := nullif(lower(trim(coalesce(p_guest_email, ''))), '');
  v_phone := nullif(trim(coalesce(p_guest_phone, '')), '');
  if v_email is null and v_phone is null then raise exception 'Enter either an email address or phone number'; end if;
  if v_email is not null and v_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid email address'; end if;
  if v_phone is not null and v_phone !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Enter a valid phone number with country code'; end if;
  if p_bonfire_sessions < 0 or p_lake_trip_guests < 0 or p_total_paise is null or p_total_paise < 0 then raise exception 'Booking quantities or total are invalid'; end if;
  if jsonb_typeof(coalesce(p_experience_selections, '[]'::jsonb)) <> 'array' then raise exception 'Experience selections are invalid'; end if;
  select * into v_product from public.bookable_products where id = p_product_id and property_id = v_property_id and active;
  if not found then raise exception 'This stay option is no longer available'; end if;
  if v_product.sellable_kind = 'entire_property' and p_meal_plan <> 'all_meals' then raise exception 'Entire-property stays require the all-meals plan'; end if;
  if v_product.sellable_kind <> 'entire_property' and p_meal_plan not in ('breakfast', 'breakfast_plus_one', 'all_meals') then raise exception 'Choose a valid meal plan'; end if;

  perform public.lock_property_inventory(v_property_id);
  select coalesce(sum(amount_paise), 0) into v_paid from public.payments where reservation_id = p_reservation_id and state = 'paid';
  if p_total_paise < v_paid then raise exception 'The agreed total cannot be less than the amount already paid (% paise)', v_paid; end if;
  if exists (select 1 from public.payments where reservation_id = p_reservation_id and provider <> 'manual' and state in ('created', 'pending')) then
    raise exception 'This booking has an active online checkout. Let it finish or expire before editing';
  end if;
  select * into v_inputs from public.reservation_request_inputs where reservation_id = p_reservation_id for update;
  v_stay_changed := v_reservation.product_id is distinct from p_product_id
    or v_reservation.check_in is distinct from p_check_in or v_reservation.check_out is distinct from p_check_out;
  if v_stay_changed and v_reservation.status = 'awaiting_manual_payment' then
    select min(expires_at) into v_expiry from public.inventory_allocations
      where reservation_id = p_reservation_id and state = 'hold' and expires_at > now();
    if v_expiry is null then raise exception 'The payment hold expired. Reopen or confirm the booking before changing its dates or stay'; end if;
  end if;
  if v_stay_changed then
    delete from public.inventory_allocations where reservation_id = p_reservation_id;
    if v_reservation.status in ('confirmed', 'awaiting_manual_payment') then
      if not public.is_product_inventory_available(v_product.id, p_check_in, p_check_out) then
        raise exception 'Those dates or rooms are unavailable. The existing booking remains unchanged';
      end if;
      if v_product.inventory_mode = 'child_rooms' then
        insert into public.inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
        select v_property_id, child.id, p_reservation_id, daterange(p_check_in, p_check_out, '[)'),
          case when v_reservation.status = 'confirmed' then 'confirmed'::public.allocation_state else 'hold'::public.allocation_state end,
          case when v_reservation.status = 'confirmed' then null else v_expiry end
        from public.resources child
        where child.parent_resource_id = v_product.primary_resource_id and child.active
          and not exists (select 1 from public.inventory_allocations a where a.resource_id = child.id
            and a.stay_during && daterange(p_check_in, p_check_out, '[)')
            and a.state in ('confirmed', 'block', 'hold') and (a.state <> 'hold' or a.expires_at > now()))
        order by child.name limit v_product.room_units_required;
        get diagnostics v_allocated = row_count;
        if v_allocated < v_product.room_units_required then raise exception 'Not enough rooms are available for that stay'; end if;
      else
        insert into public.inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
        select v_property_id, bpr.resource_id, p_reservation_id, daterange(p_check_in, p_check_out, '[)'),
          case when v_reservation.status = 'confirmed' then 'confirmed'::public.allocation_state else 'hold'::public.allocation_state end,
          case when v_reservation.status = 'confirmed' then null else v_expiry end
        from public.bookable_product_resources bpr where bpr.product_id = v_product.id;
        get diagnostics v_allocated = row_count;
        if v_allocated = 0 then raise exception 'This stay has no configured inventory'; end if;
      end if;
    end if;
  end if;

  v_quote := public.get_booking_quote_with_experiences(p_product_id, p_check_in, p_check_out,
    p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan,
    p_bonfire_sessions, 0, p_lake_trip_guests, coalesce(p_experience_selections, '[]'::jsonb));
  v_quote := jsonb_set(v_quote, '{calculated_total_paise}', to_jsonb((v_quote ->> 'total_paise')::integer), true);
  v_quote := jsonb_set(v_quote, '{total_paise}', to_jsonb(p_total_paise), true);
  v_quote := jsonb_set(v_quote, '{owner_price_override}', to_jsonb(p_total_paise <> (v_quote ->> 'calculated_total_paise')::integer), true);
  select id into v_guest_id from public.guests where id = v_reservation.guest_id and property_id = v_property_id for update;
  if v_guest_id is null then
    insert into public.guests (property_id, full_name, email, phone_e164) values (v_property_id, trim(p_guest_name), v_email, v_phone) returning id into v_guest_id;
  else
    update public.guests set full_name = trim(p_guest_name), email = v_email, phone_e164 = v_phone where id = v_guest_id;
  end if;
  update public.reservations set guest_id = v_guest_id, product_id = v_product.id, check_in = p_check_in, check_out = p_check_out,
    adults = p_adults, children_7_to_12 = p_children_7_to_12, children_0_to_6 = p_children_0_to_6,
    pets = p_pets, internal_note = nullif(trim(coalesce(p_internal_note, '')), ''), updated_at = now()
    where id = p_reservation_id;
  insert into public.reservation_request_inputs (reservation_id, meal_plan, bonfire_sessions, lake_outings, lake_trip_guests, experience_selections)
    values (p_reservation_id, p_meal_plan, p_bonfire_sessions, 0, p_lake_trip_guests, coalesce(p_experience_selections, '[]'::jsonb))
    on conflict (reservation_id) do update set meal_plan = excluded.meal_plan, bonfire_sessions = excluded.bonfire_sessions,
      lake_trip_guests = excluded.lake_trip_guests, experience_selections = excluded.experience_selections;
  update public.price_snapshots set total_paise = p_total_paise, calculation = v_quote where reservation_id = p_reservation_id;
  if not found then insert into public.price_snapshots (reservation_id, total_paise, calculation, accepted_at)
    values (p_reservation_id, p_total_paise, v_quote, case when v_reservation.status = 'confirmed' then now() else null end); end if;
  delete from public.reservation_items where reservation_id = p_reservation_id;
  for v_item in select value from jsonb_array_elements(coalesce(v_quote -> 'items', '[]'::jsonb)) loop
    insert into public.reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (p_reservation_id, coalesce(v_item ->> 'item_type', case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end),
      coalesce(v_item ->> 'label', 'Booking item'), coalesce((v_item ->> 'quantity')::numeric, 1), coalesce((v_item ->> 'amount_paise')::integer, 0));
  end loop;
  if v_reservation.status = 'confirmed' then
    update public.reservation_quote_versions set state = 'accepted', accepted_at = coalesce(accepted_at, now())
      where reservation_id = p_reservation_id and state = 'active';
  end if;
  update public.payments set amount_paise = greatest(p_total_paise - v_paid, 0),
    state = case when p_total_paise = v_paid then 'cancelled'::public.payment_state else state end,
    expires_at = null, updated_at = now()
    where reservation_id = p_reservation_id and provider = 'manual' and state = 'pending'
      and coalesce(provider_payload ->> 'source', '') = 'owner_managed_balance';
  insert into public.audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'reservation', p_reservation_id, 'owner_reservation_details_updated',
    jsonb_build_object('source', v_reservation.source, 'status', v_reservation.status, 'previous_product_id', v_reservation.product_id,
      'product_id', p_product_id, 'check_in', p_check_in, 'check_out', p_check_out, 'total_paise', p_total_paise, 'paid_paise', v_paid));
  return jsonb_build_object('reservation_id', p_reservation_id, 'total_paise', p_total_paise, 'paid_paise', v_paid, 'balance_paise', p_total_paise - v_paid);
exception when exclusion_violation then
  raise exception 'Those dates or rooms were just booked or blocked. The existing booking remains unchanged';
end;
$$;

revoke all on function public.get_owner_reservation_edit_details(uuid) from public;
revoke all on function public.owner_update_reservation_details(uuid, uuid, date, date, integer, integer, integer, integer, text, text, text, text, text, integer, integer, jsonb, integer) from public;
grant execute on function public.get_owner_reservation_edit_details(uuid) to authenticated;
grant execute on function public.owner_update_reservation_details(uuid, uuid, date, date, integer, integer, integer, integer, text, text, text, text, text, integer, integer, jsonb, integer) to authenticated;
