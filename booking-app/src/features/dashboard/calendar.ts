import { supabase } from '../../lib/supabase'

export type CalendarRow = {
  resource_id: string; resource_name: string; resource_kind: string; allocation_id: string | null; block_id: string | null; reservation_id: string | null; allocation_state: 'hold' | 'confirmed' | 'block' | null; hold_expires_at: string | null; check_in: string | null; check_out: string | null; reservation_reference: string | null; reservation_status: string | null; guest_name: string | null; block_reason: string | null
}
export type BlockTarget = { target_id: string; scope: 'room' | 'villa' | 'property'; label: string }
export type ReservationRequestRow = { reservation_id: string; reference: string; status: string; check_in: string; check_out: string; guest_name: string | null; product_name: string | null; total_paise: number | null; created_at: string }
export type ReservationAlternative = { product_id: string; product_code: string; product_name: string; sellable_kind: string; total_paise: number }
export type OwnerBookableProduct = { product_id: string; product_code: string; product_name: string; sellable_kind: string }
export type OwnerBookingQuote = { total_paise: number; items: Array<{ label: string; quantity?: number; amount_paise: number }>; notice?: string }

export type ReservationDetail = {
  reservation: {
    id: string; reference: string; status: string; check_in: string; check_out: string
    adults: number; children_7_to_12: number; children_0_to_6: number; pets: number
    source: string; guest_name: string | null; guest_email: string | null; guest_phone: string | null
    product_name: string | null; internal_note: string | null; total_paise: number | null; requested_stay_available: boolean
  }
  items: Array<{ label: string; quantity: number; amount_paise: number; item_type: string }>
  payment: { provider: string; state: string; amount_paise: number; provider_reference: string | null; expires_at: string | null } | null
  cancellation_policy: { refund_percent: number; refund_paise: number; decision: string; message: string; date_change_allowed: boolean } | null
}

export async function ownerReservationAction(reservationId: string, action: 'start_conversation' | 'decline' | 'hold_for_manual_payment' | 'confirm_manual_payment' | 'cancel', note?: string) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('owner_reservation_workflow_action', { p_reservation_id: reservationId, p_action: action, p_hold_hours: 12, p_note: note ?? null })
  if (error) throw new Error(error.message)
  return data as { status: string; expires_at?: string; cancellation_policy?: ReservationDetail['cancellation_policy'] }
}

export async function recordOwnerReservationEvent(reservationId: string, event: 'guest_contacted' | 'payment_requested', note?: string) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { error } = await supabase.rpc('owner_record_reservation_event', { p_reservation_id: reservationId, p_event: event, p_note: note ?? null })
  if (error) throw new Error(error.message)
}

export async function offerAlternativeDates(reservationId: string, checkIn: string, checkOut: string, note?: string) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('owner_reprice_reservation_request', { p_reservation_id: reservationId, p_check_in: checkIn, p_check_out: checkOut, p_note: note ?? null })
  if (error) throw new Error(error.message)
  return data as { status: string; total_paise: number }
}

export async function getOwnerReservationAlternatives(reservationId: string) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('get_owner_reservation_alternatives', { p_reservation_id: reservationId })
  if (error) throw new Error(error.message)
  return data as ReservationAlternative[]
}

export async function offerAlternativeStay(reservationId: string, productId: string, note?: string) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('owner_offer_alternative_stay', { p_reservation_id: reservationId, p_product_id: productId, p_note: note ?? null })
  if (error) throw new Error(error.message)
  return data as { status: string; total_paise: number }
}

export async function getOwnerCalendar(start: string, end: string) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('get_owner_calendar', { p_start: start, p_end: end })
  if (error) throw new Error(error.message)
  return data as CalendarRow[]
}

export async function getOwnerOpenReservationRequests() {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('get_owner_open_reservation_requests')
  if (error) throw new Error(error.message)
  return data as ReservationRequestRow[]
}

export async function getOwnerBookableProducts() {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('get_owner_bookable_products')
  if (error) throw new Error(error.message)
  return data as OwnerBookableProduct[]
}

export async function getOwnerBookingQuote(productId: string, checkIn: string, checkOut: string, adults: number, children7To12: number, children0To6: number, pets: number) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('get_booking_quote_with_experiences', {
    p_product_id: productId, p_check_in: checkIn, p_check_out: checkOut,
    p_adults: adults, p_children_7_to_12: children7To12, p_children_0_to_6: children0To6,
    p_pets: pets, p_meal_plan: 'breakfast', p_bonfire_sessions: 0, p_lake_outings: 0,
    p_lake_trip_guests: 0, p_experience_selections: [],
  })
  if (error) throw new Error(error.message)
  return data as OwnerBookingQuote
}

export type AssistedBookingInput = {
  productId: string; checkIn: string; checkOut: string; adults: number; children7To12: number; children0To6: number; pets: number
  guestName: string; guestEmail: string; guestPhone: string; source: string; totalPaise: number | null; paymentState: 'not_recorded' | 'pending' | 'paid'; paymentReference: string; internalNote: string
}

export async function createOwnerAssistedBooking(input: AssistedBookingInput) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('owner_create_assisted_booking', {
    p_product_id: input.productId, p_check_in: input.checkIn, p_check_out: input.checkOut,
    p_adults: input.adults, p_children_7_to_12: input.children7To12, p_children_0_to_6: input.children0To6,
    p_pets: input.pets, p_guest_name: input.guestName, p_guest_email: input.guestEmail || null,
    p_guest_phone: input.guestPhone || null, p_source: input.source, p_total_paise: input.totalPaise,
    p_payment_state: input.paymentState, p_payment_reference: input.paymentReference || null,
    p_internal_note: input.internalNote || null,
  })
  if (error) throw new Error(error.message)
  return data as { reservation_id: string; reference: string }
}

export async function confirmOwnerAssistedPayment(reservationId: string, paymentReference: string) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('owner_confirm_assisted_payment', { p_reservation_id: reservationId, p_payment_reference: paymentReference || null })
  if (error) throw new Error(error.message)
  return data as { status: string; reference: string }
}

export async function getOwnerPaymentInstructions() {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('get_owner_payment_instructions')
  if (error) throw new Error(error.message)
  return (data as string | null) ?? ''
}

export async function saveOwnerPaymentInstructions(instructions: string) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { error } = await supabase.rpc('owner_save_payment_instructions', { p_instructions: instructions })
  if (error) throw new Error(error.message)
}

export async function getOwnerBlockTargets() {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('get_owner_block_targets')
  if (error) throw new Error(error.message)
  return data as BlockTarget[]
}

export async function createOwnerInventoryBlock(targetId: string, scope: BlockTarget['scope'], checkIn: string, checkOut: string, reason: string) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('owner_create_inventory_block', { p_target_id: targetId, p_scope: scope, p_check_in: checkIn, p_check_out: checkOut, p_reason: reason })
  if (error) throw new Error(error.message)
  return data as { block_id: string; rooms_blocked: number }
}

export async function removeOwnerInventoryBlock(blockId: string) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { error } = await supabase.rpc('owner_remove_inventory_block', { p_block_id: blockId })
  if (error) throw new Error(error.message)
}

export async function getOwnerReservationDetail(reservationId: string) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('get_owner_reservation_detail', { p_reservation_id: reservationId })
  if (error) throw new Error(error.message)
  return data as ReservationDetail
}

export async function simulateUatSuccessfulPayment(reservationId: string) {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('simulate_uat_successful_payment', { p_reservation_id: reservationId })
  if (error) throw new Error(error.message)
  return data as { status: string; reference?: string; already_confirmed?: boolean }
}
