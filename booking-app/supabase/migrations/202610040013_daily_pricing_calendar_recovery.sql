-- Recovery continuation for a migration that stopped at room_units_for_product.

-- Run only if 202610040013_daily_pricing_calendar.sql failed with missing FROM-clause entry for table "p".

create or replace function public.room_units_for_product(p_product public.bookable_products)
returns integer language sql immutable as $$
  select case
    when (p_product).code = 'zen-villa' then 2
    when (p_product).code = 'bougan-villa' then 3
    when (p_product).code = 'entire-property' then 5
    when (p_product).inventory_mode = 'child_rooms' then (p_product).room_units_required
    else 1
  end
$$;

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
language plpgsql security definer set search_path = public
as $$
declare v_property_id uuid; v_enabled boolean;
begin
  select id into v_property_id from properties where name = 'Breathe Woods' limit 1;
  v_enabled := public.daily_pricing_is_enabled(v_property_id);

  if not v_enabled then
    return query select * from public.get_available_products_legacy(p_check_in, p_check_out, p_party_size);
    return;
  end if;

  return query
  select p.id, p.code, p.name, p.sellable_kind, p.max_overnight_guests, p.included_chargeable_guests,
    min(
      case when p.code = 'entire-property'
        then 5000000
        when p.sellable_kind = 'room' then daily.couple_room_paise
        else daily.couple_room_paise * public.room_units_for_product(p)
      end
    )::integer
  from bookable_products p
  join daily_pricing_calendar daily on daily.property_id = p.property_id
    and daily.stay_date >= p_check_in and daily.stay_date < p_check_out
  where p.active
    and p_party_size between p.minimum_overnight_guests and p.max_overnight_guests
    and public.is_product_inventory_available(p.id, p_check_in, p_check_out)
    and (p.sellable_kind <> 'room' or daily.individual_rooms_bookable)
  group by p.id, p.code, p.name, p.sellable_kind, p.max_overnight_guests, p.included_chargeable_guests
  having count(*) = p_check_out - p_check_in
    and (p_check_out - p_check_in) >= max(daily.minimum_stay_nights)
    and (p.sellable_kind <> 'room' or (p_check_out - p_check_in) >= max(daily.individual_room_minimum_nights))
  order by min(p.display_order);
end;
$$;

-- Public read endpoint for the guest date picker. It deliberately returns only
-- the published couple rate, never owner notes or unpublished configuration.
create or replace function public.get_public_daily_rate_calendar(
  p_start_date date,
  p_end_date date
)
returns table (
  stay_date date,
  couple_room_paise integer,
  tier_code text
)
language plpgsql security definer set search_path = public
as $$
declare v_property_id uuid;
begin
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'A valid calendar range is required';
  end if;
  if p_start_date < current_date - 1 or p_end_date > current_date + 548 then
    raise exception 'That calendar range is outside the published booking window';
  end if;
  select id into v_property_id from properties where name = 'Breathe Woods' limit 1;
  if not public.daily_pricing_is_enabled(v_property_id) then return; end if;

  return query
  select daily.stay_date, daily.couple_room_paise, daily.tier_code
  from daily_pricing_calendar daily
  where daily.property_id = v_property_id
    and daily.stay_date between p_start_date and p_end_date
  order by daily.stay_date;
end;
$$;

