-- Two-bedroom Bougan'villa product. It dynamically assigns any two free rooms,
-- so a guest is never charged for all three rooms and the remaining bedroom can
-- remain sellable.

alter table public.bookable_products
  add column if not exists inventory_mode text not null default 'mapped' check (inventory_mode in ('mapped', 'child_rooms')),
  add column if not exists room_units_required integer not null default 1 check (room_units_required > 0);

alter table public.bookable_products drop constraint if exists bookable_products_sellable_kind_check;
alter table public.bookable_products add constraint bookable_products_sellable_kind_check check (sellable_kind in ('room', 'room_bundle', 'villa', 'entire_property'));

do $$
declare property_uuid uuid; bougan_resource_uuid uuid; breakfast_uuid uuid; breakfast_one_uuid uuid; all_meals_uuid uuid; bundle_product_uuid uuid;
begin
  select id into property_uuid from public.properties where name = 'Breathe Woods' limit 1;
  select id into bougan_resource_uuid from public.resources where property_id = property_uuid and name = 'Bougan''villa' limit 1;
  if property_uuid is null or bougan_resource_uuid is null then raise exception 'Breathe Woods Bougan''villa configuration is missing'; end if;
  insert into public.bookable_products (property_id, primary_resource_id, code, name, sellable_kind, minimum_overnight_guests, max_overnight_guests, included_chargeable_guests, display_order, inventory_mode, room_units_required)
  values (property_uuid, bougan_resource_uuid, 'bougan-two-rooms', 'Two Bedrooms at Bougan''villa', 'room_bundle', 1, 4, 4, 35, 'child_rooms', 2)
  on conflict (property_id, code) do update set name = excluded.name, sellable_kind = excluded.sellable_kind, minimum_overnight_guests = excluded.minimum_overnight_guests, max_overnight_guests = excluded.max_overnight_guests, included_chargeable_guests = excluded.included_chargeable_guests, display_order = excluded.display_order, inventory_mode = excluded.inventory_mode, room_units_required = excluded.room_units_required, active = true
  returning id into bundle_product_uuid;
  delete from public.bookable_product_resources where product_id = bundle_product_uuid;
  select id into breakfast_uuid from public.rate_plans where property_id = property_uuid and code = 'breakfast';
  select id into breakfast_one_uuid from public.rate_plans where property_id = property_uuid and code = 'breakfast-plus-one';
  select id into all_meals_uuid from public.rate_plans where property_id = property_uuid and code = 'all-meals';
  insert into public.rate_rules (property_id, product_id, rate_plan_id, valid_during, nightly_amount_paise, minimum_nights, weekday_mask, priority, party_min, party_max)
  values
    (property_uuid, bundle_product_uuid, breakfast_uuid, daterange('2026-01-01'::date, null, '[)'), 1100000, 1, 31, 10, 1, 4),
    (property_uuid, bundle_product_uuid, breakfast_one_uuid, daterange('2026-01-01'::date, null, '[)'), 1250000, 1, 31, 10, 1, 4),
    (property_uuid, bundle_product_uuid, all_meals_uuid, daterange('2026-01-01'::date, null, '[)'), 1400000, 1, 31, 10, 1, 4)
  on conflict (product_id, rate_plan_id, valid_during, priority, party_min, party_max) do update set nightly_amount_paise = excluded.nightly_amount_paise, weekday_mask = excluded.weekday_mask, active = true;
end;
$$;

create or replace function public.is_product_inventory_available(p_product_id uuid, p_check_in date, p_check_out date)
returns boolean
language sql security definer set search_path = public
as $$
  select coalesce((
    select case when p.inventory_mode = 'child_rooms' then
      (select count(*) from resources child where child.parent_resource_id = p.primary_resource_id and child.active and not exists (
        select 1 from inventory_allocations ia where ia.resource_id = child.id and ia.stay_during && daterange(p_check_in, p_check_out, '[)') and ia.state in ('confirmed', 'block', 'hold') and (ia.state <> 'hold' or ia.expires_at > now())
      )) >= p.room_units_required
    else not exists (
      select 1 from bookable_product_resources bpr join inventory_allocations ia on ia.resource_id = bpr.resource_id
      where bpr.product_id = p.id and ia.stay_during && daterange(p_check_in, p_check_out, '[)') and ia.state in ('confirmed', 'block', 'hold') and (ia.state <> 'hold' or ia.expires_at > now())
    ) end
    from bookable_products p where p.id = p_product_id and p.active
  ), false);
$$;

