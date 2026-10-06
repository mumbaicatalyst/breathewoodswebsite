-- Small explicit owner actions provide meaningful response-time analytics.
-- They do not change the guest quote, inventory allocation or booking status.

create or replace function public.owner_record_reservation_event(
  p_reservation_id uuid,
  p_event text,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_property_id uuid;
  v_role public.dashboard_role;
begin
  select property_id, role into v_property_id, v_role from public.owner_profiles where user_id = auth.uid();
  if v_property_id is null or v_role = 'viewer' then
    raise exception 'You do not have permission to update this reservation';
  end if;
  if p_event not in ('guest_contacted', 'payment_requested') then
    raise exception 'Unsupported reservation event';
  end if;
  if not exists (select 1 from public.reservations where id = p_reservation_id and property_id = v_property_id) then
    raise exception 'Reservation not found';
  end if;

  insert into public.audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'reservation', p_reservation_id, p_event, jsonb_build_object('note', p_note));
end;
$$;

revoke all on function public.owner_record_reservation_event(uuid, text, text) from public;
grant execute on function public.owner_record_reservation_event(uuid, text, text) to authenticated;