create or replace function public.get_booking_quote(
  p_product_id uuid,
  p_check_in date,
  p_check_out date,
  p_adults integer,
  p_children_7_to_12 integer,
  p_children_0_to_6 integer,
  p_pets integer,
  p_meal_plan text,
  p_bonfire_sessions integer,
  p_lake_outings integer default 0,
  p_lake_trip_guests integer default 0
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_product bookable_products%rowtype;
  v_settings jsonb;
  v_party_size integer;
  v_chargeable_party integer;
  v_nights integer;
  v_units integer;
  v_day record;
  v_room_base integer;
  v_adult_extra integer;
  v_child_extra integer;
  v_meal_total integer;
  v_nightly_total integer;
  v_base_total integer := 0;
  v_adult_extra_total integer := 0;
  v_child_extra_total integer := 0;
  v_meal_total_all integer := 0;
  v_bonfire_total integer := 0;
  v_lake_total integer := 0;
  v_total integer;
  v_bonfire_rate integer;
  v_lake_base integer;
  v_lake_increment integer;
  v_lake_included integer;
  v_included_bonfire integer := 0;
  v_chargeable_bonfire integer := 0;
  v_nightly jsonb := '[]'::jsonb;
  v_buyout_base integer;
  v_buyout_guests integer;
  v_discount_bps integer;
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
  if v_product.sellable_kind = 'room' and (p_children_0_to_6 > 2 or p_children_7_to_12 > 1 or p_children_0_to_6 + p_children_7_to_12 > 2 or p_adults > 3) then raise exception 'A room may have up to two children, with at most one aged 7-12.'; end if;
  if v_product.code = 'entire-property' and p_meal_plan <> 'all_meals' then raise exception 'Full-property stays include All Meals.'; end if;
  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then raise exception 'This stay was just booked or blocked. Please search again.'; end if;

  select value into v_settings from property_settings where property_id = v_product.property_id and setting_key = 'daily_pricing_calendar';
  for v_day in
    select * from daily_pricing_calendar
    where property_id = v_product.property_id and stay_date >= p_check_in and stay_date < p_check_out
    order by stay_date
  loop
    if v_nights < v_day.minimum_stay_nights then raise exception 'This date requires a minimum % night stay', v_day.minimum_stay_nights; end if;
    if v_product.code = 'entire-property' and v_day.buyout_discount_eligible then
      v_buyout_guests := least(greatest(v_chargeable_party, coalesce((v_settings -> 'full_property' ->> 'minimum_paying_guests')::integer, 10)), 15);
      v_buyout_base := coalesce((v_settings -> 'full_property' ->> 'base_paise')::integer, 5000000)
        + greatest(v_buyout_guests - coalesce((v_settings -> 'full_property' ->> 'minimum_paying_guests')::integer, 10), 0)
          * coalesce((v_settings -> 'full_property' ->> 'additional_paying_guest_paise')::integer, 350000);
      v_discount_bps := case when v_nights >= 2
        then round(v_day.buyout_two_plus_nights_discount_bps_group_10 + ((v_buyout_guests - 10) * (v_day.buyout_two_plus_nights_discount_bps_group_15 - v_day.buyout_two_plus_nights_discount_bps_group_10) / 5.0))::integer
        else round(v_day.buyout_one_night_discount_bps_group_10 + ((v_buyout_guests - 10) * (v_day.buyout_one_night_discount_bps_group_15 - v_day.buyout_one_night_discount_bps_group_10) / 5.0))::integer
      end;
      v_room_base := round(v_buyout_base * (10000 - v_discount_bps) / 10000.0)::integer;
      v_adult_extra := 0; v_child_extra := 0; v_meal_total := 0;
    else
      v_room_base := case when v_product.sellable_kind = 'room' and p_adults = 1 then v_day.single_room_paise else v_day.couple_room_paise * v_units end;
      v_adult_extra := case when v_product.sellable_kind = 'room' then greatest(p_adults - 2, 0) else greatest(p_adults - v_product.included_chargeable_guests, 0) end * v_day.extra_adult_paise;
      v_child_extra := case when v_product.sellable_kind = 'room' then p_children_7_to_12 else greatest(v_chargeable_party - v_product.included_chargeable_guests - greatest(p_adults - v_product.included_chargeable_guests, 0), 0) end * v_day.extra_child_7_to_12_paise;
      v_meal_total := case p_meal_plan
        when 'breakfast_plus_one' then p_adults * coalesce((v_settings -> 'meal_upgrade_paise_per_night' -> 'breakfast_plus_one' ->> 'adult')::integer, 37500) + p_children_7_to_12 * coalesce((v_settings -> 'meal_upgrade_paise_per_night' -> 'breakfast_plus_one' ->> 'child_7_to_12')::integer, 27500)
        when 'all_meals' then p_adults * coalesce((v_settings -> 'meal_upgrade_paise_per_night' -> 'all_meals' ->> 'adult')::integer, 75000) + p_children_7_to_12 * coalesce((v_settings -> 'meal_upgrade_paise_per_night' -> 'all_meals' ->> 'child_7_to_12')::integer, 55000)
        else 0 end;
    end if;
    v_nightly_total := v_room_base + v_adult_extra + v_child_extra + v_meal_total;
    v_base_total := v_base_total + v_room_base;
    v_adult_extra_total := v_adult_extra_total + v_adult_extra;
    v_child_extra_total := v_child_extra_total + v_child_extra;
    v_meal_total_all := v_meal_total_all + v_meal_total;
    v_nightly := v_nightly || jsonb_build_array(jsonb_build_object('date', v_day.stay_date, 'tier', v_day.tier_code, 'room_base_paise', v_room_base, 'extra_adult_paise', v_adult_extra, 'extra_child_paise', v_child_extra, 'meal_upgrade_paise', v_meal_total, 'total_paise', v_nightly_total));
  end loop;
  if jsonb_array_length(v_nightly) <> v_nights then raise exception 'Daily rates are not configured for every selected night'; end if;

  if p_bonfire_sessions > 0 then
    select amount_paise into v_bonfire_rate from add_ons where property_id = v_product.property_id and code = 'bonfire-bbq' and active;
    if v_party_size >= 7 and p_meal_plan in ('all_meals', 'breakfast_plus_one') then v_included_bonfire := least(p_bonfire_sessions, 1); end if;
    v_chargeable_bonfire := p_bonfire_sessions - v_included_bonfire;
    v_bonfire_total := coalesce(v_bonfire_rate, 0) * v_party_size * v_chargeable_bonfire;
  end if;
  if p_lake_trip_guests > 0 then
    select coalesce((configuration ->> 'base_paise')::integer, 50000), coalesce((configuration ->> 'incremental_paise')::integer, 25000), coalesce((configuration ->> 'included_guests')::integer, 2)
      into v_lake_base, v_lake_increment, v_lake_included from add_ons where property_id = v_product.property_id and code = 'lake-trip' and active;
    v_lake_total := coalesce(v_lake_base, 50000) + greatest(p_lake_trip_guests - coalesce(v_lake_included, 2), 0) * coalesce(v_lake_increment, 25000);
  end if;
  v_total := v_base_total + v_adult_extra_total + v_child_extra_total + v_meal_total_all + v_bonfire_total + v_lake_total;
  return jsonb_build_object('currency','INR','nights',v_nights,'total_paise',v_total,'nightly_breakdown',v_nightly,
    'items',jsonb_build_array(
      jsonb_build_object('label','Nightly stay rate','amount_paise',v_base_total),
      jsonb_build_object('label','Additional adults','amount_paise',v_adult_extra_total),
      jsonb_build_object('label','Children aged 7-12','amount_paise',v_child_extra_total),
      jsonb_build_object('label',case when v_included_bonfire > 0 then 'Bonfire + barbecue (included)' else 'Bonfire + barbecue' end,'quantity',p_bonfire_sessions,'amount_paise',v_bonfire_total),
      jsonb_build_object('label','Lake trip','quantity',p_lake_trip_guests,'amount_paise',v_lake_total),
      jsonb_build_object('label',case when p_meal_plan = 'breakfast' then 'Breakfast included' else initcap(replace(p_meal_plan,'_',' ')) || ' upgrade' end,'amount_paise',v_meal_total_all)
    ),
    'notice','Each night is priced from the live daily calendar. Meal selections apply to the entire booking party.');
end;
$$;

create or replace function public.get_booking_quote_bundle_aware(
  p_product_id uuid, p_check_in date, p_check_out date, p_adults integer, p_children_7_to_12 integer, p_children_0_to_6 integer, p_pets integer, p_meal_plan text, p_bonfire_sessions integer, p_lake_outings integer, p_lake_trip_guests integer
)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then raise exception 'This stay was just booked or blocked. Please search again.'; end if;
  return public.get_booking_quote(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests);
end;
$$;

-- Owner/manager-only daily-rate write endpoint. The dashboard will use this for
-- single-date and date-range editing; the CSV importer will use the same schema.
create or replace function public.upsert_owner_daily_rate(
  p_stay_date date, p_tier_code text, p_couple_room_paise integer, p_single_room_paise integer,
  p_extra_adult_paise integer, p_extra_child_7_to_12_paise integer, p_minimum_stay_nights integer, p_individual_rooms_bookable boolean,
  p_individual_room_minimum_nights integer, p_buyout_discount_eligible boolean,
  p_buyout_one_night_discount_bps_group_10 integer, p_buyout_one_night_discount_bps_group_15 integer,
  p_buyout_two_plus_nights_discount_bps_group_10 integer, p_buyout_two_plus_nights_discount_bps_group_15 integer,
  p_notes text default null
)
returns void language plpgsql security definer set search_path = public as $$
declare v_property_id uuid; v_role dashboard_role;
begin
  select property_id, role into v_property_id, v_role from owner_profiles where user_id = auth.uid();
  if v_property_id is null or v_role = 'viewer' then raise exception 'You do not have permission to change pricing'; end if;
  insert into daily_pricing_calendar (property_id, stay_date, tier_code, couple_room_paise, single_room_paise, extra_adult_paise, extra_child_7_to_12_paise, minimum_stay_nights, individual_rooms_bookable, individual_room_minimum_nights, buyout_discount_eligible, buyout_one_night_discount_bps_group_10, buyout_one_night_discount_bps_group_15, buyout_two_plus_nights_discount_bps_group_10, buyout_two_plus_nights_discount_bps_group_15, notes)
  values (v_property_id, p_stay_date, p_tier_code, p_couple_room_paise, p_single_room_paise, p_extra_adult_paise, p_extra_child_7_to_12_paise, p_minimum_stay_nights, p_individual_rooms_bookable, p_individual_room_minimum_nights, p_buyout_discount_eligible, p_buyout_one_night_discount_bps_group_10, p_buyout_one_night_discount_bps_group_15, p_buyout_two_plus_nights_discount_bps_group_10, p_buyout_two_plus_nights_discount_bps_group_15, p_notes)
  on conflict (property_id, stay_date) do update set tier_code = excluded.tier_code, couple_room_paise = excluded.couple_room_paise, single_room_paise = excluded.single_room_paise, extra_adult_paise = excluded.extra_adult_paise, extra_child_7_to_12_paise = excluded.extra_child_7_to_12_paise, minimum_stay_nights = excluded.minimum_stay_nights, individual_rooms_bookable = excluded.individual_rooms_bookable, individual_room_minimum_nights = excluded.individual_room_minimum_nights, buyout_discount_eligible = excluded.buyout_discount_eligible, buyout_one_night_discount_bps_group_10 = excluded.buyout_one_night_discount_bps_group_10, buyout_one_night_discount_bps_group_15 = excluded.buyout_one_night_discount_bps_group_15, buyout_two_plus_nights_discount_bps_group_10 = excluded.buyout_two_plus_nights_discount_bps_group_10, buyout_two_plus_nights_discount_bps_group_15 = excluded.buyout_two_plus_nights_discount_bps_group_15, notes = excluded.notes, updated_at = now();
end;
$$;

-- The public hold endpoint must use the same calendar quote that the guest saw.
-- It also allocates any two free child rooms for the Bougan'villa two-room stay.
create or replace function public.create_uat_booking_hold_bundle_aware(
  p_product_id uuid, p_check_in date, p_check_out date, p_adults integer,
  p_children_7_to_12 integer, p_children_0_to_6 integer, p_pets integer,
  p_meal_plan text, p_bonfire_sessions integer, p_lake_outings integer,
  p_lake_trip_guests integer, p_guest_name text, p_guest_email text,
  p_guest_phone text, p_marketing_opt_in boolean
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_product bookable_products%rowtype; v_quote jsonb; v_guest_id uuid;
  v_reservation_id uuid; v_payment_id uuid; v_reference text; v_expiry timestamptz;
  v_hold_minutes integer; v_payment_settings jsonb; v_item jsonb;
  v_consent_version text := '2026-10-04'; v_allocated integer;
begin
  select * into v_product from bookable_products where id = p_product_id and active;
  if not found then raise exception 'This stay is no longer available'; end if;
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Please enter the lead guest name'; end if;
  if position('@' in coalesce(p_guest_email, '')) < 2 then raise exception 'Please enter a valid email address'; end if;
  if coalesce(p_guest_phone, '') !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Please enter a valid mobile number with country code'; end if;

  update payments pay set state = 'expired', updated_at = now()
  from reservations reservation
  where pay.reservation_id = reservation.id and reservation.property_id = v_product.property_id
    and pay.state in ('created', 'pending') and pay.expires_at <= now();
  update reservations reservation set status = 'cancelled', updated_at = now()
  where reservation.property_id = v_product.property_id and reservation.status = 'pending_payment'
    and exists (select 1 from inventory_allocations allocation where allocation.reservation_id = reservation.id and allocation.state = 'hold' and allocation.expires_at <= now());
  delete from inventory_allocations where property_id = v_product.property_id and state = 'hold' and expires_at <= now();
  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then raise exception 'This stay was just booked or blocked. Please search again.'; end if;

  v_quote := public.get_booking_quote(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests);
  select value into v_payment_settings from property_settings where property_id = v_product.property_id and setting_key = 'payment_holds';
  v_hold_minutes := coalesce((v_payment_settings ->> 'direct_checkout_minutes')::integer, 10);
  v_expiry := now() + make_interval(mins => v_hold_minutes);
  v_reference := 'BW-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  insert into guests (property_id, full_name, email, phone_e164, email_marketing_opt_in, whatsapp_opt_in, marketing_consent_at, marketing_consent_version)
  values (v_product.property_id, trim(p_guest_name), lower(trim(p_guest_email)), trim(p_guest_phone), p_marketing_opt_in, p_marketing_opt_in, case when p_marketing_opt_in then now() else null end, case when p_marketing_opt_in then v_consent_version else null end)
  returning id into v_guest_id;
  if p_marketing_opt_in then
    insert into guest_consents (property_id, guest_id, channel, purpose, action, consent_version, source)
    values (v_product.property_id, v_guest_id, 'email', 'marketing', 'granted', v_consent_version, 'website'), (v_product.property_id, v_guest_id, 'whatsapp', 'marketing', 'granted', v_consent_version, 'website');
  end if;
  insert into reservations (property_id, reference, guest_id, product_id, check_in, check_out, adults, children_7_to_12, children_0_to_6, pets, source, status)
  values (v_product.property_id, v_reference, v_guest_id, v_product.id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, 'website', 'pending_payment') returning id into v_reservation_id;
  if v_product.inventory_mode = 'child_rooms' then
    insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
    select v_product.property_id, child.id, v_reservation_id, daterange(p_check_in, p_check_out, '[)'), 'hold', v_expiry
    from resources child
    where child.parent_resource_id = v_product.primary_resource_id and child.active
      and not exists (select 1 from inventory_allocations allocation where allocation.resource_id = child.id and allocation.stay_during && daterange(p_check_in, p_check_out, '[)') and allocation.state in ('confirmed', 'block', 'hold'))
    order by child.name limit v_product.room_units_required;
    select count(*) into v_allocated from inventory_allocations where reservation_id = v_reservation_id and state = 'hold';
    if v_allocated < v_product.room_units_required then raise exception 'Those rooms were just booked. Please search again.'; end if;
  else
    insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
    select v_product.property_id, bpr.resource_id, v_reservation_id, daterange(p_check_in, p_check_out, '[)'), 'hold', v_expiry
    from bookable_product_resources bpr where bpr.product_id = v_product.id;
  end if;
  insert into price_snapshots (reservation_id, total_paise, calculation) values (v_reservation_id, (v_quote ->> 'total_paise')::integer, v_quote);
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (v_reservation_id, case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end, v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into payments (reservation_id, provider, amount_paise, state, expires_at) values (v_reservation_id, 'phonepe', (v_quote ->> 'total_paise')::integer, 'created', v_expiry) returning id into v_payment_id;
  insert into audit_log (property_id, entity_type, entity_id, action, data) values (v_product.property_id, 'reservation', v_reservation_id, 'uat_hold_created', jsonb_build_object('reference', v_reference, 'expires_at', v_expiry, 'pricing_calendar', public.daily_pricing_is_enabled(v_product.property_id)));
  return jsonb_build_object('reservation_id', v_reservation_id, 'reference', v_reference, 'payment_id', v_payment_id, 'expires_at', v_expiry, 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

revoke all on function public.daily_pricing_is_enabled(uuid) from public;
revoke all on function public.room_units_for_product(public.bookable_products) from public;
revoke all on function public.get_available_products(date, date, integer) from public;
grant execute on function public.get_available_products(date, date, integer) to anon, authenticated;
revoke all on function public.get_public_daily_rate_calendar(date, date) from public;
grant execute on function public.get_public_daily_rate_calendar(date, date) to anon, authenticated;
revoke all on function public.get_booking_quote(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) from public;
grant execute on function public.get_booking_quote(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) to anon, authenticated;
revoke all on function public.get_booking_quote_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) from public;
grant execute on function public.get_booking_quote_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) to anon, authenticated;
revoke all on function public.upsert_owner_daily_rate(date, text, integer, integer, integer, integer, integer, boolean, integer, boolean, integer, integer, integer, integer, text) from public;
grant execute on function public.upsert_owner_daily_rate(date, text, integer, integer, integer, integer, integer, boolean, integer, boolean, integer, integer, integer, integer, text) to authenticated;
revoke all on function public.create_uat_booking_hold_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean) from public;
grant execute on function public.create_uat_booking_hold_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean) to anon, authenticated;
