-- Whole-villa weekday pricing and meal-plan-specific additional guest pricing.
-- Apply after 202610030007_activity_pricing_revision.sql.

do $$
declare property_uuid uuid;
begin
  select id into property_uuid from public.properties where name = 'Breathe Woods' limit 1;
  if property_uuid is null then raise exception 'Breathe Woods property configuration is missing'; end if;

  -- Sun–Thu: whole-villa tariff equals every room at its published couple rate.
  insert into public.rate_rules (property_id, product_id, rate_plan_id, valid_during, nightly_amount_paise, minimum_nights, weekday_mask, priority, party_min, party_max)
  select property_uuid, product.id, plan.id, daterange('2026-01-01'::date, null, '[)'), amount.amount_paise, 1, 31, 10, 1, 999
  from (values
    ('zen-villa', 'breakfast', 1100000), ('zen-villa', 'breakfast-plus-one', 1250000), ('zen-villa', 'all-meals', 1400000),
    ('bougan-villa', 'breakfast', 1650000), ('bougan-villa', 'breakfast-plus-one', 1875000), ('bougan-villa', 'all-meals', 2100000)
  ) as amount(product_code, plan_code, amount_paise)
  join public.bookable_products product on product.property_id = property_uuid and product.code = amount.product_code
  join public.rate_plans plan on plan.property_id = property_uuid and plan.code = amount.plan_code
  on conflict (product_id, rate_plan_id, valid_during, priority, party_min, party_max)
  do update set nightly_amount_paise = excluded.nightly_amount_paise, weekday_mask = excluded.weekday_mask, active = true;

  insert into public.property_settings (property_id, setting_key, value)
  values (
    property_uuid,
    'additional_guest_pricing',
    '{
      "included_allowance_is_chargeable_guests_only": true,
      "allocation_order": "adults_then_children_7_to_12",
      "by_meal_plan": {
        "breakfast": {"adult_paise_per_night": 275000, "child_7_to_12_paise_per_night": 225000},
        "breakfast_plus_one": {"adult_paise_per_night": 312500, "child_7_to_12_paise_per_night": 262500},
        "all_meals": {"adult_paise_per_night": 350000, "child_7_to_12_paise_per_night": 300000}
      }
    }'::jsonb
  )
  on conflict (property_id, setting_key) do update set value = excluded.value, updated_at = now();
end;
$$;

-- The availability card must show the winning rate rule, not simply the lowest
-- matching amount, so higher-priority holiday rules also behave correctly later.
create or replace function public.get_available_products(
  p_check_in date,
  p_check_out date,
  p_party_size integer
)
returns table (
  product_id uuid,
  product_code text,
  product_name text,
  sellable_kind text,
  max_overnight_guests integer,
  included_chargeable_guests integer,
  from_amount_paise integer
)
language sql security definer set search_path = public
as $$
  with requested_stay as (
    select daterange(p_check_in, p_check_out, '[)') as dates, (p_check_out - p_check_in) as nights
  ), room_weekend_rule as (
    select ps.property_id, coalesce((ps.value ->> 'enabled')::boolean, false) as enabled, coalesce((ps.value ->> 'minimum_nights')::integer, 1) as minimum_nights
    from property_settings ps where ps.setting_key = 'weekend_room_rule'
  )
  select p.id, p.code, p.name, p.sellable_kind, p.max_overnight_guests, p.included_chargeable_guests,
    (select rr.nightly_amount_paise from rate_rules rr where rr.product_id = p.id and rr.active and rr.valid_during @> p_check_in and p_party_size between rr.party_min and rr.party_max and (rr.weekday_mask & (1 << extract(dow from p_check_in)::integer)) <> 0 order by rr.priority desc, lower(rr.valid_during) desc limit 1) as from_amount_paise
  from bookable_products p cross join requested_stay rs left join room_weekend_rule rwr on rwr.property_id = p.property_id
  where p.active and p_party_size between p.minimum_overnight_guests and p.max_overnight_guests
    and not (p.sellable_kind = 'room' and coalesce(rwr.enabled, false) and rs.nights < rwr.minimum_nights and exists (select 1 from generate_series(p_check_in, p_check_out - 1, interval '1 day') as stay_day where extract(dow from stay_day)::integer in (5, 6)))
    and exists (select 1 from rate_rules rr where rr.product_id = p.id and rr.active and rr.valid_during @> p_check_in and p_party_size between rr.party_min and rr.party_max and (rr.weekday_mask & (1 << extract(dow from p_check_in)::integer)) <> 0)
    and not exists (select 1 from bookable_product_resources bpr join inventory_allocations ia on ia.resource_id = bpr.resource_id where bpr.product_id = p.id and ia.stay_during && rs.dates and ia.state in ('confirmed', 'block', 'hold') and (ia.state <> 'hold' or ia.expires_at > now()))
  order by p.display_order;
