import { supabase } from '../../lib/supabase'
import type { QuoteInput } from './quote'

export type HoldInput = QuoteInput & { guestName: string; guestEmail: string; guestPhone: string; marketingOptIn: boolean }
export type BookingHold = { reservation_id: string; reference: string; payment_id: string; expires_at: string; total_paise: number }
export type BookingHoldStatus = {
  reservation_status: 'pending_payment' | 'confirmed' | 'cancelled' | 'payment_exception'
  payment_state: 'created' | 'pending' | 'paid' | 'failed' | 'cancelled' | 'expired' | 'refunded'
  expires_at: string
  total_paise: number
  reference: string
}
export type ReservationRequest = { reservation_id: string; reference: string; total_paise: number }

export async function createReservationRequest(input: HoldInput): Promise<ReservationRequest> {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('create_reservation_request_bundle_aware', {
    p_product_id: input.productId, p_check_in: input.checkIn, p_check_out: input.checkOut,
    p_adults: input.adults, p_children_7_to_12: input.children7To12, p_children_0_to_6: input.children0To6, p_pets: input.pets,
    p_meal_plan: input.mealPlan, p_bonfire_sessions: input.bonfireSessions, p_lake_outings: 0, p_lake_trip_guests: input.lakeTripGuests,
    p_experience_selections: input.experienceSelections,
    p_guest_name: input.guestName, p_guest_email: input.guestEmail, p_guest_phone: input.guestPhone,
    p_marketing_opt_in: input.marketingOptIn,
  })
  if (error) throw new Error(error.message)
  return data as ReservationRequest
}

export async function createBookingHold(input: HoldInput): Promise<BookingHold> {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('create_uat_booking_hold_bundle_aware', {
    p_product_id: input.productId, p_check_in: input.checkIn, p_check_out: input.checkOut,
    p_adults: input.adults, p_children_7_to_12: input.children7To12, p_children_0_to_6: input.children0To6, p_pets: input.pets,
    p_meal_plan: input.mealPlan, p_bonfire_sessions: input.bonfireSessions, p_lake_outings: 0, p_lake_trip_guests: input.lakeTripGuests,
    p_guest_name: input.guestName, p_guest_email: input.guestEmail, p_guest_phone: input.guestPhone,
    p_marketing_opt_in: input.marketingOptIn,
  })
  // PostgREST errors are plain objects in some browser builds; normalise them
  // so the guest sees the useful, safe database message rather than a generic failure.
  if (error) throw new Error(error.message)
  return data as BookingHold
}

/**
 * Used after a payment-provider redirect. It deliberately returns no personal
 * data; the random booking id and reference are both required to read it.
 */
export async function getBookingHoldStatus(hold: Pick<BookingHold, 'reservation_id' | 'reference'>): Promise<BookingHoldStatus | null> {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('get_public_booking_hold_status', {
    p_reservation_id: hold.reservation_id,
    p_reference: hold.reference,
  })
  if (error) throw new Error(error.message)
  return data as BookingHoldStatus | null
}
