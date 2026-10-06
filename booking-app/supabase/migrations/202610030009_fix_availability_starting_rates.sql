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
