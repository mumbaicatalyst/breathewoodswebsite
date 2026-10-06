-- UAT configuration for Breathe Woods.
-- Apply only after 202610020001_booking_foundation.sql.
-- This creates real property configuration, not fake guest reservations.

create table if not exists public.bookable_product_resources (
  product_id uuid not null references public.bookable_products(id) on delete cascade,
  resource_id uuid not null references public.resources(id) on delete cascade,
  primary key (product_id, resource_id)
);

create unique index if not exists properties_name_unique on public.properties (name);

alter table public.bookable_products
  add column if not exists minimum_overnight_guests integer not null default 1 check (minimum_overnight_guests > 0);

alter table public.rate_rules
  add column if not exists party_min integer not null default 1 check (party_min > 0),
  add column if not exists party_max integer not null default 999 check (party_max >= party_min);

create table if not exists public.add_ons (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  code text not null,
  name text not null,
  description text,
  pricing_unit text not null check (pricing_unit in ('per_stay', 'per_night', 'per_guest', 'per_session', 'per_car', 'fixed_package')),
  amount_paise integer not null check (amount_paise >= 0),
  max_quantity integer,
  active boolean not null default true,
  configuration jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (property_id, code)
);

create table if not exists public.property_settings (
  property_id uuid not null references public.properties(id) on delete cascade,
  setting_key text not null,
  value jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (property_id, setting_key)
);

create unique index if not exists rate_rules_rule_identity
  on public.rate_rules (product_id, rate_plan_id, valid_during, priority, party_min, party_max);

alter table public.bookable_product_resources enable row level security;
alter table public.add_ons enable row level security;
alter table public.property_settings enable row level security;

do $$
declare
  property_uuid uuid;
  property_resource_uuid uuid;
  zen_resource_uuid uuid;
  bougan_resource_uuid uuid;
  zen_1_resource_uuid uuid;
  zen_2_resource_uuid uuid;
  bougan_1_resource_uuid uuid;
  bougan_2_resource_uuid uuid;
  bougan_3_resource_uuid uuid;
  breakfast_uuid uuid;
  breakfast_one_uuid uuid;
  all_meals_uuid uuid;
  product_record record;
