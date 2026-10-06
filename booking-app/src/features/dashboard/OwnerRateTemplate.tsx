import { useState } from 'react'
import { supabase } from '../../lib/supabase'

type Props = {
  settings: Record<string, unknown>
  onSaved: () => Promise<void>
  onMessage: (message: string) => void
  onError: (message: string) => void
}

type RateModel = {
  base_couple_paise?: number
  base_single_paise?: number
  base_extra_adult_paise?: number
  base_extra_child_paise?: number
  tier_multipliers?: Record<string, number>
}

const tiers = [
  ['Summer Weekday', 'Summer weekday', 0.7],
  ['Summer Weekend', 'Summer weekend', 1],
  ['Shoulder Weekday', 'Shoulder weekday', 0.85],
  ['Shoulder Weekend / Peak Weekday', 'Shoulder weekend / peak weekday', 1.2],
  ['Peak Weekend', 'Peak weekend', 1.6],
  ['Tier 2: Premium Long Weekend', 'Premium long weekend', 2.08],
  ['Tier 1: Ultra-Peak Holiday', 'Ultra-peak holiday', 2.5],
  ['Tier 3: Mid-Week Dry Holiday', 'Mid-week dry holiday', 1],
] as const

function localIso(date: Date) {
  const year = date.getFullYear(); const month = String(date.getMonth() + 1).padStart(2, '0'); const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function rupeesFromPaise(value: number | undefined, fallback: number) {
  return String((value ?? fallback) / 100)
}

export function OwnerRateTemplate({ settings, onSaved, onMessage, onError }: Props) {
  const [saving, setSaving] = useState(false)
  const model = (settings.rate_management_model ?? {}) as RateModel

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!supabase) return
    const values = new FormData(event.currentTarget)
    const multipliers = Object.fromEntries(tiers.map(([key]) => [key, Number(values.get(`tier:${key}`) ?? 0)]))
    if (!window.confirm('This updates future dates from the selected effective date. Existing guest requests, payment holds and confirmed bookings will not change. Continue?')) return
    setSaving(true); onError('')
    try {
      const { data, error } = await supabase.rpc('owner_apply_rate_template', {
        p_effective_from: String(values.get('effective_from')),
        p_base_couple_paise: Math.round(Number(values.get('couple')) * 100),
        p_base_single_paise: Math.round(Number(values.get('single')) * 100),
        p_base_extra_adult_paise: Math.round(Number(values.get('adult')) * 100),
        p_base_extra_child_paise: Math.round(Number(values.get('child')) * 100),
        p_tier_multipliers: multipliers,
      })
      if (error) throw new Error(error.message)
      onMessage(`${data ?? 0} future nightly rates have been updated. Existing guest prices are unchanged.`)
      await onSaved()
    } catch (caught) { onError(caught instanceof Error ? caught.message : 'Unable to apply the rate template.') }
    finally { setSaving(false) }
  }

  return <section className="rate-template">
    <header><div><p className="eyebrow">Rate foundations</p><h3>Update the base rates and seasonal ratios in one action.</h3></div><p>Use this for a deliberate pricing reset. The day-by-day editor below is for exceptions only.</p></header>
    <form onSubmit={(event) => void submit(event)}>
      <div className="rate-template-base">
        <label>Effective from<input name="effective_from" type="date" min={localIso(new Date())} defaultValue={localIso(new Date())} required /></label>
        <label>Standard couple rate<input name="couple" type="number" min="1" step="1" defaultValue={rupeesFromPaise(model.base_couple_paise, 550000)} required /></label>
        <label>Standard single rate<input name="single" type="number" min="1" step="1" defaultValue={rupeesFromPaise(model.base_single_paise, 400000)} required /></label>
        <label>Standard extra adult<input name="adult" type="number" min="0" step="1" defaultValue={rupeesFromPaise(model.base_extra_adult_paise, 200000)} required /></label>
        <label>Standard child 7–12<input name="child" type="number" min="0" step="1" defaultValue={rupeesFromPaise(model.base_extra_child_paise, 120000)} required /></label>
      </div>
      <fieldset><legend>Seasonal multipliers</legend><p>Each rate above is multiplied by the matching season. For example, 0.70 means 70% of the standard rate.</p><div className="rate-template-tiers">{tiers.map(([key, label, fallback]) => <label key={key}><span>{label}</span><input name={`tier:${key}`} type="number" min="0.3" max="4" step="0.01" defaultValue={String(model.tier_multipliers?.[key] ?? fallback)} required /></label>)}</div></fieldset>
      <button className="primary" disabled={saving}>{saving ? 'Updating future rates…' : 'Apply future rate template'}</button>
    </form>
  </section>
}
