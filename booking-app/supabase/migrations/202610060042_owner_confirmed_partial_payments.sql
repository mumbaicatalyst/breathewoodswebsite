-- Owner-assisted bookings can be confirmed as durable inventory allocations
-- while a manually collected balance remains due. Manual payments are ledger
-- entries; outstanding balance is derived from the accepted booking total.

create or replace function public.owner_confirm_booking_with_partial_payment(
  p_reservation_id uuid,
  p_amount_received_paise integer default 0,
  p_payment_reference text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype; v_product bookable_products%rowtype;
  v_total integer := 0; v_paid integer := 0; v_balance integer := 0; v_allocated integer := 0; v_pending_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then
    raise exception 'You do not have permission to confirm a guest booking';
  end if;
  select * into v_reservation from reservations
    where id = p_reservation_id and property_id = v_property_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if v_reservation.source not in ('owner_dashboard', 'phone', 'email', 'whatsapp', 'walk_in', 'owner_referral') then
    raise exception 'This action is only for owner-assisted bookings';
  end if;
  if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered', 'awaiting_manual_payment') then
    raise exception 'Only an open owner booking can be confirmed';
  end if;
  select coalesce(total_paise, 0) into v_total from price_snapshots where reservation_id = p_reservation_id;
  if p_amount_received_paise is null or p_amount_received_paise < 0 or p_amount_received_paise > v_total then
    raise exception 'Amount received must be between zero and the booking total';
  end if;

  perform public.lock_property_inventory(v_property_id);
  if v_reservation.status = 'awaiting_manual_payment' then
    select * into v_product from bookable_products where id = v_reservation.product_id and property_id = v_property_id and active;
    if not found then raise exception 'This stay option is no longer available'; end if;
    update inventory_allocations set state = 'confirmed', expires_at = null
      where reservation_id = p_reservation_id and state = 'hold' and expires_at > now();
    get diagnostics v_allocated = row_count;
    if v_allocated = 0 then raise exception 'The payment hold expired; check availability and create a new hold'; end if;
    if v_product.inventory_mode = 'child_rooms' and v_allocated < v_product.room_units_required then
      raise exception 'The full stay hold has expired; check availability and create a new hold';
    end if;
  else
    select * into v_product from bookable_products where id = v_reservation.product_id and property_id = v_property_id and active;
    if not found then raise exception 'This stay option is no longer available'; end if;
    if not public.is_product_inventory_available(v_product.id, v_reservation.check_in, v_reservation.check_out) then
      raise exception 'These dates are no longer available';
    end if;
    if v_product.inventory_mode = 'child_rooms' then
      insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state)
      select v_property_id, child.id, p_reservation_id, daterange(v_reservation.check_in, v_reservation.check_out, '[)'), 'confirmed'
      from resources child
      where child.parent_resource_id = v_product.primary_resource_id and child.active
        and not exists (
          select 1 from inventory_allocations a
          where a.resource_id = child.id and a.stay_during && daterange(v_reservation.check_in, v_reservation.check_out, '[)')
            and a.state in ('confirmed', 'block', 'hold') and (a.state <> 'hold' or a.expires_at > now())
        )
      order by child.name limit v_product.room_units_required;
      get diagnostics v_allocated = row_count;
      if v_allocated < v_product.room_units_required then raise exception 'Those rooms are no longer available'; end if;
    else
      insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state)
      select v_property_id, bpr.resource_id, p_reservation_id, daterange(v_reservation.check_in, v_reservation.check_out, '[)'), 'confirmed'
      from bookable_product_resources bpr where bpr.product_id = v_product.id;
      get diagnostics v_allocated = row_count;
      if v_allocated = 0 then raise exception 'This stay has no configured inventory'; end if;
    end if;
  end if;

  if p_amount_received_paise > 0 then
    insert into payments (reservation_id, provider, provider_reference, amount_paise, state, provider_payload)
    values (p_reservation_id, 'manual', nullif(trim(p_payment_reference), ''), p_amount_received_paise, 'paid',
      jsonb_build_object('source', 'owner_recorded_partial_payment'));
  end if;
  v_paid := p_amount_received_paise;
  v_balance := v_total - v_paid;
  select id into v_pending_id from payments
    where reservation_id = p_reservation_id and provider = 'manual' and state in ('created', 'pending')
    order by created_at desc limit 1 for update;
  if v_pending_id is not null then
    if v_balance = 0 then
      update payments set amount_paise = 0, state = 'cancelled', expires_at = null, updated_at = now() where id = v_pending_id;
    else
      update payments set amount_paise = v_balance, state = 'pending', expires_at = null,
        provider_payload = coalesce(provider_payload, '{}'::jsonb) || jsonb_build_object('source', 'owner_managed_balance'),
        updated_at = now() where id = v_pending_id;
    end if;
  elsif v_balance > 0 then
    insert into payments (reservation_id, provider, amount_paise, state, expires_at, provider_payload)
      values (p_reservation_id, 'manual', v_balance, 'pending', null,
        jsonb_build_object('source', 'owner_managed_balance'));
  end if;
  update reservations set status = 'confirmed', updated_at = now() where id = p_reservation_id;
  update price_snapshots set accepted_at = now() where reservation_id = p_reservation_id;
  insert into calendar_sync_outbox (property_id, reservation_id, event_type, payload)
    values (v_property_id, p_reservation_id, 'confirmed', jsonb_build_object('reference', v_reservation.reference, 'source', 'owner_assisted'));
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data)
    values (v_property_id, auth.uid(), 'reservation', p_reservation_id, 'owner_booking_confirmed_with_balance',
      jsonb_build_object('amount_received_paise', v_paid, 'balance_paise', v_balance, 'payment_reference', p_payment_reference));
  return jsonb_build_object('status', 'confirmed', 'reference', v_reservation.reference,
    'paid_paise', v_paid, 'balance_paise', v_balance);
