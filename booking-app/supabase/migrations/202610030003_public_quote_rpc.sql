-- Public, read-only quote endpoint. A quote never holds inventory or creates a reservation.

create or replace function public.get_booking_quote(
  p_product_id uuid,
  p_check_in date,
  p_check_out date,
  p_adults integer,
  p_children_7_to_12 integer,
  p_children_0_to_6 integer,
  p_pets integer,
  p_meal_plan text,
  p_bonfire_sessions integer default 0,
  p_lake_outings integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product bookable_products%rowtype;
  v_party_size integer;
  v_chargeable_party integer;
  v_nights integer;
  v_day date;
  v_rate integer;
  v_base_total integer := 0;
  v_adult_extra_count integer;
  v_child_extra_count integer;
  v_adult_extra_total integer;
  v_child_extra_total integer;
  v_bonfire_total integer := 0;
  v_lake_total integer := 0;
  v_total integer;
  v_party_settings jsonb;
  v_extra_settings jsonb;
  v_weekend_settings jsonb;
  v_adult_extra_rate integer;
  v_child_extra_rate integer;
  v_bonfire_rate integer;
  v_lake_rate integer;
  v_guests_per_car integer;
  v_pet_limit integer;
begin
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then
    raise exception 'A valid check-in and check-out date are required';
  end if;
  if p_adults < 1 or p_children_7_to_12 < 0 or p_children_0_to_6 < 0 or p_pets < 0 or p_bonfire_sessions < 0 or p_lake_outings < 0 then
    raise exception 'Guest and add-on quantities cannot be negative';
  end if;

  select * into v_product from bookable_products where id = p_product_id and active;
  if not found then raise exception 'This stay is no longer available'; end if;

  v_party_size := p_adults + p_children_7_to_12 + p_children_0_to_6;
  v_chargeable_party := p_adults + p_children_7_to_12;
  v_nights := p_check_out - p_check_in;
  if v_party_size not between v_product.minimum_overnight_guests and v_product.max_overnight_guests then
    raise exception 'This stay does not suit the selected party size';
  end if;

  select value into v_party_settings from property_settings where property_id = v_product.property_id and setting_key = 'party_and_pets';
  select value into v_extra_settings from property_settings where property_id = v_product.property_id and setting_key = 'additional_guest_pricing';
  select value into v_weekend_settings from property_settings where property_id = v_product.property_id and setting_key = 'weekend_room_rule';

  v_pet_limit := case v_product.sellable_kind when 'room' then coalesce((v_party_settings -> 'pet_limits' ->> 'room')::integer, 0)
    when 'villa' then coalesce((v_party_settings -> 'pet_limits' ->> 'villa')::integer, 0)
    else coalesce((v_party_settings -> 'pet_limits' ->> 'entire_property')::integer, 0) end;
  if p_pets > v_pet_limit then raise exception 'The selected stay cannot accommodate that number of pets'; end if;

  if v_product.sellable_kind = 'room'
    and coalesce((v_weekend_settings ->> 'enabled')::boolean, false)
    and v_nights < coalesce((v_weekend_settings ->> 'minimum_nights')::integer, 1)
    and exists (select 1 from generate_series(p_check_in, p_check_out - 1, interval '1 day') d where extract(dow from d)::integer in (5, 6)) then
    raise exception 'Individual room stays that include Friday or Saturday currently require at least % nights', (v_weekend_settings ->> 'minimum_nights')::integer;
  end if;

  if exists (
    select 1 from bookable_product_resources bpr
    join inventory_allocations ia on ia.resource_id = bpr.resource_id
    where bpr.product_id = v_product.id
      and ia.stay_during && daterange(p_check_in, p_check_out, '[)')
      and ia.state in ('confirmed', 'block', 'hold')
      and (ia.state <> 'hold' or ia.expires_at > now())
  ) then raise exception 'This stay was just booked or blocked. Please search again.'; end if;

  for v_day in select generate_series(p_check_in, p_check_out - 1, interval '1 day')::date loop
    select rr.nightly_amount_paise into v_rate
    from rate_rules rr
    join rate_plans rp on rp.id = rr.rate_plan_id
    where rr.product_id = v_product.id
      and rr.active and rp.active and rp.meal_plan::text = p_meal_plan
      and rr.valid_during @> v_day
      and v_party_size between rr.party_min and rr.party_max
      and (rr.weekday_mask & (1 << extract(dow from v_day)::integer)) <> 0
    order by rr.priority desc, lower(rr.valid_during) desc
    limit 1;
    if v_rate is null then raise exception 'No % rate is configured for every selected night', p_meal_plan; end if;
    v_base_total := v_base_total + v_rate;
  end loop;

  v_adult_extra_count := greatest(p_adults - v_product.included_chargeable_guests, 0);
  v_child_extra_count := greatest(v_chargeable_party - v_product.included_chargeable_guests - v_adult_extra_count, 0);
  v_adult_extra_rate := coalesce((v_extra_settings ->> 'adult_paise_per_night')::integer, 0);
  v_child_extra_rate := coalesce((v_extra_settings ->> 'child_7_to_12_paise_per_night')::integer, 0);
  v_adult_extra_total := v_adult_extra_count * v_adult_extra_rate * v_nights;
  v_child_extra_total := v_child_extra_count * v_child_extra_rate * v_nights;

  if p_bonfire_sessions > 0 then
    select amount_paise into v_bonfire_rate from add_ons where property_id = v_product.property_id and code = 'bonfire-bbq' and active;
    v_bonfire_total := coalesce(v_bonfire_rate, 0) * v_party_size * p_bonfire_sessions;
  end if;
  if p_lake_outings > 0 then
    select amount_paise, coalesce((configuration ->> 'guests_per_car')::integer, 4) into v_lake_rate, v_guests_per_car from add_ons where property_id = v_product.property_id and code = 'lake-trip' and active;
    v_lake_total := coalesce(v_lake_rate, 0) * ceil(v_party_size::numeric / v_guests_per_car)::integer * p_lake_outings;
  end if;

  v_total := v_base_total + v_adult_extra_total + v_child_extra_total + v_bonfire_total + v_lake_total;
  return jsonb_build_object(
    'currency', 'INR', 'nights', v_nights, 'total_paise', v_total,
    'items', jsonb_build_array(
      jsonb_build_object('label', initcap(replace(p_meal_plan, '_', ' ')) || ' stay', 'amount_paise', v_base_total),
      jsonb_build_object('label', 'Additional adults', 'quantity', v_adult_extra_count, 'amount_paise', v_adult_extra_total),
      jsonb_build_object('label', 'Children aged 7–12 above included allowance', 'quantity', v_child_extra_count, 'amount_paise', v_child_extra_total),
      jsonb_build_object('label', 'Bonfire + barbecue', 'quantity', p_bonfire_sessions, 'amount_paise', v_bonfire_total),
      jsonb_build_object('label', 'Lake trip', 'quantity', p_lake_outings, 'amount_paise', v_lake_total),
      jsonb_build_object('label', 'Pets', 'quantity', p_pets, 'amount_paise', 0)
    ),
    'notice', 'This is a live quote only. Availability is held when payment begins.'
  );
end;
$$;

revoke all on function public.get_booking_quote(uuid, date, date, integer, integer, integer, integer, text, integer, integer) from public;
grant execute on function public.get_booking_quote(uuid, date, date, integer, integer, integer, integer, text, integer, integer) to anon, authenticated;
