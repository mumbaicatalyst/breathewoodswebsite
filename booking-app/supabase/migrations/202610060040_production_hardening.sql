-- Production-only hardening. Do not apply this file to UAT: UAT keeps the
-- payment simulator enabled for controlled testing.

-- The cancellation helper is called internally by security-definer owner
-- functions. It must not be callable as a standalone authenticated RPC.
revoke execute on function public.get_reservation_cancellation_policy(uuid)
  from public, anon, authenticated;

-- If the UAT simulator migration was accidentally applied to production,
-- disable it and remove its browser-callable execute privilege. The function
-- may not exist when production correctly skips the UAT-only migration.
do $$
begin
  if to_regprocedure('public.simulate_uat_successful_payment(uuid)') is not null then
    revoke execute on function public.simulate_uat_successful_payment(uuid) from public, anon, authenticated;
  end if;
end;
$$;

do $$
declare
  v_property_id uuid;
begin
  select id into v_property_id from public.properties where name = 'Breathe Woods' limit 1;
  if v_property_id is not null then
    insert into public.property_settings (property_id, setting_key, value)
    values (v_property_id, 'uat_payment_simulation', '{"enabled": false}'::jsonb)
    on conflict (property_id, setting_key) do update
      set value = excluded.value, updated_at = now();
  end if;
end;
$$;
