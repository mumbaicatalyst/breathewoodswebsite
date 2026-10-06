-- Owner-assisted booking intake for phone, email, WhatsApp, walk-in and referral reservations.
-- Intake creates a request; the existing owner workflow confirms availability and payment.

alter type public.booking_source add value if not exists 'email';
alter type public.booking_source add value if not exists 'owner_referral';

alter table public.reservation_request_inputs
  add column if not exists owner_payment_state text,
  add column if not exists owner_payment_reference text;

create or replace function public.get_owner_bookable_products()
returns table (product_id uuid, product_code text, product_name text, sellable_kind text)
language plpgsql security definer set search_path = public stable as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  return query
  select p.id, p.code, p.name, p.sellable_kind
  from bookable_products p
  where p.property_id = v_property_id and p.active
  order by p.display_order, p.name;
end;
$$;

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
  p_internal_note text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_product bookable_products%rowtype; v_guest_id uuid;
  v_reservation_id uuid; v_reference text; v_allocated integer := 0;
  v_payment_state public.payment_state;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to create a guest booking'; end if;
  if p_check_out <= p_check_in then raise exception 'Check-out must be after check-in'; end if;
  if p_adults < 1 or p_children_7_to_12 < 0 or p_children_0_to_6 < 0 or p_pets < 0 then raise exception 'Guest counts are invalid'; end if;
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Enter the guest''s full name'; end if;
  if p_guest_email is not null and length(trim(p_guest_email)) > 0 and position('@' in p_guest_email) < 2 then raise exception 'Enter a valid email address or leave it blank'; end if;
  if p_guest_phone is not null and length(trim(p_guest_phone)) > 0 and trim(p_guest_phone) !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Enter the phone number with country code or leave it blank'; end if;
  if p_source not in ('owner_dashboard', 'phone', 'email', 'whatsapp', 'walk_in', 'owner_referral') then raise exception 'Unsupported booking source'; end if;
  if p_payment_state not in ('not_recorded', 'pending', 'paid') then raise exception 'Unsupported payment state'; end if;
  if p_payment_state in ('pending', 'paid') and coalesce(p_total_paise, 0) < 0 then raise exception 'Payment amount is invalid'; end if;

  select * into v_product from bookable_products where id = p_product_id and property_id = v_property_id and active;
  if not found then raise exception 'This stay option is not available'; end if;
  perform public.lock_property_inventory(v_property_id);

  v_reference := 'BW-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-M' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 5));
  insert into guests (property_id, full_name, email, phone_e164)
  values (v_property_id, trim(p_guest_name), nullif(lower(trim(p_guest_email)), ''), nullif(trim(p_guest_phone), ''))
  returning id into v_guest_id;

  insert into reservations (property_id, reference, guest_id, product_id, check_in, check_out, adults, children_7_to_12, children_0_to_6, pets, source, status, internal_note)
  values (v_property_id, v_reference, v_guest_id, v_product.id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_source::public.booking_source, 'requested', nullif(trim(p_internal_note), ''))
  returning id into v_reservation_id;

  insert into reservation_request_inputs (reservation_id, meal_plan, bonfire_sessions, lake_outings, lake_trip_guests, owner_payment_state, owner_payment_reference)
  values (v_reservation_id, 'breakfast', 0, 0, 0, p_payment_state, nullif(trim(p_payment_reference), ''));

  if p_total_paise is not null then
    if p_total_paise < 0 then raise exception 'Total amount cannot be negative'; end if;
    insert into price_snapshots (reservation_id, total_paise, calculation, accepted_at)
    values (v_reservation_id, p_total_paise, jsonb_build_object('source', 'owner_assisted', 'entered_by', auth.uid()), now());
  end if;

  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'reservation', v_reservation_id, 'owner_assisted_request_created', jsonb_build_object('reference', v_reference, 'source', p_source, 'payment_state', p_payment_state, 'payment_reference', p_payment_reference));
  return jsonb_build_object('reservation_id', v_reservation_id, 'reference', v_reference);
end;
$$;

