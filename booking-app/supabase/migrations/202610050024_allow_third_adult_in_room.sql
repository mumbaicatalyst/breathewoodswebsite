-- A private room may have a third adult, charged at the daily extra-adult rate.
-- It still permits at most one child aged 7–12, and only one additional
-- chargeable person beyond the couple allowance.

create or replace function public.get_booking_quote(
  p_product_id uuid, p_check_in date, p_check_out date,
  p_adults integer, p_children_7_to_12 integer, p_children_0_to_6 integer,
  p_pets integer, p_meal_plan text, p_bonfire_sessions integer,
  p_lake_outings integer default 0, p_lake_trip_guests integer default 0
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_product bookable_products%rowtype; v_settings jsonb; v_party_size integer;
  v_chargeable_party integer; v_nights integer; v_units integer; v_day record;
  v_room_base integer; v_adult_extra integer; v_child_extra integer;
  v_meal_total integer; v_nightly_total integer; v_base_total integer := 0;
  v_adult_extra_total integer := 0; v_child_extra_total integer := 0;
  v_meal_total_all integer := 0; v_bonfire_total integer := 0;
  v_lake_total integer := 0; v_total integer; v_bonfire_rate integer;
  v_lake_base integer; v_lake_increment integer; v_lake_included integer;
  v_included_bonfire integer := 0; v_chargeable_bonfire integer := 0;
  v_nightly jsonb := '[]'::jsonb; v_buyout_base integer;
  v_buyout_guests integer; v_discount_bps integer;
begin
  select * into v_product from bookable_products where id = p_product_id and active;
  if not found then raise exception 'This stay is no longer available'; end if;
  if not public.daily_pricing_is_enabled(v_product.property_id) then
    return public.get_booking_quote_legacy(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests);
  end if;
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then raise exception 'A valid check-in and check-out date are required'; end if;
  if p_adults < 1 or p_children_7_to_12 < 0 or p_children_0_to_6 < 0 or p_pets < 0 or p_bonfire_sessions < 0 or p_lake_trip_guests < 0 then raise exception 'Guest and add-on quantities cannot be negative'; end if;
  v_party_size := p_adults + p_children_7_to_12 + p_children_0_to_6;
  v_chargeable_party := p_adults + p_children_7_to_12;
  v_nights := p_check_out - p_check_in;
  v_units := public.room_units_for_product(v_product);
  if v_party_size not between v_product.minimum_overnight_guests and v_product.max_overnight_guests then raise exception 'This stay does not suit the selected party size'; end if;
  if p_lake_trip_guests > v_party_size then raise exception 'Lake-trip guests cannot exceed the selected party'; end if;
  if v_product.sellable_kind = 'room' and (
    v_party_size > 4 or p_adults > 3 or p_children_7_to_12 > 1
    or p_children_0_to_6 > 2 or p_adults + p_children_7_to_12 > 3
  ) then raise exception 'A room permits up to three adults, or two adults and one child aged 7-12. Children aged 0-6 are complimentary but count toward the four-person capacity.'; end if;
  if v_product.code = 'entire-property' and p_meal_plan <> 'all_meals' then raise exception 'Full-property stays include All Meals.'; end if;
  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then raise exception 'This stay was just booked or blocked. Please search again.'; end if;

  select value into v_settings from property_settings where property_id = v_product.property_id and setting_key = 'daily_pricing_calendar';
  for v_day in select * from daily_pricing_calendar where property_id = v_product.property_id and stay_date >= p_check_in and stay_date < p_check_out order by stay_date loop
    if v_nights < v_day.minimum_stay_nights then raise exception 'This date requires a minimum % night stay', v_day.minimum_stay_nights; end if;
    if v_product.code = 'entire-property' and v_day.buyout_discount_eligible then
      v_buyout_guests := least(greatest(v_chargeable_party, coalesce((v_settings -> 'full_property' ->> 'minimum_paying_guests')::integer, 10)), 15);
      v_buyout_base := coalesce((v_settings -> 'full_property' ->> 'base_paise')::integer, 5000000) + greatest(v_buyout_guests - coalesce((v_settings -> 'full_property' ->> 'minimum_paying_guests')::integer, 10), 0) * coalesce((v_settings -> 'full_property' ->> 'additional_paying_guest_paise')::integer, 350000);
      v_discount_bps := case when v_nights >= 2 then round(v_day.buyout_two_plus_nights_discount_bps_group_10 + ((v_buyout_guests - 10) * (v_day.buyout_two_plus_nights_discount_bps_group_15 - v_day.buyout_two_plus_nights_discount_bps_group_10) / 5.0))::integer else round(v_day.buyout_one_night_discount_bps_group_10 + ((v_buyout_guests - 10) * (v_day.buyout_one_night_discount_bps_group_15 - v_day.buyout_one_night_discount_bps_group_10) / 5.0))::integer end;
      v_room_base := round(v_buyout_base * (10000 - v_discount_bps) / 10000.0)::integer; v_adult_extra := 0; v_child_extra := 0; v_meal_total := 0;
    else
      v_room_base := case when v_product.sellable_kind = 'room' and v_party_size = 1 then v_day.single_room_paise else v_day.couple_room_paise * v_units end;
      v_adult_extra := case when v_product.sellable_kind = 'room' then greatest(p_adults - 2, 0) else greatest(p_adults - v_product.included_chargeable_guests, 0) end * v_day.extra_adult_paise;
      v_child_extra := case when v_product.sellable_kind = 'room' then greatest(p_children_7_to_12 - greatest(2 - p_adults, 0), 0) else greatest(v_chargeable_party - v_product.included_chargeable_guests - greatest(p_adults - v_product.included_chargeable_guests, 0), 0) end * v_day.extra_child_7_to_12_paise;
      v_meal_total := case p_meal_plan when 'breakfast_plus_one' then p_adults * coalesce((v_settings -> 'meal_upgrade_paise_per_night' -> 'breakfast_plus_one' ->> 'adult')::integer, 37500) + p_children_7_to_12 * coalesce((v_settings -> 'meal_upgrade_paise_per_night' -> 'breakfast_plus_one' ->> 'child_7_to_12')::integer, 27500) when 'all_meals' then p_adults * coalesce((v_settings -> 'meal_upgrade_paise_per_night' -> 'all_meals' ->> 'adult')::integer, 75000) + p_children_7_to_12 * coalesce((v_settings -> 'meal_upgrade_paise_per_night' -> 'all_meals' ->> 'child_7_to_12')::integer, 55000) else 0 end;
    end if;
    v_nightly_total := v_room_base + v_adult_extra + v_child_extra + v_meal_total;
    v_base_total := v_base_total + v_room_base; v_adult_extra_total := v_adult_extra_total + v_adult_extra; v_child_extra_total := v_child_extra_total + v_child_extra; v_meal_total_all := v_meal_total_all + v_meal_total;
    v_nightly := v_nightly || jsonb_build_array(jsonb_build_object('date', v_day.stay_date, 'tier', v_day.tier_code, 'room_base_paise', v_room_base, 'extra_adult_paise', v_adult_extra, 'extra_child_paise', v_child_extra, 'meal_upgrade_paise', v_meal_total, 'total_paise', v_nightly_total));
  end loop;
  if jsonb_array_length(v_nightly) <> v_nights then raise exception 'Daily rates are not configured for every selected night'; end if;
  if p_bonfire_sessions > 0 then
    select amount_paise into v_bonfire_rate from add_ons where property_id = v_product.property_id and code = 'bonfire-bbq' and active;
    if v_party_size >= 7 and p_meal_plan in ('all_meals', 'breakfast_plus_one') then v_included_bonfire := least(p_bonfire_sessions, 1); end if;
    v_chargeable_bonfire := p_bonfire_sessions - v_included_bonfire; v_bonfire_total := coalesce(v_bonfire_rate, 0) * v_party_size * v_chargeable_bonfire;
  end if;
  if p_lake_trip_guests > 0 then
    select coalesce((configuration ->> 'base_paise')::integer, 50000), coalesce((configuration ->> 'incremental_paise')::integer, 25000), coalesce((configuration ->> 'included_guests')::integer, 2) into v_lake_base, v_lake_increment, v_lake_included from add_ons where property_id = v_product.property_id and code = 'lake-trip' and active;
    v_lake_total := coalesce(v_lake_base, 50000) + greatest(p_lake_trip_guests - coalesce(v_lake_included, 2), 0) * coalesce(v_lake_increment, 25000);
  end if;
  v_total := v_base_total + v_adult_extra_total + v_child_extra_total + v_meal_total_all + v_bonfire_total + v_lake_total;
  return jsonb_build_object('currency','INR','nights',v_nights,'total_paise',v_total,'nightly_breakdown',v_nightly,'items',jsonb_build_array(jsonb_build_object('label','Nightly stay rate','amount_paise',v_base_total),jsonb_build_object('label','Additional adults','amount_paise',v_adult_extra_total),jsonb_build_object('label','Children aged 7-12','amount_paise',v_child_extra_total),jsonb_build_object('label',case when v_included_bonfire > 0 then 'Bonfire + barbecue (included)' else 'Bonfire + barbecue' end,'quantity',p_bonfire_sessions,'amount_paise',v_bonfire_total),jsonb_build_object('label','Lake trip','quantity',p_lake_trip_guests,'amount_paise',v_lake_total),jsonb_build_object('label',case when p_meal_plan = 'breakfast' then 'Breakfast included' else initcap(replace(p_meal_plan,'_',' ')) || ' upgrade' end,'amount_paise',v_meal_total_all)),'notice','Each night is priced from the live daily calendar. Meal selections apply to the entire booking party.');
end;
$$;

revoke all on function public.get_booking_quote(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) from public;
grant execute on function public.get_booking_quote(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) to anon, authenticated;