exception when exclusion_violation then
  raise exception 'Those dates were just booked or blocked. Refresh the calendar and try again';
end;
$$;

create or replace function public.owner_record_booking_payment(
  p_reservation_id uuid,
  p_amount_received_paise integer,
  p_payment_reference text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype; v_total integer := 0;
  v_paid integer := 0; v_balance integer := 0; v_pending_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then
    raise exception 'You do not have permission to record a booking payment';
  end if;
  select * into v_reservation from reservations
    where id = p_reservation_id and property_id = v_property_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if v_reservation.status <> 'confirmed' or v_reservation.source not in ('owner_dashboard', 'phone', 'email', 'whatsapp', 'walk_in', 'owner_referral') then
    raise exception 'Payments can only be recorded for a confirmed owner booking';
  end if;
  select coalesce(total_paise, 0) into v_total from price_snapshots where reservation_id = p_reservation_id;
  select coalesce(sum(amount_paise), 0) into v_paid from payments
    where reservation_id = p_reservation_id and provider = 'manual' and state = 'paid';
  v_balance := v_total - v_paid;
  if p_amount_received_paise is null or p_amount_received_paise <= 0 or p_amount_received_paise > v_balance then
    raise exception 'Enter an amount greater than zero and no more than the remaining balance';
  end if;
  perform public.lock_property_inventory(v_property_id);
  insert into payments (reservation_id, provider, provider_reference, amount_paise, state, provider_payload)
    values (p_reservation_id, 'manual', nullif(trim(p_payment_reference), ''), p_amount_received_paise, 'paid',
      jsonb_build_object('source', 'owner_recorded_balance_payment'));
  v_paid := v_paid + p_amount_received_paise;
  v_balance := v_total - v_paid;
  select id into v_pending_id from payments
    where reservation_id = p_reservation_id and provider = 'manual' and state = 'pending'
    order by created_at desc limit 1 for update;
  if v_pending_id is not null then
    if v_balance = 0 then
      update payments set amount_paise = 0, state = 'cancelled', expires_at = null, updated_at = now() where id = v_pending_id;
    else
      update payments set amount_paise = v_balance, expires_at = null, updated_at = now() where id = v_pending_id;
    end if;
  elsif v_balance > 0 then
    insert into payments (reservation_id, provider, amount_paise, state, provider_payload)
      values (p_reservation_id, 'manual', v_balance, 'pending', jsonb_build_object('source', 'owner_managed_balance'));
  end if;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data)
    values (v_property_id, auth.uid(), 'reservation', p_reservation_id, 'owner_booking_payment_recorded',
      jsonb_build_object('amount_received_paise', p_amount_received_paise, 'paid_total_paise', v_paid, 'balance_paise', v_balance, 'payment_reference', p_payment_reference));
  return jsonb_build_object('status', case when v_balance = 0 then 'paid' else 'partial' end,
    'paid_paise', v_paid, 'balance_paise', v_balance);