-- Used only after the owner has verified availability and has already received
-- payment outside the booking flow. This shares the same allocation guard as
-- the regular manual-payment confirmation path.
create or replace function public.owner_confirm_assisted_payment(p_reservation_id uuid, p_payment_reference text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_property_id uuid; v_reservation reservations%rowtype; v_product bookable_products%rowtype; v_inputs reservation_request_inputs%rowtype; v_allocated integer := 0; v_total integer := 0; v_reference text;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to confirm a guest booking'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id for update;
  if not found or v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') or v_reservation.source not in ('owner_dashboard', 'phone', 'email', 'whatsapp', 'walk_in', 'owner_referral') then raise exception 'Only an open owner-assisted booking can be marked paid'; end if;
  select * into v_inputs from reservation_request_inputs where reservation_id = p_reservation_id;
  v_reference := coalesce(nullif(trim(p_payment_reference), ''), v_inputs.owner_payment_reference);
  select * into v_product from bookable_products where id = v_reservation.product_id and active;
  perform public.lock_property_inventory(v_property_id);
  if not public.is_product_inventory_available(v_product.id, v_reservation.check_in, v_reservation.check_out) then raise exception 'These dates are no longer available'; end if;
  if v_product.inventory_mode = 'child_rooms' then
    insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state)
    select v_property_id, child.id, p_reservation_id, daterange(v_reservation.check_in, v_reservation.check_out, '[)'), 'confirmed'
    from resources child where child.parent_resource_id = v_product.primary_resource_id and child.active and not exists
      (select 1 from inventory_allocations a where a.resource_id = child.id and a.stay_during && daterange(v_reservation.check_in, v_reservation.check_out, '[)') and a.state in ('confirmed','block','hold') and (a.state <> 'hold' or a.expires_at > now()))
    order by child.name limit v_product.room_units_required;
    select count(*) into v_allocated from inventory_allocations where reservation_id = p_reservation_id and state = 'confirmed';
    if v_allocated < v_product.room_units_required then raise exception 'Those rooms are no longer available'; end if;
  else
    insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state)
    select v_property_id, bpr.resource_id, p_reservation_id, daterange(v_reservation.check_in, v_reservation.check_out, '[)'), 'confirmed'
    from bookable_product_resources bpr where bpr.product_id = v_product.id;
    select count(*) into v_allocated from inventory_allocations where reservation_id = p_reservation_id and state = 'confirmed';
    if v_allocated = 0 then raise exception 'This stay has no configured inventory'; end if;
  end if;
  select coalesce(total_paise, 0) into v_total from price_snapshots where reservation_id = p_reservation_id;
  insert into payments (reservation_id, provider, provider_reference, amount_paise, state, provider_payload)
  values (p_reservation_id, 'manual', v_reference, v_total, 'paid', jsonb_build_object('source', 'owner_assisted'));
  update reservations set status = 'confirmed', updated_at = now() where id = p_reservation_id;
  update price_snapshots set accepted_at = now() where reservation_id = p_reservation_id;
  insert into calendar_sync_outbox (property_id, reservation_id, event_type, payload) values (v_property_id, p_reservation_id, 'confirmed', jsonb_build_object('reference', v_reservation.reference, 'source', 'owner_assisted'));
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data) values (v_property_id, auth.uid(), 'reservation', p_reservation_id, 'owner_assisted_payment_confirmed', jsonb_build_object('payment_reference', v_reference));
  return jsonb_build_object('status', 'confirmed', 'reference', v_reservation.reference);
exception when exclusion_violation then
  raise exception 'Those dates were just booked or blocked. Refresh the calendar and try again';
end;
$$;

revoke all on function public.get_owner_bookable_products() from public;
revoke all on function public.owner_create_assisted_booking(uuid, date, date, integer, integer, integer, integer, text, text, text, text, integer, text, text, text) from public;
grant execute on function public.get_owner_bookable_products() to authenticated;
grant execute on function public.owner_create_assisted_booking(uuid, date, date, integer, integer, integer, integer, text, text, text, text, integer, text, text, text) to authenticated;
revoke all on function public.owner_confirm_assisted_payment(uuid, text) from public;
grant execute on function public.owner_confirm_assisted_payment(uuid, text) to authenticated;
