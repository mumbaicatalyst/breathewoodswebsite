import { supabase } from '../../lib/supabase'
import type { ExperienceSelection } from './experiences'

export type QuoteItem = { label: string; quantity?: number; amount_paise: number }
export type NightlyQuote = {
  date: string
  tier: string
  room_base_paise: number
  extra_adult_paise: number
  extra_child_paise: number
  meal_upgrade_paise: number
  total_paise: number
}

export type BookingQuote = {
  currency: 'INR'
  nights: number
  total_paise: number
  pre_campaign_total_paise?: number
  campaign?: { id: string; name: string; discount_paise: number } | null
  items: QuoteItem[]
  notice: string
  nightly_breakdown?: NightlyQuote[]
}

export type QuoteInput = {
  productId: string; checkIn: string; checkOut: string; adults: number; children7To12: number; children0To6: number; pets: number; mealPlan: 'breakfast' | 'breakfast_plus_one' | 'all_meals'; bonfireSessions: number; lakeTripGuests: number; experienceSelections: ExperienceSelection[]
}

export async function getBookingQuote(input: QuoteInput): Promise<BookingQuote> {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('get_booking_quote_with_experiences', {
    p_product_id: input.productId,
    p_check_in: input.checkIn,
    p_check_out: input.checkOut,
    p_adults: input.adults,
    p_children_7_to_12: input.children7To12,
    p_children_0_to_6: input.children0To6,
    p_pets: input.pets,
    p_meal_plan: input.mealPlan,
    p_bonfire_sessions: input.bonfireSessions,
    p_lake_outings: 0,
    p_lake_trip_guests: input.lakeTripGuests,
    p_experience_selections: input.experienceSelections,
  })
  if (error) throw error
  return data as BookingQuote
}
