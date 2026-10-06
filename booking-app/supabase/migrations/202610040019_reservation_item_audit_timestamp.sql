-- Reservation detail uses item creation order for a stable, auditable price
-- breakdown. Earlier UAT tables did not yet carry this timestamp.

alter table public.reservation_items
  add column if not exists created_at timestamptz not null default now();
