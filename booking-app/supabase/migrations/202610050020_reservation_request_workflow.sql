-- Reservation-request workflow for launch before a payment gateway is live.
-- Requests do not allocate inventory. Only an owner-created manual payment hold
-- or a confirmed reservation can block inventory.

alter type public.reservation_status add value if not exists 'requested';
alter type public.reservation_status add value if not exists 'in_conversation';
alter type public.reservation_status add value if not exists 'alternative_offered';
alter type public.reservation_status add value if not exists 'awaiting_manual_payment';
alter type public.reservation_status add value if not exists 'declined';

create table if not exists public.calendar_sync_outbox (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  event_type text not null check (event_type in ('confirmed', 'changed', 'cancelled')),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (reservation_id, event_type, processed_at)
);
alter table public.calendar_sync_outbox enable row level security;
create unique index if not exists calendar_sync_outbox_one_pending_event
  on public.calendar_sync_outbox(reservation_id, event_type) where processed_at is null;

-- Preserve the exact guest choices that produced a request. This allows an
-- owner to offer new dates without re-entering the party, meals or add-ons.
create table if not exists public.reservation_request_inputs (
  reservation_id uuid primary key references public.reservations(id) on delete cascade,
  meal_plan text not null,
  bonfire_sessions integer not null default 0 check (bonfire_sessions >= 0),
  lake_outings integer not null default 0 check (lake_outings >= 0),
  lake_trip_guests integer not null default 0 check (lake_trip_guests >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.reservation_request_inputs enable row level security;

create or replace function public.get_reservation_cancellation_policy(p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare
  v_reservation reservations%rowtype;
  v_product bookable_products%rowtype;
  v_amount integer := 0;
  v_days integer;
  v_peak boolean := false;
begin
  select * into v_reservation from reservations where id = p_reservation_id;
  if not found then raise exception 'Reservation not found'; end if;
  select * into v_product from bookable_products where id = v_reservation.product_id;
  select coalesce(sum(amount_paise), 0) into v_amount from payments where reservation_id = p_reservation_id and state = 'paid';
  v_days := v_reservation.check_in - (now() at time zone 'Asia/Kolkata')::date;
  select exists(
    select 1 from daily_pricing_calendar
    where property_id = v_reservation.property_id
      and stay_date >= v_reservation.check_in and stay_date < v_reservation.check_out
      and tier_code ~* '(premium|ultra|holiday|long)'
  ) into v_peak;

  if v_product.sellable_kind in ('villa', 'room_bundle', 'entire_property') or v_peak then
    return jsonb_build_object('refund_percent', 0, 'refund_paise', 0, 'decision', 'non_refundable', 'message', 'This stay is non-refundable because it is a full-villa, group, long-weekend or festive-period booking.', 'date_change_allowed', false);
  elsif v_days > 14 then
    return jsonb_build_object('refund_percent', 100, 'refund_paise', v_amount, 'decision', 'full_less_gateway_charges', 'message', 'Full refund applies, less any non-refundable payment-gateway charges. Refund processing target: 5–9 days.', 'date_change_allowed', true);
  elsif v_days >= 7 then
    return jsonb_build_object('refund_percent', 50, 'refund_paise', round(v_amount * .5)::integer, 'decision', 'half_refund', 'message', 'A 50% refund applies. Refund processing target: 5–9 days.', 'date_change_allowed', false);
  else
    return jsonb_build_object('refund_percent', 0, 'refund_paise', 0, 'decision', 'no_refund', 'message', 'No refund applies within 7 days of check-in, for no-shows, or for early departures.', 'date_change_allowed', false);
  end if;
end;
$$;

create or replace function public.create_reservation_request_bundle_aware(
  p_product_id uuid, p_check_in date, p_check_out date, p_adults integer,
  p_children_7_to_12 integer, p_children_0_to_6 integer, p_pets integer,
  p_meal_plan text, p_bonfire_sessions integer, p_lake_outings integer,
  p_lake_trip_guests integer, p_guest_name text, p_guest_email text,
  p_guest_phone text, p_marketing_opt_in boolean
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_product bookable_products%rowtype; v_quote jsonb; v_guest_id uuid;
  v_reservation_id uuid; v_reference text; v_item jsonb; v_consent_version text := '2026-10-05';
begin
  select * into v_product from bookable_products where id = p_product_id and active;
  if not found then raise exception 'This stay is no longer available'; end if;
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Please enter the lead guest name'; end if;
  if position('@' in coalesce(p_guest_email, '')) < 2 then raise exception 'Please enter a valid email address'; end if;
  if coalesce(p_guest_phone, '') !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Please enter a valid mobile number with country code'; end if;
  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then raise exception 'This stay is not currently available. Please choose other dates.'; end if;
  v_quote := public.get_booking_quote(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests);
  v_reference := 'BW-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  insert into guests (property_id, full_name, email, phone_e164, email_marketing_opt_in, whatsapp_opt_in, marketing_consent_at, marketing_consent_version)
  values (v_product.property_id, trim(p_guest_name), lower(trim(p_guest_email)), trim(p_guest_phone), p_marketing_opt_in, p_marketing_opt_in, case when p_marketing_opt_in then now() else null end, case when p_marketing_opt_in then v_consent_version else null end) returning id into v_guest_id;
  if p_marketing_opt_in then insert into guest_consents (property_id, guest_id, channel, purpose, action, consent_version, source)
  values (v_product.property_id, v_guest_id, 'email', 'marketing', 'granted', v_consent_version, 'website'), (v_product.property_id, v_guest_id, 'whatsapp', 'marketing', 'granted', v_consent_version, 'website'); end if;
  insert into reservations (property_id, reference, guest_id, product_id, check_in, check_out, adults, children_7_to_12, children_0_to_6, pets, source, status)
  values (v_product.property_id, v_reference, v_guest_id, v_product.id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, 'website', 'requested') returning id into v_reservation_id;
  insert into price_snapshots (reservation_id, total_paise, calculation) values (v_reservation_id, (v_quote ->> 'total_paise')::integer, v_quote);
  insert into reservation_request_inputs (reservation_id, meal_plan, bonfire_sessions, lake_outings, lake_trip_guests)
  values (v_reservation_id, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests);
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (v_reservation_id, case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end, v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into audit_log (property_id, entity_type, entity_id, action, data)
  values (v_product.property_id, 'reservation', v_reservation_id, 'request_submitted', jsonb_build_object('reference', v_reference));
  return jsonb_build_object('reservation_id', v_reservation_id, 'reference', v_reference, 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

-- Lets an owner offer alternative dates before taking payment. Existing guest
-- selections are retained and the final total is always recalculated by the
-- same public pricing function the guest saw.
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
  v_quote := public.get_booking_quote(v_reservation.product_id, p_check_in, p_check_out, v_reservation.adults, v_reservation.children_7_to_12, v_reservation.children_0_to_6, v_reservation.pets, v_inputs.meal_plan, v_inputs.bonfire_sessions, v_inputs.lake_outings, v_inputs.lake_trip_guests);
  update reservations set check_in = p_check_in, check_out = p_check_out, status = 'alternative_offered', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
  update price_snapshots set total_paise = (v_quote ->> 'total_paise')::integer, calculation = v_quote, accepted_at = null where reservation_id = p_reservation_id;
  delete from reservation_items where reservation_id = p_reservation_id;
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (p_reservation_id, case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end, v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data) values (v_property_id, auth.uid(), 'reservation', p_reservation_id, 'alternative_dates_offered', jsonb_build_object('check_in', p_check_in, 'check_out', p_check_out, 'note', p_note));
  return jsonb_build_object('status', 'alternative_offered', 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

create or replace function public.owner_reservation_workflow_action(
  p_reservation_id uuid, p_action text, p_hold_hours integer default 12, p_note text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype; v_product bookable_products%rowtype;
  v_allocated integer; v_expiry timestamptz; v_policy jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to change this reservation'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  select * into v_product from bookable_products where id = v_reservation.product_id;
  perform public.lock_property_inventory(v_property_id);

  if p_action = 'start_conversation' then
    update reservations set status = 'in_conversation', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
  elsif p_action = 'decline' then
    delete from inventory_allocations where reservation_id = p_reservation_id and state = 'hold';
    update reservations set status = 'declined', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
  elsif p_action = 'hold_for_manual_payment' then
    if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') then raise exception 'Only an open request can be held for manual payment'; end if;
    if not public.is_product_inventory_available(v_product.id, v_reservation.check_in, v_reservation.check_out) then raise exception 'These dates are no longer available'; end if;
    v_expiry := now() + make_interval(hours => least(greatest(p_hold_hours, 1), 48));
    if v_product.inventory_mode = 'child_rooms' then
      insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
      select v_property_id, child.id, p_reservation_id, daterange(v_reservation.check_in, v_reservation.check_out, '[)'), 'hold', v_expiry
      from resources child where child.parent_resource_id = v_product.primary_resource_id and child.active and not exists
        (select 1 from inventory_allocations a where a.resource_id = child.id and a.stay_during && daterange(v_reservation.check_in, v_reservation.check_out, '[)') and a.state in ('confirmed','block','hold'))
      order by child.name limit v_product.room_units_required;
      select count(*) into v_allocated from inventory_allocations where reservation_id = p_reservation_id and state = 'hold';
      if v_allocated < v_product.room_units_required then raise exception 'Those rooms were just booked. Please offer alternate dates.'; end if;
    else
      insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
      select v_property_id, resource_id, p_reservation_id, daterange(v_reservation.check_in, v_reservation.check_out, '[)'), 'hold', v_expiry from bookable_product_resources where product_id = v_product.id;
    end if;
    insert into payments (reservation_id, provider, amount_paise, state, expires_at)
    select p_reservation_id, 'manual', total_paise, 'pending', v_expiry from price_snapshots where reservation_id = p_reservation_id;
    update reservations set status = 'awaiting_manual_payment', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
  elsif p_action = 'confirm_manual_payment' then
    if v_reservation.status <> 'awaiting_manual_payment' then raise exception 'Create a manual payment hold before confirming payment'; end if;
    update inventory_allocations set state = 'confirmed', expires_at = null where reservation_id = p_reservation_id and state = 'hold' and expires_at > now();
    if not found then raise exception 'The manual payment hold expired; check availability again'; end if;
    update payments set state = 'paid', updated_at = now() where reservation_id = p_reservation_id and provider = 'manual' and state in ('created','pending');
    update reservations set status = 'confirmed', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
    update price_snapshots set accepted_at = now() where reservation_id = p_reservation_id;
    insert into calendar_sync_outbox (property_id, reservation_id, event_type, payload) values
      (v_property_id, p_reservation_id, 'confirmed', jsonb_build_object('reference', v_reservation.reference));
  elsif p_action = 'cancel' then
    v_policy := public.get_reservation_cancellation_policy(p_reservation_id);
    delete from inventory_allocations where reservation_id = p_reservation_id;
    update reservations set status = 'cancelled', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
    insert into calendar_sync_outbox (property_id, reservation_id, event_type, payload) values
      (v_property_id, p_reservation_id, 'cancelled', v_policy);
  else
    raise exception 'Unsupported owner workflow action';
  end if;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'reservation', p_reservation_id, p_action, jsonb_build_object('note', p_note));
  return jsonb_build_object('status', (select status from reservations where id = p_reservation_id), 'expires_at', v_expiry, 'cancellation_policy', case when p_action = 'cancel' then v_policy else null end);
end;
$$;

-- Manual-payment holds should free inventory on expiry but remain visible to
-- the owner as a conversation, rather than becoming an accidental booking.
create or replace function public.release_expired_payment_holds(p_property_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_released integer := 0;
begin
  perform public.lock_property_inventory(p_property_id);
  update payments pay set state = 'expired', updated_at = now()
  from reservations r where pay.reservation_id = r.id and r.property_id = p_property_id
    and pay.state in ('created', 'pending') and pay.expires_at <= now();
  update reservations r set status = case when r.status = 'awaiting_manual_payment' then 'in_conversation' else 'cancelled' end, updated_at = now()
  where r.property_id = p_property_id and r.status in ('pending_payment', 'awaiting_manual_payment')
    and exists (select 1 from inventory_allocations a where a.reservation_id = r.id and a.state = 'hold' and a.expires_at <= now());
  delete from inventory_allocations a where a.property_id = p_property_id and a.state = 'hold' and a.expires_at <= now();
  get diagnostics v_released = row_count;
  return v_released;
end;
$$;

create or replace function public.get_owner_reservation_detail(p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_property_id uuid; v_result jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  select jsonb_build_object(
    'reservation', jsonb_build_object('id', r.id, 'reference', r.reference, 'status', r.status, 'check_in', r.check_in, 'check_out', r.check_out, 'adults', r.adults, 'children_7_to_12', r.children_7_to_12, 'children_0_to_6', r.children_0_to_6, 'pets', r.pets, 'source', r.source, 'guest_name', g.full_name, 'guest_email', g.email, 'guest_phone', g.phone_e164, 'product_name', p.name, 'internal_note', r.internal_note, 'total_paise', ps.total_paise),
    'items', coalesce((select jsonb_agg(jsonb_build_object('label', ri.label, 'quantity', ri.quantity, 'amount_paise', ri.amount_paise, 'item_type', ri.item_type) order by ri.created_at, ri.id) from reservation_items ri where ri.reservation_id = r.id), '[]'::jsonb),
    'payment', (select jsonb_build_object('provider', pay.provider, 'state', pay.state, 'amount_paise', pay.amount_paise, 'provider_reference', pay.provider_reference, 'expires_at', pay.expires_at) from payments pay where pay.reservation_id = r.id order by pay.created_at desc limit 1),
    'cancellation_policy', public.get_reservation_cancellation_policy(r.id)
  ) into v_result from reservations r left join guests g on g.id = r.guest_id left join bookable_products p on p.id = r.product_id left join price_snapshots ps on ps.reservation_id = r.id where r.id = p_reservation_id and r.property_id = v_property_id;
  if v_result is null then raise exception 'Booking not found'; end if;
  return v_result;
end;
$$;

create or replace function public.get_owner_open_reservation_requests()
returns table (
  reservation_id uuid, reference text, status text, check_in date, check_out date,
  guest_name text, product_name text, total_paise integer, created_at timestamptz
) language plpgsql security definer set search_path = public stable as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  return query
  select r.id, r.reference, r.status::text, r.check_in, r.check_out, g.full_name, p.name, ps.total_paise, r.created_at
  from reservations r
  left join guests g on g.id = r.guest_id
  left join bookable_products p on p.id = r.product_id
  left join price_snapshots ps on ps.reservation_id = r.id
  where r.property_id = v_property_id and r.status in ('requested', 'in_conversation', 'alternative_offered', 'awaiting_manual_payment')
  order by r.created_at desc;
end;
$$;

revoke all on function public.get_reservation_cancellation_policy(uuid) from public;
revoke all on function public.owner_reservation_workflow_action(uuid, text, integer, text) from public;
grant execute on function public.create_reservation_request_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean) to anon, authenticated;
grant execute on function public.get_owner_reservation_detail(uuid) to authenticated;
grant execute on function public.get_owner_open_reservation_requests() to authenticated;
-- This helper is used internally by owner workflows and owner detail. It is
-- not exposed directly because it can reveal payment/refund information for an
-- arbitrary reservation ID.
grant execute on function public.owner_reservation_workflow_action(uuid, text, integer, text) to authenticated;
grant execute on function public.owner_reprice_reservation_request(uuid, date, date, text) to authenticated;
