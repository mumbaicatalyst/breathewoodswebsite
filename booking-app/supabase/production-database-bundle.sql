-- Breathe Woods production database bundle
-- Generated from supabase/migrations and supabase/imports.
-- The UAT-only payment simulator is intentionally excluded.
-- Review the output before running it in the production SQL Editor.


-- ============================================================================
-- 01. 202610020001_booking_foundation.sql
-- ============================================================================

-- Breathe Woods booking foundation. Apply to the UAT Supabase project first.
-- The public client never writes to these tables directly; application services do.

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

create type public.reservation_status as enum ('draft', 'pending_payment', 'confirmed', 'checked_in', 'checked_out', 'cancelled', 'no_show', 'payment_exception');
create type public.allocation_state as enum ('hold', 'confirmed', 'block');
create type public.payment_state as enum ('created', 'pending', 'paid', 'failed', 'cancelled', 'expired', 'refunded');
create type public.booking_source as enum ('website', 'owner_dashboard', 'whatsapp', 'phone', 'walk_in');

create table public.properties (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  timezone text not null default 'Asia/Kolkata',
  created_at timestamptz not null default now()
);

create table public.resources (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  parent_resource_id uuid references public.resources(id),
  name text not null,
  resource_kind text not null check (resource_kind in ('villa', 'room', 'property')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (property_id, name)
);

create table public.bookable_products (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  primary_resource_id uuid not null references public.resources(id),
  code text not null,
  name text not null,
  sellable_kind text not null check (sellable_kind in ('room', 'villa', 'entire_property')),
  max_overnight_guests integer not null check (max_overnight_guests > 0),
  included_chargeable_guests integer not null check (included_chargeable_guests >= 0),
  active boolean not null default true,
  display_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (property_id, code)
);

create table public.rate_plans (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  code text not null,
  name text not null,
  meal_plan text not null check (meal_plan in ('breakfast', 'breakfast_plus_one', 'all_meals')),
  active boolean not null default true,
  unique (property_id, code)
);

create table public.rate_rules (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  product_id uuid not null references public.bookable_products(id) on delete cascade,
  rate_plan_id uuid not null references public.rate_plans(id) on delete cascade,
  valid_during daterange not null,
  nightly_amount_paise integer not null check (nightly_amount_paise >= 0),
  minimum_nights integer not null default 1 check (minimum_nights > 0),
  weekday_mask smallint not null default 127 check (weekday_mask between 0 and 127),
  priority integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.guests (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  full_name text not null,
  email text,
  phone_e164 text,
  whatsapp_opt_in boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  reference text not null unique,
  guest_id uuid references public.guests(id),
  product_id uuid references public.bookable_products(id),
  check_in date not null,
  check_out date not null check (check_out > check_in),
  adults integer not null default 1 check (adults >= 1),
  children_7_to_12 integer not null default 0 check (children_7_to_12 >= 0),
  children_0_to_6 integer not null default 0 check (children_0_to_6 >= 0),
  pets integer not null default 0 check (pets >= 0),
  source public.booking_source not null default 'website',
  status public.reservation_status not null default 'draft',
  internal_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.inventory_blocks (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  reason text not null,
  created_by uuid,
  created_at timestamptz not null default now()
);

-- A whole-villa or entire-property booking inserts one row for every physical
-- resource it occupies. The exclusion constraint is the database double-booking guard.
create table public.inventory_allocations (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  resource_id uuid not null references public.resources(id) on delete cascade,
  reservation_id uuid references public.reservations(id) on delete cascade,
  block_id uuid references public.inventory_blocks(id) on delete cascade,
  stay_during daterange not null,
  state public.allocation_state not null,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  check ((reservation_id is not null) <> (block_id is not null)),
  exclude using gist (resource_id with =, stay_during with &&)
    where (state in ('hold', 'confirmed', 'block'))
);

create table public.reservation_items (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  item_type text not null check (item_type in ('meal_plan', 'guest_supplement', 'add_on', 'discount', 'tax', 'fee')),
  label text not null,
  quantity numeric not null default 1,
  amount_paise integer not null,
  metadata jsonb not null default '{}'::jsonb
);

create table public.price_snapshots (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null unique references public.reservations(id) on delete cascade,
  currency text not null default 'INR',
  total_paise integer not null check (total_paise >= 0),
  policy_version text,
  calculation jsonb not null,
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  provider text not null check (provider in ('phonepe', 'razorpay', 'manual')),
  provider_reference text,
  amount_paise integer not null check (amount_paise >= 0),
  state public.payment_state not null default 'created',
  expires_at timestamptz,
  provider_payload jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, provider_reference)
);

create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  actor_id uuid,
  entity_type text not null,
  entity_id uuid not null,
  action text not null,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.properties enable row level security;
alter table public.resources enable row level security;
alter table public.bookable_products enable row level security;
alter table public.rate_plans enable row level security;
alter table public.rate_rules enable row level security;
alter table public.guests enable row level security;
alter table public.reservations enable row level security;
alter table public.inventory_blocks enable row level security;
alter table public.inventory_allocations enable row level security;
alter table public.reservation_items enable row level security;
alter table public.price_snapshots enable row level security;
alter table public.payments enable row level security;
alter table public.audit_log enable row level security;

-- RLS policies are intentionally added with the authenticated owner roles and
-- server-side booking functions. No broad anonymous table access is permitted.


-- ============================================================================
-- 02. 202610030001_breathe_woods_uat_configuration.sql
-- ============================================================================

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


-- ============================================================================
-- 03. 202610030002_public_availability_rpc.sql
-- ============================================================================

-- Read-only public availability endpoint.
-- It exposes only sellable product information and a starting rate, never guest,
-- reservation, payment or owner-block details.

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
language sql
security definer
set search_path = public
as $$
  with requested_stay as (
    select daterange(p_check_in, p_check_out, '[)') as dates,
           (p_check_out - p_check_in) as nights
  ),
  room_weekend_rule as (
    select ps.property_id,
           coalesce((ps.value ->> 'enabled')::boolean, false) as enabled,
           coalesce((ps.value ->> 'minimum_nights')::integer, 1) as minimum_nights
    from property_settings ps
    where ps.setting_key = 'weekend_room_rule'
  )
  select
    p.id,
    p.code,
    p.name,
    p.sellable_kind,
    p.max_overnight_guests,
    p.included_chargeable_guests,
    (
      select min(rr.nightly_amount_paise)
      from rate_rules rr
      where rr.product_id = p.id
        and rr.active
        and rr.valid_during @> p_check_in
        and p_party_size between rr.party_min and rr.party_max
        and (rr.weekday_mask & (1 << extract(dow from p_check_in)::integer)) <> 0
    ) as from_amount_paise
  from bookable_products p
  cross join requested_stay rs
  left join room_weekend_rule rwr on rwr.property_id = p.property_id
  where p.active
    and p_party_size between p.minimum_overnight_guests and p.max_overnight_guests
    and not (
      p.sellable_kind = 'room'
      and coalesce(rwr.enabled, false)
      and rs.nights < rwr.minimum_nights
      and exists (
        select 1
        from generate_series(p_check_in, p_check_out - 1, interval '1 day') as stay_day
        where extract(dow from stay_day)::integer in (5, 6)
      )
    )
    and exists (
      select 1
      from rate_rules rr
      where rr.product_id = p.id
        and rr.active
        and rr.valid_during @> p_check_in
        and p_party_size between rr.party_min and rr.party_max
        and (rr.weekday_mask & (1 << extract(dow from p_check_in)::integer)) <> 0
    )
    and not exists (
      select 1
      from bookable_product_resources bpr
      join inventory_allocations ia on ia.resource_id = bpr.resource_id
      where bpr.product_id = p.id
        and ia.stay_during && rs.dates
        and ia.state in ('confirmed', 'block', 'hold')
        and (ia.state <> 'hold' or ia.expires_at > now())
    )
  order by p.display_order;
$$;

revoke all on function public.get_available_products(date, date, integer) from public;
grant execute on function public.get_available_products(date, date, integer) to anon, authenticated;


-- ============================================================================
-- 04. 202610030003_public_quote_rpc.sql
-- ============================================================================

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


-- ============================================================================
-- 05. 202610030004_uat_booking_hold_rpc.sql
-- ============================================================================

-- UAT-only booking hold endpoint. It will move behind a rate-limited server
-- endpoint before production. The hold and quote are still created atomically
-- in the database so inventory conflicts cannot be bypassed by the browser.

create or replace function public.create_uat_booking_hold(
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
  p_guest_name text,
  p_guest_email text,
  p_guest_phone text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product bookable_products%rowtype;
  v_quote jsonb;
  v_guest_id uuid;
  v_reservation_id uuid;
  v_payment_id uuid;
  v_reference text;
  v_expiry timestamptz;
  v_hold_minutes integer;
  v_payment_settings jsonb;
  v_item jsonb;
begin
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Please enter the lead guest name'; end if;
  if position('@' in coalesce(p_guest_email, '')) < 2 then raise exception 'Please enter a valid email address'; end if;
  if length(regexp_replace(coalesce(p_guest_phone, ''), '[^0-9]', '', 'g')) < 10 then raise exception 'Please enter a valid mobile number'; end if;

  select * into v_product from bookable_products where id = p_product_id and active;
  if not found then raise exception 'This stay is no longer available'; end if;

  -- get_booking_quote rechecks availability and applies all configured commercial rules.
  select get_booking_quote(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings) into v_quote;
  select value into v_payment_settings from property_settings where property_id = v_product.property_id and setting_key = 'payment_holds';
  v_hold_minutes := coalesce((v_payment_settings ->> 'direct_checkout_minutes')::integer, 10);
  v_expiry := now() + make_interval(mins => v_hold_minutes);
  v_reference := 'BW-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));

  insert into guests (property_id, full_name, email, phone_e164)
  values (v_product.property_id, trim(p_guest_name), lower(trim(p_guest_email)), trim(p_guest_phone))
  returning id into v_guest_id;

  insert into reservations (property_id, reference, guest_id, product_id, check_in, check_out, adults, children_7_to_12, children_0_to_6, pets, source, status)
  values (v_product.property_id, v_reference, v_guest_id, v_product.id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, 'website', 'pending_payment')
  returning id into v_reservation_id;

  -- Whole-villa and entire-property products allocate every associated resource.
  insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
  select v_product.property_id, bpr.resource_id, v_reservation_id, daterange(p_check_in, p_check_out, '[)'), 'hold', v_expiry
  from bookable_product_resources bpr
  where bpr.product_id = v_product.id;

  insert into price_snapshots (reservation_id, total_paise, calculation)
  values (v_reservation_id, (v_quote ->> 'total_paise')::integer, v_quote);

  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (
      v_reservation_id,
      case when v_item ->> 'label' like '%stay' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end,
      v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer
    );
  end loop;

  insert into payments (reservation_id, provider, amount_paise, state, expires_at)
  values (v_reservation_id, 'phonepe', (v_quote ->> 'total_paise')::integer, 'created', v_expiry)
  returning id into v_payment_id;

  insert into audit_log (property_id, entity_type, entity_id, action, data)
  values (v_product.property_id, 'reservation', v_reservation_id, 'uat_hold_created', jsonb_build_object('reference', v_reference, 'expires_at', v_expiry));

  return jsonb_build_object('reservation_id', v_reservation_id, 'reference', v_reference, 'payment_id', v_payment_id, 'expires_at', v_expiry, 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

revoke all on function public.create_uat_booking_hold(uuid, date, date, integer, integer, integer, integer, text, integer, integer, text, text, text) from public;
grant execute on function public.create_uat_booking_hold(uuid, date, date, integer, integer, integer, integer, text, integer, integer, text, text, text) to anon, authenticated;


-- ============================================================================
-- 06. 202610030005_owner_calendar_access.sql
-- ============================================================================

-- Invite-only owner/manager access. Auth users are invited manually from the
-- Supabase Dashboard, then explicitly allow-listed below by an administrator.

do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'dashboard_role' and n.nspname = 'public'
  ) then
    create type public.dashboard_role as enum ('owner', 'manager', 'viewer');
  end if;
end;
$$;

create table if not exists public.owner_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  property_id uuid not null references public.properties(id) on delete cascade,
  role public.dashboard_role not null default 'owner',
  created_at timestamptz not null default now()
);

alter table public.owner_profiles enable row level security;
revoke all on public.owner_profiles from anon, authenticated;
grant select on public.owner_profiles to authenticated;

drop policy if exists "users can read only their own dashboard profile" on public.owner_profiles;

create policy "users can read only their own dashboard profile"
  on public.owner_profiles for select to authenticated
  using (user_id = auth.uid());

create or replace function public.get_owner_calendar(p_start date, p_end date)
returns table (
  resource_id uuid,
  resource_name text,
  resource_kind text,
  allocation_id uuid,
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
  select r.id, r.name, r.resource_kind, ia.id, ia.state, ia.expires_at,
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


-- ============================================================================
-- 07. 202610030006_guest_marketing_consent.sql
-- ============================================================================

-- Marketing consent remains optional and distinct from operational booking messages.
-- The client uses one combined checkbox, while the database records the two channels
-- separately so a future guest preference centre can manage either one precisely.

alter table public.guests
  add column if not exists email_marketing_opt_in boolean not null default false,
  add column if not exists marketing_consent_at timestamptz,
  add column if not exists marketing_consent_version text;

create table if not exists public.guest_consents (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  guest_id uuid not null references public.guests(id) on delete cascade,
  channel text not null check (channel in ('email', 'whatsapp')),
  purpose text not null check (purpose = 'marketing'),
  action text not null check (action in ('granted', 'withdrawn')),
  consent_version text not null,
  source public.booking_source not null,
  captured_at timestamptz not null default now()
);

alter table public.guest_consents enable row level security;
revoke all on public.guest_consents from anon, authenticated;
grant select on public.guest_consents to authenticated;

drop policy if exists "authorised dashboard users can view guest consents" on public.guest_consents;
create policy "authorised dashboard users can view guest consents"
  on public.guest_consents for select to authenticated
  using (
    exists (
      select 1 from public.owner_profiles op
      where op.user_id = auth.uid() and op.property_id = guest_consents.property_id
    )
  );

-- New UAT endpoint signature; production will move this responsibility to a
-- rate-limited server function before launch.
create or replace function public.create_uat_booking_hold(
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
  p_guest_name text,
  p_guest_email text,
  p_guest_phone text,
  p_marketing_opt_in boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product bookable_products%rowtype;
  v_quote jsonb;
  v_guest_id uuid;
  v_reservation_id uuid;
  v_payment_id uuid;
  v_reference text;
  v_expiry timestamptz;
  v_hold_minutes integer;
  v_payment_settings jsonb;
  v_item jsonb;
  v_consent_version text := '2026-10-03';
begin
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Please enter the lead guest name'; end if;
  if position('@' in coalesce(p_guest_email, '')) < 2 then raise exception 'Please enter a valid email address'; end if;
  if coalesce(p_guest_phone, '') !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Please enter a valid mobile number with country code'; end if;

  select * into v_product from bookable_products where id = p_product_id and active;
  if not found then raise exception 'This stay is no longer available'; end if;

  select get_booking_quote(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings) into v_quote;
  select value into v_payment_settings from property_settings where property_id = v_product.property_id and setting_key = 'payment_holds';
  v_hold_minutes := coalesce((v_payment_settings ->> 'direct_checkout_minutes')::integer, 10);
  v_expiry := now() + make_interval(mins => v_hold_minutes);
  v_reference := 'BW-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));

  insert into guests (property_id, full_name, email, phone_e164, email_marketing_opt_in, whatsapp_opt_in, marketing_consent_at, marketing_consent_version)
  values (v_product.property_id, trim(p_guest_name), lower(trim(p_guest_email)), trim(p_guest_phone), p_marketing_opt_in, p_marketing_opt_in,
    case when p_marketing_opt_in then now() else null end,
    case when p_marketing_opt_in then v_consent_version else null end)
  returning id into v_guest_id;

  if p_marketing_opt_in then
    insert into guest_consents (property_id, guest_id, channel, purpose, action, consent_version, source)
    values
      (v_product.property_id, v_guest_id, 'email', 'marketing', 'granted', v_consent_version, 'website'),
      (v_product.property_id, v_guest_id, 'whatsapp', 'marketing', 'granted', v_consent_version, 'website');
  end if;

  insert into reservations (property_id, reference, guest_id, product_id, check_in, check_out, adults, children_7_to_12, children_0_to_6, pets, source, status)
  values (v_product.property_id, v_reference, v_guest_id, v_product.id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, 'website', 'pending_payment')
  returning id into v_reservation_id;

  insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
  select v_product.property_id, bpr.resource_id, v_reservation_id, daterange(p_check_in, p_check_out, '[)'), 'hold', v_expiry
  from bookable_product_resources bpr
  where bpr.product_id = v_product.id;

  insert into price_snapshots (reservation_id, total_paise, calculation)
  values (v_reservation_id, (v_quote ->> 'total_paise')::integer, v_quote);

  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (
      v_reservation_id,
      case when v_item ->> 'label' like '%stay' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end,
      v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer
    );
  end loop;

  insert into payments (reservation_id, provider, amount_paise, state, expires_at)
  values (v_reservation_id, 'phonepe', (v_quote ->> 'total_paise')::integer, 'created', v_expiry)
  returning id into v_payment_id;

  insert into audit_log (property_id, entity_type, entity_id, action, data)
  values (v_product.property_id, 'reservation', v_reservation_id, 'uat_hold_created', jsonb_build_object('reference', v_reference, 'expires_at', v_expiry, 'marketing_opt_in', p_marketing_opt_in));

  return jsonb_build_object('reservation_id', v_reservation_id, 'reference', v_reference, 'payment_id', v_payment_id, 'expires_at', v_expiry, 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

revoke all on function public.create_uat_booking_hold(uuid, date, date, integer, integer, integer, integer, text, integer, integer, text, text, text, boolean) from public;
grant execute on function public.create_uat_booking_hold(uuid, date, date, integer, integer, integer, integer, text, integer, integer, text, text, text, boolean) to anon, authenticated;


-- ============================================================================
-- 08. 202610030007_activity_pricing_revision.sql
-- ============================================================================

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


-- ============================================================================
-- 09. 202610030008_weekday_villa_and_extra_pax_pricing.sql
-- ============================================================================

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


-- ============================================================================
-- 10. 202610030009_fix_availability_starting_rates.sql
-- ============================================================================

-- Show the lowest current meal-plan tariff as the availability-card "From" price.
-- Each plan first resolves its highest-priority applicable rule; then the UI gets
-- the lowest of those resolved plans.

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
    (
      select min(winning_rate.nightly_amount_paise)
      from (
        select distinct on (rr.rate_plan_id) rr.nightly_amount_paise
        from rate_rules rr
        where rr.product_id = p.id and rr.active and rr.valid_during @> p_check_in
          and p_party_size between rr.party_min and rr.party_max
          and (rr.weekday_mask & (1 << extract(dow from p_check_in)::integer)) <> 0
        order by rr.rate_plan_id, rr.priority desc, lower(rr.valid_during) desc
      ) as winning_rate
    ) as from_amount_paise
  from bookable_products p cross join requested_stay rs left join room_weekend_rule rwr on rwr.property_id = p.property_id
  where p.active and p_party_size between p.minimum_overnight_guests and p.max_overnight_guests
    and not (p.sellable_kind = 'room' and coalesce(rwr.enabled, false) and rs.nights < rwr.minimum_nights and exists (select 1 from generate_series(p_check_in, p_check_out - 1, interval '1 day') as stay_day where extract(dow from stay_day)::integer in (5, 6)))
    and exists (select 1 from rate_rules rr where rr.product_id = p.id and rr.active and rr.valid_during @> p_check_in and p_party_size between rr.party_min and rr.party_max and (rr.weekday_mask & (1 << extract(dow from p_check_in)::integer)) <> 0)
    and not exists (select 1 from bookable_product_resources bpr join inventory_allocations ia on ia.resource_id = bpr.resource_id where bpr.product_id = p.id and ia.stay_during && rs.dates and ia.state in ('confirmed', 'block', 'hold') and (ia.state <> 'hold' or ia.expires_at > now()))
  order by p.display_order;
$$;

revoke all on function public.get_available_products(date, date, integer) from public;
grant execute on function public.get_available_products(date, date, integer) to anon, authenticated;


-- ============================================================================
-- 11. 202610030010_bougan_two_room_bundle.sql
-- ============================================================================

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


-- ============================================================================
-- 12. 202610030011_owner_reservation_detail.sql
-- ============================================================================

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


-- ============================================================================
-- 13. 202610030012_release_expired_payment_holds.sql
-- ============================================================================

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


-- ============================================================================
-- 14. 202610040014_daily_pricing_calendar_clean_install.sql
-- ============================================================================

-- Clean installation script. Use this fresh file after the prior failed attempts.

-- Daily pricing calendar v2. The calendar is deliberately disabled until the
-- owner-approved CSV is imported. While disabled, existing UAT pricing remains
-- unchanged through the renamed legacy functions.

create table if not exists public.daily_pricing_calendar (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  stay_date date not null,
  tier_code text not null,
  couple_room_paise integer not null check (couple_room_paise >= 0),
  single_room_paise integer not null check (single_room_paise >= 0),
  extra_adult_paise integer not null check (extra_adult_paise >= 0),
  extra_child_7_to_12_paise integer not null check (extra_child_7_to_12_paise >= 0),
  minimum_stay_nights integer not null default 1 check (minimum_stay_nights > 0),
  individual_rooms_bookable boolean not null default true,
  individual_room_minimum_nights integer not null default 1 check (individual_room_minimum_nights > 0),
  buyout_discount_eligible boolean not null default false,
  buyout_one_night_discount_bps_group_10 integer not null default 0 check (buyout_one_night_discount_bps_group_10 between 0 and 10000),
  buyout_one_night_discount_bps_group_15 integer not null default 0 check (buyout_one_night_discount_bps_group_15 between 0 and 10000),
  buyout_two_plus_nights_discount_bps_group_10 integer not null default 0 check (buyout_two_plus_nights_discount_bps_group_10 between 0 and 10000),
  buyout_two_plus_nights_discount_bps_group_15 integer not null default 0 check (buyout_two_plus_nights_discount_bps_group_15 between 0 and 10000),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (property_id, stay_date)
);

alter table public.daily_pricing_calendar enable row level security;
revoke all on public.daily_pricing_calendar from anon, authenticated;

do $$
declare property_uuid uuid;
begin
  select id into property_uuid from public.properties where name = 'Breathe Woods' limit 1;
  if property_uuid is null then raise exception 'Breathe Woods property configuration is missing'; end if;

  insert into public.property_settings (property_id, setting_key, value)
  values (
    property_uuid,
    'daily_pricing_calendar',
    '{
      "enabled": false,
      "status": "awaiting_owner_approved_csv",
      "meal_upgrade_paise_per_night": {
        "breakfast_plus_one": {"adult": 37500, "child_7_to_12": 27500},
        "all_meals": {"adult": 75000, "child_7_to_12": 55000}
      },
      "full_property": {"minimum_paying_guests": 10, "base_paise": 5000000, "additional_paying_guest_paise": 350000}
    }'::jsonb
  ) on conflict (property_id, setting_key) do update set value = excluded.value, updated_at = now();
end;
$$;

-- Preserve the current pricing behaviour for safe rollback and for the period
-- before the owner supplies the actual daily CSV.
alter function public.get_available_products(date, date, integer) rename to get_available_products_legacy;
alter function public.get_booking_quote(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) rename to get_booking_quote_legacy;

create or replace function public.daily_pricing_is_enabled(p_property_id uuid)
returns boolean language sql security definer set search_path = public as $$
  select coalesce((value ->> 'enabled')::boolean, false)
  from property_settings
  where property_id = p_property_id and setting_key = 'daily_pricing_calendar'
$$;

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


-- ============================================================================
-- 15. 202610040015_simplified_room_selection.sql
-- ============================================================================

-- Guest-facing room selection simplification and family room capacity.
-- Physical room resources remain operational-only; guest-facing products allocate any free child room.

do $$
declare
  v_property_id uuid;
  v_zen_id uuid;
  v_bougan_id uuid;
begin
  select id into v_property_id from public.properties where name = 'Breathe Woods' limit 1;
  select id into v_zen_id from public.resources where property_id = v_property_id and name = 'Zen Villa' limit 1;
  select id into v_bougan_id from public.resources where property_id = v_property_id and name = 'Bougan''villa' limit 1;
  if v_property_id is null or v_zen_id is null or v_bougan_id is null then raise exception 'Breathe Woods accommodation configuration is missing'; end if;

  update public.bookable_products
  set active = false
  where property_id = v_property_id and code in ('zen-1', 'zen-2', 'bougan-1', 'bougan-2', 'bougan-3');

  insert into public.bookable_products (property_id, primary_resource_id, code, name, sellable_kind, minimum_overnight_guests, max_overnight_guests, included_chargeable_guests, display_order, inventory_mode, room_units_required)
  values
    (v_property_id, v_zen_id, 'zen-room', 'Private room at Zen Villa', 'room', 1, 4, 2, 10, 'child_rooms', 1),
    (v_property_id, v_bougan_id, 'bougan-room', 'Private room at Bougan''villa', 'room', 1, 4, 2, 30, 'child_rooms', 1)
  on conflict (property_id, code) do update set
    primary_resource_id = excluded.primary_resource_id,
    name = excluded.name,
    sellable_kind = excluded.sellable_kind,
    minimum_overnight_guests = excluded.minimum_overnight_guests,
    max_overnight_guests = excluded.max_overnight_guests,
    included_chargeable_guests = excluded.included_chargeable_guests,
    display_order = excluded.display_order,
    inventory_mode = excluded.inventory_mode,
    room_units_required = excluded.room_units_required,
    active = true;

  update public.bookable_products
  set max_overnight_guests = 8, included_chargeable_guests = 4, active = true
  where property_id = v_property_id and code = 'bougan-two-rooms';
end;
$$;

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
  if v_product.sellable_kind = 'room' and (v_party_size > 4 or p_children_0_to_6 > 2 or p_children_7_to_12 > 1 or p_children_0_to_6 + p_children_7_to_12 > 2 or p_adults > 2) then raise exception 'A room accommodates up to two adults and two children, with at most one child aged 7-12.'; end if;
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
      v_room_base := case when v_product.sellable_kind = 'room' and v_party_size = 1 then v_day.single_room_paise else v_day.couple_room_paise * v_units end;
      v_adult_extra := case when v_product.sellable_kind = 'room' then greatest(p_adults - 2, 0) else greatest(p_adults - v_product.included_chargeable_guests, 0) end * v_day.extra_adult_paise;
      v_child_extra := case when v_product.sellable_kind = 'room' then greatest(p_children_7_to_12 - greatest(2 - p_adults, 0), 0) else greatest(v_chargeable_party - v_product.included_chargeable_guests - greatest(p_adults - v_product.included_chargeable_guests, 0), 0) end * v_day.extra_child_7_to_12_paise;
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


-- ============================================================================
-- 16. 202610040016_payment_hold_lifecycle.sql
-- ============================================================================

-- Payment hold lifecycle hardening.
--
-- This migration makes the database—not the browser—the authority for a
-- temporary hold, its expiry, and the eventual confirmed booking. The
-- PhonePe Edge Function will call the server-only functions below after it
-- creates checkout and after it verifies a PhonePe callback signature.

create or replace function public.lock_property_inventory(p_property_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- One short transaction lock per property prevents two overlapping requests
  -- from selecting the same physical room before either allocation is written.
  perform pg_advisory_xact_lock(hashtextextended(p_property_id::text, 0));
end;
$$;

create or replace function public.release_expired_payment_holds(p_property_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_released integer := 0;
begin
  perform public.lock_property_inventory(p_property_id);

  update payments pay
  set state = 'expired', updated_at = now()
  from reservations reservation
  where pay.reservation_id = reservation.id
    and reservation.property_id = p_property_id
    and pay.state in ('created', 'pending')
    and pay.expires_at <= now();

  update reservations reservation
  set status = 'cancelled', updated_at = now()
  where reservation.property_id = p_property_id
    and reservation.status = 'pending_payment'
    and exists (
      select 1
      from inventory_allocations allocation
      where allocation.reservation_id = reservation.id
        and allocation.state = 'hold'
        and allocation.expires_at <= now()
    );

  delete from inventory_allocations allocation
  where allocation.property_id = p_property_id
    and allocation.state = 'hold'
    and allocation.expires_at <= now();

  get diagnostics v_released = row_count;
  return v_released;
end;
$$;

-- Replaces the previous public endpoint with one that takes the same short
-- property lock before quote validation and allocation. This makes a room,
-- villa, bundle, or whole-property request atomic with every other request.
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

  perform public.lock_property_inventory(v_product.property_id);
  perform public.release_expired_payment_holds(v_product.property_id);

  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then
    raise exception 'This stay was just booked or blocked. Please search again.';
  end if;

  -- This is the final server-side quote. It is written as an immutable price
  -- snapshot and is the only amount a payment attempt may charge.
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
  values (v_product.property_id, v_reference, v_guest_id, v_product.id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, 'website', 'pending_payment')
  returning id into v_reservation_id;

  if v_product.inventory_mode = 'child_rooms' then
    insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
    select v_product.property_id, child.id, v_reservation_id, daterange(p_check_in, p_check_out, '[)'), 'hold', v_expiry
    from resources child
    where child.parent_resource_id = v_product.primary_resource_id and child.active
      and not exists (
        select 1 from inventory_allocations allocation
        where allocation.resource_id = child.id
          and allocation.stay_during && daterange(p_check_in, p_check_out, '[)')
          and allocation.state in ('confirmed', 'block', 'hold')
      )
    order by child.name limit v_product.room_units_required;
    select count(*) into v_allocated from inventory_allocations where reservation_id = v_reservation_id and state = 'hold';
    if v_allocated < v_product.room_units_required then
      raise exception 'Those rooms were just booked. Please search again.';
    end if;
  else
    insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
    select v_product.property_id, bpr.resource_id, v_reservation_id, daterange(p_check_in, p_check_out, '[)'), 'hold', v_expiry
    from bookable_product_resources bpr where bpr.product_id = v_product.id;
  end if;

  insert into price_snapshots (reservation_id, total_paise, calculation)
  values (v_reservation_id, (v_quote ->> 'total_paise')::integer, v_quote);
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (v_reservation_id,
      case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end,
      v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into payments (reservation_id, provider, amount_paise, state, expires_at)
  values (v_reservation_id, 'phonepe', (v_quote ->> 'total_paise')::integer, 'created', v_expiry)
  returning id into v_payment_id;
  insert into audit_log (property_id, entity_type, entity_id, action, data)
  values (v_product.property_id, 'reservation', v_reservation_id, 'payment_hold_created', jsonb_build_object('reference', v_reference, 'expires_at', v_expiry, 'total_paise', (v_quote ->> 'total_paise')::integer));
  return jsonb_build_object('reservation_id', v_reservation_id, 'reference', v_reference, 'payment_id', v_payment_id, 'expires_at', v_expiry, 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

-- Called only by the server-side PhonePe checkout creator. A browser cannot
-- register a payment identifier or move a payment to pending.
create or replace function public.register_payment_checkout(
  p_payment_id uuid, p_provider_reference text, p_provider_payload jsonb default '{}'::jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_payment payments%rowtype; v_property_id uuid;
begin
  select * into v_payment from payments where id = p_payment_id for update;
  if not found then raise exception 'Payment hold was not found'; end if;
  select property_id into v_property_id from reservations where id = v_payment.reservation_id;
  perform public.lock_property_inventory(v_property_id);
  if v_payment.state not in ('created', 'pending') or v_payment.expires_at <= now() then
    raise exception 'This payment window has expired';
  end if;
  update payments set provider_reference = p_provider_reference, provider_payload = coalesce(p_provider_payload, '{}'::jsonb), state = 'pending', updated_at = now()
  where id = p_payment_id;
  return jsonb_build_object('payment_id', p_payment_id, 'merchant_reference', p_provider_reference, 'amount_paise', v_payment.amount_paise, 'expires_at', v_payment.expires_at);
end;
$$;

-- Called only after PhonePe's callback has been signature-verified by an Edge
-- Function. It is idempotent: a repeated genuine callback returns confirmed.
create or replace function public.confirm_verified_payment(
  p_provider text, p_provider_reference text, p_amount_paise integer,
  p_provider_payload jsonb default '{}'::jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_payment payments%rowtype; v_reservation reservations%rowtype; v_has_live_hold boolean;
begin
  select pay.* into v_payment from payments pay
  where pay.provider = p_provider and pay.provider_reference = p_provider_reference for update;
  if not found then raise exception 'Payment reference was not found'; end if;
  select * into v_reservation from reservations where id = v_payment.reservation_id for update;
  perform public.lock_property_inventory(v_reservation.property_id);

  if v_payment.state = 'paid' and v_reservation.status = 'confirmed' then
    return jsonb_build_object('status', 'confirmed', 'reservation_id', v_reservation.id, 'reference', v_reservation.reference);
  end if;
  if p_amount_paise <> v_payment.amount_paise then
    update reservations set status = 'payment_exception', updated_at = now() where id = v_reservation.id;
    update payments set provider_payload = coalesce(p_provider_payload, '{}'::jsonb), updated_at = now() where id = v_payment.id;
    insert into audit_log (property_id, entity_type, entity_id, action, data)
    values (v_reservation.property_id, 'payment', v_payment.id, 'payment_amount_mismatch', jsonb_build_object('expected_paise', v_payment.amount_paise, 'received_paise', p_amount_paise));
    return jsonb_build_object('status', 'payment_exception', 'reason', 'amount_mismatch', 'reference', v_reservation.reference);
  end if;
  select exists(
    select 1 from inventory_allocations allocation
    where allocation.reservation_id = v_reservation.id and allocation.state = 'hold' and allocation.expires_at > now()
  ) into v_has_live_hold;
  if not v_has_live_hold or v_payment.expires_at <= now() then
    update payments set state = 'paid', provider_payload = coalesce(p_provider_payload, '{}'::jsonb), updated_at = now() where id = v_payment.id;
    update reservations set status = 'payment_exception', updated_at = now() where id = v_reservation.id;
    insert into audit_log (property_id, entity_type, entity_id, action, data)
    values (v_reservation.property_id, 'payment', v_payment.id, 'late_payment_requires_review', jsonb_build_object('reference', v_reservation.reference));
    return jsonb_build_object('status', 'payment_exception', 'reason', 'hold_expired', 'reference', v_reservation.reference);
  end if;

  update payments set state = 'paid', provider_payload = coalesce(p_provider_payload, '{}'::jsonb), updated_at = now() where id = v_payment.id;
  update inventory_allocations set state = 'confirmed', expires_at = null where reservation_id = v_reservation.id and state = 'hold';
  update reservations set status = 'confirmed', updated_at = now() where id = v_reservation.id;
  update price_snapshots set accepted_at = now() where reservation_id = v_reservation.id;
  insert into audit_log (property_id, entity_type, entity_id, action, data)
  values (v_reservation.property_id, 'reservation', v_reservation.id, 'payment_verified_booking_confirmed', jsonb_build_object('provider', p_provider, 'provider_reference', p_provider_reference));
  return jsonb_build_object('status', 'confirmed', 'reservation_id', v_reservation.id, 'reference', v_reservation.reference);
end;
$$;

-- Safe status polling after a payment redirect. The random reservation id and
-- booking reference are both required; no guest data is returned.
create or replace function public.get_public_booking_hold_status(p_reservation_id uuid, p_reference text)
returns jsonb language sql security definer set search_path = public stable as $$
  select jsonb_build_object(
    'reservation_status', reservation.status,
    'payment_state', payment.state,
    'expires_at', payment.expires_at,
    'total_paise', payment.amount_paise,
    'reference', reservation.reference
  )
  from reservations reservation
  join payments payment on payment.reservation_id = reservation.id
  where reservation.id = p_reservation_id and reservation.reference = p_reference;
$$;

revoke all on function public.lock_property_inventory(uuid) from public;
revoke all on function public.release_expired_payment_holds(uuid) from public;
revoke all on function public.register_payment_checkout(uuid, text, jsonb) from public;
revoke all on function public.confirm_verified_payment(text, text, integer, jsonb) from public;
revoke all on function public.get_public_booking_hold_status(uuid, text) from public;
grant execute on function public.create_uat_booking_hold_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean) to anon, authenticated;
grant execute on function public.get_public_booking_hold_status(uuid, text) to anon, authenticated;
grant execute on function public.lock_property_inventory(uuid) to service_role;
grant execute on function public.release_expired_payment_holds(uuid) to service_role;
grant execute on function public.register_payment_checkout(uuid, text, jsonb) to service_role;
grant execute on function public.confirm_verified_payment(text, text, integer, jsonb) to service_role;


-- ============================================================================
-- 17. 202610040018_indian_mobile_validation.sql
-- ============================================================================

-- Keep India-specific mobile validation at the database boundary as well as
-- in the form. This protects future owner-created and WhatsApp bookings too.

create or replace function public.validate_guest_phone_e164()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.phone_e164 is not null
    and left(new.phone_e164, 3) = '+91'
    and substring(new.phone_e164 from 4) !~ '^[6-9][0-9]{9}$' then
    raise exception 'For India, enter a 10-digit mobile number after +91';
  end if;
  return new;
end;
$$;

drop trigger if exists validate_guest_phone_e164_before_write on public.guests;
create trigger validate_guest_phone_e164_before_write
  before insert or update of phone_e164 on public.guests
  for each row execute function public.validate_guest_phone_e164();


-- ============================================================================
-- 18. 202610040019_reservation_item_audit_timestamp.sql
-- ============================================================================

-- Reservation detail uses item creation order for a stable, auditable price
-- breakdown. Earlier UAT tables did not yet carry this timestamp.

alter table public.reservation_items
  add column if not exists created_at timestamptz not null default now();


-- ============================================================================
-- 19. 202610050020_reservation_request_workflow.sql
-- ============================================================================

-- Reservation-request workflow for launch before a payment gateway is live.
-- Requests do not allocate inventory. Only an owner-created manual payment hold
-- or a confirmed reservation can block inventory.

alter type public.reservation_status add value if not exists 'requested';
alter type public.reservation_status add value if not exists 'in_conversation';
alter type public.reservation_status add value if not exists 'alternative_offered';
alter type public.reservation_status add value if not exists 'awaiting_manual_payment';
alter type public.reservation_status add value if not exists 'declined';

create table if not exists public.calendar_sync_outbox (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  event_type text not null check (event_type in ('confirmed', 'changed', 'cancelled')),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (reservation_id, event_type, processed_at)
);
alter table public.calendar_sync_outbox enable row level security;
create unique index if not exists calendar_sync_outbox_one_pending_event
  on public.calendar_sync_outbox(reservation_id, event_type) where processed_at is null;

-- Preserve the exact guest choices that produced a request. This allows an
-- owner to offer new dates without re-entering the party, meals or add-ons.
create table if not exists public.reservation_request_inputs (
  reservation_id uuid primary key references public.reservations(id) on delete cascade,
  meal_plan text not null,
  bonfire_sessions integer not null default 0 check (bonfire_sessions >= 0),
  lake_outings integer not null default 0 check (lake_outings >= 0),
  lake_trip_guests integer not null default 0 check (lake_trip_guests >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.reservation_request_inputs enable row level security;

create or replace function public.get_reservation_cancellation_policy(p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare
  v_reservation reservations%rowtype;
  v_product bookable_products%rowtype;
  v_amount integer := 0;
  v_days integer;
  v_peak boolean := false;
begin
  select * into v_reservation from reservations where id = p_reservation_id;
  if not found then raise exception 'Reservation not found'; end if;
  select * into v_product from bookable_products where id = v_reservation.product_id;
  select coalesce(sum(amount_paise), 0) into v_amount from payments where reservation_id = p_reservation_id and state = 'paid';
  v_days := v_reservation.check_in - (now() at time zone 'Asia/Kolkata')::date;
  select exists(
    select 1 from daily_pricing_calendar
    where property_id = v_reservation.property_id
      and stay_date >= v_reservation.check_in and stay_date < v_reservation.check_out
      and tier_code ~* '(premium|ultra|holiday|long)'
  ) into v_peak;

  if v_product.sellable_kind in ('villa', 'room_bundle', 'entire_property') or v_peak then
    return jsonb_build_object('refund_percent', 0, 'refund_paise', 0, 'decision', 'non_refundable', 'message', 'This stay is non-refundable because it is a full-villa, group, long-weekend or festive-period booking.', 'date_change_allowed', false);
  elsif v_days > 14 then
    return jsonb_build_object('refund_percent', 100, 'refund_paise', v_amount, 'decision', 'full_less_gateway_charges', 'message', 'Full refund applies, less any non-refundable payment-gateway charges. Refund processing target: 5–9 days.', 'date_change_allowed', true);
  elsif v_days >= 7 then
    return jsonb_build_object('refund_percent', 50, 'refund_paise', round(v_amount * .5)::integer, 'decision', 'half_refund', 'message', 'A 50% refund applies. Refund processing target: 5–9 days.', 'date_change_allowed', false);
  else
    return jsonb_build_object('refund_percent', 0, 'refund_paise', 0, 'decision', 'no_refund', 'message', 'No refund applies within 7 days of check-in, for no-shows, or for early departures.', 'date_change_allowed', false);
  end if;
end;
$$;

create or replace function public.create_reservation_request_bundle_aware(
  p_product_id uuid, p_check_in date, p_check_out date, p_adults integer,
  p_children_7_to_12 integer, p_children_0_to_6 integer, p_pets integer,
  p_meal_plan text, p_bonfire_sessions integer, p_lake_outings integer,
  p_lake_trip_guests integer, p_guest_name text, p_guest_email text,
  p_guest_phone text, p_marketing_opt_in boolean
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_product bookable_products%rowtype; v_quote jsonb; v_guest_id uuid;
  v_reservation_id uuid; v_reference text; v_item jsonb; v_consent_version text := '2026-10-05';
begin
  select * into v_product from bookable_products where id = p_product_id and active;
  if not found then raise exception 'This stay is no longer available'; end if;
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Please enter the lead guest name'; end if;
  if position('@' in coalesce(p_guest_email, '')) < 2 then raise exception 'Please enter a valid email address'; end if;
  if coalesce(p_guest_phone, '') !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Please enter a valid mobile number with country code'; end if;
  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then raise exception 'This stay is not currently available. Please choose other dates.'; end if;
  v_quote := public.get_booking_quote(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests);
  v_reference := 'BW-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  insert into guests (property_id, full_name, email, phone_e164, email_marketing_opt_in, whatsapp_opt_in, marketing_consent_at, marketing_consent_version)
  values (v_product.property_id, trim(p_guest_name), lower(trim(p_guest_email)), trim(p_guest_phone), p_marketing_opt_in, p_marketing_opt_in, case when p_marketing_opt_in then now() else null end, case when p_marketing_opt_in then v_consent_version else null end) returning id into v_guest_id;
  if p_marketing_opt_in then insert into guest_consents (property_id, guest_id, channel, purpose, action, consent_version, source)
  values (v_product.property_id, v_guest_id, 'email', 'marketing', 'granted', v_consent_version, 'website'), (v_product.property_id, v_guest_id, 'whatsapp', 'marketing', 'granted', v_consent_version, 'website'); end if;
  insert into reservations (property_id, reference, guest_id, product_id, check_in, check_out, adults, children_7_to_12, children_0_to_6, pets, source, status)
  values (v_product.property_id, v_reference, v_guest_id, v_product.id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, 'website', 'requested') returning id into v_reservation_id;
  insert into price_snapshots (reservation_id, total_paise, calculation) values (v_reservation_id, (v_quote ->> 'total_paise')::integer, v_quote);
  insert into reservation_request_inputs (reservation_id, meal_plan, bonfire_sessions, lake_outings, lake_trip_guests)
  values (v_reservation_id, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests);
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (v_reservation_id, case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end, v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into audit_log (property_id, entity_type, entity_id, action, data)
  values (v_product.property_id, 'reservation', v_reservation_id, 'request_submitted', jsonb_build_object('reference', v_reference));
  return jsonb_build_object('reservation_id', v_reservation_id, 'reference', v_reference, 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

-- Lets an owner offer alternative dates before taking payment. Existing guest
-- selections are retained and the final total is always recalculated by the
-- same public pricing function the guest saw.
create or replace function public.owner_reprice_reservation_request(
  p_reservation_id uuid, p_check_in date, p_check_out date, p_note text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype; v_inputs reservation_request_inputs%rowtype; v_quote jsonb; v_item jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to change this reservation'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') then raise exception 'Only an open reservation request can be re-priced'; end if;
  if p_check_out <= p_check_in then raise exception 'Check-out must be after check-in'; end if;
  perform public.lock_property_inventory(v_property_id);
  if not public.is_product_inventory_available(v_reservation.product_id, p_check_in, p_check_out) then raise exception 'Those dates are no longer available'; end if;
  select * into v_inputs from reservation_request_inputs where reservation_id = p_reservation_id;
  if not found then raise exception 'The original request inputs are unavailable'; end if;
  v_quote := public.get_booking_quote(v_reservation.product_id, p_check_in, p_check_out, v_reservation.adults, v_reservation.children_7_to_12, v_reservation.children_0_to_6, v_reservation.pets, v_inputs.meal_plan, v_inputs.bonfire_sessions, v_inputs.lake_outings, v_inputs.lake_trip_guests);
  update reservations set check_in = p_check_in, check_out = p_check_out, status = 'alternative_offered', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
  update price_snapshots set total_paise = (v_quote ->> 'total_paise')::integer, calculation = v_quote, accepted_at = null where reservation_id = p_reservation_id;
  delete from reservation_items where reservation_id = p_reservation_id;
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (p_reservation_id, case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end, v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data) values (v_property_id, auth.uid(), 'reservation', p_reservation_id, 'alternative_dates_offered', jsonb_build_object('check_in', p_check_in, 'check_out', p_check_out, 'note', p_note));
  return jsonb_build_object('status', 'alternative_offered', 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

create or replace function public.owner_reservation_workflow_action(
  p_reservation_id uuid, p_action text, p_hold_hours integer default 12, p_note text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype; v_product bookable_products%rowtype;
  v_allocated integer; v_expiry timestamptz; v_policy jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to change this reservation'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  select * into v_product from bookable_products where id = v_reservation.product_id;
  perform public.lock_property_inventory(v_property_id);

  if p_action = 'start_conversation' then
    update reservations set status = 'in_conversation', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
  elsif p_action = 'decline' then
    delete from inventory_allocations where reservation_id = p_reservation_id and state = 'hold';
    update reservations set status = 'declined', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
  elsif p_action = 'hold_for_manual_payment' then
    if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') then raise exception 'Only an open request can be held for manual payment'; end if;
    if not public.is_product_inventory_available(v_product.id, v_reservation.check_in, v_reservation.check_out) then raise exception 'These dates are no longer available'; end if;
    v_expiry := now() + make_interval(hours => least(greatest(p_hold_hours, 1), 48));
    if v_product.inventory_mode = 'child_rooms' then
      insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
      select v_property_id, child.id, p_reservation_id, daterange(v_reservation.check_in, v_reservation.check_out, '[)'), 'hold', v_expiry
      from resources child where child.parent_resource_id = v_product.primary_resource_id and child.active and not exists
        (select 1 from inventory_allocations a where a.resource_id = child.id and a.stay_during && daterange(v_reservation.check_in, v_reservation.check_out, '[)') and a.state in ('confirmed','block','hold'))
      order by child.name limit v_product.room_units_required;
      select count(*) into v_allocated from inventory_allocations where reservation_id = p_reservation_id and state = 'hold';
      if v_allocated < v_product.room_units_required then raise exception 'Those rooms were just booked. Please offer alternate dates.'; end if;
    else
      insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state, expires_at)
      select v_property_id, resource_id, p_reservation_id, daterange(v_reservation.check_in, v_reservation.check_out, '[)'), 'hold', v_expiry from bookable_product_resources where product_id = v_product.id;
    end if;
    insert into payments (reservation_id, provider, amount_paise, state, expires_at)
    select p_reservation_id, 'manual', total_paise, 'pending', v_expiry from price_snapshots where reservation_id = p_reservation_id;
    update reservations set status = 'awaiting_manual_payment', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
  elsif p_action = 'confirm_manual_payment' then
    if v_reservation.status <> 'awaiting_manual_payment' then raise exception 'Create a manual payment hold before confirming payment'; end if;
    update inventory_allocations set state = 'confirmed', expires_at = null where reservation_id = p_reservation_id and state = 'hold' and expires_at > now();
    if not found then raise exception 'The manual payment hold expired; check availability again'; end if;
    update payments set state = 'paid', updated_at = now() where reservation_id = p_reservation_id and provider = 'manual' and state in ('created','pending');
    update reservations set status = 'confirmed', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
    update price_snapshots set accepted_at = now() where reservation_id = p_reservation_id;
    insert into calendar_sync_outbox (property_id, reservation_id, event_type, payload) values
      (v_property_id, p_reservation_id, 'confirmed', jsonb_build_object('reference', v_reservation.reference));
  elsif p_action = 'cancel' then
    v_policy := public.get_reservation_cancellation_policy(p_reservation_id);
    delete from inventory_allocations where reservation_id = p_reservation_id;
    update reservations set status = 'cancelled', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
    insert into calendar_sync_outbox (property_id, reservation_id, event_type, payload) values
      (v_property_id, p_reservation_id, 'cancelled', v_policy);
  else
    raise exception 'Unsupported owner workflow action';
  end if;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'reservation', p_reservation_id, p_action, jsonb_build_object('note', p_note));
  return jsonb_build_object('status', (select status from reservations where id = p_reservation_id), 'expires_at', v_expiry, 'cancellation_policy', case when p_action = 'cancel' then v_policy else null end);
end;
$$;

-- Manual-payment holds should free inventory on expiry but remain visible to
-- the owner as a conversation, rather than becoming an accidental booking.
create or replace function public.release_expired_payment_holds(p_property_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_released integer := 0;
begin
  perform public.lock_property_inventory(p_property_id);
  update payments pay set state = 'expired', updated_at = now()
  from reservations r where pay.reservation_id = r.id and r.property_id = p_property_id
    and pay.state in ('created', 'pending') and pay.expires_at <= now();
  update reservations r set status = case when r.status = 'awaiting_manual_payment' then 'in_conversation' else 'cancelled' end, updated_at = now()
  where r.property_id = p_property_id and r.status in ('pending_payment', 'awaiting_manual_payment')
    and exists (select 1 from inventory_allocations a where a.reservation_id = r.id and a.state = 'hold' and a.expires_at <= now());
  delete from inventory_allocations a where a.property_id = p_property_id and a.state = 'hold' and a.expires_at <= now();
  get diagnostics v_released = row_count;
  return v_released;
end;
$$;

create or replace function public.get_owner_reservation_detail(p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_property_id uuid; v_result jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  select jsonb_build_object(
    'reservation', jsonb_build_object('id', r.id, 'reference', r.reference, 'status', r.status, 'check_in', r.check_in, 'check_out', r.check_out, 'adults', r.adults, 'children_7_to_12', r.children_7_to_12, 'children_0_to_6', r.children_0_to_6, 'pets', r.pets, 'source', r.source, 'guest_name', g.full_name, 'guest_email', g.email, 'guest_phone', g.phone_e164, 'product_name', p.name, 'internal_note', r.internal_note, 'total_paise', ps.total_paise),
    'items', coalesce((select jsonb_agg(jsonb_build_object('label', ri.label, 'quantity', ri.quantity, 'amount_paise', ri.amount_paise, 'item_type', ri.item_type) order by ri.created_at, ri.id) from reservation_items ri where ri.reservation_id = r.id), '[]'::jsonb),
    'payment', (select jsonb_build_object('provider', pay.provider, 'state', pay.state, 'amount_paise', pay.amount_paise, 'provider_reference', pay.provider_reference, 'expires_at', pay.expires_at) from payments pay where pay.reservation_id = r.id order by pay.created_at desc limit 1),
    'cancellation_policy', public.get_reservation_cancellation_policy(r.id)
  ) into v_result from reservations r left join guests g on g.id = r.guest_id left join bookable_products p on p.id = r.product_id left join price_snapshots ps on ps.reservation_id = r.id where r.id = p_reservation_id and r.property_id = v_property_id;
  if v_result is null then raise exception 'Booking not found'; end if;
  return v_result;
end;
$$;

create or replace function public.get_owner_open_reservation_requests()
returns table (
  reservation_id uuid, reference text, status text, check_in date, check_out date,
  guest_name text, product_name text, total_paise integer, created_at timestamptz
) language plpgsql security definer set search_path = public stable as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  return query
  select r.id, r.reference, r.status::text, r.check_in, r.check_out, g.full_name, p.name, ps.total_paise, r.created_at
  from reservations r
  left join guests g on g.id = r.guest_id
  left join bookable_products p on p.id = r.product_id
  left join price_snapshots ps on ps.reservation_id = r.id
  where r.property_id = v_property_id and r.status in ('requested', 'in_conversation', 'alternative_offered', 'awaiting_manual_payment')
  order by r.created_at desc;
end;
$$;

revoke all on function public.get_reservation_cancellation_policy(uuid) from public;
revoke all on function public.owner_reservation_workflow_action(uuid, text, integer, text) from public;
grant execute on function public.create_reservation_request_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean) to anon, authenticated;
grant execute on function public.get_owner_reservation_detail(uuid) to authenticated;
grant execute on function public.get_owner_open_reservation_requests() to authenticated;
-- This helper is used internally by owner workflows and owner detail. It is
-- not exposed directly because it can reveal payment/refund information for an
-- arbitrary reservation ID.
grant execute on function public.owner_reservation_workflow_action(uuid, text, integer, text) to authenticated;
grant execute on function public.owner_reprice_reservation_request(uuid, date, date, text) to authenticated;


-- ============================================================================
-- 20. 202610050021_owner_inventory_blocks.sql
-- ============================================================================

-- Owner-created availability blocks. The dashboard writes only through these
-- functions, so blocks use the same allocation guard as web reservations.

create or replace function public.get_owner_block_targets()
returns table (target_id uuid, scope text, label text)
language plpgsql security definer set search_path = public stable as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  return query
  select * from (
    select r.id as target_id, 'room'::text as scope, r.name as label from resources r
      where r.property_id = v_property_id and r.active and r.resource_kind = 'room'
    union all
    select r.id as target_id, 'villa'::text as scope, r.name || ' (entire villa)' as label from resources r
      where r.property_id = v_property_id and r.active and r.resource_kind = 'villa'
    union all
    select r.id as target_id, 'property'::text as scope, 'Entire property' as label from resources r
      where r.property_id = v_property_id and r.active and r.resource_kind = 'property'
  ) targets
  order by targets.scope, targets.label;
end;
$$;

create or replace function public.owner_create_inventory_block(
  p_target_id uuid, p_scope text, p_check_in date, p_check_out date, p_reason text
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_property_id uuid; v_block_id uuid; v_target resources%rowtype; v_count integer; v_expected_scope text;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to change availability'; end if;
  if p_check_out <= p_check_in then raise exception 'Choose a valid block date range'; end if;
  if length(trim(coalesce(p_reason, ''))) < 2 then raise exception 'Please add a short reason for the block'; end if;
  select * into v_target from resources where id = p_target_id and property_id = v_property_id and active;
  if not found then raise exception 'This block target is not available'; end if;
  v_expected_scope := case
    when v_target.resource_kind = 'room' then 'room'
    when v_target.resource_kind = 'villa' then 'villa'
    else 'property'
  end;
  if p_scope not in ('room', 'villa', 'property') or p_scope <> v_expected_scope then
    raise exception 'This block target is invalid';
  end if;
  perform public.lock_property_inventory(v_property_id);
  insert into inventory_blocks (property_id, reason, created_by) values (v_property_id, trim(p_reason), auth.uid()) returning id into v_block_id;
  insert into inventory_allocations (property_id, resource_id, block_id, stay_during, state)
  select v_property_id, r.id, v_block_id, daterange(p_check_in, p_check_out, '[)'), 'block'
  from resources r
  where r.property_id = v_property_id and r.active and r.resource_kind = 'room'
    and (p_scope = 'property' or (p_scope = 'villa' and r.parent_resource_id = v_target.id) or (p_scope = 'room' and r.id = v_target.id));
  get diagnostics v_count = row_count;
  if v_count = 0 then raise exception 'No rooms were found for this block'; end if;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'inventory_block', v_block_id, 'created', jsonb_build_object('scope', p_scope, 'target_id', p_target_id, 'check_in', p_check_in, 'check_out', p_check_out, 'reason', trim(p_reason)));
  return jsonb_build_object('block_id', v_block_id, 'rooms_blocked', v_count);
exception when exclusion_violation then
  delete from inventory_blocks where id = v_block_id;
  raise exception 'One or more selected rooms already have a booking, hold or block on those dates';
end;
$$;

create or replace function public.owner_remove_inventory_block(p_block_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to change availability'; end if;
  perform public.lock_property_inventory(v_property_id);
  if not exists (select 1 from inventory_blocks where id = p_block_id and property_id = v_property_id) then raise exception 'This block was not found'; end if;
  delete from inventory_blocks where id = p_block_id and property_id = v_property_id;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action) values (v_property_id, auth.uid(), 'inventory_block', p_block_id, 'removed');
end;
$$;

drop function if exists public.get_owner_calendar(date, date);

create function public.get_owner_calendar(p_start date, p_end date)
returns table (
  resource_id uuid, resource_name text, resource_kind text, allocation_id uuid, block_id uuid,
  reservation_id uuid, allocation_state public.allocation_state, hold_expires_at timestamptz,
  check_in date, check_out date, reservation_reference text, reservation_status public.reservation_status,
  guest_name text, block_reason text
) language plpgsql security definer set search_path = public as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  if p_end <= p_start then raise exception 'Choose a valid calendar range'; end if;
  return query
  select r.id, r.name, r.resource_kind, ia.id, ia.block_id, ia.reservation_id, ia.state, ia.expires_at,
    lower(ia.stay_during)::date, upper(ia.stay_during)::date, reservation.reference, reservation.status, guest.full_name, block.reason
  from resources r
  left join inventory_allocations ia on ia.resource_id = r.id and ia.stay_during && daterange(p_start, p_end, '[)') and (ia.state <> 'hold' or ia.expires_at > now())
  left join reservations reservation on reservation.id = ia.reservation_id
  left join guests guest on guest.id = reservation.guest_id
  left join inventory_blocks block on block.id = ia.block_id
  where r.property_id = v_property_id and r.active
  order by r.resource_kind, r.name, lower(ia.stay_during);
end;
$$;

revoke all on function public.get_owner_block_targets() from public;
revoke all on function public.owner_create_inventory_block(uuid, text, date, date, text) from public;
revoke all on function public.owner_remove_inventory_block(uuid) from public;
grant execute on function public.get_owner_block_targets() to authenticated;
grant execute on function public.owner_create_inventory_block(uuid, text, date, date, text) to authenticated;
grant execute on function public.owner_remove_inventory_block(uuid) to authenticated;
grant execute on function public.get_owner_calendar(date, date) to authenticated;


-- ============================================================================
-- 21. 202610050022_fix_owner_block_targets.sql
-- ============================================================================

-- Fix ordering in the target list used by the owner availability-block form.
create or replace function public.get_owner_block_targets()
returns table (target_id uuid, scope text, label text)
language plpgsql security definer set search_path = public stable as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  return query
  select * from (
    select r.id as target_id, 'room'::text as scope, r.name as label from resources r
      where r.property_id = v_property_id and r.active and r.resource_kind = 'room'
    union all
    select r.id as target_id, 'villa'::text as scope, r.name || ' (entire villa)' as label from resources r
      where r.property_id = v_property_id and r.active and r.resource_kind = 'villa'
    union all
    select r.id as target_id, 'property'::text as scope, 'Entire property' as label from resources r
      where r.property_id = v_property_id and r.active and r.resource_kind = 'property'
  ) targets
  order by targets.scope, targets.label;
end;
$$;

grant execute on function public.get_owner_block_targets() to authenticated;


-- ============================================================================
-- 22. 202610050023_fix_villa_inventory_from_room_blocks.sql
-- ============================================================================

-- A villa is sellable only when every physical bedroom within it is free.
-- This makes room-level owner blocks, holds, and confirmed bookings correctly
-- remove the corresponding whole-villa option from the guest search.

create or replace function public.is_product_inventory_available(
  p_product_id uuid,
  p_check_in date,
  p_check_out date
)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((
    select case
      -- Guest-facing room products and room bundles can use any required
      -- number of unoccupied physical bedrooms within their parent villa.
      when p.inventory_mode = 'child_rooms' then
        (
          select count(*)
          from resources child
          where child.parent_resource_id = p.primary_resource_id
            and child.active
            and child.resource_kind = 'room'
            and not exists (
              select 1
              from inventory_allocations allocation
              where allocation.resource_id = child.id
                and allocation.stay_during && daterange(p_check_in, p_check_out, '[)')
                and allocation.state in ('confirmed', 'block', 'hold')
                and (allocation.state <> 'hold' or allocation.expires_at > now())
            )
        ) >= p.room_units_required

      -- Whole-villa and whole-property products require every physical room
      -- they contain to be free. Never rely on a separate villa allocation:
      -- an owner may legitimately block just one underlying room.
      else not exists (
        select 1
        from resources required_room
        join inventory_allocations allocation
          on allocation.resource_id = required_room.id
        where required_room.property_id = p.property_id
          and required_room.active
          and required_room.resource_kind = 'room'
          and (
            p.sellable_kind = 'entire_property'
            or required_room.parent_resource_id = p.primary_resource_id
            or required_room.id = p.primary_resource_id
          )
          and allocation.stay_during && daterange(p_check_in, p_check_out, '[)')
          and allocation.state in ('confirmed', 'block', 'hold')
          and (allocation.state <> 'hold' or allocation.expires_at > now())
      )
    end
    from bookable_products p
    where p.id = p_product_id
      and p.active
  ), false);
$$;

revoke all on function public.is_product_inventory_available(uuid, date, date) from public;
grant execute on function public.is_product_inventory_available(uuid, date, date) to anon, authenticated;


-- ============================================================================
-- 23. 202610050024_allow_third_adult_in_room.sql
-- ============================================================================

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


-- ============================================================================
-- 24. 202610050025_complimentary_children_activities.sql
-- ============================================================================

-- Children aged 0–6 join activities free. Lake-trip and bonfire/barbecue
-- calculations use adults plus children aged 7–12 only.

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
  if p_lake_trip_guests > v_chargeable_party then raise exception 'Lake-trip guests cannot exceed the selected party'; end if;
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
    if v_chargeable_party >= 7 and p_meal_plan in ('all_meals', 'breakfast_plus_one') then v_included_bonfire := least(p_bonfire_sessions, 1); end if;
    v_chargeable_bonfire := p_bonfire_sessions - v_included_bonfire; v_bonfire_total := coalesce(v_bonfire_rate, 0) * v_chargeable_party * v_chargeable_bonfire;
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


-- ============================================================================
-- 25. 202610050026_room_third_adult_capacity_guard.sql
-- ============================================================================

-- A third adult is allowed in a private room only when no children are included.
-- This keeps the operational four-person limit clear and enforceable.

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
  if p_lake_trip_guests > v_chargeable_party then raise exception 'Lake-trip guests cannot exceed the selected party'; end if;
  if v_product.sellable_kind = 'room' and (
    v_party_size > 4 or p_adults > 3 or p_children_7_to_12 > 1
    or p_children_0_to_6 > 2 or (p_adults >= 3 and p_children_7_to_12 + p_children_0_to_6 > 0)
  ) then raise exception 'A room permits up to three adults only. If a child is joining, please choose two adults or add another room.'; end if;
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
    if v_chargeable_party >= 7 and p_meal_plan in ('all_meals', 'breakfast_plus_one') then v_included_bonfire := least(p_bonfire_sessions, 1); end if;
    v_chargeable_bonfire := p_bonfire_sessions - v_included_bonfire; v_bonfire_total := coalesce(v_bonfire_rate, 0) * v_chargeable_party * v_chargeable_bonfire;
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


-- ============================================================================
-- 26. 202610050027_owner_alternative_stay_workflow.sql
-- ============================================================================

-- Turn an unavailable reservation request into a guided alternative-stay offer.
-- The owner chooses the alternative; nothing is held until the guest agrees.

create or replace function public.get_owner_reservation_alternatives(p_reservation_id uuid)
returns table (
  product_id uuid,
  product_code text,
  product_name text,
  sellable_kind text,
  total_paise integer
)
language plpgsql security definer set search_path = public stable as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype;
  v_inputs reservation_request_inputs%rowtype; v_candidate record; v_quote jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to change this reservation'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id;
  if not found then raise exception 'Reservation not found'; end if;
  if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') then
    raise exception 'Alternatives are available only for an open reservation request';
  end if;
  select * into v_inputs from reservation_request_inputs where reservation_id = p_reservation_id;
  if not found then raise exception 'The original request inputs are unavailable'; end if;

  for v_candidate in
    select available.* from public.get_available_products(
      v_reservation.check_in,
      v_reservation.check_out,
      v_reservation.adults + v_reservation.children_7_to_12 + v_reservation.children_0_to_6
    ) available
    where available.product_id <> v_reservation.product_id
    order by available.product_name
  loop
    v_quote := public.get_booking_quote(
      v_candidate.product_id, v_reservation.check_in, v_reservation.check_out,
      v_reservation.adults, v_reservation.children_7_to_12, v_reservation.children_0_to_6,
      v_reservation.pets, v_inputs.meal_plan, v_inputs.bonfire_sessions,
      v_inputs.lake_outings, v_inputs.lake_trip_guests
    );
    product_id := v_candidate.product_id;
    product_code := v_candidate.product_code;
    product_name := v_candidate.product_name;
    sellable_kind := v_candidate.sellable_kind;
    total_paise := (v_quote ->> 'total_paise')::integer;
    return next;
  end loop;
end;
$$;

create or replace function public.owner_offer_alternative_stay(
  p_reservation_id uuid,
  p_product_id uuid,
  p_note text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype;
  v_product bookable_products%rowtype; v_inputs reservation_request_inputs%rowtype;
  v_quote jsonb; v_item jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') then
    raise exception 'Only an open reservation request can be changed';
  end if;
  select * into v_product from bookable_products where id = p_product_id and property_id = v_property_id and active;
  if not found then raise exception 'That alternative stay is unavailable'; end if;
  select * into v_inputs from reservation_request_inputs where reservation_id = p_reservation_id;
  if not found then raise exception 'The original request inputs are unavailable'; end if;

  perform public.lock_property_inventory(v_property_id);
  if not public.is_product_inventory_available(v_product.id, v_reservation.check_in, v_reservation.check_out) then
    raise exception 'That alternative was just booked or blocked. Please choose another stay.';
  end if;
  v_quote := public.get_booking_quote(
    v_product.id, v_reservation.check_in, v_reservation.check_out,
    v_reservation.adults, v_reservation.children_7_to_12, v_reservation.children_0_to_6,
    v_reservation.pets, v_inputs.meal_plan, v_inputs.bonfire_sessions,
    v_inputs.lake_outings, v_inputs.lake_trip_guests
  );
  update reservations
  set product_id = v_product.id,
      status = 'alternative_offered',
      internal_note = coalesce(p_note, internal_note),
      updated_at = now()
  where id = p_reservation_id;
  update price_snapshots
  set total_paise = (v_quote ->> 'total_paise')::integer,
      calculation = v_quote,
      accepted_at = null
  where reservation_id = p_reservation_id;
  delete from reservation_items where reservation_id = p_reservation_id;
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (
      p_reservation_id,
      case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end,
      v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer
    );
  end loop;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'reservation', p_reservation_id, 'alternative_stay_offered', jsonb_build_object('product_id', v_product.id, 'product_name', v_product.name, 'note', p_note));
  return jsonb_build_object('status', 'alternative_offered', 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

revoke all on function public.get_owner_reservation_alternatives(uuid) from public;
grant execute on function public.get_owner_reservation_alternatives(uuid) to authenticated;
revoke all on function public.owner_offer_alternative_stay(uuid, uuid, text) from public;
grant execute on function public.owner_offer_alternative_stay(uuid, uuid, text) to authenticated;

-- Expose a simple availability signal in the owner detail so the dashboard can
-- warn before the owner attempts a payment hold.
create or replace function public.get_owner_reservation_detail(p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_property_id uuid; v_result jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  select jsonb_build_object(
    'reservation', jsonb_build_object(
      'id', r.id, 'reference', r.reference, 'status', r.status,
      'check_in', r.check_in, 'check_out', r.check_out,
      'adults', r.adults, 'children_7_to_12', r.children_7_to_12,
      'children_0_to_6', r.children_0_to_6, 'pets', r.pets, 'source', r.source,
      'guest_name', g.full_name, 'guest_email', g.email, 'guest_phone', g.phone_e164,
      'product_name', p.name, 'internal_note', r.internal_note, 'total_paise', ps.total_paise,
      'requested_stay_available', public.is_product_inventory_available(r.product_id, r.check_in, r.check_out)
    ),
    'items', coalesce((select jsonb_agg(jsonb_build_object('label', ri.label, 'quantity', ri.quantity, 'amount_paise', ri.amount_paise, 'item_type', ri.item_type) order by ri.created_at, ri.id) from reservation_items ri where ri.reservation_id = r.id), '[]'::jsonb),
    'payment', (select jsonb_build_object('provider', pay.provider, 'state', pay.state, 'amount_paise', pay.amount_paise, 'provider_reference', pay.provider_reference, 'expires_at', pay.expires_at) from payments pay where pay.reservation_id = r.id order by pay.created_at desc limit 1),
    'cancellation_policy', public.get_reservation_cancellation_policy(r.id)
  ) into v_result
  from reservations r
  left join guests g on g.id = r.guest_id
  left join bookable_products p on p.id = r.product_id
  left join price_snapshots ps on ps.reservation_id = r.id
  where r.id = p_reservation_id and r.property_id = v_property_id;
  if v_result is null then raise exception 'Booking not found'; end if;
  return v_result;
end;
$$;

revoke all on function public.get_owner_reservation_detail(uuid) from public;
grant execute on function public.get_owner_reservation_detail(uuid) to authenticated;


-- ============================================================================
-- 27. 202610050028_email_notification_outbox.sql
-- ============================================================================

-- Transactional email outbox.
-- The browser never sends email. It writes a booking through the approved RPCs;
-- this outbox then gives Make a reliable, auditable event to deliver.

create table if not exists public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  event_type text not null check (event_type in ('owner_request_received', 'guest_booking_confirmed')),
  recipient_role text not null check (recipient_role in ('owner', 'guest')),
  recipient_email text,
  payload jsonb not null default '{}'::jsonb,
  delivery_state text not null default 'queued' check (delivery_state in ('queued', 'sent', 'failed')),
  provider_message_id text,
  delivery_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  unique (reservation_id, event_type, recipient_role)
);

create index if not exists notification_outbox_queued_idx
  on public.notification_outbox (delivery_state, created_at)
  where delivery_state = 'queued';

alter table public.notification_outbox enable row level security;

create or replace function public.build_reservation_notification_payload(p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare
  v_payload jsonb;
begin
  select jsonb_build_object(
    'reservation', jsonb_build_object(
      'id', r.id,
      'reference', r.reference,
      'status', r.status::text,
      'check_in', r.check_in,
      'check_out', r.check_out,
      'nights', r.check_out - r.check_in,
      'dashboard_path', '/owner?reservation=' || r.id
    ),
    'guest', jsonb_build_object(
      'name', g.full_name,
      'email', g.email,
      'phone', g.phone_e164
    ),
    'stay', jsonb_build_object(
      'name', p.name,
      'adults', r.adults,
      'children_7_to_12', r.children_7_to_12,
      'children_0_to_6', r.children_0_to_6,
      'pets', r.pets,
      'meal_plan', coalesce(i.meal_plan, 'breakfast'),
      'bonfire_sessions', coalesce(i.bonfire_sessions, 0),
      'lake_trip_guests', coalesce(i.lake_trip_guests, 0)
    ),
    'pricing', jsonb_build_object('total_paise', coalesce(ps.total_paise, 0)),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'label', ri.label,
        'quantity', ri.quantity,
        'amount_paise', ri.amount_paise
      ) order by ri.created_at, ri.id)
      from public.reservation_items ri
      where ri.reservation_id = r.id
    ), '[]'::jsonb)
  ) into v_payload
  from public.reservations r
  left join public.guests g on g.id = r.guest_id
  left join public.bookable_products p on p.id = r.product_id
  left join public.reservation_request_inputs i on i.reservation_id = r.id
  left join public.price_snapshots ps on ps.reservation_id = r.id
  where r.id = p_reservation_id;

  if v_payload is null then raise exception 'Reservation not found'; end if;
  return v_payload;
end;
$$;

create or replace function public.queue_reservation_email_notification(
  p_reservation_id uuid,
  p_event_type text,
  p_recipient_role text
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid;
  v_payload jsonb;
  v_guest_email text;
begin
  select property_id into v_property_id from public.reservations where id = p_reservation_id;
  if v_property_id is null then raise exception 'Reservation not found'; end if;

  v_payload := public.build_reservation_notification_payload(p_reservation_id);
  v_guest_email := nullif(v_payload #>> '{guest,email}', '');
  if p_recipient_role = 'guest' and v_guest_email is null then
    raise exception 'A guest email is required for a booking confirmation';
  end if;

  insert into public.notification_outbox (
    property_id, reservation_id, event_type, recipient_role, recipient_email, payload
  ) values (
    v_property_id, p_reservation_id, p_event_type, p_recipient_role,
    case when p_recipient_role = 'guest' then v_guest_email else null end,
    v_payload
  ) on conflict (reservation_id, event_type, recipient_role) do nothing;
end;
$$;

-- The request audit entry is written after the booking quote and its item lines,
-- so the owner event always contains the complete stay summary.
create or replace function public.queue_owner_request_email_from_audit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.entity_type = 'reservation' and new.action = 'request_submitted' then
    perform public.queue_reservation_email_notification(new.entity_id, 'owner_request_received', 'owner');
  end if;
  return new;
end;
$$;

drop trigger if exists queue_owner_request_email_from_audit on public.audit_log;
create trigger queue_owner_request_email_from_audit
  after insert on public.audit_log
  for each row execute function public.queue_owner_request_email_from_audit();

-- A payment provider or the owner dashboard changes the reservation to
-- confirmed only after successful payment. That status transition queues the
-- guest's confirmation email exactly once.
create or replace function public.queue_guest_confirmation_email()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status::text = 'confirmed' and old.status::text is distinct from 'confirmed' then
    perform public.queue_reservation_email_notification(new.id, 'guest_booking_confirmed', 'guest');
  end if;
  return new;
end;
$$;

drop trigger if exists queue_guest_confirmation_email on public.reservations;
create trigger queue_guest_confirmation_email
  after update of status on public.reservations
  for each row execute function public.queue_guest_confirmation_email();

revoke all on table public.notification_outbox from public;
revoke all on function public.build_reservation_notification_payload(uuid) from public;
revoke all on function public.queue_reservation_email_notification(uuid, text, text) from public;


-- ============================================================================
-- 28. 202610050029_email_templates_and_app_url.sql
-- ============================================================================

-- Polished transactional-email payloads. Make maps one subject and one HTML
-- field, keeping the presentation consistent across owner and guest messages.

create or replace function public.html_escape(p_value text)
returns text language sql immutable as $$
  select replace(replace(replace(replace(replace(coalesce(p_value, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;

create or replace function public.format_inr_from_paise(p_value integer)
returns text language sql immutable as $$
  select '₹' || to_char(coalesce(p_value, 0)::numeric / 100, 'FM999,999,999,990');
$$;

do $$
declare v_property_id uuid;
begin
  select id into v_property_id from public.properties where name = 'Breathe Woods' limit 1;
  if v_property_id is not null then
    insert into public.property_settings (property_id, setting_key, value)
    values (v_property_id, 'booking_app_url', jsonb_build_object('url', 'http://127.0.0.1:5173'))
    on conflict (property_id, setting_key) do nothing;
  end if;
end;
$$;

create or replace function public.build_reservation_notification_payload(p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare
  v_reservation public.reservations%rowtype;
  v_guest public.guests%rowtype;
  v_product public.bookable_products%rowtype;
  v_inputs public.reservation_request_inputs%rowtype;
  v_total integer := 0;
  v_app_url text := '';
  v_dashboard_url text := '';
  v_guest_summary text;
  v_stay_summary text;
  v_owner_html text;
  v_guest_html text;
  v_items jsonb;
begin
  select * into v_reservation from public.reservations where id = p_reservation_id;
  if not found then raise exception 'Reservation not found'; end if;
  select * into v_guest from public.guests where id = v_reservation.guest_id;
  select * into v_product from public.bookable_products where id = v_reservation.product_id;
  select * into v_inputs from public.reservation_request_inputs where reservation_id = v_reservation.id;
  select coalesce(total_paise, 0) into v_total from public.price_snapshots where reservation_id = v_reservation.id;
  select coalesce(value ->> 'url', '') into v_app_url from public.property_settings
  where property_id = v_reservation.property_id and setting_key = 'booking_app_url';

  v_app_url := regexp_replace(coalesce(v_app_url, ''), '/+$', '');
  if v_app_url <> '' then v_dashboard_url := v_app_url || '/owner?reservation=' || v_reservation.id; end if;
  v_guest_summary := v_reservation.adults || ' adult' || case when v_reservation.adults = 1 then '' else 's' end
    || case when v_reservation.children_7_to_12 > 0 then ', ' || v_reservation.children_7_to_12 || ' child' || case when v_reservation.children_7_to_12 = 1 then '' else 'ren' end || ' aged 7–12' else '' end
    || case when v_reservation.children_0_to_6 > 0 then ', ' || v_reservation.children_0_to_6 || ' child' || case when v_reservation.children_0_to_6 = 1 then '' else 'ren' end || ' aged 0–6' else '' end;
  v_stay_summary := to_char(v_reservation.check_in, 'DD Mon YYYY') || ' – ' || to_char(v_reservation.check_out, 'DD Mon YYYY') || ' · ' || (v_reservation.check_out - v_reservation.check_in) || ' night' || case when v_reservation.check_out - v_reservation.check_in = 1 then '' else 's' end;
  select coalesce(jsonb_agg(jsonb_build_object('label', ri.label, 'quantity', ri.quantity, 'amount_paise', ri.amount_paise) order by ri.created_at, ri.id), '[]'::jsonb)
  into v_items from public.reservation_items ri where ri.reservation_id = v_reservation.id;

  v_owner_html := '<div style="margin:0;padding:28px 12px;background:#f6f4ed;color:#27362f;font-family:Arial,sans-serif"><div style="max-width:620px;margin:0 auto;background:#ffffff;border:1px solid #dce4d7;border-radius:16px;overflow:hidden">'
    || '<div style="padding:22px 28px;background:#173b31;color:#ffffff"><div style="font-family:Georgia,serif;font-size:25px;font-weight:700">Breathe Woods</div><div style="margin-top:5px;font-size:12px;letter-spacing:1.5px;text-transform:uppercase;color:#dbe7d8">New reservation request</div></div>'
    || '<div style="padding:28px"><h1 style="margin:0 0 10px;color:#173b31;font-family:Georgia,serif;font-size:28px;font-weight:500">A guest would like to stay</h1><p style="margin:0 0 22px;color:#5b6b61;font-size:16px;line-height:1.55">Review the request, confirm availability, then contact the guest with next steps for payment.</p>'
    || '<div style="margin:0 0 20px;padding:12px 14px;border-radius:10px;background:#f2f6ee;color:#173b31;font-size:14px"><strong>Request reference:</strong> ' || public.html_escape(v_reservation.reference) || '</div>'
    || '<table role="presentation" style="width:100%;border-collapse:collapse;font-size:15px"><tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078;width:37%">Guest</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31"><strong>' || public.html_escape(v_guest.full_name) || '</strong><br><a style="color:#173b31" href="mailto:' || public.html_escape(v_guest.email) || '">' || public.html_escape(v_guest.email) || '</a><br><a style="color:#173b31" href="tel:' || public.html_escape(v_guest.phone_e164) || '">' || public.html_escape(v_guest.phone_e164) || '</a></td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Dates</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(v_stay_summary) || '</td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Stay</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(v_product.name) || '</td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Guests</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(v_guest_summary) || '</td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Meal plan</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(initcap(replace(coalesce(v_inputs.meal_plan, 'breakfast'), '_', ' '))) || '</td></tr>'
    || '<tr><td style="padding:14px 0 0;color:#173b31;font-size:17px"><strong>Estimated total</strong></td><td style="padding:14px 0 0;color:#173b31;font-size:20px;text-align:right"><strong>' || public.format_inr_from_paise(v_total) || '</strong></td></tr></table>'
    || case when v_dashboard_url <> '' then '<p style="margin:26px 0 0"><a href="' || public.html_escape(v_dashboard_url) || '" style="display:inline-block;padding:13px 18px;border-radius:8px;background:#173b31;color:#ffffff;font-weight:700;text-decoration:none">Review request in dashboard</a></p>' else '' end
    || '</div></div></div>';

  v_guest_html := '<div style="margin:0;padding:28px 12px;background:#f6f4ed;color:#27362f;font-family:Arial,sans-serif"><div style="max-width:620px;margin:0 auto;background:#ffffff;border:1px solid #dce4d7;border-radius:16px;overflow:hidden">'
    || '<div style="padding:22px 28px;background:#173b31;color:#ffffff"><div style="font-family:Georgia,serif;font-size:25px;font-weight:700">Breathe Woods</div><div style="margin-top:5px;font-size:12px;letter-spacing:1.5px;text-transform:uppercase;color:#dbe7d8">Booking confirmed</div></div>'
    || '<div style="padding:28px"><h1 style="margin:0 0 10px;color:#173b31;font-family:Georgia,serif;font-size:28px;font-weight:500">Your stay is confirmed</h1><p style="margin:0 0 22px;color:#5b6b61;font-size:16px;line-height:1.55">Hello ' || public.html_escape(v_guest.full_name) || ', we have received your payment and look forward to welcoming you to Breathe Woods.</p>'
    || '<div style="margin:0 0 20px;padding:12px 14px;border-radius:10px;background:#f2f6ee;color:#173b31;font-size:14px"><strong>Booking reference:</strong> ' || public.html_escape(v_reservation.reference) || '</div>'
    || '<table role="presentation" style="width:100%;border-collapse:collapse;font-size:15px"><tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078;width:37%">Dates</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(v_stay_summary) || '</td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Stay</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(v_product.name) || '</td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Guests</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(v_guest_summary) || '</td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Meal plan</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(initcap(replace(coalesce(v_inputs.meal_plan, 'breakfast'), '_', ' '))) || '</td></tr>'
    || '<tr><td style="padding:14px 0 0;color:#173b31;font-size:17px"><strong>Amount paid</strong></td><td style="padding:14px 0 0;color:#173b31;font-size:20px;text-align:right"><strong>' || public.format_inr_from_paise(v_total) || '</strong></td></tr></table>'
    || '<p style="margin:25px 0 0;color:#5b6b61;font-size:15px;line-height:1.55">For arrival questions or special requests, reply to this email or message Breathe Woods on WhatsApp.</p><p style="margin:20px 0 0;color:#173b31;font-size:15px">Warmly,<br><strong>Breathe Woods</strong></p></div></div></div>';

  return jsonb_build_object(
    'reservation', jsonb_build_object('id', v_reservation.id, 'reference', v_reservation.reference, 'status', v_reservation.status::text, 'check_in', v_reservation.check_in, 'check_out', v_reservation.check_out, 'nights', v_reservation.check_out - v_reservation.check_in, 'dashboard_path', '/owner?reservation=' || v_reservation.id, 'dashboard_url', nullif(v_dashboard_url, '')),
    'guest', jsonb_build_object('name', v_guest.full_name, 'email', v_guest.email, 'phone', v_guest.phone_e164),
    'stay', jsonb_build_object('name', v_product.name, 'adults', v_reservation.adults, 'children_7_to_12', v_reservation.children_7_to_12, 'children_0_to_6', v_reservation.children_0_to_6, 'pets', v_reservation.pets, 'meal_plan', coalesce(v_inputs.meal_plan, 'breakfast'), 'bonfire_sessions', coalesce(v_inputs.bonfire_sessions, 0), 'lake_trip_guests', coalesce(v_inputs.lake_trip_guests, 0)),
    'pricing', jsonb_build_object('total_paise', v_total),
    'items', v_items,
    'email', jsonb_build_object('owner', jsonb_build_object('subject', 'New Breathe Woods reservation request — ' || v_reservation.reference, 'html', v_owner_html), 'guest', jsonb_build_object('subject', 'Your Breathe Woods stay is confirmed — ' || v_reservation.reference, 'html', v_guest_html))
  );
end;
$$;


-- ============================================================================
-- 29. 202610050030_guest_confirmation_contact_links.sql
-- ============================================================================

-- Adds tappable direct-contact details to the guest confirmation email.
-- The email HTML remains generated in Supabase; Make continues mapping the same
-- record.payload.email.guest.subject and record.payload.email.guest.html fields.

create or replace function public.add_guest_confirmation_contact_links()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_html text;
  v_contact_html constant text :=
    '<div style="margin:24px 0 0;padding:16px;border:1px solid #dce4d7;border-radius:10px;background:#f2f6ee;color:#173b31;font-size:15px;line-height:1.65">'
    || '<strong style="display:block;margin-bottom:5px">Need anything before your stay?</strong>'
    || 'Call us: <a href="tel:+919967786444" style="color:#173b31;font-weight:700">+91 99677 86444</a><br>'
    || 'WhatsApp: <a href="https://wa.me/919967786444" style="color:#173b31;font-weight:700">Message Breathe Woods</a><br>'
    || 'Website: <a href="https://breathewoods.com" style="color:#173b31;font-weight:700">breathewoods.com</a>'
    || '</div>';
begin
  if new.event_type <> 'guest_booking_confirmed' then
    return new;
  end if;

  v_html := new.payload #>> '{email,guest,html}';
  if coalesce(v_html, '') = '' then
    return new;
  end if;

  new.payload := jsonb_set(
    new.payload,
    '{email,guest,html}',
    to_jsonb(regexp_replace(v_html, '</div></div></div>$', v_contact_html || '</div></div></div>')),
    true
  );

  return new;
end;
$$;

drop trigger if exists enrich_guest_confirmation_email on public.notification_outbox;
create trigger enrich_guest_confirmation_email
before insert on public.notification_outbox
for each row
execute function public.add_guest_confirmation_contact_links();

revoke all on function public.add_guest_confirmation_contact_links() from public;


-- ============================================================================
-- 30. 202610050031_owner_management_foundation.sql
-- ============================================================================

-- Owner management foundation: immutable quote history, campaign configuration,
-- workflow timestamps and a safe pre-publish impact check.
--
-- This migration intentionally does not alter live guest pricing. It gives the
-- owner dashboard safe structures to manage future pricing and campaigns while
-- retaining every price a guest was actually quoted.

do $$
begin
  create type public.pricing_campaign_status as enum ('draft', 'scheduled', 'active', 'paused', 'ended', 'archived');
exception when duplicate_object then null;
end $$;

create table if not exists public.pricing_campaigns (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 120),
  internal_note text,
  guest_message text,
  status public.pricing_campaign_status not null default 'draft',
  booking_starts_on date,
  booking_ends_on date,
  stay_starts_on date not null,
  stay_ends_on date not null,
  incentive_type text not null check (incentive_type in ('percentage_discount', 'fixed_discount', 'complimentary_add_on')),
  discount_bps integer check (discount_bps between 1 and 10000),
  fixed_discount_paise integer check (fixed_discount_paise > 0),
  complimentary_add_on_id uuid references public.add_ons(id) on delete restrict,
  minimum_nights integer not null default 1 check (minimum_nights > 0),
  minimum_guests integer not null default 1 check (minimum_guests > 0),
  promo_code text,
  stackable boolean not null default false,
  configuration jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz,
  check (stay_ends_on >= stay_starts_on),
  check (booking_ends_on is null or booking_starts_on is null or booking_ends_on >= booking_starts_on),
  check (
    (incentive_type = 'percentage_discount' and discount_bps is not null and fixed_discount_paise is null and complimentary_add_on_id is null)
    or (incentive_type = 'fixed_discount' and fixed_discount_paise is not null and discount_bps is null and complimentary_add_on_id is null)
    or (incentive_type = 'complimentary_add_on' and complimentary_add_on_id is not null and discount_bps is null and fixed_discount_paise is null)
  )
);

create unique index if not exists pricing_campaigns_property_promo_code_unique
  on public.pricing_campaigns (property_id, lower(promo_code))
  where promo_code is not null;
create index if not exists pricing_campaigns_property_status_dates_idx
  on public.pricing_campaigns (property_id, status, stay_starts_on, stay_ends_on);

create table if not exists public.pricing_campaign_product_targets (
  campaign_id uuid not null references public.pricing_campaigns(id) on delete cascade,
  product_id uuid not null references public.bookable_products(id) on delete cascade,
  primary key (campaign_id, product_id)
);

-- Each version is an immutable record of what a guest was quoted. The existing
-- price_snapshots row remains the live quote consumed by the booking flow; this
-- table provides protected history as an owner revises a quote intentionally.
create table if not exists public.reservation_quote_versions (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  version_number integer not null check (version_number > 0),
  total_paise integer not null check (total_paise >= 0),
  currency text not null default 'INR',
  calculation jsonb not null,
  campaign_id uuid references public.pricing_campaigns(id) on delete set null,
  state text not null default 'active' check (state in ('active', 'superseded', 'accepted', 'expired')),
  source text not null default 'website_quote' check (source in ('website_quote', 'owner_revision', 'system_snapshot_update')),
  reason text,
  issued_at timestamptz not null default now(),
  accepted_at timestamptz,
  created_by uuid,
  unique (reservation_id, version_number)
);

create unique index if not exists reservation_quote_versions_one_active_per_reservation
  on public.reservation_quote_versions (reservation_id) where state = 'active';
create index if not exists reservation_quote_versions_campaign_idx
  on public.reservation_quote_versions (campaign_id) where campaign_id is not null;

create or replace function public.capture_reservation_quote_version()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_next_version integer;
begin
  if tg_op = 'UPDATE'
    and new.total_paise is not distinct from old.total_paise
    and new.calculation is not distinct from old.calculation then
    return new;
  end if;

  update public.reservation_quote_versions
  set state = 'superseded'
  where reservation_id = new.reservation_id and state = 'active';

  select coalesce(max(version_number), 0) + 1
  into v_next_version
  from public.reservation_quote_versions
  where reservation_id = new.reservation_id;

  insert into public.reservation_quote_versions (
    reservation_id, version_number, total_paise, currency, calculation, state, source
  ) values (
    new.reservation_id, v_next_version, new.total_paise, new.currency, new.calculation,
    'active', case when tg_op = 'INSERT' then 'website_quote' else 'system_snapshot_update' end
  );

  return new;
end;
$$;

drop trigger if exists capture_reservation_quote_version on public.price_snapshots;
create trigger capture_reservation_quote_version
after insert or update of total_paise, calculation on public.price_snapshots
for each row execute function public.capture_reservation_quote_version();

create or replace function public.update_reservation_quote_state()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = old.status then
    return new;
  end if;

  if new.status = 'confirmed' then
    update public.reservation_quote_versions
    set state = 'accepted', accepted_at = coalesce(accepted_at, now())
    where reservation_id = new.id and state = 'active';
  elsif new.status in ('cancelled', 'declined') then
    update public.reservation_quote_versions
    set state = 'expired'
    where reservation_id = new.id and state = 'active';
  end if;

  return new;
end;
$$;

drop trigger if exists update_reservation_quote_state on public.reservations;
create trigger update_reservation_quote_state
after update of status on public.reservations
for each row execute function public.update_reservation_quote_state();

-- Backfill the protected first version for UAT requests created before this
-- migration. No guest-facing price is changed.
insert into public.reservation_quote_versions (
  reservation_id, version_number, total_paise, currency, calculation, state, source, issued_at, accepted_at
)
select
  ps.reservation_id,
  1,
  ps.total_paise,
  ps.currency,
  ps.calculation,
  case when r.status = 'confirmed' then 'accepted'
       when r.status in ('cancelled', 'declined') then 'expired'
       else 'active' end,
  'website_quote',
  ps.created_at,
  case when r.status = 'confirmed' then coalesce(ps.accepted_at, r.updated_at) else null end
from public.price_snapshots ps
join public.reservations r on r.id = ps.reservation_id
where not exists (
  select 1 from public.reservation_quote_versions q where q.reservation_id = ps.reservation_id
);

-- Normalised operating events make response-time, conversion and future
-- analytics reliable without putting personally identifying data into analytics.
create table if not exists public.reservation_operational_events (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  event_type text not null check (event_type in (
    'request_submitted', 'owner_opened', 'guest_contacted', 'payment_requested',
    'alternative_offered', 'payment_hold_created', 'payment_confirmed',
    'request_declined', 'request_cancelled'
  )),
  actor_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists reservation_operational_events_reservation_idx
  on public.reservation_operational_events (reservation_id, created_at);
create index if not exists reservation_operational_events_property_type_idx
  on public.reservation_operational_events (property_id, event_type, created_at);

create or replace function public.capture_reservation_operational_event_from_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_type text;
begin
  if new.entity_type <> 'reservation' then
    return new;
  end if;

  v_event_type := case new.action
    when 'request_submitted' then 'request_submitted'
    when 'start_conversation' then 'owner_opened'
    when 'guest_contacted' then 'guest_contacted'
    when 'payment_requested' then 'payment_requested'
    when 'alternative_dates_offered' then 'alternative_offered'
    when 'hold_for_manual_payment' then 'payment_hold_created'
    when 'confirm_manual_payment' then 'payment_confirmed'
    when 'decline' then 'request_declined'
    when 'cancel' then 'request_cancelled'
    else null
  end;

  if v_event_type is not null then
    insert into public.reservation_operational_events (
      property_id, reservation_id, event_type, actor_id, metadata, created_at
    ) values (
      new.property_id, new.entity_id, v_event_type, new.actor_id, new.data, new.created_at
    );
  end if;
  return new;
end;
$$;

drop trigger if exists capture_reservation_operational_event_from_audit on public.audit_log;
create trigger capture_reservation_operational_event_from_audit
after insert on public.audit_log
for each row execute function public.capture_reservation_operational_event_from_audit();

insert into public.reservation_operational_events (
  property_id, reservation_id, event_type, actor_id, metadata, created_at
)
select
  a.property_id,
  a.entity_id,
  case a.action
    when 'request_submitted' then 'request_submitted'
    when 'start_conversation' then 'owner_opened'
    when 'guest_contacted' then 'guest_contacted'
    when 'payment_requested' then 'payment_requested'
    when 'alternative_dates_offered' then 'alternative_offered'
    when 'hold_for_manual_payment' then 'payment_hold_created'
    when 'confirm_manual_payment' then 'payment_confirmed'
    when 'decline' then 'request_declined'
    when 'cancel' then 'request_cancelled'
  end,
  a.actor_id, a.data, a.created_at
from public.audit_log a
where a.entity_type = 'reservation'
  and a.action in ('request_submitted', 'start_conversation', 'guest_contacted', 'payment_requested', 'alternative_dates_offered', 'hold_for_manual_payment', 'confirm_manual_payment', 'decline', 'cancel')
  and not exists (
    select 1 from public.reservation_operational_events e
    where e.reservation_id = a.entity_id and e.event_type = case a.action
      when 'request_submitted' then 'request_submitted'
      when 'start_conversation' then 'owner_opened'
      when 'guest_contacted' then 'guest_contacted'
      when 'payment_requested' then 'payment_requested'
      when 'alternative_dates_offered' then 'alternative_offered'
      when 'hold_for_manual_payment' then 'payment_hold_created'
      when 'confirm_manual_payment' then 'payment_confirmed'
      when 'decline' then 'request_declined'
      when 'cancel' then 'request_cancelled'
    end
      and e.created_at = a.created_at
  );

create or replace function public.get_owner_pricing_change_impact(
  p_stay_starts_on date,
  p_stay_ends_on date,
  p_product_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_property_id uuid;
begin
  select property_id into v_property_id from public.owner_profiles where user_id = auth.uid();
  if v_property_id is null then
    raise exception 'You do not have access to this dashboard';
  end if;
  if p_stay_starts_on is null or p_stay_ends_on is null or p_stay_ends_on < p_stay_starts_on then
    raise exception 'Choose a valid stay-date range';
  end if;

  return (
    select jsonb_build_object(
      'affected_open_quotes', count(*) filter (where r.status in ('requested', 'in_conversation', 'alternative_offered')),
      'affected_payment_holds', count(*) filter (where r.status in ('awaiting_manual_payment', 'pending_payment')),
      'quoted_value_paise', coalesce(sum(ps.total_paise) filter (where r.status in ('requested', 'in_conversation', 'alternative_offered', 'awaiting_manual_payment', 'pending_payment')), 0),
      'reservations', coalesce(jsonb_agg(jsonb_build_object(
        'reservation_id', r.id,
        'reference', r.reference,
        'status', r.status::text,
        'check_in', r.check_in,
        'check_out', r.check_out,
        'product_name', p.name,
        'quoted_total_paise', ps.total_paise
      ) order by r.created_at desc), '[]'::jsonb)
    )
    from public.reservations r
    join public.bookable_products p on p.id = r.product_id
    join public.price_snapshots ps on ps.reservation_id = r.id
    where r.property_id = v_property_id
      and r.check_in <= p_stay_ends_on
      and r.check_out > p_stay_starts_on
      and r.status in ('requested', 'in_conversation', 'alternative_offered', 'awaiting_manual_payment', 'pending_payment')
      and (p_product_ids is null or r.product_id = any(p_product_ids))
  );
end;
$$;

alter table public.pricing_campaigns enable row level security;
alter table public.pricing_campaign_product_targets enable row level security;
alter table public.reservation_quote_versions enable row level security;
alter table public.reservation_operational_events enable row level security;

revoke all on public.pricing_campaigns, public.pricing_campaign_product_targets,
  public.reservation_quote_versions, public.reservation_operational_events from anon, authenticated;
revoke all on function public.capture_reservation_quote_version() from public;
revoke all on function public.update_reservation_quote_state() from public;
revoke all on function public.capture_reservation_operational_event_from_audit() from public;
revoke all on function public.get_owner_pricing_change_impact(date, date, uuid[]) from public;
grant execute on function public.get_owner_pricing_change_impact(date, date, uuid[]) to authenticated;


-- ============================================================================
-- 31. 202610050032_owner_management_api.sql
-- ============================================================================

-- Owner-only read and write endpoints for the Manage property dashboard.
-- Changes are intentionally server-side, auditable, and immediately reflected
-- in new guest quotes; existing price snapshots are never recalculated here.

create or replace function public.get_owner_management_summary(
  p_start_date date default current_date,
  p_end_date date default current_date + 90
)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_property_id uuid;
begin
  select property_id into v_property_id from public.owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'Choose a valid date range';
  end if;

  return jsonb_build_object(
    'date_range', jsonb_build_object('start', p_start_date, 'end', p_end_date),
    'rates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'stay_date', d.stay_date,
        'tier_code', d.tier_code,
        'couple_room_paise', d.couple_room_paise,
        'single_room_paise', d.single_room_paise,
        'extra_adult_paise', d.extra_adult_paise,
        'extra_child_7_to_12_paise', d.extra_child_7_to_12_paise,
        'minimum_stay_nights', d.minimum_stay_nights,
        'individual_rooms_bookable', d.individual_rooms_bookable,
        'individual_room_minimum_nights', d.individual_room_minimum_nights,
        'buyout_discount_eligible', d.buyout_discount_eligible,
        'buyout_one_night_discount_bps_group_10', d.buyout_one_night_discount_bps_group_10,
        'buyout_one_night_discount_bps_group_15', d.buyout_one_night_discount_bps_group_15,
        'buyout_two_plus_nights_discount_bps_group_10', d.buyout_two_plus_nights_discount_bps_group_10,
        'buyout_two_plus_nights_discount_bps_group_15', d.buyout_two_plus_nights_discount_bps_group_15,
        'notes', d.notes
      ) order by d.stay_date)
      from public.daily_pricing_calendar d
      where d.property_id = v_property_id and d.stay_date between p_start_date and p_end_date
    ), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'code', p.code, 'name', p.name, 'sellable_kind', p.sellable_kind, 'active', p.active) order by p.display_order)
      from public.bookable_products p where p.property_id = v_property_id
    ), '[]'::jsonb),
    'experiences', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'description', a.description, 'pricing_unit', a.pricing_unit, 'amount_paise', a.amount_paise, 'max_quantity', a.max_quantity, 'active', a.active, 'configuration', a.configuration) order by a.name)
      from public.add_ons a where a.property_id = v_property_id
    ), '[]'::jsonb),
    'settings', coalesce((
      select jsonb_object_agg(s.setting_key, s.value)
      from public.property_settings s where s.property_id = v_property_id
    ), '{}'::jsonb),
    'campaigns', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name, 'internal_note', c.internal_note, 'guest_message', c.guest_message,
        'status', c.status, 'booking_starts_on', c.booking_starts_on, 'booking_ends_on', c.booking_ends_on,
        'stay_starts_on', c.stay_starts_on, 'stay_ends_on', c.stay_ends_on, 'incentive_type', c.incentive_type,
        'discount_bps', c.discount_bps, 'fixed_discount_paise', c.fixed_discount_paise,
        'complimentary_add_on_id', c.complimentary_add_on_id, 'minimum_nights', c.minimum_nights,
        'minimum_guests', c.minimum_guests, 'promo_code', c.promo_code, 'stackable', c.stackable,
        'configuration', c.configuration, 'published_at', c.published_at,
        'product_ids', coalesce((select jsonb_agg(t.product_id) from public.pricing_campaign_product_targets t where t.campaign_id = c.id), '[]'::jsonb)
      ) order by c.created_at desc)
      from public.pricing_campaigns c where c.property_id = v_property_id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.owner_upsert_pricing_campaign(
  p_campaign jsonb,
  p_product_ids uuid[] default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_property_id uuid;
  v_role public.dashboard_role;
  v_campaign_id uuid;
  v_status public.pricing_campaign_status;
  v_incentive_type text;
begin
  select property_id, role into v_property_id, v_role from public.owner_profiles where user_id = auth.uid();
  if v_property_id is null or v_role = 'viewer' then raise exception 'You do not have permission to manage campaigns'; end if;

  v_status := coalesce((p_campaign ->> 'status')::public.pricing_campaign_status, 'draft');
  v_incentive_type := coalesce(p_campaign ->> 'incentive_type', 'percentage_discount');
  if nullif(trim(coalesce(p_campaign ->> 'name', '')), '') is null then raise exception 'Give this campaign a name'; end if;
  if (p_campaign ->> 'stay_starts_on') is null or (p_campaign ->> 'stay_ends_on') is null then raise exception 'Choose the dates guests can stay'; end if;

  if p_campaign ->> 'id' is not null then
    select id into v_campaign_id from public.pricing_campaigns where id = (p_campaign ->> 'id')::uuid and property_id = v_property_id for update;
    if v_campaign_id is null then raise exception 'Campaign not found'; end if;
    update public.pricing_campaigns set
      name = trim(p_campaign ->> 'name'), internal_note = nullif(trim(p_campaign ->> 'internal_note'), ''), guest_message = nullif(trim(p_campaign ->> 'guest_message'), ''),
      status = v_status, booking_starts_on = nullif(p_campaign ->> 'booking_starts_on', '')::date, booking_ends_on = nullif(p_campaign ->> 'booking_ends_on', '')::date,
      stay_starts_on = (p_campaign ->> 'stay_starts_on')::date, stay_ends_on = (p_campaign ->> 'stay_ends_on')::date,
      incentive_type = v_incentive_type, discount_bps = case when v_incentive_type = 'percentage_discount' then (p_campaign ->> 'discount_bps')::integer else null end,
      fixed_discount_paise = case when v_incentive_type = 'fixed_discount' then (p_campaign ->> 'fixed_discount_paise')::integer else null end,
      complimentary_add_on_id = case when v_incentive_type = 'complimentary_add_on' then nullif(p_campaign ->> 'complimentary_add_on_id', '')::uuid else null end,
      minimum_nights = greatest(coalesce((p_campaign ->> 'minimum_nights')::integer, 1), 1), minimum_guests = greatest(coalesce((p_campaign ->> 'minimum_guests')::integer, 1), 1),
      promo_code = nullif(upper(trim(p_campaign ->> 'promo_code')), ''), stackable = coalesce((p_campaign ->> 'stackable')::boolean, false),
      configuration = coalesce(p_campaign -> 'configuration', '{}'::jsonb), updated_at = now(),
      published_at = case when v_status in ('active', 'scheduled') then coalesce(published_at, now()) else published_at end
    where id = v_campaign_id;
  else
    insert into public.pricing_campaigns (
      property_id, name, internal_note, guest_message, status, booking_starts_on, booking_ends_on, stay_starts_on, stay_ends_on,
      incentive_type, discount_bps, fixed_discount_paise, complimentary_add_on_id, minimum_nights, minimum_guests, promo_code, stackable, configuration, created_by, published_at
    ) values (
      v_property_id, trim(p_campaign ->> 'name'), nullif(trim(p_campaign ->> 'internal_note'), ''), nullif(trim(p_campaign ->> 'guest_message'), ''), v_status,
      nullif(p_campaign ->> 'booking_starts_on', '')::date, nullif(p_campaign ->> 'booking_ends_on', '')::date, (p_campaign ->> 'stay_starts_on')::date, (p_campaign ->> 'stay_ends_on')::date,
      v_incentive_type, case when v_incentive_type = 'percentage_discount' then (p_campaign ->> 'discount_bps')::integer else null end,
      case when v_incentive_type = 'fixed_discount' then (p_campaign ->> 'fixed_discount_paise')::integer else null end,
      case when v_incentive_type = 'complimentary_add_on' then nullif(p_campaign ->> 'complimentary_add_on_id', '')::uuid else null end,
      greatest(coalesce((p_campaign ->> 'minimum_nights')::integer, 1), 1), greatest(coalesce((p_campaign ->> 'minimum_guests')::integer, 1), 1),
      nullif(upper(trim(p_campaign ->> 'promo_code')), ''), coalesce((p_campaign ->> 'stackable')::boolean, false), coalesce(p_campaign -> 'configuration', '{}'::jsonb), auth.uid(),
      case when v_status in ('active', 'scheduled') then now() else null end
    ) returning id into v_campaign_id;
  end if;

  delete from public.pricing_campaign_product_targets where campaign_id = v_campaign_id;
  if coalesce(array_length(p_product_ids, 1), 0) > 0 then
    insert into public.pricing_campaign_product_targets (campaign_id, product_id)
    select v_campaign_id, ids.product_id
    from unnest(p_product_ids) as ids(product_id)
    join public.bookable_products p on p.id = ids.product_id and p.property_id = v_property_id;
  end if;

  insert into public.audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'pricing_campaign', v_campaign_id, 'campaign_saved', jsonb_build_object('status', v_status));
  return v_campaign_id;
end;
$$;

create or replace function public.owner_update_experience(
  p_experience_id uuid,
  p_name text,
  p_description text,
  p_amount_paise integer,
  p_active boolean,
  p_configuration jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_property_id uuid; v_role public.dashboard_role;
begin
  select property_id, role into v_property_id, v_role from public.owner_profiles where user_id = auth.uid();
  if v_property_id is null or v_role = 'viewer' then raise exception 'You do not have permission to change experiences'; end if;
  if nullif(trim(coalesce(p_name, '')), '') is null or p_amount_paise < 0 then raise exception 'Enter a valid experience name and amount'; end if;
  update public.add_ons set name = trim(p_name), description = nullif(trim(p_description), ''), amount_paise = p_amount_paise,
    active = p_active, configuration = coalesce(p_configuration, '{}'::jsonb)
  where id = p_experience_id and property_id = v_property_id;
  if not found then raise exception 'Experience not found'; end if;
  insert into public.audit_log (property_id, actor_id, entity_type, entity_id, action)
  values (v_property_id, auth.uid(), 'experience', p_experience_id, 'experience_saved');
end;
$$;

revoke all on function public.get_owner_management_summary(date, date) from public;
revoke all on function public.owner_upsert_pricing_campaign(jsonb, uuid[]) from public;
revoke all on function public.owner_update_experience(uuid, text, text, integer, boolean, jsonb) from public;
grant execute on function public.get_owner_management_summary(date, date) to authenticated;
grant execute on function public.owner_upsert_pricing_campaign(jsonb, uuid[]) to authenticated;
grant execute on function public.owner_update_experience(uuid, text, text, integer, boolean, jsonb) to authenticated;


-- ============================================================================
-- 32. 202610050033_owner_operational_events.sql
-- ============================================================================

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


-- ============================================================================
-- 33. 202610050034_campaign_pricing_engine.sql
-- ============================================================================

-- Campaign pricing is applied only while a guest is obtaining a fresh quote.
-- Once submitted, the resulting price snapshot is immutable to later campaign
-- or rate changes.

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
  v_campaign record;
  v_campaign_applied boolean := false;
  v_campaign_discount_paise integer := 0;
  v_pre_campaign_total_paise integer := 0;
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
  if p_lake_trip_guests > v_chargeable_party then raise exception 'Lake-trip guests cannot exceed the selected party'; end if;
  if v_product.sellable_kind = 'room' and (
    v_party_size > 4 or p_adults > 3 or p_children_7_to_12 > 1
    or p_children_0_to_6 > 2 or (p_adults >= 3 and p_children_7_to_12 + p_children_0_to_6 > 0)
  ) then raise exception 'A room permits up to three adults only. If a child is joining, please choose two adults or add another room.'; end if;
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
      v_room_base := case when v_product.sellable_kind = 'room' and v_party_size = 1 then v_day.single_room_paise else v_day.couple_room_paise * v_units end;
      v_adult_extra := case when v_product.sellable_kind = 'room' then greatest(p_adults - 2, 0) else greatest(p_adults - v_product.included_chargeable_guests, 0) end * v_day.extra_adult_paise;
      v_child_extra := case when v_product.sellable_kind = 'room' then greatest(p_children_7_to_12 - greatest(2 - p_adults, 0), 0) else greatest(v_chargeable_party - v_product.included_chargeable_guests - greatest(p_adults - v_product.included_chargeable_guests, 0), 0) end * v_day.extra_child_7_to_12_paise;
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
    if v_chargeable_party >= 7 and p_meal_plan in ('all_meals', 'breakfast_plus_one') then v_included_bonfire := least(p_bonfire_sessions, 1); end if;
    v_chargeable_bonfire := p_bonfire_sessions - v_included_bonfire;
    v_bonfire_total := coalesce(v_bonfire_rate, 0) * (p_adults + p_children_7_to_12) * v_chargeable_bonfire;
  end if;
  if p_lake_trip_guests > 0 then
    select coalesce((configuration ->> 'base_paise')::integer, amount_paise, 50000), coalesce((configuration ->> 'incremental_paise')::integer, 25000), coalesce((configuration ->> 'included_guests')::integer, 2)
      into v_lake_base, v_lake_increment, v_lake_included from add_ons where property_id = v_product.property_id and code = 'lake-trip' and active;
    v_lake_total := coalesce(v_lake_base, 50000) + greatest(p_lake_trip_guests - coalesce(v_lake_included, 2), 0) * coalesce(v_lake_increment, 25000);
  end if;

  v_total := v_base_total + v_adult_extra_total + v_child_extra_total + v_meal_total_all + v_bonfire_total + v_lake_total;
  v_pre_campaign_total_paise := v_total;
  select c.* into v_campaign
  from public.pricing_campaigns c
  where c.property_id = v_product.property_id
    and c.status = 'active'
    and c.stay_starts_on <= p_check_in and c.stay_ends_on >= p_check_out
    and (c.booking_starts_on is null or c.booking_starts_on <= (now() at time zone 'Asia/Kolkata')::date)
    and (c.booking_ends_on is null or c.booking_ends_on >= (now() at time zone 'Asia/Kolkata')::date)
    and c.minimum_nights <= v_nights and c.minimum_guests <= v_party_size
    and c.promo_code is null
    and c.incentive_type in ('percentage_discount', 'fixed_discount')
    and (not exists (select 1 from public.pricing_campaign_product_targets t where t.campaign_id = c.id)
      or exists (select 1 from public.pricing_campaign_product_targets t where t.campaign_id = c.id and t.product_id = v_product.id))
  order by case when c.incentive_type = 'percentage_discount' then coalesce(c.discount_bps, 0) else 0 end desc,
    case when c.incentive_type = 'fixed_discount' then coalesce(c.fixed_discount_paise, 0) else 0 end desc,
    c.created_at desc
  limit 1;
  v_campaign_applied := found;
  if v_campaign_applied then
    v_campaign_discount_paise := case v_campaign.incentive_type
      when 'percentage_discount' then round(v_total * v_campaign.discount_bps / 10000.0)::integer
      when 'fixed_discount' then v_campaign.fixed_discount_paise
      else 0 end;
    v_campaign_discount_paise := least(greatest(v_campaign_discount_paise, 0), v_total);
    v_total := v_total - v_campaign_discount_paise;
  end if;

  return jsonb_build_object(
    'currency','INR','nights',v_nights,'total_paise',v_total,'pre_campaign_total_paise',v_pre_campaign_total_paise,
    'campaign', case when v_campaign_applied then jsonb_build_object('id', v_campaign.id, 'name', v_campaign.name, 'discount_paise', v_campaign_discount_paise) else null end,
    'nightly_breakdown',v_nightly,
    'items',jsonb_build_array(
      jsonb_build_object('label','Nightly stay rate','amount_paise',v_base_total),
      jsonb_build_object('label','Additional adults','amount_paise',v_adult_extra_total),
      jsonb_build_object('label','Children aged 7-12','amount_paise',v_child_extra_total),
      jsonb_build_object('label',case when v_included_bonfire > 0 then 'Bonfire + barbecue (included)' else 'Bonfire + barbecue' end,'quantity',p_bonfire_sessions,'amount_paise',v_bonfire_total),
      jsonb_build_object('label','Lake trip','quantity',p_lake_trip_guests,'amount_paise',v_lake_total),
      jsonb_build_object('label',case when p_meal_plan = 'breakfast' then 'Breakfast included' else initcap(replace(p_meal_plan,'_',' ')) || ' upgrade' end,'amount_paise',v_meal_total_all)
    ) || case when v_campaign_applied and v_campaign_discount_paise > 0 then jsonb_build_array(jsonb_build_object('label', v_campaign.name || ' campaign discount', 'amount_paise', -v_campaign_discount_paise, 'campaign_id', v_campaign.id)) else '[]'::jsonb end,
    'notice', case when v_campaign_applied then 'An eligible Breathe Woods offer has been applied. Existing quotes are protected from later rate or campaign changes.' else 'Each night is priced from the live daily calendar. Meal selections apply to the entire booking party.' end
  );
end;
$$;

create or replace function public.capture_reservation_quote_version()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_next_version integer;
begin
  if tg_op = 'UPDATE' and new.total_paise is not distinct from old.total_paise and new.calculation is not distinct from old.calculation then return new; end if;
  update public.reservation_quote_versions set state = 'superseded' where reservation_id = new.reservation_id and state = 'active';
  select coalesce(max(version_number), 0) + 1 into v_next_version from public.reservation_quote_versions where reservation_id = new.reservation_id;
  insert into public.reservation_quote_versions (reservation_id, version_number, total_paise, currency, calculation, campaign_id, state, source)
  values (new.reservation_id, v_next_version, new.total_paise, new.currency, new.calculation, nullif(new.calculation #>> '{campaign,id}', '')::uuid, 'active', case when tg_op = 'INSERT' then 'website_quote' else 'system_snapshot_update' end);
  return new;
end;
$$;

revoke all on function public.get_booking_quote(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) from public;
grant execute on function public.get_booking_quote(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer) to anon, authenticated;


-- ============================================================================
-- 34. 202610060035_owner_rate_controls_and_offer_visibility.sql
-- ============================================================================

-- Makes active public offers visible before a guest reaches the final quote,
-- and gives owners a safe way to update the future rate matrix in bulk.

create or replace function public.get_public_rate_calendar_with_offers(
  p_start_date date,
  p_end_date date
)
returns table (
  stay_date date,
  couple_room_paise integer,
  tier_code text,
  promotion_label text,
  promotion_discount_bps integer,
  promotional_couple_room_paise integer
)
language plpgsql security definer set search_path = public
as $$
declare v_property_id uuid;
begin
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'A valid calendar range is required';
  end if;
  select id into v_property_id from public.properties where name = 'Breathe Woods' limit 1;
  if not public.daily_pricing_is_enabled(v_property_id) then return; end if;

  return query
  select d.stay_date, d.couple_room_paise, d.tier_code,
    offer.name,
    offer.discount_bps,
    case when offer.discount_bps is null then null
      else round(d.couple_room_paise * (10000 - offer.discount_bps) / 10000.0)::integer end
  from public.daily_pricing_calendar d
  left join lateral (
    select c.name, c.discount_bps
    from public.pricing_campaigns c
    where c.property_id = d.property_id
      and c.status = 'active'
      and c.stay_starts_on <= d.stay_date and c.stay_ends_on >= d.stay_date
      and (c.booking_starts_on is null or c.booking_starts_on <= (now() at time zone 'Asia/Kolkata')::date)
      and (c.booking_ends_on is null or c.booking_ends_on >= (now() at time zone 'Asia/Kolkata')::date)
      and c.minimum_nights <= 1 and c.minimum_guests <= 2
      and c.promo_code is null and c.incentive_type = 'percentage_discount'
      and (
        not exists (select 1 from public.pricing_campaign_product_targets t where t.campaign_id = c.id)
        or exists (
          select 1
          from public.pricing_campaign_product_targets t
          join public.bookable_products p on p.id = t.product_id
          where t.campaign_id = c.id and p.property_id = d.property_id and p.sellable_kind = 'room'
        )
      )
    order by c.discount_bps desc, c.created_at desc
    limit 1
  ) offer on true
  where d.property_id = v_property_id
    and d.stay_date between p_start_date and p_end_date
  order by d.stay_date;
end;
$$;

create or replace function public.get_available_products_with_offers(
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
  from_amount_paise integer,
  standard_from_amount_paise integer,
  offer_name text,
  offer_discount_bps integer
)
language sql security definer set search_path = public
as $$
  select a.product_id, a.product_code, a.product_name, a.sellable_kind,
    a.max_overnight_guests, a.included_chargeable_guests,
    case when offer.discount_bps is null then a.from_amount_paise
      else round(a.from_amount_paise * (10000 - offer.discount_bps) / 10000.0)::integer end,
    a.from_amount_paise,
    offer.name,
    offer.discount_bps
  from public.get_available_products(p_check_in, p_check_out, p_party_size) a
  join public.bookable_products p on p.id = a.product_id
  left join lateral (
    select c.name, c.discount_bps
    from public.pricing_campaigns c
    where c.property_id = p.property_id
      and c.status = 'active'
      and c.stay_starts_on <= p_check_in and c.stay_ends_on >= p_check_out
      and (c.booking_starts_on is null or c.booking_starts_on <= (now() at time zone 'Asia/Kolkata')::date)
      and (c.booking_ends_on is null or c.booking_ends_on >= (now() at time zone 'Asia/Kolkata')::date)
      and c.minimum_nights <= (p_check_out - p_check_in) and c.minimum_guests <= p_party_size
      and c.promo_code is null and c.incentive_type = 'percentage_discount'
      and (
        not exists (select 1 from public.pricing_campaign_product_targets t where t.campaign_id = c.id)
        or exists (select 1 from public.pricing_campaign_product_targets t where t.campaign_id = c.id and t.product_id = p.id)
      )
    order by c.discount_bps desc, c.created_at desc
    limit 1
  ) offer on true;
$$;

create or replace function public.owner_apply_rate_template(
  p_effective_from date,
  p_base_couple_paise integer,
  p_base_single_paise integer,
  p_base_extra_adult_paise integer,
  p_base_extra_child_paise integer,
  p_tier_multipliers jsonb
)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_property_id uuid;
  v_role public.dashboard_role;
  v_updated integer := 0;
begin
  select property_id, role into v_property_id from public.owner_profiles where user_id = auth.uid();
  if v_property_id is null or v_role = 'viewer' then raise exception 'You do not have permission to change pricing'; end if;
  if p_effective_from is null or p_effective_from < current_date then raise exception 'Choose today or a future effective date'; end if;
  if p_base_couple_paise <= 0 or p_base_single_paise <= 0 or p_base_extra_adult_paise < 0 or p_base_extra_child_paise < 0 then
    raise exception 'Enter valid base rates';
  end if;
  if p_tier_multipliers is null or jsonb_typeof(p_tier_multipliers) <> 'object' then
    raise exception 'Provide a multiplier for each rate tier';
  end if;
  if exists (select 1 from jsonb_each_text(p_tier_multipliers) t where case when t.value ~ '^[0-9]+([.][0-9]+)?$' then t.value::numeric < 0.30 or t.value::numeric > 4.00 else true end) then
    raise exception 'Rate multipliers must be between 0.30 and 4.00';
  end if;

  update public.daily_pricing_calendar d
  set couple_room_paise = round(p_base_couple_paise * t.value::numeric)::integer,
    single_room_paise = round(p_base_single_paise * t.value::numeric)::integer,
    extra_adult_paise = round(p_base_extra_adult_paise * t.value::numeric)::integer,
    extra_child_7_to_12_paise = round(p_base_extra_child_paise * t.value::numeric)::integer,
    updated_at = now(),
    notes = concat_ws(' · ', nullif(d.notes, ''), 'Updated through owner rate template')
  from jsonb_each_text(p_tier_multipliers) t
  where d.property_id = v_property_id
    and d.stay_date >= p_effective_from
    and d.tier_code = t.key;
  get diagnostics v_updated = row_count;

  insert into public.property_settings (property_id, setting_key, value)
  values (v_property_id, 'rate_management_model', jsonb_build_object(
    'effective_from', p_effective_from,
    'base_couple_paise', p_base_couple_paise,
    'base_single_paise', p_base_single_paise,
    'base_extra_adult_paise', p_base_extra_adult_paise,
    'base_extra_child_paise', p_base_extra_child_paise,
    'tier_multipliers', p_tier_multipliers,
    'updated_at', now()
  ))
  on conflict (property_id, setting_key) do update set value = excluded.value, updated_at = now();

  insert into public.audit_log (property_id, actor_id, entity_type, action, data)
  values (v_property_id, auth.uid(), 'rate_template', 'rate_template_applied', jsonb_build_object('effective_from', p_effective_from, 'updated_dates', v_updated));
  return v_updated;
end;
$$;

revoke all on function public.get_public_rate_calendar_with_offers(date, date) from public;
revoke all on function public.get_available_products_with_offers(date, date, integer) from public;
revoke all on function public.owner_apply_rate_template(date, integer, integer, integer, integer, jsonb) from public;
grant execute on function public.get_public_rate_calendar_with_offers(date, date) to anon, authenticated;
grant execute on function public.get_available_products_with_offers(date, date, integer) to anon, authenticated;
grant execute on function public.owner_apply_rate_template(date, integer, integer, integer, integer, jsonb) to authenticated;


-- ============================================================================
-- 35. 202610060036_campaign_lifecycle_and_experience_catalog.sql
-- ============================================================================

-- Campaign lifecycle controls retain historical attribution instead of
-- physically deleting records that may be referenced by an existing quote.

create or replace function public.owner_set_pricing_campaign_status(
  p_campaign_id uuid,
  p_status public.pricing_campaign_status
)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_property_id uuid; v_role public.dashboard_role;
begin
  select property_id, role into v_property_id, v_role from public.owner_profiles where user_id = auth.uid();
  if v_property_id is null or v_role = 'viewer' then raise exception 'You do not have permission to manage campaigns'; end if;
  if p_status not in ('paused', 'active', 'archived') then raise exception 'Campaigns can only be paused, resumed or archived here'; end if;
  update public.pricing_campaigns
  set status = p_status, updated_at = now(), published_at = case when p_status = 'active' then coalesce(published_at, now()) else published_at end
  where id = p_campaign_id and property_id = v_property_id;
  if not found then raise exception 'Campaign not found'; end if;
  insert into public.audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'pricing_campaign', p_campaign_id, 'campaign_status_changed', jsonb_build_object('status', p_status));
end;
$$;

alter table public.add_ons add column if not exists display_order integer not null default 100;

create or replace function public.owner_upsert_experience_catalog_item(p_experience jsonb)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_property_id uuid;
  v_role public.dashboard_role;
  v_experience_id uuid;
  v_code text;
  v_unit text;
  v_configuration jsonb;
begin
  select property_id, role into v_property_id, v_role from public.owner_profiles where user_id = auth.uid();
  if v_property_id is null or v_role = 'viewer' then raise exception 'You do not have permission to manage experiences'; end if;
  if nullif(trim(coalesce(p_experience ->> 'name', '')), '') is null then raise exception 'Give this experience a guest-facing name'; end if;
  v_unit := coalesce(p_experience ->> 'pricing_unit', 'per_stay');
  if v_unit not in ('per_stay', 'per_night', 'per_guest', 'per_session', 'fixed_package') then raise exception 'Choose a supported charging method'; end if;
  if coalesce((p_experience ->> 'amount_paise')::integer, -1) < 0 then raise exception 'Enter a valid price'; end if;
  v_configuration := coalesce(p_experience -> 'configuration', '{}'::jsonb) || jsonb_build_object('guest_visible', true, 'catalog_item', true);

  if p_experience ->> 'id' is not null then
    select id into v_experience_id from public.add_ons where id = (p_experience ->> 'id')::uuid and property_id = v_property_id for update;
    if v_experience_id is null then raise exception 'Experience not found'; end if;
    update public.add_ons set
      name = trim(p_experience ->> 'name'), description = nullif(trim(p_experience ->> 'description'), ''),
      pricing_unit = v_unit, amount_paise = (p_experience ->> 'amount_paise')::integer,
      max_quantity = nullif(p_experience ->> 'max_quantity', '')::integer,
      active = coalesce((p_experience ->> 'active')::boolean, true),
      display_order = greatest(coalesce((p_experience ->> 'display_order')::integer, 100), 0),
      configuration = v_configuration
    where id = v_experience_id;
  else
    v_code := lower(regexp_replace(trim(p_experience ->> 'name'), '[^a-z0-9]+', '-', 'g')) || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
    insert into public.add_ons (property_id, code, name, description, pricing_unit, amount_paise, max_quantity, active, display_order, configuration)
    values (v_property_id, v_code, trim(p_experience ->> 'name'), nullif(trim(p_experience ->> 'description'), ''), v_unit,
      (p_experience ->> 'amount_paise')::integer, nullif(p_experience ->> 'max_quantity', '')::integer,
      coalesce((p_experience ->> 'active')::boolean, true), greatest(coalesce((p_experience ->> 'display_order')::integer, 100), 0), v_configuration)
    returning id into v_experience_id;
  end if;
  insert into public.audit_log (property_id, actor_id, entity_type, entity_id, action)
  values (v_property_id, auth.uid(), 'experience', v_experience_id, 'experience_catalog_saved');
  return v_experience_id;
end;
$$;

revoke all on function public.owner_set_pricing_campaign_status(uuid, public.pricing_campaign_status) from public;
revoke all on function public.owner_upsert_experience_catalog_item(jsonb) from public;
grant execute on function public.owner_set_pricing_campaign_status(uuid, public.pricing_campaign_status) to authenticated;
grant execute on function public.owner_upsert_experience_catalog_item(jsonb) to authenticated;


-- ============================================================================
-- 36. 202610060037_guest_experience_selection.sql
-- ============================================================================

-- Guest-selected experience packages. The server is the source of truth for
-- availability, price calculations and the immutable reservation snapshot.

alter table public.reservation_request_inputs
  add column if not exists experience_selections jsonb not null default '[]'::jsonb;

create or replace function public.get_public_experience_catalog()
returns table (
  id uuid,
  name text,
  description text,
  pricing_unit text,
  amount_paise integer,
  max_quantity integer,
  display_order integer
)
language sql security definer set search_path = public stable as $$
  select a.id, a.name, a.description, a.pricing_unit, a.amount_paise,
    coalesce(a.max_quantity, 1), a.display_order
  from public.add_ons a
  join public.properties p on p.id = a.property_id
  where p.name = 'Breathe Woods'
    and a.active
    and coalesce((a.configuration ->> 'catalog_item')::boolean, false)
    and coalesce((a.configuration ->> 'guest_visible')::boolean, false)
  order by a.display_order, a.name;
$$;

create or replace function public.get_booking_quote_with_experiences(
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
  p_experience_selections jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_quote jsonb;
  v_product bookable_products%rowtype;
  v_selection jsonb;
  v_add_on add_ons%rowtype;
  v_quantity integer;
  v_nights integer;
  v_chargeable_guests integer;
  v_amount integer;
  v_items jsonb := '[]'::jsonb;
  v_total integer;
begin
  if p_experience_selections is null then p_experience_selections := '[]'::jsonb; end if;
  if jsonb_typeof(p_experience_selections) <> 'array' then
    raise exception 'Experience selections must be a list';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_experience_selections) value
    group by value ->> 'id'
    having count(*) > 1
  ) then
    raise exception 'Each experience can be selected only once';
  end if;

  v_quote := public.get_booking_quote_bundle_aware(
    p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12,
    p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions,
    p_lake_outings, p_lake_trip_guests
  );
  select * into v_product from public.bookable_products where id = p_product_id;
  if not found then raise exception 'This stay is no longer available'; end if;
  v_nights := p_check_out - p_check_in;
  v_chargeable_guests := p_adults + p_children_7_to_12;
  v_total := (v_quote ->> 'total_paise')::integer;

  for v_selection in select value from jsonb_array_elements(p_experience_selections) loop
    if nullif(v_selection ->> 'id', '') is null then raise exception 'An experience selection is missing its package'; end if;
    v_quantity := coalesce(nullif(v_selection ->> 'quantity', '')::integer, 0);
    if v_quantity < 1 then raise exception 'Choose a valid quantity for each experience'; end if;
    select * into v_add_on
    from public.add_ons
    where id = (v_selection ->> 'id')::uuid
      and property_id = v_product.property_id
      and active
      and coalesce((configuration ->> 'catalog_item')::boolean, false)
      and coalesce((configuration ->> 'guest_visible')::boolean, false);
    if not found then raise exception 'One of the selected experiences is no longer available'; end if;
    if v_quantity > coalesce(v_add_on.max_quantity, 1) then
      raise exception 'The selected quantity exceeds the limit for %', v_add_on.name;
    end if;
    v_amount := case v_add_on.pricing_unit
      when 'per_guest' then v_add_on.amount_paise * v_chargeable_guests * v_quantity
      when 'per_night' then v_add_on.amount_paise * v_nights * v_quantity
      else v_add_on.amount_paise * v_quantity
    end;
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'label', v_add_on.name,
      'quantity', v_quantity,
      'amount_paise', v_amount,
      'item_type', 'add_on',
      'experience_id', v_add_on.id,
      'pricing_unit', v_add_on.pricing_unit
    ));
    v_total := v_total + v_amount;
  end loop;

  return jsonb_set(
    jsonb_set(v_quote, '{total_paise}', to_jsonb(v_total)),
    '{items}', coalesce(v_quote -> 'items', '[]'::jsonb) || v_items
  );
end;
$$;

create or replace function public.create_reservation_request_bundle_aware(
  p_product_id uuid, p_check_in date, p_check_out date, p_adults integer,
  p_children_7_to_12 integer, p_children_0_to_6 integer, p_pets integer,
  p_meal_plan text, p_bonfire_sessions integer, p_lake_outings integer,
  p_lake_trip_guests integer, p_guest_name text, p_guest_email text,
  p_guest_phone text, p_marketing_opt_in boolean, p_experience_selections jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_product bookable_products%rowtype; v_quote jsonb; v_guest_id uuid;
  v_reservation_id uuid; v_reference text; v_item jsonb; v_consent_version text := '2026-10-05';
begin
  select * into v_product from public.bookable_products where id = p_product_id and active;
  if not found then raise exception 'This stay is no longer available'; end if;
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Please enter the lead guest name'; end if;
  if position('@' in coalesce(p_guest_email, '')) < 2 then raise exception 'Please enter a valid email address'; end if;
  if coalesce(p_guest_phone, '') !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Please enter a valid mobile number with country code'; end if;
  if not public.is_product_inventory_available(p_product_id, p_check_in, p_check_out) then raise exception 'This stay is not currently available. Please choose other dates.'; end if;
  v_quote := public.get_booking_quote_with_experiences(p_product_id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests, p_experience_selections);
  v_reference := 'BW-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  insert into public.guests (property_id, full_name, email, phone_e164, email_marketing_opt_in, whatsapp_opt_in, marketing_consent_at, marketing_consent_version)
  values (v_product.property_id, trim(p_guest_name), lower(trim(p_guest_email)), trim(p_guest_phone), p_marketing_opt_in, p_marketing_opt_in, case when p_marketing_opt_in then now() else null end, case when p_marketing_opt_in then v_consent_version else null end) returning id into v_guest_id;
  if p_marketing_opt_in then insert into public.guest_consents (property_id, guest_id, channel, purpose, action, consent_version, source)
  values (v_product.property_id, v_guest_id, 'email', 'marketing', 'granted', v_consent_version, 'website'), (v_product.property_id, v_guest_id, 'whatsapp', 'marketing', 'granted', v_consent_version, 'website'); end if;
  insert into public.reservations (property_id, reference, guest_id, product_id, check_in, check_out, adults, children_7_to_12, children_0_to_6, pets, source, status)
  values (v_product.property_id, v_reference, v_guest_id, v_product.id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, 'website', 'requested') returning id into v_reservation_id;
  insert into public.price_snapshots (reservation_id, total_paise, calculation) values (v_reservation_id, (v_quote ->> 'total_paise')::integer, v_quote);
  insert into public.reservation_request_inputs (reservation_id, meal_plan, bonfire_sessions, lake_outings, lake_trip_guests, experience_selections)
  values (v_reservation_id, p_meal_plan, p_bonfire_sessions, p_lake_outings, p_lake_trip_guests, coalesce(p_experience_selections, '[]'::jsonb));
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into public.reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (v_reservation_id, coalesce(v_item ->> 'item_type', case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end), v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into public.audit_log (property_id, entity_type, entity_id, action, data)
  values (v_product.property_id, 'reservation', v_reservation_id, 'request_submitted', jsonb_build_object('reference', v_reference));
  return jsonb_build_object('reservation_id', v_reservation_id, 'reference', v_reference, 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

-- Preserve package choices if an owner reprices, moves, or offers a different stay.
create or replace function public.owner_reprice_reservation_request(
  p_reservation_id uuid, p_check_in date, p_check_out date, p_note text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype; v_inputs reservation_request_inputs%rowtype; v_quote jsonb; v_item jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to change this reservation'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') then raise exception 'Only an open reservation request can be re-priced'; end if;
  if p_check_out <= p_check_in then raise exception 'Check-out must be after check-in'; end if;
  perform public.lock_property_inventory(v_property_id);
  if not public.is_product_inventory_available(v_reservation.product_id, p_check_in, p_check_out) then raise exception 'Those dates are no longer available'; end if;
  select * into v_inputs from reservation_request_inputs where reservation_id = p_reservation_id;
  if not found then raise exception 'The original request inputs are unavailable'; end if;
  v_quote := public.get_booking_quote_with_experiences(v_reservation.product_id, p_check_in, p_check_out, v_reservation.adults, v_reservation.children_7_to_12, v_reservation.children_0_to_6, v_reservation.pets, v_inputs.meal_plan, v_inputs.bonfire_sessions, v_inputs.lake_outings, v_inputs.lake_trip_guests, v_inputs.experience_selections);
  update reservations set check_in = p_check_in, check_out = p_check_out, status = 'alternative_offered', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
  update price_snapshots set total_paise = (v_quote ->> 'total_paise')::integer, calculation = v_quote, accepted_at = null where reservation_id = p_reservation_id;
  delete from reservation_items where reservation_id = p_reservation_id;
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (p_reservation_id, coalesce(v_item ->> 'item_type', case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end), v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data) values (v_property_id, auth.uid(), 'reservation', p_reservation_id, 'alternative_dates_offered', jsonb_build_object('check_in', p_check_in, 'check_out', p_check_out, 'note', p_note));
  return jsonb_build_object('status', 'alternative_offered', 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

create or replace function public.get_owner_reservation_alternatives(p_reservation_id uuid)
returns table (
  product_id uuid, product_code text, product_name text, sellable_kind text, total_paise integer
)
language plpgsql security definer set search_path = public stable as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype;
  v_inputs reservation_request_inputs%rowtype; v_candidate record; v_quote jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id;
  if not found then raise exception 'Reservation not found'; end if;
  if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') then raise exception 'Alternatives are available only for an open reservation request'; end if;
  select * into v_inputs from reservation_request_inputs where reservation_id = p_reservation_id;
  if not found then raise exception 'The original request inputs are unavailable'; end if;
  for v_candidate in select available.* from public.get_available_products(v_reservation.check_in, v_reservation.check_out, v_reservation.adults + v_reservation.children_7_to_12 + v_reservation.children_0_to_6) available where available.product_id <> v_reservation.product_id order by available.product_name loop
    v_quote := public.get_booking_quote_with_experiences(v_candidate.product_id, v_reservation.check_in, v_reservation.check_out, v_reservation.adults, v_reservation.children_7_to_12, v_reservation.children_0_to_6, v_reservation.pets, v_inputs.meal_plan, v_inputs.bonfire_sessions, v_inputs.lake_outings, v_inputs.lake_trip_guests, v_inputs.experience_selections);
    product_id := v_candidate.product_id; product_code := v_candidate.product_code; product_name := v_candidate.product_name; sellable_kind := v_candidate.sellable_kind; total_paise := (v_quote ->> 'total_paise')::integer;
    return next;
  end loop;
end;
$$;

create or replace function public.owner_offer_alternative_stay(
  p_reservation_id uuid, p_product_id uuid, p_note text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_reservation reservations%rowtype; v_product bookable_products%rowtype;
  v_inputs reservation_request_inputs%rowtype; v_quote jsonb; v_item jsonb;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to change this reservation'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id for update;
  if not found then raise exception 'Reservation not found'; end if;
  if v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') then raise exception 'Only an open reservation request can be changed'; end if;
  select * into v_product from bookable_products where id = p_product_id and property_id = v_property_id and active;
  if not found then raise exception 'That alternative stay is unavailable'; end if;
  select * into v_inputs from reservation_request_inputs where reservation_id = p_reservation_id;
  if not found then raise exception 'The original request inputs are unavailable'; end if;
  perform public.lock_property_inventory(v_property_id);
  if not public.is_product_inventory_available(v_product.id, v_reservation.check_in, v_reservation.check_out) then raise exception 'That alternative was just booked or blocked. Please choose another stay.'; end if;
  v_quote := public.get_booking_quote_with_experiences(v_product.id, v_reservation.check_in, v_reservation.check_out, v_reservation.adults, v_reservation.children_7_to_12, v_reservation.children_0_to_6, v_reservation.pets, v_inputs.meal_plan, v_inputs.bonfire_sessions, v_inputs.lake_outings, v_inputs.lake_trip_guests, v_inputs.experience_selections);
  update reservations set product_id = v_product.id, status = 'alternative_offered', internal_note = coalesce(p_note, internal_note), updated_at = now() where id = p_reservation_id;
  update price_snapshots set total_paise = (v_quote ->> 'total_paise')::integer, calculation = v_quote, accepted_at = null where reservation_id = p_reservation_id;
  delete from reservation_items where reservation_id = p_reservation_id;
  for v_item in select value from jsonb_array_elements(v_quote -> 'items') loop
    insert into reservation_items (reservation_id, item_type, label, quantity, amount_paise)
    values (p_reservation_id, coalesce(v_item ->> 'item_type', case when v_item ->> 'label' like '%rate' then 'meal_plan' when v_item ->> 'label' like '%Lake%' or v_item ->> 'label' like '%Bonfire%' then 'add_on' else 'guest_supplement' end), v_item ->> 'label', coalesce((v_item ->> 'quantity')::numeric, 1), (v_item ->> 'amount_paise')::integer);
  end loop;
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data) values (v_property_id, auth.uid(), 'reservation', p_reservation_id, 'alternative_stay_offered', jsonb_build_object('product_id', v_product.id, 'product_name', v_product.name, 'note', p_note));
  return jsonb_build_object('status', 'alternative_offered', 'total_paise', (v_quote ->> 'total_paise')::integer);
end;
$$;

revoke all on function public.get_public_experience_catalog() from public;
revoke all on function public.get_booking_quote_with_experiences(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, jsonb) from public;
revoke all on function public.create_reservation_request_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean, jsonb) from public;
grant execute on function public.get_public_experience_catalog() to anon, authenticated;
grant execute on function public.get_booking_quote_with_experiences(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, jsonb) to anon, authenticated;
grant execute on function public.create_reservation_request_bundle_aware(uuid, date, date, integer, integer, integer, integer, text, integer, integer, integer, text, text, text, boolean, jsonb) to anon, authenticated;
grant execute on function public.owner_reprice_reservation_request(uuid, date, date, text) to authenticated;
grant execute on function public.get_owner_reservation_alternatives(uuid) to authenticated;
grant execute on function public.owner_offer_alternative_stay(uuid, uuid, text) to authenticated;


-- ============================================================================
-- 37. 202610060038_owner_assisted_bookings.sql
-- ============================================================================

-- Owner-assisted booking intake for phone, email, WhatsApp, walk-in and referral reservations.
-- Intake creates a request; the existing owner workflow confirms availability and payment.

alter type public.booking_source add value if not exists 'email';
alter type public.booking_source add value if not exists 'owner_referral';

alter table public.reservation_request_inputs
  add column if not exists owner_payment_state text,
  add column if not exists owner_payment_reference text;

create or replace function public.get_owner_bookable_products()
returns table (product_id uuid, product_code text, product_name text, sellable_kind text)
language plpgsql security definer set search_path = public stable as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  return query
  select p.id, p.code, p.name, p.sellable_kind
  from bookable_products p
  where p.property_id = v_property_id and p.active
  order by p.display_order, p.name;
end;
$$;

create or replace function public.owner_create_assisted_booking(
  p_product_id uuid,
  p_check_in date,
  p_check_out date,
  p_adults integer,
  p_children_7_to_12 integer default 0,
  p_children_0_to_6 integer default 0,
  p_pets integer default 0,
  p_guest_name text default null,
  p_guest_email text default null,
  p_guest_phone text default null,
  p_source text default 'owner_dashboard',
  p_total_paise integer default null,
  p_payment_state text default 'not_recorded',
  p_payment_reference text default null,
  p_internal_note text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_property_id uuid; v_product bookable_products%rowtype; v_guest_id uuid;
  v_reservation_id uuid; v_reference text; v_allocated integer := 0;
  v_payment_state public.payment_state;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to create a guest booking'; end if;
  if p_check_out <= p_check_in then raise exception 'Check-out must be after check-in'; end if;
  if p_adults < 1 or p_children_7_to_12 < 0 or p_children_0_to_6 < 0 or p_pets < 0 then raise exception 'Guest counts are invalid'; end if;
  if length(trim(coalesce(p_guest_name, ''))) < 2 then raise exception 'Enter the guest''s full name'; end if;
  if p_guest_email is not null and length(trim(p_guest_email)) > 0 and position('@' in p_guest_email) < 2 then raise exception 'Enter a valid email address or leave it blank'; end if;
  if p_guest_phone is not null and length(trim(p_guest_phone)) > 0 and trim(p_guest_phone) !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'Enter the phone number with country code or leave it blank'; end if;
  if p_source not in ('owner_dashboard', 'phone', 'email', 'whatsapp', 'walk_in', 'owner_referral') then raise exception 'Unsupported booking source'; end if;
  if p_payment_state not in ('not_recorded', 'pending', 'paid') then raise exception 'Unsupported payment state'; end if;
  if p_payment_state in ('pending', 'paid') and coalesce(p_total_paise, 0) < 0 then raise exception 'Payment amount is invalid'; end if;

  select * into v_product from bookable_products where id = p_product_id and property_id = v_property_id and active;
  if not found then raise exception 'This stay option is not available'; end if;
  perform public.lock_property_inventory(v_property_id);

  v_reference := 'BW-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMMDD') || '-M' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 5));
  insert into guests (property_id, full_name, email, phone_e164)
  values (v_property_id, trim(p_guest_name), nullif(lower(trim(p_guest_email)), ''), nullif(trim(p_guest_phone), ''))
  returning id into v_guest_id;

  insert into reservations (property_id, reference, guest_id, product_id, check_in, check_out, adults, children_7_to_12, children_0_to_6, pets, source, status, internal_note)
  values (v_property_id, v_reference, v_guest_id, v_product.id, p_check_in, p_check_out, p_adults, p_children_7_to_12, p_children_0_to_6, p_pets, p_source::public.booking_source, 'requested', nullif(trim(p_internal_note), ''))
  returning id into v_reservation_id;

  insert into reservation_request_inputs (reservation_id, meal_plan, bonfire_sessions, lake_outings, lake_trip_guests, owner_payment_state, owner_payment_reference)
  values (v_reservation_id, 'breakfast', 0, 0, 0, p_payment_state, nullif(trim(p_payment_reference), ''));

  if p_total_paise is not null then
    if p_total_paise < 0 then raise exception 'Total amount cannot be negative'; end if;
    insert into price_snapshots (reservation_id, total_paise, calculation, accepted_at)
    values (v_reservation_id, p_total_paise, jsonb_build_object('source', 'owner_assisted', 'entered_by', auth.uid()), now());
  end if;

  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'reservation', v_reservation_id, 'owner_assisted_request_created', jsonb_build_object('reference', v_reference, 'source', p_source, 'payment_state', p_payment_state, 'payment_reference', p_payment_reference));
  return jsonb_build_object('reservation_id', v_reservation_id, 'reference', v_reference);
end;
$$;

-- Used only after the owner has verified availability and has already received
-- payment outside the booking flow. This shares the same allocation guard as
-- the regular manual-payment confirmation path.
create or replace function public.owner_confirm_assisted_payment(p_reservation_id uuid, p_payment_reference text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_property_id uuid; v_reservation reservations%rowtype; v_product bookable_products%rowtype; v_inputs reservation_request_inputs%rowtype; v_allocated integer := 0; v_total integer := 0; v_reference text;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to confirm a guest booking'; end if;
  select * into v_reservation from reservations where id = p_reservation_id and property_id = v_property_id for update;
  if not found or v_reservation.status not in ('requested', 'in_conversation', 'alternative_offered') or v_reservation.source not in ('owner_dashboard', 'phone', 'email', 'whatsapp', 'walk_in', 'owner_referral') then raise exception 'Only an open owner-assisted booking can be marked paid'; end if;
  select * into v_inputs from reservation_request_inputs where reservation_id = p_reservation_id;
  v_reference := coalesce(nullif(trim(p_payment_reference), ''), v_inputs.owner_payment_reference);
  select * into v_product from bookable_products where id = v_reservation.product_id and active;
  perform public.lock_property_inventory(v_property_id);
  if not public.is_product_inventory_available(v_product.id, v_reservation.check_in, v_reservation.check_out) then raise exception 'These dates are no longer available'; end if;
  if v_product.inventory_mode = 'child_rooms' then
    insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state)
    select v_property_id, child.id, p_reservation_id, daterange(v_reservation.check_in, v_reservation.check_out, '[)'), 'confirmed'
    from resources child where child.parent_resource_id = v_product.primary_resource_id and child.active and not exists
      (select 1 from inventory_allocations a where a.resource_id = child.id and a.stay_during && daterange(v_reservation.check_in, v_reservation.check_out, '[)') and a.state in ('confirmed','block','hold') and (a.state <> 'hold' or a.expires_at > now()))
    order by child.name limit v_product.room_units_required;
    select count(*) into v_allocated from inventory_allocations where reservation_id = p_reservation_id and state = 'confirmed';
    if v_allocated < v_product.room_units_required then raise exception 'Those rooms are no longer available'; end if;
  else
    insert into inventory_allocations (property_id, resource_id, reservation_id, stay_during, state)
    select v_property_id, bpr.resource_id, p_reservation_id, daterange(v_reservation.check_in, v_reservation.check_out, '[)'), 'confirmed'
    from bookable_product_resources bpr where bpr.product_id = v_product.id;
    select count(*) into v_allocated from inventory_allocations where reservation_id = p_reservation_id and state = 'confirmed';
    if v_allocated = 0 then raise exception 'This stay has no configured inventory'; end if;
  end if;
  select coalesce(total_paise, 0) into v_total from price_snapshots where reservation_id = p_reservation_id;
  insert into payments (reservation_id, provider, provider_reference, amount_paise, state, provider_payload)
  values (p_reservation_id, 'manual', v_reference, v_total, 'paid', jsonb_build_object('source', 'owner_assisted'));
  update reservations set status = 'confirmed', updated_at = now() where id = p_reservation_id;
  update price_snapshots set accepted_at = now() where reservation_id = p_reservation_id;
  insert into calendar_sync_outbox (property_id, reservation_id, event_type, payload) values (v_property_id, p_reservation_id, 'confirmed', jsonb_build_object('reference', v_reservation.reference, 'source', 'owner_assisted'));
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data) values (v_property_id, auth.uid(), 'reservation', p_reservation_id, 'owner_assisted_payment_confirmed', jsonb_build_object('payment_reference', v_reference));
  return jsonb_build_object('status', 'confirmed', 'reference', v_reservation.reference);
exception when exclusion_violation then
  raise exception 'Those dates were just booked or blocked. Refresh the calendar and try again';
end;
$$;

revoke all on function public.get_owner_bookable_products() from public;
revoke all on function public.owner_create_assisted_booking(uuid, date, date, integer, integer, integer, integer, text, text, text, text, integer, text, text, text) from public;
grant execute on function public.get_owner_bookable_products() to authenticated;
grant execute on function public.owner_create_assisted_booking(uuid, date, date, integer, integer, integer, integer, text, text, text, text, integer, text, text, text) to authenticated;
revoke all on function public.owner_confirm_assisted_payment(uuid, text) from public;
grant execute on function public.owner_confirm_assisted_payment(uuid, text) to authenticated;


-- ============================================================================
-- 38. 202610060039_owner_payment_instructions.sql
-- ============================================================================

-- Reusable owner payment instructions. These are private property settings,
-- never public guest configuration or repository content.

create or replace function public.get_owner_payment_instructions()
returns text
language plpgsql security definer set search_path = public stable as $$
declare v_property_id uuid; v_instructions text;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null then raise exception 'You do not have access to this dashboard'; end if;
  select coalesce(value ->> 'text', '') into v_instructions from property_settings
  where property_id = v_property_id and setting_key = 'owner_payment_instructions';
  return coalesce(v_instructions, '');
end;
$$;

create or replace function public.owner_save_payment_instructions(p_instructions text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_property_id uuid;
begin
  select property_id into v_property_id from owner_profiles where user_id = auth.uid();
  if v_property_id is null or (select role from owner_profiles where user_id = auth.uid()) = 'viewer' then raise exception 'You do not have permission to save payment instructions'; end if;
  if length(coalesce(p_instructions, '')) > 2000 then raise exception 'Payment instructions are too long'; end if;
  insert into property_settings (property_id, setting_key, value)
  values (v_property_id, 'owner_payment_instructions', jsonb_build_object('text', trim(coalesce(p_instructions, ''))))
  on conflict (property_id, setting_key) do update set value = excluded.value, updated_at = now();
  insert into audit_log (property_id, actor_id, entity_type, entity_id, action, data)
  values (v_property_id, auth.uid(), 'property_setting', v_property_id, 'owner_payment_instructions_saved', '{}'::jsonb);
end;
$$;

revoke all on function public.get_owner_payment_instructions() from public;
revoke all on function public.owner_save_payment_instructions(text) from public;
grant execute on function public.get_owner_payment_instructions() to authenticated;
grant execute on function public.owner_save_payment_instructions(text) to authenticated;


-- ============================================================================
-- 39. breathe-woods-daily-rates-2026-2027.sql
-- ============================================================================

-- Generated from Resort_Daily_Rates_2026_2027.csv. This imports rates but deliberately does NOT activate them.
-- Run only after migration 202610040013_daily_pricing_calendar.sql.

begin;

insert into public.daily_pricing_calendar (
  property_id, stay_date, tier_code, couple_room_paise, single_room_paise,
  extra_adult_paise, extra_child_7_to_12_paise, minimum_stay_nights, individual_rooms_bookable,
  individual_room_minimum_nights, buyout_discount_eligible,
  buyout_one_night_discount_bps_group_10, buyout_one_night_discount_bps_group_15,
  buyout_two_plus_nights_discount_bps_group_10, buyout_two_plus_nights_discount_bps_group_15,
  notes
) values
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-04', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-05', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-06', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-07', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-08', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-09', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-10', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-11', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-12', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-13', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-14', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-15', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-16', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-17', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-18', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-19', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-20', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-21', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-22', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-23', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-24', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-25', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-26', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-27', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-28', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-29', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-30', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-10-31', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-01', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-02', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-03', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-04', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-05', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-06', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-07', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-08', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-09', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-10', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-11', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-12', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-13', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-14', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-15', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-16', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-17', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-18', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-19', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-20', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-21', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-22', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-23', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-24', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-25', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-26', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-27', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-28', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-29', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-11-30', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-01', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-02', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-03', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-04', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-05', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-06', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-07', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-08', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-09', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-10', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-11', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-12', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-13', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-14', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-15', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-16', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-17', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-18', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-19', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-20', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-21', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-22', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-23', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-24', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-25', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-26', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-27', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-28', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-29', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-30', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2026-12-31', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-01', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-02', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-03', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-04', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-05', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-06', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-07', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-08', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-09', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-10', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-11', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-12', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-13', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-14', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-15', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-16', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-17', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-18', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-19', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-20', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-21', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-22', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-23', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-24', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-25', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-26', 'Tier 3: Mid-Week Dry Holiday', 880000, 640000, 320000, 192000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-27', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-28', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-29', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-30', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-01-31', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-01', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-02', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-03', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-04', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-05', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-06', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-07', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-08', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-09', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-10', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-11', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-12', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-13', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-14', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-15', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-16', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-17', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-18', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-19', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-20', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-21', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-22', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-23', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-24', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-25', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-26', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-27', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-02-28', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-01', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-02', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-03', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-04', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-05', 'Tier 2: Premium Long Weekend', 1144000, 832000, 416000, 249600, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-06', 'Tier 2: Premium Long Weekend', 1144000, 832000, 416000, 249600, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-07', 'Tier 2: Premium Long Weekend', 1144000, 832000, 416000, 249600, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-08', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-09', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-10', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-11', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-12', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-13', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-14', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-15', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-16', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-17', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-18', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-19', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-20', 'Tier 2: Premium Long Weekend', 1144000, 832000, 416000, 249600, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-21', 'Tier 2: Premium Long Weekend', 1144000, 832000, 416000, 249600, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-22', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-23', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-24', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-25', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-26', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-27', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-28', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-29', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-30', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-03-31', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-01', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-02', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-03', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-04', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-05', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-06', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-07', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-08', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-09', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-10', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-11', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-12', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-13', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-14', 'Tier 3: Mid-Week Dry Holiday', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-15', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-16', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-17', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-18', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-19', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-20', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-21', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-22', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-23', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-24', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-25', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-26', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-27', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-28', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-29', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-04-30', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-01', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-02', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-03', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-04', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-05', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-06', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-07', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-08', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-09', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-10', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-11', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-12', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-13', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-14', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-15', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-16', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-17', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-18', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-19', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-20', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-21', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-22', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-23', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-24', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-25', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-26', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-27', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-28', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-29', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-30', 'Summer Weekend', 550000, 400000, 200000, 120000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-05-31', 'Summer Weekday', 385000, 280000, 140000, 84000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-01', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-02', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-03', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-04', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-05', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-06', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-07', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-08', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-09', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-10', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-11', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-12', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-13', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-14', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-15', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-16', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-17', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-18', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-19', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-20', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-21', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-22', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-23', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-24', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-25', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-26', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-27', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-28', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-29', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-06-30', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-01', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-02', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-03', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-04', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-05', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-06', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-07', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-08', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-09', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-10', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-11', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-12', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-13', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-14', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-15', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-16', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-17', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-18', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-19', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-20', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-21', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-22', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-23', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-24', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-25', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-26', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-27', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-28', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-29', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-30', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-07-31', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-01', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-02', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-03', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-04', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-05', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-06', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-07', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-08', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-09', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-10', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-11', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-12', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-13', 'Tier 2: Premium Long Weekend', 1144000, 832000, 416000, 249600, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-14', 'Tier 2: Premium Long Weekend', 1144000, 832000, 416000, 249600, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-15', 'Tier 2: Premium Long Weekend', 1144000, 832000, 416000, 249600, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-16', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-17', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-18', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-19', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-20', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-21', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-22', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-23', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-24', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-25', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-26', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-27', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-28', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-29', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-30', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-08-31', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-01', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-02', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-03', 'Tier 2: Premium Long Weekend', 1144000, 832000, 416000, 249600, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-04', 'Tier 2: Premium Long Weekend', 1144000, 832000, 416000, 249600, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-05', 'Tier 2: Premium Long Weekend', 1144000, 832000, 416000, 249600, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-06', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-07', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-08', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-09', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-10', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-11', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-12', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-13', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-14', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-15', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-16', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-17', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-18', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-19', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-20', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-21', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-22', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-23', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-24', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-25', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-26', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-27', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-28', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-29', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-09-30', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-01', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-02', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-03', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-04', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-05', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-06', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-07', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-08', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-09', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-10', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-11', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-12', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-13', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-14', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-15', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-16', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-17', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-18', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-19', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-20', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-21', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-22', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-23', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-24', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-25', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-26', 'Shoulder Weekday', 467500, 340000, 170000, 102000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-27', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-28', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-29', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-30', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-10-31', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-01', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-02', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-03', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-04', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-05', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-06', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-07', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-08', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-09', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-10', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-11', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-12', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-13', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-14', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-15', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-16', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-17', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-18', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-19', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-20', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-21', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-22', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-23', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-24', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-25', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-26', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-27', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-28', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-29', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-11-30', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-01', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-02', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-03', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-04', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-05', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-06', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-07', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-08', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-09', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-10', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-11', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-12', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-13', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-14', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-15', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-16', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-17', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-18', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-19', 'Peak Weekend', 880000, 640000, 320000, 192000, 1, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-20', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-21', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-22', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-23', 'Shoulder Weekend / Peak Weekday', 660000, 480000, 240000, 144000, 1, true, 1, true, 750, 1000, 1500, 2000, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-24', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-25', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-26', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-27', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-28', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-29', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-30', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv'),
  ((select id from public.properties where name = 'Breathe Woods' limit 1), '2027-12-31', 'Tier 1: Ultra-Peak Holiday', 1375000, 1000000, 500000, 300000, 2, true, 1, false, 0, 0, 0, 0, 'Imported from Resort_Daily_Rates_2026_2027.csv')
on conflict (property_id, stay_date) do update set
  tier_code = excluded.tier_code,
  couple_room_paise = excluded.couple_room_paise,
  single_room_paise = excluded.single_room_paise,
  extra_adult_paise = excluded.extra_adult_paise,
  extra_child_7_to_12_paise = excluded.extra_child_7_to_12_paise,
  minimum_stay_nights = excluded.minimum_stay_nights,
  individual_rooms_bookable = excluded.individual_rooms_bookable,
  individual_room_minimum_nights = excluded.individual_room_minimum_nights,
  buyout_discount_eligible = excluded.buyout_discount_eligible,
  buyout_one_night_discount_bps_group_10 = excluded.buyout_one_night_discount_bps_group_10,
  buyout_one_night_discount_bps_group_15 = excluded.buyout_one_night_discount_bps_group_15,
  buyout_two_plus_nights_discount_bps_group_10 = excluded.buyout_two_plus_nights_discount_bps_group_10,
  buyout_two_plus_nights_discount_bps_group_15 = excluded.buyout_two_plus_nights_discount_bps_group_15,
  notes = excluded.notes,
  updated_at = now();

commit;


-- ============================================================================
-- 40. verify-and-activate-daily-pricing-calendar.sql
-- ============================================================================

-- Run this only after the daily-rate import has completed successfully.
-- It verifies the supplied 2026–27 range before publishing it to guests.

do $$
declare
  v_property_id uuid;
  v_rate_count integer;
  v_first_date date;
  v_last_date date;
begin
  select id into v_property_id from public.properties where name = 'Breathe Woods' limit 1;
  if v_property_id is null then raise exception 'Breathe Woods property configuration is missing'; end if;

  select count(*), min(stay_date), max(stay_date)
  into v_rate_count, v_first_date, v_last_date
  from public.daily_pricing_calendar
  where property_id = v_property_id;

  if v_rate_count <> 454 or v_first_date <> date '2026-10-04' or v_last_date <> date '2027-12-31' then
    raise exception 'Daily-rate calendar is incomplete: % rows from % to %', v_rate_count, v_first_date, v_last_date;
  end if;

  update public.property_settings
  set value = jsonb_set(
    jsonb_set(value, '{enabled}', 'true'::jsonb),
    '{status}', '"published_2026_2027"'::jsonb
  ), updated_at = now()
  where property_id = v_property_id and setting_key = 'daily_pricing_calendar';
end;
$$;

select count(*) as published_days, min(stay_date) as first_day, max(stay_date) as last_day
from public.daily_pricing_calendar
where property_id = (select id from public.properties where name = 'Breathe Woods' limit 1);


-- ============================================================================
-- 41. 202610060040_production_hardening.sql
-- ============================================================================

-- Production-only hardening. Do not apply this file to UAT: UAT keeps the
-- payment simulator enabled for controlled testing.

-- The cancellation helper is called internally by security-definer owner
-- functions. It must not be callable as a standalone authenticated RPC.
revoke execute on function public.get_reservation_cancellation_policy(uuid)
  from public, anon, authenticated;

-- If the UAT simulator migration was accidentally applied to production,
-- disable it and remove its browser-callable execute privilege. The function
-- may not exist when production correctly skips the UAT-only migration.
do $$
begin
  if to_regprocedure('public.simulate_uat_successful_payment(uuid)') is not null then
    revoke execute on function public.simulate_uat_successful_payment(uuid) from public, anon, authenticated;
  end if;
end;
$$;

do $$
declare
  v_property_id uuid;
begin
  select id into v_property_id from public.properties where name = 'Breathe Woods' limit 1;
  if v_property_id is not null then
    insert into public.property_settings (property_id, setting_key, value)
    values (v_property_id, 'uat_payment_simulation', '{"enabled": false}'::jsonb)
    on conflict (property_id, setting_key) do update
      set value = excluded.value, updated_at = now();
  end if;
end;
$$;


-- ============================================================================
-- 42. 202610060041_rpc_hardening.sql
-- ============================================================================

-- Apply in both UAT and production after the complete migration set.
-- The current website uses reservation requests; these older public hold RPCs
-- must not remain callable by anonymous browsers.

revoke execute on function public.create_uat_booking_hold(
  uuid, date, date, integer, integer, integer, integer, text, integer, integer,
  text, text, text
) from public, anon, authenticated;

revoke execute on function public.create_uat_booking_hold(
  uuid, date, date, integer, integer, integer, integer, text, integer, integer,
  text, text, text, boolean
) from public, anon, authenticated;

revoke execute on function public.create_uat_booking_hold_bundle_aware(
  uuid, date, date, integer, integer, integer, integer, text, integer, integer,
  integer, text, text, text, boolean
) from public, anon, authenticated;

revoke execute on function public.get_public_booking_hold_status(uuid, text)
  from public, anon, authenticated;
