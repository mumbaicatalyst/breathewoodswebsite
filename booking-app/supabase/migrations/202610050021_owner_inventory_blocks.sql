-- Owner-created availability blocks. The dashboard writes only through these
-- functions, so blocks use the same allocation guard as web reservations.

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

create or replace function public.owner_create_inventory_block(
  p_target_id uuid, p_scope text, p_check_in date, p_check_out date, p_reason text
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_property_id uuid; v_block_id uuid; v_target resources%rowtype; v_count integer; v_expected_scope text;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to change availability'; end if;
  if p_check_out <= p_check_in then raise exception 'Choose a valid block date range'; end if;
  if length(trim(coalesce(p_reason, ''))) < 2 then raise exception 'Please add a short reason for the block'; end if;
  select * into v_target from resources where id = p_target_id and property_id = v_property_id and active;
  if not found then raise exception 'This block target is not available'; end if;
  v_expected_scope := case
    when v_target.resource_kind = 'room' then 'room'
    when v_target.resource_kind = 'villa' then 'villa'
    else 'property'
  end;
  if p_scope not in ('room', 'villa', 'property') or p_scope <> v_expected_scope then
    raise exception 'This block target is invalid';
  end if;
  perform public.lock_property_inventory(v_property_id);
  insert into inventory_blocks (property_id, reason, created_by) values (v_property_id, trim(p_reason), auth.uid()) returning id into v_block_id;
  insert into inventory_allocations (property_id, resource_id, block_id, stay_during, state)
  select v_property_id, r.id, v_block_id, daterange(p_check_in, p_check_out, '[)'), 'block'
  from resources r
  where r.property_id = v_property_id and r.active and r.resource_kind = 'room'
    and (p_scope = 'property' or (p_scope = 'villa' and r.parent_resource_id = v_target.id) or (p_scope = 'room' and r.id = v_target.id));
  get diagnostics v_count = row_count;
  if v_count = 0 then raise exception 'No rooms were found for this block'; end if;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'inventory_block', v_block_id, 'created', jsonb_build_object('scope', p_scope, 'target_id', p_target_id, 'check_in', p_check_in, 'check_out', p_check_out, 'reason', trim(p_reason)));
  return jsonb_build_object('block_id', v_block_id, 'rooms_blocked', v_count);
exception when exclusion_violation then
  delete from inventory_blocks where id = v_block_id;
  raise exception 'One or more selected rooms already have a booking, hold or block on those dates';
end;
$$;

create or replace function public.owner_remove_inventory_block(p_block_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to change availability'; end if;
  perform public.lock_property_inventory(v_property_id);
  if not exists (select 1 from inventory_blocks where id = p_block_id and property_id = v_property_id) then raise exception 'This block was not found'; end if;
  delete from inventory_blocks where id = p_block_id and property_id = v_property_id;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action) values (v_property_id, auth.uid(), 'inventory_block', p_block_id, 'removed');
end;
$$;

drop function if exists public.get_owner_calendar(date, date);

create function public.get_owner_calendar(p_start date, p_end date)
returns table (
  resource_id uuid, resource_name text, resource_kind text, allocation_id uuid, block_id uuid,
  reservation_id uuid, allocation_state public.allocation_state, hold_expires_at timestamptz,
  check_in date, check_out date, reservation_reference text, reservation_status public.reservation_status,
  guest_name text, block_reason text
) language plpgsql security definer set search_path = public as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  if p_end <= p_start then raise exception 'Choose a valid calendar range'; end if;
  return query
  select r.id, r.name, r.resource_kind, ia.id, ia.block_id, ia.reservation_id, ia.state, ia.expires_at,
    lower(ia.stay_during)::date, upper(ia.stay_during)::date, reservation.reference, reservation.status, guest.full_name, block.reason
  from resources r
  left join inventory_allocations ia on ia.resource_id = r.id and ia.stay_during && daterange(p_start, p_end, '[)') and (ia.state <> 'hold' or ia.expires_at > now())
  left join reservations reservation on reservation.id = ia.reservation_id
  left join guests guest on guest.id = reservation.guest_id
  left join inventory_blocks block on block.id = ia.block_id
  where r.property_id = v_property_id and r.active
  order by r.resource_kind, r.name, lower(ia.stay_during);
end;
$$;

revoke all on function public.get_owner_block_targets() from public;
revoke all on function public.owner_create_inventory_block(uuid, text, date, date, text) from public;
revoke all on function public.owner_remove_inventory_block(uuid) from public;
grant execute on function public.get_owner_block_targets() to authenticated;
grant execute on function public.owner_create_inventory_block(uuid, text, date, date, text) to authenticated;
grant execute on function public.owner_remove_inventory_block(uuid) to authenticated;
grant execute on function public.get_owner_calendar(date, date) to authenticated;
