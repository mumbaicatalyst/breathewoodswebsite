import { supabase } from '../../lib/supabase'

export type AvailableProduct = {
  productId: string
  productCode: string
  productName: string
  sellableKind: 'room' | 'room_bundle' | 'villa' | 'entire_property'
  maxOvernightGuests: number
  includedChargeableGuests: number
  fromAmountPaise: number | null
  standardFromAmountPaise: number | null
  offerName: string | null
  offerDiscountBps: number | null
}

type AvailabilityRow = {
  product_id: string
  product_code: string
  product_name: string
  sellable_kind: AvailableProduct['sellableKind']
  max_overnight_guests: number
  included_chargeable_guests: number
  from_amount_paise: number | null
  standard_from_amount_paise: number | null
  offer_name: string | null
  offer_discount_bps: number | null
}

export async function getAvailableProducts(checkIn: string, checkOut: string, partySize: number): Promise<AvailableProduct[]> {
  if (!supabase) throw new Error('UAT connection has not been configured.')

  const { data, error } = await supabase.rpc('get_available_products_with_offers', {
    p_check_in: checkIn,
    p_check_out: checkOut,
    p_party_size: partySize,
  })

  if (error) throw error

  return (data as AvailabilityRow[]).map((row) => ({
    productId: row.product_id,
    productCode: row.product_code,
    productName: row.product_name,
    sellableKind: row.sellable_kind,
    maxOvernightGuests: row.max_overnight_guests,
    includedChargeableGuests: row.included_chargeable_guests,
    fromAmountPaise: row.from_amount_paise,
    standardFromAmountPaise: row.standard_from_amount_paise,
    offerName: row.offer_name,
    offerDiscountBps: row.offer_discount_bps,
  }))
}

export function formatInrFromPaise(value: number | null) {
  return value === null ? 'Price on request' : new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 }).format(value / 100)
}