end;
$$;

create or replace function public.get_owner_reservation_detail(p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_property_id uuid; v_result jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  select jsonb_build_object(
    'reservation', jsonb_build_object(
      'id', r.id, 'reference', r.reference, 'status', r.status, 'check_in', r.check_in, 'check_out', r.check_out,
      'adults', r.adults, 'children_7_to_12', r.children_7_to_12, 'children_0_to_6', r.children_0_to_6,
      'pets', r.pets, 'source', r.source, 'guest_name', g.full_name, 'guest_email', g.email,
      'guest_phone', g.phone_e164, 'product_name', p.name, 'internal_note', r.internal_note,
      'total_paise', ps.total_paise,
      'requested_stay_available', public.is_product_inventory_available(r.product_id, r.check_in, r.check_out)
    ),
    'items', coalesce((select jsonb_agg(jsonb_build_object('label', ri.label, 'quantity', ri.quantity,
      'amount_paise', ri.amount_paise, 'item_type', ri.item_type) order by ri.created_at, ri.id)
      from reservation_items ri where ri.reservation_id = r.id), '[]'::jsonb),
    'payment', (select jsonb_build_object('provider', pay.provider, 'state', pay.state,
      'amount_paise', pay.amount_paise, 'provider_reference', pay.provider_reference, 'expires_at', pay.expires_at)
      from payments pay where pay.reservation_id = r.id order by pay.created_at desc limit 1),
    'payment_summary', jsonb_build_object(
      'total_paise', coalesce(ps.total_paise, 0),
      'paid_paise', coalesce((select sum(pay.amount_paise) from payments pay
        where pay.reservation_id = r.id and pay.state = 'paid'), 0),
      'balance_paise', greatest(coalesce(ps.total_paise, 0) - coalesce((select sum(pay.amount_paise) from payments pay
        where pay.reservation_id = r.id and pay.state = 'paid'), 0), 0),
      'state', case
        when coalesce((select sum(pay.amount_paise) from payments pay where pay.reservation_id = r.id and pay.state = 'paid'), 0) = 0 then 'unpaid'
        when coalesce((select sum(pay.amount_paise) from payments pay where pay.reservation_id = r.id and pay.state = 'paid'), 0) < coalesce(ps.total_paise, 0) then 'partial'
        else 'paid' end
    ),
    'cancellation_policy', public.get_reservation_cancellation_policy(r.id)
  ) into v_result
  from reservations r left join guests g on g.id = r.guest_id
  left join bookable_products p on p.id = r.product_id
  left join price_snapshots ps on ps.reservation_id = r.id
  where r.id = p_reservation_id and r.property_id = v_property_id;
  if v_result is null then raise exception 'Booking not found'; end if;
  return v_result;
end;
$$;

revoke all on function public.owner_confirm_booking_with_partial_payment(uuid, integer, text) from public;
revoke all on function public.owner_record_booking_payment(uuid, integer, text) from public;
revoke all on function public.get_owner_reservation_detail(uuid) from public;
grant execute on function public.owner_confirm_booking_with_partial_payment(uuid, integer, text) to authenticated;
grant execute on function public.owner_record_booking_payment(uuid, integer, text) to authenticated;
grant execute on function public.get_owner_reservation_detail(uuid) to authenticated;
