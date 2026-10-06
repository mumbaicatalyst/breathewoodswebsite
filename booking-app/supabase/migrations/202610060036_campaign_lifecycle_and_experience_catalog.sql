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
