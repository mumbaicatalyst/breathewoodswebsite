-- Reusable owner payment instructions. These are private property settings,
-- never public guest configuration or repository content.

create or replace function public.get_owner_payment_instructions()
returns text
language plpgsql security definer set search_path = public stable as $$
declare v_property_id uuid; v_instructions text;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  select coalesce(value ->> 'text', '') into v_instructions from property_settings
  where property_id = v_property_id and setting_key = 'owner_payment_instructions';
  return coalesce(v_instructions, '');
end;
$$;

create or replace function public.owner_save_payment_instructions(p_instructions text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to save payment instructions'; end if;
  if length(coalesce(p_instructions, '')) > 2000 then raise exception 'Payment instructions are too long'; end if;
  insert into property_settings (property_id, setting_key, value)
  values (v_property_id, 'owner_payment_instructions', jsonb_build_object('text', trim(coalesce(p_instructions, ''))))
  on conflict (property_id, setting_key) do update set value = excluded.value, updated_at = now();
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'property_setting', v_property_id, 'owner_payment_instructions_saved', '{}'::jsonb);
end;
$$;

revoke all on function public.get_owner_payment_instructions() from public;
revoke all on function public.owner_save_payment_instructions(text) from public;
grant execute on function public.get_owner_payment_instructions() to authenticated;
grant execute on function public.owner_save_payment_instructions(text) to authenticated;
