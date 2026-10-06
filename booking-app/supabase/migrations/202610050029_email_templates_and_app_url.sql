-- Polished transactional-email payloads. Make maps one subject and one HTML
-- field, keeping the presentation consistent across owner and guest messages.

create or replace function public.html_escape(p_value text)
returns text language sql immutable as $$
  select replace(replace(replace(replace(replace(coalesce(p_value, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;

create or replace function public.format_inr_from_paise(p_value integer)
returns text language sql immutable as $$
  select '₹' || to_char(coalesce(p_value, 0)::numeric / 100, 'FM999,999,999,990');
$$;

do $$
declare v_property_id uuid;
begin
  select id into v_property_id from public.properties where name = 'Breathe Woods' limit 1;
  if v_property_id is not null then
    insert into public.property_settings (property_id, setting_key, value)
    values (v_property_id, 'booking_app_url', jsonb_build_object('url', 'http://127.0.0.1:5173'))
    on conflict (property_id, setting_key) do nothing;
  end if;
end;
$$;

create or replace function public.build_reservation_notification_payload(p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare
  v_reservation public.reservations%rowtype;
  v_guest public.guests%rowtype;
  v_product public.bookable_products%rowtype;
  v_inputs public.reservation_request_inputs%rowtype;
  v_total integer := 0;
  v_app_url text := '';
  v_dashboard_url text := '';
  v_guest_summary text;
  v_stay_summary text;
  v_owner_html text;
  v_guest_html text;
  v_items jsonb;
begin
  select * into v_reservation from public.reservations where id = p_reservation_id;
  if not found then raise exception 'Reservation not found'; end if;
  select * into v_guest from public.guests where id = v_reservation.guest_id;
  select * into v_product from public.bookable_products where id = v_reservation.product_id;
  select * into v_inputs from public.reservation_request_inputs where reservation_id = v_reservation.id;
  select coalesce(total_paise, 0) into v_total from public.price_snapshots where reservation_id = v_reservation.id;
  select coalesce(value ->> 'url', '') into v_app_url from public.property_settings
  where property_id = v_reservation.property_id and setting_key = 'booking_app_url';

  v_app_url := regexp_replace(coalesce(v_app_url, ''), '/+$', '');
  if v_app_url <> '' then v_dashboard_url := v_app_url || '/owner?reservation=' || v_reservation.id; end if;
  v_guest_summary := v_reservation.adults || ' adult' || case when v_reservation.adults = 1 then '' else 's' end
    || case when v_reservation.children_7_to_12 > 0 then ', ' || v_reservation.children_7_to_12 || ' child' || case when v_reservation.children_7_to_12 = 1 then '' else 'ren' end || ' aged 7–12' else '' end
    || case when v_reservation.children_0_to_6 > 0 then ', ' || v_reservation.children_0_to_6 || ' child' || case when v_reservation.children_0_to_6 = 1 then '' else 'ren' end || ' aged 0–6' else '' end;
  v_stay_summary := to_char(v_reservation.check_in, 'DD Mon YYYY') || ' – ' || to_char(v_reservation.check_out, 'DD Mon YYYY') || ' · ' || (v_reservation.check_out - v_reservation.check_in) || ' night' || case when v_reservation.check_out - v_reservation.check_in = 1 then '' else 's' end;
  select coalesce(jsonb_agg(jsonb_build_object('label', ri.label, 'quantity', ri.quantity, 'amount_paise', ri.amount_paise) order by ri.created_at, ri.id), '[]'::jsonb)
  into v_items from public.reservation_items ri where ri.reservation_id = v_reservation.id;

  v_owner_html := '<div style="margin:0;padding:28px 12px;background:#f6f4ed;color:#27362f;font-family:Arial,sans-serif"><div style="max-width:620px;margin:0 auto;background:#ffffff;border:1px solid #dce4d7;border-radius:16px;overflow:hidden">'
    || '<div style="padding:22px 28px;background:#173b31;color:#ffffff"><div style="font-family:Georgia,serif;font-size:25px;font-weight:700">Breathe Woods</div><div style="margin-top:5px;font-size:12px;letter-spacing:1.5px;text-transform:uppercase;color:#dbe7d8">New reservation request</div></div>'
    || '<div style="padding:28px"><h1 style="margin:0 0 10px;color:#173b31;font-family:Georgia,serif;font-size:28px;font-weight:500">A guest would like to stay</h1><p style="margin:0 0 22px;color:#5b6b61;font-size:16px;line-height:1.55">Review the request, confirm availability, then contact the guest with next steps for payment.</p>'
    || '<div style="margin:0 0 20px;padding:12px 14px;border-radius:10px;background:#f2f6ee;color:#173b31;font-size:14px"><strong>Request reference:</strong> ' || public.html_escape(v_reservation.reference) || '</div>'
    || '<table role="presentation" style="width:100%;border-collapse:collapse;font-size:15px"><tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078;width:37%">Guest</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31"><strong>' || public.html_escape(v_guest.full_name) || '</strong><br><a style="color:#173b31" href="mailto:' || public.html_escape(v_guest.email) || '">' || public.html_escape(v_guest.email) || '</a><br><a style="color:#173b31" href="tel:' || public.html_escape(v_guest.phone_e164) || '">' || public.html_escape(v_guest.phone_e164) || '</a></td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Dates</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(v_stay_summary) || '</td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Stay</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(v_product.name) || '</td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Guests</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(v_guest_summary) || '</td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Meal plan</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(initcap(replace(coalesce(v_inputs.meal_plan, 'breakfast'), '_', ' '))) || '</td></tr>'
    || '<tr><td style="padding:14px 0 0;color:#173b31;font-size:17px"><strong>Estimated total</strong></td><td style="padding:14px 0 0;color:#173b31;font-size:20px;text-align:right"><strong>' || public.format_inr_from_paise(v_total) || '</strong></td></tr></table>'
    || case when v_dashboard_url <> '' then '<p style="margin:26px 0 0"><a href="' || public.html_escape(v_dashboard_url) || '" style="display:inline-block;padding:13px 18px;border-radius:8px;background:#173b31;color:#ffffff;font-weight:700;text-decoration:none">Review request in dashboard</a></p>' else '' end
    || '</div></div></div>';

  v_guest_html := '<div style="margin:0;padding:28px 12px;background:#f6f4ed;color:#27362f;font-family:Arial,sans-serif"><div style="max-width:620px;margin:0 auto;background:#ffffff;border:1px solid #dce4d7;border-radius:16px;overflow:hidden">'
    || '<div style="padding:22px 28px;background:#173b31;color:#ffffff"><div style="font-family:Georgia,serif;font-size:25px;font-weight:700">Breathe Woods</div><div style="margin-top:5px;font-size:12px;letter-spacing:1.5px;text-transform:uppercase;color:#dbe7d8">Booking confirmed</div></div>'
    || '<div style="padding:28px"><h1 style="margin:0 0 10px;color:#173b31;font-family:Georgia,serif;font-size:28px;font-weight:500">Your stay is confirmed</h1><p style="margin:0 0 22px;color:#5b6b61;font-size:16px;line-height:1.55">Hello ' || public.html_escape(v_guest.full_name) || ', we have received your payment and look forward to welcoming you to Breathe Woods.</p>'
    || '<div style="margin:0 0 20px;padding:12px 14px;border-radius:10px;background:#f2f6ee;color:#173b31;font-size:14px"><strong>Booking reference:</strong> ' || public.html_escape(v_reservation.reference) || '</div>'
    || '<table role="presentation" style="width:100%;border-collapse:collapse;font-size:15px"><tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078;width:37%">Dates</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(v_stay_summary) || '</td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Stay</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(v_product.name) || '</td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Guests</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(v_guest_summary) || '</td></tr>'
    || '<tr><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#718078">Meal plan</td><td style="padding:12px 0;border-bottom:1px solid #e5ebe1;color:#173b31">' || public.html_escape(initcap(replace(coalesce(v_inputs.meal_plan, 'breakfast'), '_', ' '))) || '</td></tr>'
    || '<tr><td style="padding:14px 0 0;color:#173b31;font-size:17px"><strong>Amount paid</strong></td><td style="padding:14px 0 0;color:#173b31;font-size:20px;text-align:right"><strong>' || public.format_inr_from_paise(v_total) || '</strong></td></tr></table>'
    || '<p style="margin:25px 0 0;color:#5b6b61;font-size:15px;line-height:1.55">For arrival questions or special requests, reply to this email or message Breathe Woods on WhatsApp.</p><p style="margin:20px 0 0;color:#173b31;font-size:15px">Warmly,<br><strong>Breathe Woods</strong></p></div></div></div>';

  return jsonb_build_object(
    'reservation', jsonb_build_object('id', v_reservation.id, 'reference', v_reservation.reference, 'status', v_reservation.status::text, 'check_in', v_reservation.check_in, 'check_out', v_reservation.check_out, 'nights', v_reservation.check_out - v_reservation.check_in, 'dashboard_path', '/owner?reservation=' || v_reservation.id, 'dashboard_url', nullif(v_dashboard_url, '')),
    'guest', jsonb_build_object('name', v_guest.full_name, 'email', v_guest.email, 'phone', v_guest.phone_e164),
    'stay', jsonb_build_object('name', v_product.name, 'adults', v_reservation.adults, 'children_7_to_12', v_reservation.children_7_to_12, 'children_0_to_6', v_reservation.children_0_to_6, 'pets', v_reservation.pets, 'meal_plan', coalesce(v_inputs.meal_plan, 'breakfast'), 'bonfire_sessions', coalesce(v_inputs.bonfire_sessions, 0), 'lake_trip_guests', coalesce(v_inputs.lake_trip_guests, 0)),
    'pricing', jsonb_build_object('total_paise', v_total),
    'items', v_items,
    'email', jsonb_build_object('owner', jsonb_build_object('subject', 'New Breathe Woods reservation request — ' || v_reservation.reference, 'html', v_owner_html), 'guest', jsonb_build_object('subject', 'Your Breathe Woods stay is confirmed — ' || v_reservation.reference, 'html', v_guest_html))
  );
end;
$$;