$$;

create or replace function public.get_booking_quote(
  p_product_id uuid, p_check_in date, p_check_out date, p_adults integer, p_children_7_to_12 integer, p_children_0_to_6 integer, p_pets integer, p_meal_plan text, p_bonfire_sessions integer, p_lake_outings integer default 0, p_lake_trip_guests integer default 0
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_product bookable_products%rowtype; v_party_size integer; v_chargeable_party integer; v_nights integer; v_day date; v_rate integer; v_base_total integer := 0; v_adult_extra_count integer; v_child_extra_count integer; v_adult_extra_total integer; v_child_extra_total integer; v_bonfire_total integer := 0; v_lake_total integer := 0; v_total integer; v_party_settings jsonb; v_extra_settings jsonb; v_weekend_settings jsonb; v_meal_extra_settings jsonb; v_adult_extra_rate integer; v_child_extra_rate integer; v_bonfire_rate integer; v_lake_base integer; v_lake_increment integer; v_lake_included_guests integer; v_pet_limit integer; v_included_bonfire_sessions integer := 0; v_chargeable_bonfire_sessions integer := 0;
begin
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then raise exception 'A valid check-in and check-out date are required'; end if;
  if p_adults < 1 or p_children_7_to_12 < 0 or p_children_0_to_6 < 0 or p_pets < 0 or p_bonfire_sessions < 0 or p_lake_trip_guests < 0 then raise exception 'Guest and add-on quantities cannot be negative'; end if;
  select * into v_product from bookable_products where id = p_product_id and active; if not found then raise exception 'This stay is no longer available'; end if;
  v_party_size := p_adults + p_children_7_to_12 + p_children_0_to_6; v_chargeable_party := p_adults + p_children_7_to_12; v_nights := p_check_out - p_check_in;
  if v_party_size not between v_product.minimum_overnight_guests and v_product.max_overnight_guests then raise exception 'This stay does not suit the selected party size'; end if;
  if p_lake_trip_guests > v_party_size then raise exception 'Lake-trip guests cannot exceed the selected party'; end if;
  select value into v_party_settings from property_settings where property_id = v_product.property_id and setting_key = 'party_and_pets';
  select value into v_extra_settings from property_settings where property_id = v_product.property_id and setting_key = 'additional_guest_pricing';
  select value into v_weekend_settings from property_settings where property_id = v_product.property_id and setting_key = 'weekend_room_rule';
  v_pet_limit := case v_product.sellable_kind when 'room' then coalesce((v_party_settings -> 'pet_limits' ->> 'room')::integer, 0) when 'villa' then coalesce((v_party_settings -> 'pet_limits' ->> 'villa')::integer, 0) else coalesce((v_party_settings -> 'pet_limits' ->> 'entire_property')::integer, 0) end;
  if p_pets > v_pet_limit then raise exception 'The selected stay cannot accommodate that number of pets'; end if;
  if v_product.sellable_kind = 'room' and coalesce((v_weekend_settings ->> 'enabled')::boolean, false) and v_nights < coalesce((v_weekend_settings ->> 'minimum_nights')::integer, 1) and exists (select 1 from generate_series(p_check_in, p_check_out - 1, interval '1 day') d where extract(dow from d)::integer in (5, 6)) then raise exception 'Individual room stays that include Friday or Saturday currently require at least % nights', (v_weekend_settings ->> 'minimum_nights')::integer; end if;
  if exists (select 1 from bookable_product_resources bpr join inventory_allocations ia on ia.resource_id = bpr.resource_id where bpr.product_id = v_product.id and ia.stay_during && daterange(p_check_in, p_check_out, '[)') and ia.state in ('confirmed', 'block', 'hold') and (ia.state <> 'hold' or ia.expires_at > now())) then raise exception 'This stay was just booked or blocked. Please search again.'; end if;
  for v_day in select generate_series(p_check_in, p_check_out - 1, interval '1 day')::date loop
    select rr.nightly_amount_paise into v_rate from rate_rules rr join rate_plans rp on rp.id = rr.rate_plan_id where rr.product_id = v_product.id and rr.active and rp.active and rp.meal_plan::text = p_meal_plan and rr.valid_during @> v_day and v_party_size between rr.party_min and rr.party_max and (rr.weekday_mask & (1 << extract(dow from v_day)::integer)) <> 0 order by rr.priority desc, lower(rr.valid_during) desc limit 1;
    if v_rate is null then raise exception 'No % rate is configured for every selected night', p_meal_plan; end if; v_base_total := v_base_total + v_rate;
  end loop;
  v_adult_extra_count := greatest(p_adults - v_product.included_chargeable_guests, 0); v_child_extra_count := greatest(v_chargeable_party - v_product.included_chargeable_guests - v_adult_extra_count, 0);
  v_meal_extra_settings := v_extra_settings -> 'by_meal_plan' -> p_meal_plan;
  v_adult_extra_rate := coalesce((v_meal_extra_settings ->> 'adult_paise_per_night')::integer, (v_extra_settings ->> 'adult_paise_per_night')::integer, 0);
  v_child_extra_rate := coalesce((v_meal_extra_settings ->> 'child_7_to_12_paise_per_night')::integer, (v_extra_settings ->> 'child_7_to_12_paise_per_night')::integer, 0);
  v_adult_extra_total := v_adult_extra_count * v_adult_extra_rate * v_nights; v_child_extra_total := v_child_extra_count * v_child_extra_rate * v_nights;
  if p_bonfire_sessions > 0 then select amount_paise into v_bonfire_rate from add_ons where property_id = v_product.property_id and code = 'bonfire-bbq' and active; if v_party_size >= 7 and p_meal_plan in ('all_meals', 'breakfast_plus_one') then v_included_bonfire_sessions := least(p_bonfire_sessions, 1); end if; v_chargeable_bonfire_sessions := p_bonfire_sessions - v_included_bonfire_sessions; v_bonfire_total := coalesce(v_bonfire_rate, 0) * v_party_size * v_chargeable_bonfire_sessions; end if;
  if p_lake_trip_guests > 0 then select coalesce((configuration ->> 'base_paise')::integer, 50000), coalesce((configuration ->> 'incremental_paise')::integer, 25000), coalesce((configuration ->> 'included_guests')::integer, 2) into v_lake_base, v_lake_increment, v_lake_included_guests from add_ons where property_id = v_product.property_id and code = 'lake-trip' and active; v_lake_total := coalesce(v_lake_base, 50000) + greatest(p_lake_trip_guests - coalesce(v_lake_included_guests, 2), 0) * coalesce(v_lake_increment, 25000); end if;
  v_total := v_base_total + v_adult_extra_total + v_child_extra_total + v_bonfire_total + v_lake_total;
  return jsonb_build_object('currency', 'INR', 'nights', v_nights, 'total_paise', v_total, 'items', jsonb_build_array(
    jsonb_build_object('label', initcap(replace(p_meal_plan, '_', ' ')) || ' stay', 'amount_paise', v_base_total),
    jsonb_build_object('label', 'Additional adults', 'quantity', v_adult_extra_count, 'amount_paise', v_adult_extra_total),
    jsonb_build_object('label', 'Children aged 7–12 above included allowance', 'quantity', v_child_extra_count, 'amount_paise', v_child_extra_total),
    jsonb_build_object('label', case when v_included_bonfire_sessions > 0 and v_chargeable_bonfire_sessions > 0 then 'Bonfire + barbecue (1 included; ' || v_chargeable_bonfire_sessions || ' additional)' when v_included_bonfire_sessions > 0 then 'Bonfire + barbecue (included)' else 'Bonfire + barbecue' end, 'quantity', p_bonfire_sessions, 'amount_paise', v_bonfire_total),
    jsonb_build_object('label', 'Lake trip', 'quantity', p_lake_trip_guests, 'amount_paise', v_lake_total), jsonb_build_object('label', 'Pets', 'quantity', p_pets, 'amount_paise', 0)
  ), 'notice', case when v_included_bonfire_sessions > 0 and p_meal_plan = 'breakfast_plus_one' then 'One bonfire evening is included; dinner will be the included meal on the evening you choose. Confirm your preferred evening at check-in or by messaging Breathe Woods. Additional bonfire evenings are chargeable.' when v_included_bonfire_sessions > 0 then 'One bonfire + barbecue evening is included with your qualifying meal plan. Confirm your preferred evening at check-in or by messaging Breathe Woods. Additional evenings are chargeable.' else 'This is a live quote only. Availability is held when payment begins.' end);
end;
$$;

revoke all on function public.get_available_products(date, date, integer) from public;
grant execute on function public.get_available_products(date, date, integer) to anon, authenticated;
revoke all on function public.get_booking_quote(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) from public;
grant execute on function public.get_booking_quote(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) to anon, authenticated;
