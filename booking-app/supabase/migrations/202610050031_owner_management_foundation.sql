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
