import { supabase } from '../../lib/supabase'

export type GuestExperience = {
  id: string
  name: string
  description: string | null
  pricingUnit: 'per_stay' | 'per_night' | 'per_guest' | 'per_session' | 'fixed_package'
  amountPaise: number
  maxQuantity: number
  displayOrder: number
}

type ExperienceRow = {
  id: string
  name: string
  description: string | null
  pricing_unit: GuestExperience['pricingUnit']
  amount_paise: number
  max_quantity: number
  display_order: number
}

export type ExperienceSelection = { id: string; quantity: number }

export async function getGuestExperiences(): Promise<GuestExperience[]> {
  if (!supabase) throw new Error('UAT connection has not been configured.')
  const { data, error } = await supabase.rpc('get_public_experience_catalog')
  if (error) throw error
  return (data as ExperienceRow[]).map((row) => ({
    id: row.id,
    name: row.name,
    description: row.description,
    pricingUnit: row.pricing_unit,
    amountPaise: row.amount_paise,
    maxQuantity: row.max_quantity,
    displayOrder: row.display_order,
  }))
}

export function experiencePriceLabel(experience: GuestExperience) {
  const amount = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 }).format(experience.amountPaise / 100)
  const labels: Record<GuestExperience['pricingUnit'], string> = {
    per_stay: 'per stay',
    per_night: 'per night',
    per_guest: 'per chargeable guest',
    per_session: 'per session',
    fixed_package: 'per package',
  }
  return `${amount} ${labels[experience.pricingUnit]}`
}
