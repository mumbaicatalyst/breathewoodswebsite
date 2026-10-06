export type BookingStage = 'search' | 'personalise' | 'details' | 'request'

export type Party = {
  adults: number
  children7To12: number
  children0To6: number
  pets: number
}

export type BookingDraft = {
  checkIn: string
  checkOut: string
  party: Party
  selectedProductId?: string
  mealPlanId?: string
}

export type PaymentProvider = 'phonepe' | 'razorpay'

export type PaymentState = 'created' | 'pending' | 'paid' | 'failed' | 'cancelled' | 'expired'
