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
