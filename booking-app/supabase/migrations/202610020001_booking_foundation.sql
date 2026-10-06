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
