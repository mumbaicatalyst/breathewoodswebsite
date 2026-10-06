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
