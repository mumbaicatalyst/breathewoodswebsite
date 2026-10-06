-- Payment hold lifecycle hardening.
--
-- This migration makes the database—not the browser—the authority for a
-- temporary hold, its expiry, and the eventual confirmed booking. The
-- PhonePe Edge Function will call the server-only functions below after it
-- creates checkout and after it verifies a PhonePe callback signature.

create or replace function public.lock_property_inventory(p_property_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- One short transaction lock per property prevents two overlapping requests
  -- from selecting the same physical room before either allocation is written.
  perform pg_advisory_xact_lock(hashtextextended(p_property_id::text, 0));
end;
$$;

create or replace function public.release_expired_payment_holds(p_property_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_released integer := 0;
begin
  perform public.lock_property_inventory(p_property_id);

  update payments pay
  set state = 'expired', updated_at = now()
  from reservations reservation
  where pay.reservation_id = reservation.id
    and reservation.property_id = p_property_id
    and pay.state in ('created', 'pending')
    and pay.expires_at <= now();

  update reservations reservation
  set status = 'cancelled', updated_at = now()
  where reservation.property_id = p_property_id
    and reservation.status = 'pending_payment'
    and exists (
      select 1
      from inventory_allocations allocation
      where allocation.reservation_id = reservation.id
        and allocation.state = 'hold'
        and allocation.expires_at <= now()
    );

  delete from inventory_allocations allocation
  where allocation.property_id = p_property_id
    and allocation.state = 'hold'
    and allocation.expires_at <= now();

  get diagnostics v_released = row_count;
  return v_released;
end;
$$;

-- Replaces the previous public endpoint with one that takes the same short
-- property lock before quote validation and allocation. This makes a room,
-- villa, bundle, or whole-property request atomic with every other request.
create or replace function public.create_uat_booking_hold_bundle_aware(
  p_product_id uuid, p_check_in date, p_check_out date, p_adults integer,
  p_children_7_to_12 integer, p_children_0_to_6 integer, p_pets integer,
  p_meal_plan text, p_bonfire_sessions integer, p_lake_outings integer,
  p_lake_trip_guests integer, p_guest_name text, p_guest_email text,
  p_guest_phone text, p_marketing_opt_in boolean
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_product bookable_products%rowtype; v_quote jsonb; v_guest_id uuid;
  v_reservation_id uuid; v_payment_id uuid; v_reference text; v_expiry timestamptz;
  v_hold_minutes integer; v_payment_settings jsonb; v_item jsonb;
  v_consent_version text := '2026-10-04'; v_allocated integer;
begin
  select * into v_product from bookable_products where id = p_product_id and active;
  if not found then raise exception 'This stay is no longer available'; end if;
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Please enter the lead guest name'; end if;
  if position('@' in coalesce(p_guest_email, '')) < 2 then raise exception 'Please enter a valid email address'; end if;
  if coalesce(p_guest_phone, '') !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Please enter a valid mobile number with country code'; end if;

  perform public.lock_property_inventory(v_product.property_id);
  perform public.release_expired_payment_holds(v_product.property_id);

  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then
    raise exception 'This stay was just booked or blocked. Please search again.';
  end if;

  -- This is the final server-side quote. It is written as an immutable price
  -- snapshot and is the only amount a payment attempt may charge.
  v_quote := public.get_booking_quote(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests);
  select value into v_payment_settings from property_settings where property_id = v_product.property_id and setting_key = 'payment_holds';
  v_hold_minutes := coalesce((v_payment_settings ->> 'direct_checkout_minutes')::integer, 10);
  v_expiry := now() + make_interval(mins => v_hold_minutes);
  v_reference := 'BW-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));

  insert into guests (property_id, full_name, email, phone_e164, email_marketing_opt_in, whatsapp_opt_in, marketing_consent_at, marketing_consent_version)
  values (v_product.property_id, trim(p_guest_name), lower(trim(p_guest_email)), trim(p_guest_phone), p_marketing_opt_in, p_marketing_opt_in, case when p_marketing_opt_in then now() else null end, case when p_marketing_opt_in then v_consent_version else null end)
  returning id into v_guest_id;
  if p_marketing_opt_in then
    insert into guest_consents (property_id, guest_id, channel, purpose, action, consent_version, source)
    values (v_product.property_id, v_guest_id, 'email', 'marketing', 'granted', v_consent_version, 'website'), (v_product.property_id, v_guest_id, 'whatsapp', 'marketing', 'granted', v_consent_version, 'website');
  end if;

  insert into reservations (property_id, reference, guest_id, product_id, check_in, check_out, adults, children_7_to_12, children_0_to_6, pets, source, status)
  values (v_product.property_id, v_reference, v_guest_id, v_product.id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, 'website', 'pending_payment')
  returning id into v_reservation_id;

  if v_product.inventory_mode = 'child_rooms' then
    insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
    select v_product.property_id, child.id, v_reservation_id, daterange(p_check_in, p_check_out, '[)'), 'hold', v_expiry
    from resources child
    where child.parent_resource_id = v_product.primary_resource_id and child.active
      and not exists (
        select 1 from inventory_allocations allocation
        where allocation.resource_id = child.id
          and allocation.stay_during && daterange(p_check_in, p_check_out, '[)')
          and allocation.state in ('confirmed', 'block', 'hold')
      )
    order by child.name limit v_product.room_units_required;
    select count(*) into v_allocated from inventory_allocations where reservation_id = v_reservation_id and state = 'hold';
    if v_allocated < v_product.room_units_required then
      raise exception 'Those rooms were just booked. Please search again.';
    end if;
  else
    insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
    select v_product.property_id, bpr.resource_id, v_reservation_id, daterange(p_check_in, p_check_out, '[)'), 'hold', v_expiry
    from bookable_product_resources bpr where bpr.product_id = v_product.id;
  end if;

  insert into price_snapshots (reservation_id, total_paise, calculation)
  values (v_reservation_id, (v_quote ->> 'total_paise')::integer, v_quote);
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (v_reservation_id,
      case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end,
      v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into payments (reservation_id, provider, amount_paise, state, expires_at)
  values (v_reservation_id, 'phonepe', (v_quote ->> 'total_paise')::integer, 'created', v_expiry)
  returning id into v_payment_id;
  insert into audit_log (property_id, entity_type, entity_id, action, data)
  values (v_product.property_id, 'reservation', v_reservation_id, 'payment_hold_created', jsonb_build_object('reference', v_reference, 'expires_at', v_expiry, 'total_paise', (v_quote ->> 'total_paise')::integer));
  return jsonb_build_object('reservation_id', v_reservation_id, 'reference', v_reference, 'payment_id', v_payment_id, 'expires_at', v_expiry, 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

-- Called only by the server-side PhonePe checkout creator. A browser cannot
-- register a payment identifier or move a payment to pending.
create or replace function public.register_payment_checkout(
  p_payment_id uuid, p_provider_reference text, p_provider_payload jsonb default '{}'::jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_payment payments%rowtype; v_property_id uuid;
begin
  select * into v_payment from payments where id = p_payment_id for update;
  if not found then raise exception 'Payment hold was not found'; end if;
  select property_id into v_property_id from reservations where id = v_payment.reservation_id;
  perform public.lock_property_inventory(v_property_id);
  if v_payment.state not in ('created', 'pending') or v_payment.expires_at <= now() then
    raise exception 'This payment window has expired';
  end if;
  update payments set provider_reference = p_provider_reference, provider_payload = coalesce(p_provider_payload, '{}'::jsonb), state = 'pending', updated_at = now()
  where id = p_payment_id;
  return jsonb_build_object('payment_id', p_payment_id, 'merchant_reference', p_provider_reference, 'amount_paise', v_payment.amount_paise, 'expires_at', v_payment.expires_at);
end;
$$;

-- Called only after PhonePe's callback has been signature-verified by an Edge
-- Function. It is idempotent: a repeated genuine callback returns confirmed.
create or replace function public.confirm_verified_payment(
  p_provider text, p_provider_reference text, p_amount_paise integer,
  p_provider_payload jsonb default '{}'::jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_payment payments%rowtype; v_reservation reservations%rowtype; v_has_live_hold boolean;
begin
  select pay.* into v_payment from payments pay
  where pay.provider = p_provider and pay.provider_reference = p_provider_reference for update;
  if not found then raise exception 'Payment reference was not found'; end if;
  select * into v_reservation from reservations where id = v_payment.reservation_id for update;
  perform public.lock_property_inventory(v_reservation.property_id);

  if v_payment.state = 'paid' and v_reservation.status = 'confirmed' then
    return jsonb_build_object('status', 'confirmed', 'reservation_id', v_reservation.id, 'reference', v_reservation.reference);
  end if;
  if p_amount_paise <> v_payment.amount_paise then
    update reservations set status = 'payment_exception', updated_at = now() where id = v_reservation.id;
    update payments set provider_payload = coalesce(p_provider_payload, '{}'::jsonb), updated_at = now() where id = v_payment.id;
    insert into audit_log (property_id, entity_type, entity_id, action, data)
    values (v_reservation.property_id, 'payment', v_payment.id, 'payment_amount_mismatch', jsonb_build_object('expected_paise', v_payment.amount_paise, 'received_paise', p_amount_paise));
    return jsonb_build_object('status', 'payment_exception', 'reason', 'amount_mismatch', 'reference', v_reservation.reference);
  end if;
  select exists(
    select 1 from inventory_allocations allocation
    where allocation.reservation_id = v_reservation.id and allocation.state = 'hold' and allocation.expires_at > now()
  ) into v_has_live_hold;
  if not v_has_live_hold or v_payment.expires_at <= now() then
    update payments set state = 'paid', provider_payload = coalesce(p_provider_payload, '{}'::jsonb), updated_at = now() where id = v_payment.id;
    update reservations set status = 'payment_exception', updated_at = now() where id = v_reservation.id;
    insert into audit_log (property_id, entity_type, entity_id, action, data)
    values (v_reservation.property_id, 'payment', v_payment.id, 'late_payment_requires_review', jsonb_build_object('reference', v_reservation.reference));
    return jsonb_build_object('status', 'payment_exception', 'reason', 'hold_expired', 'reference', v_reservation.reference);
  end if;

  update payments set state = 'paid', provider_payload = coalesce(p_provider_payload, '{}'::jsonb), updated_at = now() where id = v_payment.id;
  update inventory_allocations set state = 'confirmed', expires_at = null where reservation_id = v_reservation.id and state = 'hold';
  update reservations set status = 'confirmed', updated_at = now() where id = v_reservation.id;
  update price_snapshots set accepted_at = now() where reservation_id = v_reservation.id;
  insert into audit_log (property_id, entity_type, entity_id, action, data)
  values (v_reservation.property_id, 'reservation', v_reservation.id, 'payment_verified_booking_confirmed', jsonb_build_object('provider', p_provider, 'provider_reference', p_provider_reference));
  return jsonb_build_object('status', 'confirmed', 'reservation_id', v_reservation.id, 'reference', v_reservation.reference);
end;
$$;

-- Safe status polling after a payment redirect. The random reservation id and
-- booking reference are both required; no guest data is returned.
create or replace function public.get_public_booking_hold_status(p_reservation_id uuid, p_reference text)
returns jsonb language sql security definer set search_path = public stable as $$
  select jsonb_build_object(
    'reservation_status', reservation.status,
    'payment_state', payment.state,
    'expires_at', payment.expires_at,
    'total_paise', payment.amount_paise,
    'reference', reservation.reference
  )
  from reservations reservation
  join payments payment on payment.reservation_id = reservation.id
  where reservation.id = p_reservation_id and reservation.reference = p_reference;
$$;

revoke all on function public.lock_property_inventory(uuid) from public;
revoke all on function public.release_expired_payment_holds(uuid) from public;
revoke all on function public.register_payment_checkout(uuid, text, jsonb) from public;
revoke all on function public.confirm_verified_payment(text, text, integer, jsonb) from public;
revoke all on function public.get_public_booking_hold_status(uuid, text) from public;
grant execute on function public.create_uat_booking_hold_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean) to anon, authenticated;
grant execute on function public.get_public_booking_hold_status(uuid, text) to anon, authenticated;
grant execute on function public.lock_property_inventory(uuid) to service_role;
grant execute on function public.release_expired_payment_holds(uuid) to service_role;
grant execute on function public.register_payment_checkout(uuid, text, jsonb) to service_role;
grant execute on function public.confirm_verified_payment(text, text, integer, jsonb) to service_role;
