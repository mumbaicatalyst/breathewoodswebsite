-- Apply in both UAT and production after the complete migration set.
-- The current website uses reservation requests; these older public hold RPCs
-- must not remain callable by anonymous browsers.

revoke execute on function public.create_uat_booking_hold(
  uuid, date, date, integer, integer, integer, integer, text, integer, integer,
  text, text, text
) from public, anon, authenticated;

revoke execute on function public.create_uat_booking_hold(
  uuid, date, date, integer, integer, integer, integer, text, integer, integer,
  text, text, text, boolean
) from public, anon, authenticated;

revoke execute on function public.create_uat_booking_hold_bundle_aware(
  uuid, date, date, integer, integer, integer, integer, text, integer, integer,
  integer, text, text, text, boolean
) from public, anon, authenticated;

revoke execute on function public.get_public_booking_hold_status(uuid, text)
  from public, anon, authenticated;
