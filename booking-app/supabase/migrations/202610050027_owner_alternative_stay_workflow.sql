-- Turn an unavailable reservation request into a guided alternative-stay offer.
-- The owner chooses the alternative; nothing is held until the guest agrees.

create or replace function public.get_owner_reservation_alternatives(p_reservation_id uuid)
returns table (
  product_id uuid,
  product_code text,
  product_name text,
  sellable_kind text,
  total_paise integer
)
language plpgsql security definer set search_path = public stable as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype;
  v_inputs reservation_request_inputs%rowtype; v_candidate record; v_quote jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to change this reservation'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id;
  if not found then raise exception 'Reservation not found'; end if;
  if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') then
    raise exception 'Alternatives are available only for an open reservation request';
  end if;
  select * into v_inputs from reservation_request_inputs where reservation_id = p_reservation_id;
  if not found then raise exception 'The original request inputs are unavailable'; end if;

  for v_candidate in
    select available.* from public.get_available_products(
      v_reservation.check_in,
      v_reservation.check_out,
      v_reservation.adults + v_reservation.children_7_to_12 + v_reservation.children_0_to_6
    ) available
    where available.product_id <> v_reservation.product_id
    order by available.product_name
  loop
    v_quote := public.get_booking_quote(
      v_candidate.product_id, v_reservation.check_in, v_reservation.check_out,
      v_reservation.adults, v_reservation.children_7_to_12, v_reservation.children_0_to_6,
      v_reservation.pets, v_inputs.meal_plan, v_inputs.bonfire_sessions,
      v_inputs.lake_outings, v_inputs.lake_trip_guests
    );
    product_id := v_candidate.product_id;
    product_code := v_candidate.product_code;
    product_name := v_candidate.product_name;
    sellable_kind := v_candidate.sellable_kind;
    total_paise := (v_quote ->> 'total_paise')::integer;
    return next;
  end loop;
end;
$$;

create or replace function public.owner_offer_alternative_stay(
  p_reservation_id uuid,
  p_product_id uuid,
  p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype;
  v_product bookable_products%rowtype; v_inputs reservation_request_inputs%rowtype;
  v_quote jsonb; v_item jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') then
    raise exception 'Only an open reservation request can be changed';
  end if;
  select * into v_product from bookable_products where id = p_product_id and property_id = v_property_id and active;
  if not found then raise exception 'That alternative stay is unavailable'; end if;
  select * into v_inputs from reservation_request_inputs where reservation_id = p_reservation_id;
  if not found then raise exception 'The original request inputs are unavailable'; end if;

  perform public.lock_property_inventory(v_property_id);
  if not public.is_product_inventory_available(v_product.id, v_reservation.check_in, v_reservation.check_out) then
    raise exception 'That alternative was just booked or blocked. Please choose another stay.';
  end if;
  v_quote := public.get_booking_quote(
    v_product.id, v_reservation.check_in, v_reservation.check_out,
    v_reservation.adults, v_reservation.children_7_to_12, v_reservation.children_0_to_6,
    v_reservation.pets, v_inputs.meal_plan, v_inputs.bonfire_sessions,
    v_inputs.lake_outings, v_inputs.lake_trip_guests
  );
  update reservations
  set product_id = v_product.id,
      status = 'alternative_offered',
      internal_note = coalesce(p_note, internal_note),
      updated_at = now()
  where id = p_reservation_id;
  update price_snapshots
  set total_paise = (v_quote ->> 'total_paise')::integer,
      calculation = v_quote,
      accepted_at = null
  where reservation_id = p_reservation_id;
  delete from reservation_items where reservation_id = p_reservation_id;
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (
      p_reservation_id,
      case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end,
      v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer
    );
  end loop;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'reservation', p_reservation_id, 'alternative_stay_offered', jsonb_build_object('product_id', v_product.id, 'product_name', v_product.name, 'note', p_note));
  return jsonb_build_object('status', 'alternative_offered', 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

revoke all on function public.get_owner_reservation_alternatives(uuid) from public;
grant execute on function public.get_owner_reservation_alternatives(uuid) to authenticated;
revoke all on function public.owner_offer_alternative_stay(uuid, uuid, text) from public;
grant execute on function public.owner_offer_alternative_stay(uuid, uuid, text) to authenticated;

-- Expose a simple availability signal in the owner detail so the dashboard can
-- warn before the owner attempts a payment hold.
create or replace function public.get_owner_reservation_detail(p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_property_id uuid; v_result jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  select jsonb_build_object(
    'reservation', jsonb_build_object(
      'id', r.id, 'reference', r.reference, 'status', r.status,
      'check_in', r.check_in, 'check_out', r.check_out,
      'adults', r.adults, 'children_7_to_12', r.children_7_to_12,
      'children_0_to_6', r.children_0_to_6, 'pets', r.pets, 'source', r.source,
      'guest_name', g.full_name, 'guest_email', g.email, 'guest_phone', g.phone_e164,
      'product_name', p.name, 'internal_note', r.internal_note, 'total_paise', ps.total_paise,
      'requested_stay_available', public.is_product_inventory_available(r.product_id, r.check_in, r.check_out)
    ),
    'items', coalesce((select jsonb_agg(jsonb_build_object('label', ri.label, 'quantity', ri.quantity, 'amount_paise', ri.amount_paise, 'item_type', ri.item_type) order by ri.created_at, ri.id) from reservation_items ri where ri.reservation_id = r.id), '[]'::jsonb),
    'payment', (select jsonb_build_object('provider', pay.provider, 'state', pay.state, 'amount_paise', pay.amount_paise, 'provider_reference', pay.provider_reference, 'expires_at', pay.expires_at) from payments pay where pay.reservation_id = r.id order by pay.created_at desc limit 1),
    'cancellation_policy', public.get_reservation_cancellation_policy(r.id)
  ) into v_result
  from reservations r
  left join guests g on g.id = r.guest_id
  left join bookable_products p on p.id = r.product_id
  left join price_snapshots ps on ps.reservation_id = r.id
  where r.id = p_reservation_id and r.property_id = v_property_id;
  if v_result is null then raise exception 'Booking not found'; end if;
  return v_result;
end;
$$;

revoke all on function public.get_owner_reservation_detail(uuid) from public;
grant execute on function public.get_owner_reservation_detail(uuid) to authenticated;
