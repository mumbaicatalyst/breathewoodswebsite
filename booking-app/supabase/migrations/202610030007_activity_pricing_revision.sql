-- Revised activity rules received from the owner.
-- The existing functions remain available for any already-open UAT browser tabs;
-- the current application calls the expanded function signatures below.

do $$
declare property_uuid uuid;
begin
  select id into property_uuid from public.properties where name = 'Breathe Woods' limit 1;
  if property_uuid is null then raise exception 'Breathe Woods property configuration is missing'; end if;

  update public.add_ons
  set amount_paise = 25000,
      pricing_unit = 'per_guest',
      description = '₹500 covers up to 2 guests; ₹250 for each additional guest.',
      configuration = jsonb_build_object('base_paise', 50000, 'included_guests', 2, 'incremental_paise', 25000, 'one_trip_per_stay', true)
  where property_id = property_uuid and code = 'lake-trip';

  update public.add_ons
  set amount_paise = 50000,
      pricing_unit = 'per_guest',
      description = '₹500 per guest for parties of 6 or fewer. Groups of 7+ receive the package with qualifying meal plans.',
      configuration = jsonb_build_object('small_group_threshold', 6, 'included_group_minimum', 7, 'qualifying_meal_plans', jsonb_build_array('breakfast_plus_one', 'all_meals'), 'included_sessions_per_stay', 1)
  where property_id = property_uuid and code = 'bonfire-bbq';
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
  v_lake_base integer;
  v_lake_increment integer;
  v_lake_included_guests integer;
  v_pet_limit integer;
  v_included_bonfire_sessions integer := 0;
  v_chargeable_bonfire_sessions integer := 0;
begin
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then raise exception 'A valid check-in and check-out date are required'; end if;
  if p_adults < 1 or p_children_7_to_12 < 0 or p_children_0_to_6 < 0 or p_pets < 0 or p_bonfire_sessions < 0 or p_lake_trip_guests < 0 then raise exception 'Guest and add-on quantities cannot be negative'; end if;

  select * into v_product from bookable_products where id = p_product_id and active;
  if not found then raise exception 'This stay is no longer available'; end if;
  v_party_size := p_adults + p_children_7_to_12 + p_children_0_to_6;
  v_chargeable_party := p_adults + p_children_7_to_12;
  v_nights := p_check_out - p_check_in;
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
    if v_party_size >= 7 and p_meal_plan in ('all_meals', 'breakfast_plus_one') then
      v_included_bonfire_sessions := least(p_bonfire_sessions, 1);
    end if;
    v_chargeable_bonfire_sessions := p_bonfire_sessions - v_included_bonfire_sessions;
    v_bonfire_total := coalesce(v_bonfire_rate, 0) * v_party_size * v_chargeable_bonfire_sessions;
  end if;

  if p_lake_trip_guests > 0 then
    select coalesce((configuration ->> 'base_paise')::integer, 50000), coalesce((configuration ->> 'incremental_paise')::integer, 25000), coalesce((configuration ->> 'included_guests')::integer, 2) into v_lake_base, v_lake_increment, v_lake_included_guests from add_ons where property_id = v_product.property_id and code = 'lake-trip' and active;
    v_lake_total := coalesce(v_lake_base, 50000) + greatest(p_lake_trip_guests - coalesce(v_lake_included_guests, 2), 0) * coalesce(v_lake_increment, 25000);
  end if;

  v_total := v_base_total + v_adult_extra_total + v_child_extra_total + v_bonfire_total + v_lake_total;
  return jsonb_build_object('currency', 'INR', 'nights', v_nights, 'total_paise', v_total,
    'items', jsonb_build_array(
      jsonb_build_object('label', initcap(replace(p_meal_plan, '_', ' ')) || ' stay', 'amount_paise', v_base_total),
      jsonb_build_object('label', 'Additional adults', 'quantity', v_adult_extra_count, 'amount_paise', v_adult_extra_total),
      jsonb_build_object('label', 'Children aged 7–12 above included allowance', 'quantity', v_child_extra_count, 'amount_paise', v_child_extra_total),
      jsonb_build_object('label', case when v_included_bonfire_sessions > 0 and v_chargeable_bonfire_sessions > 0 then 'Bonfire + barbecue (1 included; ' || v_chargeable_bonfire_sessions || ' additional)' when v_included_bonfire_sessions > 0 then 'Bonfire + barbecue (included)' else 'Bonfire + barbecue' end, 'quantity', p_bonfire_sessions, 'amount_paise', v_bonfire_total),
      jsonb_build_object('label', 'Lake trip', 'quantity', p_lake_trip_guests, 'amount_paise', v_lake_total),
      jsonb_build_object('label', 'Pets', 'quantity', p_pets, 'amount_paise', 0)
    ),
    'notice', case when v_included_bonfire_sessions > 0 and p_meal_plan = 'breakfast_plus_one' then 'One bonfire evening is included; dinner will be the included meal on the evening you choose. Confirm your preferred evening at check-in or by messaging Breathe Woods. Additional bonfire evenings are chargeable.' when v_included_bonfire_sessions > 0 then 'One bonfire + barbecue evening is included with your qualifying meal plan. Confirm your preferred evening at check-in or by messaging Breathe Woods. Additional evenings are chargeable.' else 'This is a live quote only. Availability is held when payment begins.' end
  );
