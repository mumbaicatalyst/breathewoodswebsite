-- UAT-only payment simulator. It is deliberately owner/manager restricted and
-- calls the exact same confirmation routine used by a verified PhonePe webhook.
-- Before production deployment, set this setting to {"enabled": false}.

do $$
declare v_property_id uuid;
begin
  select id into v_property_id from properties where name = 'Breathe Woods' limit 1;
  if v_property_id is null then raise exception 'Breathe Woods property configuration is missing'; end if;
  insert into property_settings (property_id, setting_key, value)
  values (v_property_id, 'uat_payment_simulation', '{"enabled": true}'::jsonb)
  on conflict (property_id, setting_key) do update set value = excluded.value, updated_at = now();
end;
$$;

create or replace function public.simulate_uat_successful_payment(p_reservation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_property_id uuid;
  v_role dashboard_role;
  v_enabled boolean;
  v_payment payments%rowtype;
  v_reference text;
  v_result jsonb;
begin
  select profile.property_id, profile.role into v_property_id, v_role
  from owner_profiles profile
  where profile.user_id = auth.uid();
  if v_property_id is null or v_role = 'viewer' then
    raise exception 'You do not have permission to simulate a payment';
  end if;
  select coalesce((value ->> 'enabled')::boolean, false) into v_enabled
  from property_settings
  where property_id = v_property_id and setting_key = 'uat_payment_simulation';
  if coalesce(v_enabled, false) is not true then
    raise exception 'UAT payment simulation is disabled for this property';
  end if;

  select pay.* into v_payment
  from payments pay
  join reservations reservation on reservation.id = pay.reservation_id
  where pay.reservation_id = p_reservation_id
    and reservation.property_id = v_property_id
  for update;
  if not found then raise exception 'Payment hold was not found'; end if;
  if v_payment.state = 'paid' then
    return jsonb_build_object('status', 'confirmed', 'already_confirmed', true);
  end if;
  if v_payment.expires_at <= now() then
    perform public.release_expired_payment_holds(v_property_id);
    raise exception 'This payment hold has expired. Create a fresh test booking.';
  end if;

  v_reference := 'UAT-' || upper(substr(replace(v_payment.id::text, '-', ''), 1, 16));
  perform public.register_payment_checkout(
    v_payment.id,
    v_reference,
    jsonb_build_object('mode', 'uat_simulation', 'simulated_at', now())
  );
  v_result := public.confirm_verified_payment(
    'phonepe',
    v_reference,
    v_payment.amount_paise,
    jsonb_build_object('mode', 'uat_simulation', 'result', 'success', 'simulated_at', now())
  );
  insert into audit_log (property_id, entity_type, entity_id, action, data)
  values (v_property_id, 'payment', v_payment.id, 'uat_payment_simulated_success', jsonb_build_object('reservation_id', p_reservation_id, 'provider_reference', v_reference));
  return v_result;
end;
$$;

revoke all on function public.simulate_uat_successful_payment(uuid) from public;
grant execute on function public.simulate_uat_successful_payment(uuid) to authenticated;
