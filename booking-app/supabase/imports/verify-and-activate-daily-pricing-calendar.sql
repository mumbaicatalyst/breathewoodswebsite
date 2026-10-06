-- Run this only after the daily-rate import has completed successfully.
-- It verifies the supplied 2026–27 range before publishing it to guests.

do $$
declare
  v_property_id uuid;
  v_rate_count integer;
  v_first_date date;
  v_last_date date;
begin
  select id into v_property_id from public.properties where name = 'Breathe Woods' limit 1;
  if v_property_id is null then raise exception 'Breathe Woods property configuration is missing'; end if;

  select count(*), min(stay_date), max(stay_date)
  into v_rate_count, v_first_date, v_last_date
  from public.daily_pricing_calendar
  where property_id = v_property_id;

  if v_rate_count <> 454 or v_first_date <> date '2026-10-04' or v_last_date <> date '2027-12-31' then
    raise exception 'Daily-rate calendar is incomplete: % rows from % to %', v_rate_count, v_first_date, v_last_date;
  end if;

  update public.property_settings
  set value = jsonb_set(
    jsonb_set(value, '{enabled}', 'true'::jsonb),
    '{status}', '"published_2026_2027"'::jsonb
  ), updated_at = now()
  where property_id = v_property_id and setting_key = 'daily_pricing_calendar';
end;
$$;

select count(*) as published_days, min(stay_date) as first_day, max(stay_date) as last_day
from public.daily_pricing_calendar
where property_id = (select id from public.properties where name = 'Breathe Woods' limit 1);