end;
$$;

revoke all on function public.get_booking_quote(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) from public;
grant execute on function public.get_booking_quote(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) to anon, authenticated;

create or replace function public.create_uat_booking_hold(
  p_product_id uuid, p_check_in date, p_check_out date, p_adults integer, p_children_7_to_12 integer, p_children_0_to_6 integer, p_pets integer, p_meal_plan text, p_bonfire_sessions integer, p_lake_outings integer, p_lake_trip_guests integer, p_guest_name text, p_guest_email text, p_guest_phone text, p_marketing_opt_in boolean
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_product bookable_products%rowtype; v_quote jsonb; v_guest_id uuid; v_reservation_id uuid; v_payment_id uuid; v_reference text; v_expiry timestamptz; v_hold_minutes integer; v_payment_settings jsonb; v_item jsonb; v_consent_version text := '2026-10-03';
begin
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Please enter the lead guest name'; end if;
  if position('@' in coalesce(p_guest_email, '')) < 2 then raise exception 'Please enter a valid email address'; end if;
  if coalesce(p_guest_phone, '') !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Please enter a valid mobile number with country code'; end if;
  select * into v_product from bookable_products where id = p_product_id and active;
  if not found then raise exception 'This stay is no longer available'; end if;
  select get_booking_quote(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests) into v_quote;
  select value into v_payment_settings from property_settings where property_id = v_product.property_id and setting_key = 'payment_holds';
  v_hold_minutes := coalesce((v_payment_settings ->> 'direct_checkout_minutes')::integer, 10); v_expiry := now() + make_interval(mins => v_hold_minutes); v_reference := 'BW-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  insert into guests (property_id, full_name, email, phone_e164, email_marketing_opt_in, whatsapp_opt_in, marketing_consent_at, marketing_consent_version) values (v_product.property_id, trim(p_guest_name), lower(trim(p_guest_email)), trim(p_guest_phone), p_marketing_opt_in, p_marketing_opt_in, case when p_marketing_opt_in then now() else null end, case when p_marketing_opt_in then v_consent_version else null end) returning id into v_guest_id;
  if p_marketing_opt_in then insert into guest_consents (property_id, guest_id, channel, purpose, action, consent_version, source) values (v_product.property_id, v_guest_id, 'email', 'marketing', 'granted', v_consent_version, 'website'), (v_product.property_id, v_guest_id, 'whatsapp', 'marketing', 'granted', v_consent_version, 'website'); end if;
  insert into reservations (property_id, reference, guest_id, product_id, check_in, check_out, adults, children_7_to_12, children_0_to_6, pets, source, status) values (v_product.property_id, v_reference, v_guest_id, v_product.id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, 'website', 'pending_payment') returning id into v_reservation_id;
  insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at) select v_product.property_id, bpr.resource_id, v_reservation_id, daterange(p_check_in, p_check_out, '[)'), 'hold', v_expiry from bookable_product_resources bpr where bpr.product_id = v_product.id;
  insert into price_snapshots (reservation_id, total_paise, calculation) values (v_reservation_id, (v_quote ->> 'total_paise')::integer, v_quote);
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise) values (v_reservation_id, case when v_item ->> 'label' like '%stay' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end, v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer); end loop;
  insert into payments (reservation_id, provider, amount_paise, state, expires_at) values (v_reservation_id, 'phonepe', (v_quote ->> 'total_paise')::integer, 'created', v_expiry) returning id into v_payment_id;
  insert into audit_log (property_id, entity_type, entity_id, action, data) values (v_product.property_id, 'reservation', v_reservation_id, 'uat_hold_created', jsonb_build_object('reference', v_reference, 'expires_at', v_expiry, 'marketing_opt_in', p_marketing_opt_in));
  return jsonb_build_object('reservation_id', v_reservation_id, 'reference', v_reference, 'payment_id', v_payment_id, 'expires_at', v_expiry, 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

revoke all on function public.create_uat_booking_hold(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean) from public;
grant execute on function public.create_uat_booking_hold(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean) to anon, authenticated;
