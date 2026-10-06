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
