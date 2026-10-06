-- Keep India-specific mobile validation at the database boundary as well as
-- in the form. This protects future owner-created and WhatsApp bookings too.

create or replace function public.validate_guest_phone_e164()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.phone_e164 is not null
    and left(new.phone_e164, 3) = '+91'
    and substring(new.phone_e164 from 4) !~ '^[6-9][0-9]{9}$' then
    raise exception 'For India, enter a 10-digit mobile number after +91';
  end if;
  return new;
end;
$$;

drop trigger if exists validate_guest_phone_e164_before_write on public.guests;
create trigger validate_guest_phone_e164_before_write
  before insert or update of phone_e164 on public.guests
  for each row execute function public.validate_guest_phone_e164();
