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