create or replace function public.get_available_products(p_check_in date, p_check_out date, p_party_size integer)
returns table (product_id uuid, product_code text, product_name text, sellable_kind text, max_overnight_guests integer, included_chargeable_guests integer, from_amount_paise integer)
language sql security definer set search_path = public
as $$
  with room_weekend_rule as (
    select ps.property_id, coalesce((ps.value ->> 'enabled')::boolean, false) as enabled, coalesce((ps.value ->> 'minimum_nights')::integer, 1) as minimum_nights from property_settings ps where ps.setting_key = 'weekend_room_rule'
  )
  select p.id, p.code, p.name, p.sellable_kind, p.max_overnight_guests, p.included_chargeable_guests,
    (select min(winning.nightly_amount_paise) from (select distinct on (rr.rate_plan_id) rr.nightly_amount_paise from rate_rules rr where rr.product_id = p.id and rr.active and rr.valid_during @> p_check_in and p_party_size between rr.party_min and rr.party_max and (rr.weekday_mask & (1 << extract(dow from p_check_in)::integer)) <> 0 order by rr.rate_plan_id, rr.priority desc, lower(rr.valid_during) desc) winning) as from_amount_paise
  from bookable_products p left join room_weekend_rule rwr on rwr.property_id = p.property_id
  where p.active and p_party_size between p.minimum_overnight_guests and p.max_overnight_guests
    and not (p.sellable_kind = 'room' and coalesce(rwr.enabled, false) and (p_check_out - p_check_in) < rwr.minimum_nights and exists (select 1 from generate_series(p_check_in, p_check_out - 1, interval '1 day') d where extract(dow from d)::integer in (5, 6)))
    and not exists (select 1 from generate_series(p_check_in, p_check_out - 1, interval '1 day') d where not exists (select 1 from rate_rules rr where rr.product_id = p.id and rr.active and rr.valid_during @> d::date and p_party_size between rr.party_min and rr.party_max and (rr.weekday_mask & (1 << extract(dow from d)::integer)) <> 0))
    and public.is_product_inventory_available(p.id, p_check_in, p_check_out)
  order by p.display_order;
$$;

create or replace function public.get_booking_quote_bundle_aware(p_product_id uuid, p_check_in date, p_check_out date, p_adults integer, p_children_7_to_12 integer, p_children_0_to_6 integer, p_pets integer, p_meal_plan text, p_bonfire_sessions integer, p_lake_outings integer, p_lake_trip_guests integer)
returns jsonb language plpgsql security definer set search_path = public
as $$ begin
  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then raise exception 'This stay was just booked or blocked. Please search again.'; end if;
  return public.get_booking_quote(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests);
end; $$;

create or replace function public.create_uat_booking_hold_bundle_aware(p_product_id uuid, p_check_in date, p_check_out date, p_adults integer, p_children_7_to_12 integer, p_children_0_to_6 integer, p_pets integer, p_meal_plan text, p_bonfire_sessions integer, p_lake_outings integer, p_lake_trip_guests integer, p_guest_name text, p_guest_email text, p_guest_phone text, p_marketing_opt_in boolean)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_product bookable_products%rowtype; v_result jsonb; v_reservation_id uuid; v_hold_expires_at timestamptz; v_allocated integer;
begin
  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then raise exception 'This stay was just booked or blocked. Please search again.'; end if;
  select * into v_product from bookable_products where id = p_product_id and active;
  v_result := public.create_uat_booking_hold(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests, p_guest_name, p_guest_email, p_guest_phone, p_marketing_opt_in);
  if v_product.inventory_mode = 'child_rooms' then
    v_reservation_id := (v_result ->> 'reservation_id')::uuid; v_hold_expires_at := (v_result ->> 'expires_at')::timestamptz;
    insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
    select v_product.property_id, child.id, v_reservation_id, daterange(p_check_in, p_check_out, '[)'), 'hold', v_hold_expires_at
    from resources child
    where child.parent_resource_id = v_product.primary_resource_id and child.active and not exists (
      select 1 from inventory_allocations ia where ia.resource_id = child.id and ia.stay_during && daterange(p_check_in, p_check_out, '[)') and ia.state in ('confirmed', 'block', 'hold') and (ia.state <> 'hold' or ia.expires_at > now())
    ) order by child.name limit v_product.room_units_required;
    select count(*) into v_allocated from inventory_allocations where reservation_id = v_reservation_id and state = 'hold';
    if v_allocated < v_product.room_units_required then raise exception 'Those rooms were just booked. Please search again.'; end if;
  end if;
  return v_result;
end; $$;

revoke all on function public.is_product_inventory_available(uuid, date, date) from public;
grant execute on function public.is_product_inventory_available(uuid, date, date) to anon, authenticated;
revoke all on function public.get_available_products(date, date, integer) from public;
grant execute on function public.get_available_products(date, date, integer) to anon, authenticated;
revoke all on function public.get_booking_quote_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) from public;
grant execute on function public.get_booking_quote_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) to anon, authenticated;
revoke all on function public.create_uat_booking_hold_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean) from public;
grant execute on function public.create_uat_booking_hold_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean) to anon, authenticated;
