import { useEffect, useState, type FormEvent } from 'react'
import { experiencePriceLabel, getGuestExperiences, type ExperienceSelection, type GuestExperience } from '../booking/experiences'
import type { OwnerBookableProduct, OwnerBookingQuote, ReservationDetail, ReservationEditDetails } from './calendar'
import { getOwnerBookableProducts, getOwnerBookingQuote, getOwnerReservationEditDetails, updateOwnerReservation } from './calendar'

type Props = { booking: ReservationDetail; onCancel: () => void; onSaved: () => Promise<void> }

export function OwnerReservationEditor({ booking, onCancel, onSaved }: Props) {
  const [products, setProducts] = useState<OwnerBookableProduct[]>([])
  const [experiences, setExperiences] = useState<GuestExperience[]>([])
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [quote, setQuote] = useState<OwnerBookingQuote | null>(null)
  const [form, setForm] = useState({ productId: '', checkIn: '', checkOut: '', adults: '1', children7To12: '0', children0To6: '0', pets: '0', guestName: '', guestEmail: '', guestPhone: '', internalNote: '', mealPlan: 'breakfast' as 'breakfast' | 'breakfast_plus_one' | 'all_meals', bonfireSessions: '0', lakeTripGuests: '0', totalRupees: '' })
  const [selection, setSelection] = useState<ExperienceSelection[]>([])

  useEffect(() => {
    let active = true
    void Promise.all([getOwnerBookableProducts(), getGuestExperiences(), getOwnerReservationEditDetails(booking.reservation.id)])
      .then(([nextProducts, nextExperiences, input]: [OwnerBookableProduct[], GuestExperience[], ReservationEditDetails]) => {
        if (!active) return
        setProducts(nextProducts); setExperiences(nextExperiences); setSelection(input.experience_selections ?? [])
        setForm({
          productId: input.product_id, checkIn: booking.reservation.check_in, checkOut: booking.reservation.check_out,
          adults: String(booking.reservation.adults), children7To12: String(booking.reservation.children_7_to_12),
          children0To6: String(booking.reservation.children_0_to_6), pets: String(booking.reservation.pets),
          guestName: booking.reservation.guest_name ?? '', guestEmail: booking.reservation.guest_email ?? '',
          guestPhone: booking.reservation.guest_phone ?? '', internalNote: booking.reservation.internal_note ?? '',
          mealPlan: input.meal_plan, bonfireSessions: String(input.bonfire_sessions), lakeTripGuests: String(input.lake_trip_guests),
          totalRupees: ((booking.reservation.total_paise ?? 0) / 100).toFixed(2),
        })
      }).catch((e: unknown) => setError(e instanceof Error ? e.message : 'Unable to load booking choices.'))
      .finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [booking])

  const selectedProduct = products.find((product) => product.product_id === form.productId)
  const effectiveMealPlan = selectedProduct?.sellable_kind === 'entire_property' ? 'all_meals' : form.mealPlan
  const currentTotalPaise = booking.reservation.total_paise ?? 0
  const suggestedDifferencePaise = quote ? quote.total_paise - currentTotalPaise : null
  const money = (paise: number) => new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 }).format(Math.abs(paise) / 100)
  useEffect(() => {
    if (loading || !form.productId || !form.checkIn || !form.checkOut || form.checkOut <= form.checkIn || Number(form.adults) < 1) return
    let active = true
    void getOwnerBookingQuote({ productId: form.productId, checkIn: form.checkIn, checkOut: form.checkOut,
      adults: Number(form.adults), children7To12: Number(form.children7To12), children0To6: Number(form.children0To6), pets: Number(form.pets),
      mealPlan: effectiveMealPlan, bonfireSessions: Number(form.bonfireSessions), lakeTripGuests: Number(form.lakeTripGuests), experienceSelections: selection })
      .then((nextQuote) => { if (active) setQuote(nextQuote) })
      .catch((e: unknown) => { if (active) { setQuote(null); setError(e instanceof Error ? e.message : 'Could not calculate the updated quote.') } })
    return () => { active = false }
  }, [loading, form.productId, form.checkIn, form.checkOut, form.adults, form.children7To12, form.children0To6, form.pets, effectiveMealPlan, form.bonfireSessions, form.lakeTripGuests, selection])

  function set<K extends keyof typeof form>(key: K, value: (typeof form)[K]) { setForm((current) => ({ ...current, [key]: value })) }
  function setExperience(id: string, quantity: number) {
    setSelection((current) => [...current.filter((item) => item.id !== id), ...(quantity > 0 ? [{ id, quantity }] : [])])
  }
  async function save(event: FormEvent) {
    event.preventDefault(); setError(null)
    const rupees = Number(form.totalRupees)
    if (!Number.isFinite(rupees) || rupees < 0) { setError('Enter a valid agreed total.'); return }
    setSaving(true)
    try {
      await updateOwnerReservation({ reservationId: booking.reservation.id, productId: form.productId, checkIn: form.checkIn, checkOut: form.checkOut,
        adults: Number(form.adults), children7To12: Number(form.children7To12), children0To6: Number(form.children0To6), pets: Number(form.pets),
        guestName: form.guestName, guestEmail: form.guestEmail, guestPhone: form.guestPhone, internalNote: form.internalNote,
        mealPlan: effectiveMealPlan, bonfireSessions: Number(form.bonfireSessions), lakeTripGuests: Number(form.lakeTripGuests),
        experienceSelections: selection, totalPaise: Math.round(rupees * 100) })
      await onSaved()
    } catch (e) { setError(e instanceof Error ? e.message : 'Unable to save these changes.') }
    finally { setSaving(false) }
  }

  if (loading) return <div className="detail-section"><span>Loading editable booking details…</span></div>
  return <form className="detail-section reservation-edit-form" onSubmit={(event) => void save(event)}>
    <div className="edit-form-heading"><strong>Edit booking · {booking.reservation.source === 'website' ? 'Website reservation' : 'Owner booking'}</strong><button type="button" className="text-button" onClick={onCancel}>Cancel</button></div>
    <p className="edit-form-note">Changes update the reservation on the website too. Recorded payments stay in the ledger. Confirmed inventory is moved atomically if the stay or dates change.</p>
    {error && <p className="form-error">{error}</p>}
    <label>Guest name<input required minLength={2} value={form.guestName} onChange={(e) => set('guestName', e.target.value)} /></label>
    <label>Email (optional)<input type="email" value={form.guestEmail} onChange={(e) => set('guestEmail', e.target.value)} /></label>
    <label>Phone (optional)<input type="tel" value={form.guestPhone} onChange={(e) => set('guestPhone', e.target.value)} placeholder="+91…" /></label>
    <label>Stay option<select required value={form.productId} onChange={(e) => set('productId', e.target.value)}>{!products.some((p) => p.product_id === form.productId) && <option value={form.productId}>{booking.reservation.product_name ?? 'Current stay option'}</option>}{products.map((p) => <option key={p.product_id} value={p.product_id}>{p.product_name}</option>)}</select></label>
    <div className="edit-form-grid"><label>Check-in<input required type="date" value={form.checkIn} onChange={(e) => set('checkIn', e.target.value)} /></label><label>Check-out<input required type="date" value={form.checkOut} onChange={(e) => set('checkOut', e.target.value)} /></label></div>
    <div className="edit-form-grid"><label>Adults<input required type="number" min="1" value={form.adults} onChange={(e) => set('adults', e.target.value)} /></label><label>Children 7–12<input type="number" min="0" value={form.children7To12} onChange={(e) => set('children7To12', e.target.value)} /></label><label>Children 0–6<input type="number" min="0" value={form.children0To6} onChange={(e) => set('children0To6', e.target.value)} /></label><label>Pets<input type="number" min="0" value={form.pets} onChange={(e) => set('pets', e.target.value)} /></label></div>
    <label>Meal plan<select value={effectiveMealPlan} disabled={selectedProduct?.sellable_kind === 'entire_property'} onChange={(e) => set('mealPlan', e.target.value as typeof form.mealPlan)}><option value="breakfast">Breakfast</option><option value="breakfast_plus_one">Breakfast + one meal</option><option value="all_meals">All meals</option></select></label>
    <div className="edit-form-grid"><label>Bonfire sessions<input type="number" min="0" value={form.bonfireSessions} onChange={(e) => set('bonfireSessions', e.target.value)} /></label><label>Lake trip guests<input type="number" min="0" value={form.lakeTripGuests} onChange={(e) => set('lakeTripGuests', e.target.value)} /></label></div>
    {experiences.map((experience) => <label className="edit-experience" key={experience.id}>{experience.name} <small>{experiencePriceLabel(experience)}</small><input type="number" min="0" max={experience.maxQuantity} value={selection.find((item) => item.id === experience.id)?.quantity ?? 0} onChange={(e) => setExperience(experience.id, Number(e.target.value))} /></label>)}
    <div className="edit-quote">
      <span>Recalculated quote: <strong>{quote ? money(quote.total_paise) : 'Calculating…'}</strong></span>
      {suggestedDifferencePaise !== null && <div className={`edit-price-difference ${suggestedDifferencePaise > 0 ? 'is-additional' : suggestedDifferencePaise < 0 ? 'is-refund' : ''}`}>
        <strong>{suggestedDifferencePaise > 0 ? `Suggested additional charge: ${money(suggestedDifferencePaise)}` : suggestedDifferencePaise < 0 ? `Suggested refund: ${money(suggestedDifferencePaise)}` : 'No suggested price difference'}</strong>
        <small>This is only a recommendation compared with the current booking total. It does not change the booking total, record a payment, or issue a refund.</small>
      </div>}
      <label>Agreed booking total (₹)<input required type="number" min="0" step="0.01" value={form.totalRupees} onChange={(e) => set('totalRupees', e.target.value)} /></label>
      <small>The agreed total stays as entered. Update it separately only if the owner and guest agree to a new amount.</small>
      <button className="text-button" type="button" onClick={() => quote && set('totalRupees', (quote.total_paise / 100).toFixed(2))} disabled={!quote}>Set agreed total to recalculated quote</button>
    </div>
    <label>Internal note<textarea rows={3} value={form.internalNote} onChange={(e) => set('internalNote', e.target.value)} /></label>
    <button className="primary" type="submit" disabled={saving || !quote}>{saving ? 'Saving changes…' : 'Save booking changes'}</button>
  </form>
}