begin
  insert into public.properties (name)
  values ('Breathe Woods')
  on conflict do nothing;

  select id into property_uuid from public.properties where name = 'Breathe Woods' limit 1;

  insert into public.resources (property_id, name, resource_kind)
  values (property_uuid, 'Entire Property', 'property')
  on conflict (property_id, name) do update set active = true
  returning id into property_resource_uuid;

  insert into public.resources (property_id, parent_resource_id, name, resource_kind)
  values (property_uuid, property_resource_uuid, 'Zen Villa', 'villa')
  on conflict (property_id, name) do update set parent_resource_id = excluded.parent_resource_id, active = true
  returning id into zen_resource_uuid;

  insert into public.resources (property_id, parent_resource_id, name, resource_kind)
  values (property_uuid, property_resource_uuid, 'Bougan''villa', 'villa')
  on conflict (property_id, name) do update set parent_resource_id = excluded.parent_resource_id, active = true
  returning id into bougan_resource_uuid;

  insert into public.resources (property_id, parent_resource_id, name, resource_kind)
  values (property_uuid, zen_resource_uuid, 'Zen 1', 'room')
  on conflict (property_id, name) do update set parent_resource_id = excluded.parent_resource_id, active = true
  returning id into zen_1_resource_uuid;

  insert into public.resources (property_id, parent_resource_id, name, resource_kind)
  values (property_uuid, zen_resource_uuid, 'Zen 2', 'room')
  on conflict (property_id, name) do update set parent_resource_id = excluded.parent_resource_id, active = true
  returning id into zen_2_resource_uuid;

  insert into public.resources (property_id, parent_resource_id, name, resource_kind)
  values (property_uuid, bougan_resource_uuid, 'Bougan''villa 1', 'room')
  on conflict (property_id, name) do update set parent_resource_id = excluded.parent_resource_id, active = true
  returning id into bougan_1_resource_uuid;

  insert into public.resources (property_id, parent_resource_id, name, resource_kind)
  values (property_uuid, bougan_resource_uuid, 'Bougan''villa 2', 'room')
  on conflict (property_id, name) do update set parent_resource_id = excluded.parent_resource_id, active = true
  returning id into bougan_2_resource_uuid;

  insert into public.resources (property_id, parent_resource_id, name, resource_kind)
  values (property_uuid, bougan_resource_uuid, 'Bougan''villa 3', 'room')
  on conflict (property_id, name) do update set parent_resource_id = excluded.parent_resource_id, active = true
  returning id into bougan_3_resource_uuid;

  insert into public.bookable_products (property_id, primary_resource_id, code, name, sellable_kind, minimum_overnight_guests, max_overnight_guests, included_chargeable_guests, display_order)
  values
    (property_uuid, zen_1_resource_uuid, 'zen-1', 'Zen 1', 'room', 1, 2, 2, 10),
    (property_uuid, zen_2_resource_uuid, 'zen-2', 'Zen 2', 'room', 1, 2, 2, 11),
    (property_uuid, zen_resource_uuid, 'zen-villa', 'Zen Villa', 'villa', 1, 6, 4, 20),
    (property_uuid, bougan_1_resource_uuid, 'bougan-1', 'Bougan''villa 1', 'room', 1, 2, 2, 30),
    (property_uuid, bougan_2_resource_uuid, 'bougan-2', 'Bougan''villa 2', 'room', 1, 2, 2, 31),
    (property_uuid, bougan_3_resource_uuid, 'bougan-3', 'Bougan''villa 3', 'room', 1, 2, 2, 32),
    (property_uuid, bougan_resource_uuid, 'bougan-villa', 'Bougan''villa', 'villa', 1, 9, 6, 40),
    (property_uuid, property_resource_uuid, 'entire-property', 'Entire Property', 'entire_property', 10, 15, 10, 50)
  on conflict (property_id, code) do update set
    primary_resource_id = excluded.primary_resource_id,
    name = excluded.name,
    sellable_kind = excluded.sellable_kind,
    minimum_overnight_guests = excluded.minimum_overnight_guests,
    max_overnight_guests = excluded.max_overnight_guests,
    included_chargeable_guests = excluded.included_chargeable_guests,
    active = true,
    display_order = excluded.display_order;

  for product_record in select id, code from public.bookable_products where property_id = property_uuid loop
    delete from public.bookable_product_resources where product_id = product_record.id;
    if product_record.code = 'zen-1' then
      insert into public.bookable_product_resources values (product_record.id, zen_1_resource_uuid);
    elsif product_record.code = 'zen-2' then
      insert into public.bookable_product_resources values (product_record.id, zen_2_resource_uuid);
    elsif product_record.code = 'zen-villa' then
      insert into public.bookable_product_resources values (product_record.id, zen_resource_uuid), (product_record.id, zen_1_resource_uuid), (product_record.id, zen_2_resource_uuid);
    elsif product_record.code = 'bougan-1' then
      insert into public.bookable_product_resources values (product_record.id, bougan_1_resource_uuid);
    elsif product_record.code = 'bougan-2' then
      insert into public.bookable_product_resources values (product_record.id, bougan_2_resource_uuid);
    elsif product_record.code = 'bougan-3' then
      insert into public.bookable_product_resources values (product_record.id, bougan_3_resource_uuid);
    elsif product_record.code = 'bougan-villa' then
      insert into public.bookable_product_resources values (product_record.id, bougan_resource_uuid), (product_record.id, bougan_1_resource_uuid), (product_record.id, bougan_2_resource_uuid), (product_record.id, bougan_3_resource_uuid);
    elsif product_record.code = 'entire-property' then
      insert into public.bookable_product_resources values
        (product_record.id, property_resource_uuid), (product_record.id, zen_resource_uuid), (product_record.id, zen_1_resource_uuid), (product_record.id, zen_2_resource_uuid),
        (product_record.id, bougan_resource_uuid), (product_record.id, bougan_1_resource_uuid), (product_record.id, bougan_2_resource_uuid), (product_record.id, bougan_3_resource_uuid);
    end if;
  end loop;

  insert into public.rate_plans (property_id, code, name, meal_plan)
  values
    (property_uuid, 'breakfast', 'Breakfast only', 'breakfast'),
    (property_uuid, 'breakfast-plus-one', 'Breakfast + 1 meal', 'breakfast_plus_one'),
    (property_uuid, 'all-meals', 'All meals', 'all_meals')
  on conflict (property_id, code) do update set name = excluded.name, active = true;

  select id into breakfast_uuid from public.rate_plans where property_id = property_uuid and code = 'breakfast';
  select id into breakfast_one_uuid from public.rate_plans where property_id = property_uuid and code = 'breakfast-plus-one';
  select id into all_meals_uuid from public.rate_plans where property_id = property_uuid and code = 'all-meals';

  -- weekday_mask uses Sunday = bit 0 through Saturday = bit 6. 31 = Sunday–Thursday, 127 = every day.
  insert into public.rate_rules (property_id, product_id, rate_plan_id, valid_during, nightly_amount_paise, minimum_nights, weekday_mask, priority, party_min, party_max)
  select property_uuid, p.id, rp.id, daterange('2026-01-01'::date, null, '[)'), amount.amount_paise, 1, amount.weekday_mask, 0, amount.party_min, amount.party_max
  from (
    values
      ('zen-villa', 'breakfast', 1700000, 127, 1, 999), ('zen-villa', 'breakfast-plus-one', 1850000, 127, 1, 999), ('zen-villa', 'all-meals', 2000000, 127, 1, 999),
      ('bougan-villa', 'breakfast', 2600000, 127, 1, 999), ('bougan-villa', 'breakfast-plus-one', 2800000, 127, 1, 999), ('bougan-villa', 'all-meals', 3000000, 127, 1, 999),
      ('zen-1', 'breakfast', 400000, 31, 1, 1), ('zen-1', 'breakfast', 550000, 31, 2, 2), ('zen-1', 'breakfast-plus-one', 450000, 31, 1, 1), ('zen-1', 'breakfast-plus-one', 625000, 31, 2, 2), ('zen-1', 'all-meals', 500000, 31, 1, 1), ('zen-1', 'all-meals', 700000, 31, 2, 2),
      ('zen-2', 'breakfast', 400000, 31, 1, 1), ('zen-2', 'breakfast', 550000, 31, 2, 2), ('zen-2', 'breakfast-plus-one', 450000, 31, 1, 1), ('zen-2', 'breakfast-plus-one', 625000, 31, 2, 2), ('zen-2', 'all-meals', 500000, 31, 1, 1), ('zen-2', 'all-meals', 700000, 31, 2, 2),
      ('bougan-1', 'breakfast', 400000, 31, 1, 1), ('bougan-1', 'breakfast', 550000, 31, 2, 2), ('bougan-1', 'breakfast-plus-one', 450000, 31, 1, 1), ('bougan-1', 'breakfast-plus-one', 625000, 31, 2, 2), ('bougan-1', 'all-meals', 500000, 31, 1, 1), ('bougan-1', 'all-meals', 700000, 31, 2, 2),
      ('bougan-2', 'breakfast', 400000, 31, 1, 1), ('bougan-2', 'breakfast', 550000, 31, 2, 2), ('bougan-2', 'breakfast-plus-one', 450000, 31, 1, 1), ('bougan-2', 'breakfast-plus-one', 625000, 31, 2, 2), ('bougan-2', 'all-meals', 500000, 31, 1, 1), ('bougan-2', 'all-meals', 700000, 31, 2, 2),
      ('bougan-3', 'breakfast', 400000, 31, 1, 1), ('bougan-3', 'breakfast', 550000, 31, 2, 2), ('bougan-3', 'breakfast-plus-one', 450000, 31, 1, 1), ('bougan-3', 'breakfast-plus-one', 625000, 31, 2, 2), ('bougan-3', 'all-meals', 500000, 31, 1, 1), ('bougan-3', 'all-meals', 700000, 31, 2, 2),
      ('entire-property', 'all-meals', 5000000, 127, 10, 15)
  ) as amount(product_code, rate_plan_code, amount_paise, weekday_mask, party_min, party_max)
  join public.bookable_products p on p.property_id = property_uuid and p.code = amount.product_code
  join public.rate_plans rp on rp.property_id = property_uuid and rp.code = amount.rate_plan_code
  on conflict (product_id, rate_plan_id, valid_during, priority, party_min, party_max) do update set nightly_amount_paise = excluded.nightly_amount_paise, weekday_mask = excluded.weekday_mask;

  insert into public.add_ons (property_id, code, name, description, pricing_unit, amount_paise, max_quantity, configuration)
  values
    (property_uuid, 'bonfire-bbq', 'Bonfire + barbecue', 'For the whole party; select the number of evenings.', 'per_session', 50000, null, '{"applies_to":"entire_party","requires_confirmation":true}'::jsonb),
    (property_uuid, 'lake-trip', 'Lake trip', '₹1,000 per car/outings; up to four participating guests per car.', 'per_car', 100000, null, '{"guests_per_car":4,"requires_confirmation":true}'::jsonb)
  on conflict (property_id, code) do update set name = excluded.name, description = excluded.description, pricing_unit = excluded.pricing_unit, amount_paise = excluded.amount_paise, configuration = excluded.configuration, active = true;

  insert into public.property_settings (property_id, setting_key, value)
  values
    (property_uuid, 'party_and_pets', '{"adult_min_age":13,"children_chargeable_min_age":7,"children_complimentary_max_age":6,"all_children_count_toward_capacity":true,"pet_fee_paise":0,"pet_deposit_paise":0,"pet_limits":{"room":1,"villa":2,"entire_property":3}}'::jsonb),
    (property_uuid, 'additional_guest_pricing', '{"adult_paise_per_night":350000,"child_7_to_12_paise_per_night":300000,"included_allowance_is_chargeable_guests_only":true,"allocation_order":"adults_then_children_7_to_12"}'::jsonb),
    (property_uuid, 'payment_holds', '{"direct_checkout_minutes":10,"owner_payment_link_minutes":30}'::jsonb),
    (property_uuid, 'weekend_room_rule', '{"enabled":true,"minimum_nights":4,"applies_when_stay_includes":"friday_or_saturday","room_party_limit":2,"status":"working_assumption_pending_owner_confirmation"}'::jsonb),
    (property_uuid, 'tax', '{"enabled":false,"percentage":0,"status":"awaiting_ca_confirmation"}'::jsonb)
  on conflict (property_id, setting_key) do update set value = excluded.value, updated_at = now();
end $$;
