-- Fix ordering in the target list used by the owner availability-block form.
create or replace function public.get_owner_block_targets()
returns table (target_id uuid, scope text, label text)
language plpgsql security definer set search_path = public stable as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  return query
  select * from (
    select r.id as target_id, 'room'::text as scope, r.name as label from resources r
      where r.property_id = v_property_id and r.active and r.resource_kind = 'room'
    union all
    select r.id as target_id, 'villa'::text as scope, r.name || ' (entire villa)' as label from resources r
      where r.property_id = v_property_id and r.active and r.resource_kind = 'villa'
    union all
    select r.id as target_id, 'property'::text as scope, 'Entire property' as label from resources r
      where r.property_id = v_property_id and r.active and r.resource_kind = 'property'
  ) targets
  order by targets.scope, targets.label;
end;
$$;

grant execute on function public.get_owner_block_targets() to authenticated;
