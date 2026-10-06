-- Adds tappable direct-contact details to the guest confirmation email.
-- The email HTML remains generated in Supabase; Make continues mapping the same
-- record.payload.email.guest.subject and record.payload.email.guest.html fields.

create or replace function public.add_guest_confirmation_contact_links()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_html text;
  v_contact_html constant text :=
    '<div style="margin:24px 0 0;padding:16px;border:1px solid #dce4d7;border-radius:10px;background:#f2f6ee;color:#173b31;font-size:15px;line-height:1.65">'
    || '<strong style="display:block;margin-bottom:5px">Need anything before your stay?</strong>'
    || 'Call us: <a href="tel:+919967786444" style="color:#173b31;font-weight:700">+91 99677 86444</a><br>'
    || 'WhatsApp: <a href="https://wa.me/919967786444" style="color:#173b31;font-weight:700">Message Breathe Woods</a><br>'
    || 'Website: <a href="https://breathewoods.com" style="color:#173b31;font-weight:700">breathewoods.com</a>'
    || '</div>';
begin
  if new.event_type <> 'guest_booking_confirmed' then
    return new;
  end if;

  v_html := new.payload #>> '{email,guest,html}';
  if coalesce(v_html, '') = '' then
    return new;
  end if;

  new.payload := jsonb_set(
    new.payload,
    '{email,guest,html}',
    to_jsonb(regexp_replace(v_html, '</div></div></div>$', v_contact_html || '</div></div></div>')),
    true
  );

  return new;
end;
$$;

drop trigger if exists enrich_guest_confirmation_email on public.notification_outbox;
create trigger enrich_guest_confirmation_email
before insert on public.notification_outbox
for each row
execute function public.add_guest_confirmation_contact_links();

revoke all on function public.add_guest_confirmation_contact_links() from public;
