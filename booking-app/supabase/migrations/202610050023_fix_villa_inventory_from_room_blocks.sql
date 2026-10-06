-- A villa is sellable only when every physical bedroom within it is free.
-- This makes room-level owner blocks, holds, and confirmed bookings correctly
-- remove the corresponding whole-villa option from the guest search.

create or replace function public.is_product_inventory_available(
  p_product_id uuid,
  p_check_in date,
  p_check_out date
)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((
    select case
      -- Guest-facing room products and room bundles can use any required
      -- number of unoccupied physical bedrooms within their parent villa.
      when p.inventory_mode = 'child_rooms' then
        (
          select count(*)
          from resources child
          where child.parent_resource_id = p.primary_resource_id
            and child.active
            and child.resource_kind = 'room'
            and not exists (
              select 1
              from inventory_allocations allocation
              where allocation.resource_id = child.id
                and allocation.stay_during && daterange(p_check_in, p_check_out, '[)')
                and allocation.state in ('confirmed', 'block', 'hold')
                and (allocation.state <> 'hold' or allocation.expires_at > now())
            )
        ) >= p.room_units_required

      -- Whole-villa and whole-property products require every physical room
      -- they contain to be free. Never rely on a separate villa allocation:
      -- an owner may legitimately block just one underlying room.
      else not exists (
        select 1
        from resources required_room
        join inventory_allocations allocation
          on allocation.resource_id = required_room.id
        where required_room.property_id = p.property_id
          and required_room.active
          and required_room.resource_kind = 'room'
          and (
            p.sellable_kind = 'entire_property'
            or required_room.parent_resource_id = p.primary_resource_id
            or required_room.id = p.primary_resource_id
          )
          and allocation.stay_during && daterange(p_check_in, p_check_out, '[)')
          and allocation.state in ('confirmed', 'block', 'hold')
          and (allocation.state <> 'hold' or allocation.expires_at > now())
      )
    end
    from bookable_products p
    where p.id = p_product_id
      and p.active
  ), false);
$$;

revoke all on function public.is_product_inventory_available(uuid, date, date) from public;
grant execute on function public.is_product_inventory_available(uuid, date, date) to anon, authenticated;
