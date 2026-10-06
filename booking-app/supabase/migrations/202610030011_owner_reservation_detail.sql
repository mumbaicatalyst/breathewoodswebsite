-- Secure booking-detail view for the owner dashboard. The browser receives only
-- data for the property explicitly assigned to the signed-in owner/manager.

create or replace function public.get_owner_reservation_detail(p_reservation_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_property_id uuid;
  v_result jsonb;
begin
  select property_id into v_property_id
  from owner_profiles
  where user_id = auth.uid();

  if v_property_id is null then
    raise exception 'You do not have access to this dashboard';
  end if;

  select jsonb_build_object(
    'reservation', jsonb_build_object(
      'id', r.id,
      'reference', r.reference,
      'status', r.status,
      'check_in', r.check_in,
      'check_out', r.check_out,
      'adults', r.adults,
      'children_7_to_12', r.children_7_to_12,
      'children_0_to_6', r.children_0_to_6,
      'pets', r.pets,
      'source', r.source,
      'guest_name', g.full_name,
      'guest_email', g.email,
      'guest_phone', g.phone_e164,
      'product_name', p.name,
      'internal_note', r.internal_note,
      'total_paise', ps.total_paise
    ),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'label', ri.label,
        'quantity', ri.quantity,
        'amount_paise', ri.amount_paise,
        'item_type', ri.item_type
      ) order by ri.created_at, ri.id)
      from reservation_items ri
      where ri.reservation_id = r.id
    ), '[]'::jsonb),
    'payment', (
      select jsonb_build_object(
        'provider', pay.provider,
        'state', pay.state,
        'amount_paise', pay.amount_paise,
        'provider_reference', pay.provider_reference,
        'expires_at', pay.expires_at
      )
      from payments pay
      where pay.reservation_id = r.id
      order by pay.created_at desc
      limit 1
    )
  ) into v_result
  from reservations r
  left join guests g on g.id = r.guest_id
  left join bookable_products p on p.id = r.product_id
  left join price_snapshots ps on ps.reservation_id = r.id
  where r.id = p_reservation_id
    and r.property_id = v_property_id;

  if v_result is null then
    raise exception 'Booking not found';
  end if;

  return v_result;
end;
$$;

revoke all on function public.get_owner_reservation_detail(uuid) from public;
grant execute on function public.get_owner_reservation_detail(uuid) to authenticated;

-- Add the reservation id to the calendar response so the dashboard can open a
-- selected reservation without exposing any direct table access.
drop function if exists public.get_owner_calendar(date, date);

create function public.get_owner_calendar(p_start date, p_end date)
returns table (
  resource_id uuid,
  resource_name text,
  resource_kind text,
  allocation_id uuid,
  reservation_id uuid,
  allocation_state public.allocation_state,
  hold_expires_at timestamptz,
  check_in date,
  check_out date,
  reservation_reference text,
  reservation_status public.reservation_status,
  guest_name text,
  block_reason text
)
language plpgsql security definer set search_path = public
as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  if p_end <= p_start then raise exception 'Choose a valid calendar range'; end if;

  return query
  select r.id, r.name, r.resource_kind, ia.id, ia.reservation_id, ia.state, ia.expires_at,
    lower(ia.stay_during)::date, upper(ia.stay_during)::date,
    reservation.reference, reservation.status, guest.full_name, block.reason
  from resources r
  left join inventory_allocations ia on ia.resource_id = r.id
    and ia.stay_during && daterange(p_start, p_end, '[)')
    and (ia.state <> 'hold' or ia.expires_at > now())
  left join reservations reservation on reservation.id = ia.reservation_id
  left join guests guest on guest.id = reservation.guest_id
  left join inventory_blocks block on block.id = ia.block_id
  where r.property_id = v_property_id and r.active
  order by r.resource_kind, r.name, lower(ia.stay_during);
end;
$$;

revoke all on function public.get_owner_calendar(date, date) from public;
grant execute on function public.get_owner_calendar(date, date) to authenticated;
