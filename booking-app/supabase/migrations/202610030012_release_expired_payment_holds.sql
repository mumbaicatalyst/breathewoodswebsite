-- A payment hold must stop blocking inventory after its expiry. Availability
-- already ignores expired holds; this keeps the exclusion constraint aligned
-- by releasing the corresponding allocations before the next booking attempt.

create or replace function public.create_uat_booking_hold_bundle_aware(
  p_product_id uuid,
  p_check_in date,
  p_check_out date,
  p_adults integer,
  p_children_7_to_12 integer,
  p_children_0_to_6 integer,
  p_pets integer,
  p_meal_plan text,
  p_bonfire_sessions integer,
  p_lake_outings integer,
  p_lake_trip_guests integer,
  p_guest_name text,
  p_guest_email text,
  p_guest_phone text,
  p_marketing_opt_in boolean
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_product bookable_products%rowtype;
  v_result jsonb;
  v_reservation_id uuid;
  v_hold_expires_at timestamptz;
  v_allocated integer;
begin
  select * into v_product
  from bookable_products
  where id = p_product_id and active;

  if not found then
    raise exception 'This stay is no longer available';
  end if;

  -- Preserve the expired reservation and payment for UAT audit history, but
  -- release only its temporary allocation so it can no longer block a stay.
  update payments pay
  set state = 'expired', updated_at = now()
  from reservations reservation
  where pay.reservation_id = reservation.id
    and reservation.property_id = v_product.property_id
    and pay.state in ('created', 'pending')
    and pay.expires_at <= now();

  update reservations reservation
  set status = 'cancelled', updated_at = now()
  where reservation.property_id = v_product.property_id
    and reservation.status = 'pending_payment'
    and exists (
      select 1 from inventory_allocations allocation
      where allocation.reservation_id = reservation.id
        and allocation.state = 'hold'
        and allocation.expires_at <= now()
    );

  delete from inventory_allocations
  where property_id = v_product.property_id
    and state = 'hold'
    and expires_at <= now();

  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then
    raise exception 'This stay was just booked or blocked. Please search again.';
  end if;

  v_result := public.create_uat_booking_hold(
    p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12,
    p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions,
    p_lake_outings, p_lake_trip_guests, p_guest_name, p_guest_email,
    p_guest_phone, p_marketing_opt_in
  );

  if v_product.inventory_mode = 'child_rooms' then
    v_reservation_id := (v_result ->> 'reservation_id')::uuid;
    v_hold_expires_at := (v_result ->> 'expires_at')::timestamptz;

    insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
    select v_product.property_id, child.id, v_reservation_id,
      daterange(p_check_in, p_check_out, '[)'), 'hold', v_hold_expires_at
    from resources child
    where child.parent_resource_id = v_product.primary_resource_id
      and child.active
      and not exists (
        select 1 from inventory_allocations allocation
        where allocation.resource_id = child.id
          and allocation.stay_during && daterange(p_check_in, p_check_out, '[)')
          and allocation.state in ('confirmed', 'block', 'hold')
          and (allocation.state <> 'hold' or allocation.expires_at > now())
      )
    order by child.name
    limit v_product.room_units_required;

    select count(*) into v_allocated
    from inventory_allocations
    where reservation_id = v_reservation_id and state = 'hold';

    if v_allocated < v_product.room_units_required then
      raise exception 'Those rooms were just booked. Please search again.';
    end if;
  end if;

  return v_result;
end;
$$;

revoke all on function public.create_uat_booking_hold_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean) from public;
grant execute on function public.create_uat_booking_hold_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean) to anon, authenticated;
