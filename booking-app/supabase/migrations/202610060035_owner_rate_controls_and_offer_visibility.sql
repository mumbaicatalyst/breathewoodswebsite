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
