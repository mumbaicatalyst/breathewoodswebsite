import { useEffect, useState, type FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import { appConfig, isSupabaseConfigured } from '../../lib/config'
import { supabase } from '../../lib/supabase'
import { OwnerOverview } from './OwnerOverview'
import { OwnerManagement } from './OwnerManagement'
import { confirmOwnerAssistedPayment, createOwnerAssistedBooking, getOwnerBookableProducts, getOwnerBookingQuote, getOwnerCalendar, getOwnerOpenReservationRequests, getOwnerPaymentInstructions, getOwnerReservationAlternatives, getOwnerReservationDetail, offerAlternativeDates, offerAlternativeStay, ownerReservationAction, recordOwnerReservationEvent, saveOwnerPaymentInstructions, simulateUatSuccessfulPayment, type CalendarRow, type OwnerBookableProduct, type ReservationAlternative, type ReservationDetail, type ReservationRequestRow, type OwnerBookingQuote } from './calendar'

function isoDate(date: Date) {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return year + '-' + month + '-' + day
}

function startOfToday() {
  const now = new Date()
  return new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12)
}

function formatInr(paise: number | null) {
  return paise === null
    ? '—'
    : new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 }).format(paise / 100)
}

function formatOwnerDate(value: string) {
  return new Intl.DateTimeFormat('en-IN', { day: 'numeric', month: 'short' }).format(new Date(`${value}T12:00:00`))
}

export function OwnerDashboard() {
  const [session, setSession] = useState<Session | null>(null)
  const [email, setEmail] = useState('')
  const [message, setMessage] = useState<string | null>(null)
  const [dashboardView, setDashboardView] = useState<'overview' | 'reservations' | 'manage'>('overview')
  const [calendarRows, setCalendarRows] = useState<CalendarRow[]>([])
  const [reservationRequests, setReservationRequests] = useState<ReservationRequestRow[]>([])
  const [calendarError, setCalendarError] = useState<string | null>(null)
  const [selectedBooking, setSelectedBooking] = useState<ReservationDetail | null>(null)
  const [detailError, setDetailError] = useState<string | null>(null)
  const [isLoadingDetail, setIsLoadingDetail] = useState(false)
  const [isSimulatingPayment, setIsSimulatingPayment] = useState(false)
  const [isUpdatingReservation, setIsUpdatingReservation] = useState(false)
  const [alternativeCheckIn, setAlternativeCheckIn] = useState('')
  const [alternativeCheckOut, setAlternativeCheckOut] = useState('')
  const [stayAlternatives, setStayAlternatives] = useState<ReservationAlternative[]>([])
  const [isLoadingAlternatives, setIsLoadingAlternatives] = useState(false)
  const [workflowMessage, setWorkflowMessage] = useState<string | null>(null)
  const [showInventoryLedger, setShowInventoryLedger] = useState(false)
  const [isLoading, setIsLoading] = useState(false)
  const [start, setStart] = useState(isoDate(startOfToday()))
  const [end, setEnd] = useState(isoDate(new Date(startOfToday().getTime() + 7 * 86400000)))
  const [manualBookingOpen, setManualBookingOpen] = useState(false)
  const [manualProducts, setManualProducts] = useState<OwnerBookableProduct[]>([])
  const [manualProductId, setManualProductId] = useState('')
  const [manualCheckIn, setManualCheckIn] = useState('')
  const [manualCheckOut, setManualCheckOut] = useState('')
  const [manualGuestName, setManualGuestName] = useState('')
  const [manualGuestEmail, setManualGuestEmail] = useState('')
  const [manualGuestPhone, setManualGuestPhone] = useState('')
  const [manualAdults, setManualAdults] = useState('2')
  const [manualChildren7To12, setManualChildren7To12] = useState('0')
  const [manualChildren0To6, setManualChildren0To6] = useState('0')
  const [manualPets, setManualPets] = useState('0')
  const [manualSource, setManualSource] = useState('phone')
  const [manualTotal, setManualTotal] = useState('')
  const [manualPaymentState, setManualPaymentState] = useState<'not_recorded' | 'pending' | 'paid'>('not_recorded')
  const [manualPaymentReference, setManualPaymentReference] = useState('')
  const [manualNote, setManualNote] = useState('')
  const [manualQuote, setManualQuote] = useState<OwnerBookingQuote | null>(null)
  const [lastAutoManualTotal, setLastAutoManualTotal] = useState('')
  const [isLoadingManualQuote, setIsLoadingManualQuote] = useState(false)
  const [manualMessage, setManualMessage] = useState<string | null>(null)
  const [manualError, setManualError] = useState<string | null>(null)
  const [isCreatingManual, setIsCreatingManual] = useState(false)
  const [paymentInstructions, setPaymentInstructions] = useState('')
  const [savedPaymentInstructions, setSavedPaymentInstructions] = useState('')
  const [isSavingPaymentInstructions, setIsSavingPaymentInstructions] = useState(false)

  useEffect(() => {
    if (!supabase) return
    void supabase.auth.getSession().then(({ data }) => setSession(data.session))
    const { data: listener } = supabase.auth.onAuthStateChange((_event, nextSession) => setSession(nextSession))
    return () => listener.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    if (!session) return
    void getOwnerPaymentInstructions().then((instructions) => { setSavedPaymentInstructions(instructions); setPaymentInstructions(instructions) }).catch(() => undefined)
  }, [session])

  useEffect(() => {
    const validDates = manualCheckIn && manualCheckOut && manualCheckOut > manualCheckIn
    if (!manualBookingOpen || !manualProductId || !validDates || Number(manualAdults) < 1) {
      setManualQuote(null)
      setIsLoadingManualQuote(false)
      return
    }
    let active = true
    setIsLoadingManualQuote(true)
    void getOwnerBookingQuote(manualProductId, manualCheckIn, manualCheckOut, Number(manualAdults), Number(manualChildren7To12), Number(manualChildren0To6), Number(manualPets))
      .then((quote) => {
        if (!active) return
        setManualQuote(quote)
        const suggestedTotal = (quote.total_paise / 100).toFixed(2)
        if (!manualTotal || manualTotal === lastAutoManualTotal) {
          setManualTotal(suggestedTotal)
          setLastAutoManualTotal(suggestedTotal)
        }
      })
      .catch(() => { if (active) setManualQuote(null) })
      .finally(() => { if (active) setIsLoadingManualQuote(false) })
    return () => { active = false }
  }, [manualBookingOpen, manualProductId, manualCheckIn, manualCheckOut, manualAdults, manualChildren7To12, manualChildren0To6, manualPets])

  useEffect(() => {
    if (session && dashboardView === 'reservations') void loadCalendar()
  }, [session, dashboardView])

  async function requestSignIn() {
    if (!supabase) return
    setMessage(null)
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: new URL(window.location.pathname, window.location.origin).toString(),
        shouldCreateUser: false,
      },
    })
    setMessage(error ? error.message : 'Check your email for the secure sign-in link.')
  }

  async function loadCalendar() {
    setIsLoading(true)
    setCalendarError(null)
    try {
      const [rows, requests] = await Promise.all([getOwnerCalendar(start, end), getOwnerOpenReservationRequests()])
      setCalendarRows(rows); setReservationRequests(requests)
    } catch (error) {
      setCalendarRows([])
      setReservationRequests([])
      setCalendarError(error instanceof Error ? error.message : 'Unable to load the calendar.')
    } finally {
      setIsLoading(false)
    }
  }

  async function openManualBooking() {
    setManualBookingOpen(true); setManualError(null); setManualMessage(null)
    if (manualProducts.length > 0) return
    try {
      const products = await getOwnerBookableProducts()
      setManualProducts(products); setManualProductId(products[0]?.product_id ?? '')
    } catch (error) { setManualError(error instanceof Error ? error.message : 'Unable to load stay options.') }
  }

  function resetManualBooking() {
    setManualBookingOpen(false); setManualMessage(null); setManualError(null); setManualProductId(''); setManualCheckIn(''); setManualCheckOut('')
    setManualGuestName(''); setManualGuestEmail(''); setManualGuestPhone(''); setManualAdults('2'); setManualChildren7To12('0'); setManualChildren0To6('0'); setManualPets('0')
    setManualSource('phone'); setManualTotal(''); setLastAutoManualTotal(''); setManualQuote(null); setManualPaymentState('not_recorded'); setManualPaymentReference(''); setManualNote('')
  }

  async function saveManualBooking(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setManualError(null); setManualMessage(null)
    if (!manualCheckIn || !manualCheckOut || manualCheckOut <= manualCheckIn) { setManualError('Check-out must be after check-in.'); return }
    setIsCreatingManual(true)
    try {
      const result = await createOwnerAssistedBooking({
        productId: manualProductId, checkIn: manualCheckIn, checkOut: manualCheckOut, adults: Number(manualAdults),
        children7To12: Number(manualChildren7To12), children0To6: Number(manualChildren0To6), pets: Number(manualPets),
        guestName: manualGuestName, guestEmail: manualGuestEmail, guestPhone: manualGuestPhone, source: manualSource,
        totalPaise: manualTotal.trim() ? Math.round(Number(manualTotal) * 100) : null, paymentState: manualPaymentState,
        paymentReference: manualPaymentReference, internalNote: manualNote,
      })
      await loadCalendar(); await loadBookingDetail(result.reservation_id)
      setManualMessage(`Booking request ${result.reference} created. Confirm availability and payment below before sending the guest confirmation.`)
      setManualBookingOpen(false)
    } catch (error) { setManualError(error instanceof Error ? error.message : 'Unable to create the booking.') }
    finally { setIsCreatingManual(false) }
  }

  async function confirmAssistedPayment() {
    if (!selectedBooking || !window.confirm(`Confirm availability and mark ${selectedBooking.reservation.reference} as paid? This will block the selected inventory.`)) return
    setIsUpdatingReservation(true); setDetailError(null); setWorkflowMessage(null)
    try {
      await confirmOwnerAssistedPayment(selectedBooking.reservation.id, selectedBooking.payment?.provider_reference ?? '')
      await Promise.all([loadBookingDetail(selectedBooking.reservation.id), loadCalendar()])
      setWorkflowMessage('Booking confirmed. You can now prepare the guest confirmation message.')
    } catch (error) { setDetailError(error instanceof Error ? error.message : 'We could not confirm this booking.') }
    finally { setIsUpdatingReservation(false) }
  }

  async function savePaymentInstructions() {
    setIsSavingPaymentInstructions(true)
    try { await saveOwnerPaymentInstructions(paymentInstructions); setSavedPaymentInstructions(paymentInstructions); setWorkflowMessage('Saved. These payment instructions will be ready for future guest messages.') }
    catch (error) { setDetailError(error instanceof Error ? error.message : 'We could not save the payment instructions.') }
    finally { setIsSavingPaymentInstructions(false) }
  }

  async function loadBookingDetail(reservationId: string) {
    setIsLoadingDetail(true)
    setDetailError(null)
    try {
      const booking = await getOwnerReservationDetail(reservationId)
      setSelectedBooking(booking)
      setAlternativeCheckIn(booking.reservation.check_in)
      setAlternativeCheckOut(booking.reservation.check_out)
      void loadStayAlternatives(reservationId)
    } catch (error) {
      setSelectedBooking(null)
      setDetailError(error instanceof Error ? error.message : 'Unable to load booking details.')
    } finally {
      setIsLoadingDetail(false)
    }
  }

  async function loadStayAlternatives(reservationId: string) {
    setIsLoadingAlternatives(true)
    try {
      setStayAlternatives(await getOwnerReservationAlternatives(reservationId))
    } catch {
      setStayAlternatives([])
    } finally {
      setIsLoadingAlternatives(false)
    }
  }

  async function runWorkflowAction(action: 'start_conversation' | 'decline' | 'hold_for_manual_payment' | 'confirm_manual_payment' | 'cancel') {
    if (!selectedBooking) return
    const policy = selectedBooking.cancellation_policy
    const confirmation = action === 'cancel'
      ? `Cancel ${selectedBooking.reservation.reference}? ${policy?.message ?? 'Review the policy before continuing.'} Expected refund: ${formatInr(policy?.refund_paise ?? 0)}. Gateway charges may still be deducted where applicable.`
      : action === 'confirm_manual_payment'
        ? `Mark payment as received and confirm ${selectedBooking.reservation.reference}? This will block the stay inventory.`
        : undefined
    if (confirmation && !window.confirm(confirmation)) return
    setIsUpdatingReservation(true); setDetailError(null); setWorkflowMessage(null)
    try {
      await ownerReservationAction(selectedBooking.reservation.id, action)
      await Promise.all([loadBookingDetail(selectedBooking.reservation.id), loadCalendar()])
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'We could not update this reservation.'
      setDetailError(errorMessage)
      if (/no longer available|just booked|rooms were just booked/i.test(errorMessage)) {
        setWorkflowMessage('This requested stay is no longer available. Choose one of the available alternatives below to prepare a clear guest offer.')
        await loadStayAlternatives(selectedBooking.reservation.id)
      }
    }
    finally { setIsUpdatingReservation(false) }
  }

  async function recordOperationalEvent(event: 'guest_contacted' | 'payment_requested') {
    if (!selectedBooking) return
    setIsUpdatingReservation(true); setDetailError(null); setWorkflowMessage(null)
    try {
      await recordOwnerReservationEvent(selectedBooking.reservation.id, event)
      setWorkflowMessage(event === 'guest_contacted' ? 'Guest contact recorded. This helps track response time.' : 'Payment instructions recorded. The quoted price remains protected.')
    } catch (error) {
      setDetailError(error instanceof Error ? error.message : 'We could not record this action.')
    } finally { setIsUpdatingReservation(false) }
  }

  async function offerSelectedAlternative(alternative: ReservationAlternative) {
    if (!selectedBooking) return
    setIsUpdatingReservation(true); setDetailError(null); setWorkflowMessage(null)
    try {
      await offerAlternativeStay(selectedBooking.reservation.id, alternative.product_id)
      await Promise.all([loadBookingDetail(selectedBooking.reservation.id), loadCalendar()])
      setWorkflowMessage(`Alternative saved: ${alternative.product_name}. Contact the guest for approval, then create the manual-payment hold.`)
    } catch (error) {
      setDetailError(error instanceof Error ? error.message : 'We could not offer that alternative.')
    } finally { setIsUpdatingReservation(false) }
  }

  function guestAlternativeMessage() {
    if (!selectedBooking) return ''
    return `Hello ${selectedBooking.reservation.guest_name ?? ''}, thank you for your Breathe Woods reservation request. Your original stay is no longer available, but we can offer ${selectedBooking.reservation.product_name ?? 'an alternative stay'} for ${selectedBooking.reservation.check_in} to ${selectedBooking.reservation.check_out}, estimated at ${formatInr(selectedBooking.reservation.total_paise)}. If this works for you, please reply here and we will share the payment details to confirm your booking.`
  }

  function guestConfirmationMessage() {
    if (!selectedBooking) return ''
    const r = selectedBooking.reservation; const payment = selectedBooking.payment
    const paymentLine = payment?.state === 'paid'
      ? 'Payment has already been received.'
      : paymentInstructions.trim() ? `Payment details: ${paymentInstructions.trim()}` : 'Please reply to this message if you need the payment details.'
    return `Hello ${r.guest_name ?? ''}, your Breathe Woods stay is confirmed.\n\nBooking reference: ${r.reference}\nDates: ${r.check_in} to ${r.check_out}\nStay: ${r.product_name ?? 'Breathe Woods'}\nGuests: ${r.adults} adults, ${r.children_7_to_12} children aged 7–12, ${r.children_0_to_6} younger children, ${r.pets} pets\nAmount: ${formatInr(r.total_paise)}\n${paymentLine}\n\nWe look forward to welcoming you.`
  }

  function guestConfirmationEmail() {
    return { subject: selectedBooking ? `Your Breathe Woods booking is confirmed — ${selectedBooking.reservation.reference}` : '', body: guestConfirmationMessage() }
  }

  function guestPaymentMessage() {
    if (!selectedBooking) return ''
    const r = selectedBooking.reservation
    return `Hello ${r.guest_name ?? ''}, we have received your request to book with Breathe Woods. We have held the following stay for you while payment is completed.\n\nBooking reference: ${r.reference}\nDates: ${r.check_in} to ${r.check_out}\nStay: ${r.product_name ?? 'Breathe Woods'}\nAmount due: ${formatInr(r.total_paise)}\n\nPayment details:\n${paymentInstructions.trim() || 'Please enter the Breathe Woods UPI ID or payment link in the owner dashboard before sending this message.'}\n\nOnce payment is complete, please send a screenshot or payment confirmation here so that we can verify it and confirm your booking.`
  }

  function guestUnavailableMessage() {
    if (!selectedBooking) return ''
    const r = selectedBooking.reservation
    return `Hello ${r.guest_name ?? ''}, thank you for your Breathe Woods reservation request. Unfortunately, the requested stay from ${r.check_in} to ${r.check_out} is no longer available. We do not currently have a suitable alternative for those dates. Please let us know if you would like to consider different dates, and we will be happy to check again.`
  }

  async function repriceAlternativeDates() {
    if (!selectedBooking) return
    setIsUpdatingReservation(true); setDetailError(null)
    try {
      await offerAlternativeDates(selectedBooking.reservation.id, alternativeCheckIn, alternativeCheckOut)
      await Promise.all([loadBookingDetail(selectedBooking.reservation.id), loadCalendar()])
    } catch (error) { setDetailError(error instanceof Error ? error.message : 'We could not offer those dates.') }
    finally { setIsUpdatingReservation(false) }
  }

  async function simulatePayment() {
    if (!selectedBooking || !window.confirm('Simulate a successful UAT PhonePe payment for ' + selectedBooking.reservation.reference + '? This confirms the booking and blocks its inventory.')) return
    setIsSimulatingPayment(true)
    setDetailError(null)
    try {
      await simulateUatSuccessfulPayment(selectedBooking.reservation.id)
      await Promise.all([loadBookingDetail(selectedBooking.reservation.id), loadCalendar()])
    } catch (error) {
      setDetailError(error instanceof Error ? error.message : 'We could not simulate the payment.')
    } finally {
      setIsSimulatingPayment(false)
    }
  }

  function openReservations(nextStart: string, nextEnd: string, reservationId?: string) {
    setStart(nextStart)
    setEnd(nextEnd)
    setDashboardView('reservations')
    setSelectedBooking(null)
    if (reservationId) void loadBookingDetail(reservationId)
  }

  if (!isSupabaseConfigured) {
    return <main className="owner-shell"><section className="owner-callout"><h1>Setup pending</h1><p>The owner dashboard requires the UAT database connection.</p></section></main>
  }

  if (!session) {
    return <main className="owner-shell"><section className="owner-login"><p className="eyebrow">Breathe Woods</p><h1>Owner dashboard</h1><p>Only a pre-authorised owner or manager can sign in. Guest accounts are not created here.</p><label>Email address<input type="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} /></label><button className="primary" onClick={requestSignIn} disabled={!email}>Send secure sign-in link</button>{message && <p className="setup-note">{message}</p>}</section></main>
  }

  const resourceGroups = calendarRows.reduce<Record<string, CalendarRow[]>>((groups, row) => {
    ;(groups[row.resource_kind] ??= []).push(row)
    return groups
  }, {})
  const bookingAgenda = (() => {
    const groups = new Map<string, { row: CalendarRow; resources: string[] }>()
    for (const row of calendarRows) {
      if (!row.reservation_id || !row.check_in || !row.check_out) continue
      const group = groups.get(row.reservation_id)
      if (group) group.resources.push(row.resource_name)
      else groups.set(row.reservation_id, { row, resources: [row.resource_name] })
    }
    return [...groups.values()].sort((left, right) => left.row.check_in!.localeCompare(right.row.check_in!))
  })()
  const blockAgenda = (() => {
    const groups = new Map<string, { row: CalendarRow; resources: string[] }>()
    for (const row of calendarRows) {
      if (row.allocation_state !== 'block' || !row.block_id || !row.check_in || !row.check_out) continue
      const group = groups.get(row.block_id)
      if (group) group.resources.push(row.resource_name)
      else groups.set(row.block_id, { row, resources: [row.resource_name] })
    }
    return [...groups.values()].sort((left, right) => left.row.check_in!.localeCompare(right.row.check_in!))
  })()

  return <main className="owner-shell">
    <header className="owner-header">
      <div><p className="eyebrow">Breathe Woods</p><h1>Owner dashboard</h1></div>
      <div className="owner-header-actions">
        <nav className="owner-nav" aria-label="Owner dashboard sections">
          <button className={dashboardView === 'overview' ? 'is-active' : ''} onClick={() => setDashboardView('overview')}>Overview</button>
          <button className={dashboardView === 'reservations' ? 'is-active' : ''} onClick={() => setDashboardView('reservations')}>Reservations</button>
          <button className={dashboardView === 'manage' ? 'is-active' : ''} onClick={() => setDashboardView('manage')}>Manage</button>
        </nav>
        <button className="secondary" onClick={() => void supabase?.auth.signOut()}>Sign out</button>
      </div>
    </header>

    {dashboardView === 'overview' && <OwnerOverview onOpenReservations={openReservations} />}

    {dashboardView === 'manage' && <OwnerManagement />}

    {dashboardView === 'reservations' && <>
      <section className="owner-intro"><p>Review availability, guest requests and confirmed stays. Select a booking to see its details and next action.</p><button className="primary" aria-expanded={manualBookingOpen} onClick={() => void openManualBooking()}>Add a booking for a guest</button></section>
      {manualBookingOpen && <section className="manual-booking-panel">
        <header><div><p className="eyebrow">Add a booking for a guest</p><h2>Enter the guest’s booking request</h2><p>Use this when the guest contacted Breathe Woods by phone, email, WhatsApp, walk-in, or referral. You will confirm availability and payment separately.</p></div><button className="secondary" type="button" onClick={resetManualBooking}>Close</button></header>
        {manualError && <p className="form-error">{manualError}</p>}
        <form onSubmit={(event) => void saveManualBooking(event)} className="manual-booking-form">
          <label>What is the guest booking?<select value={manualProductId} onChange={(event) => setManualProductId(event.target.value)} required><option value="">Choose a stay</option>{manualProducts.map((product) => <option key={product.product_id} value={product.product_id}>{product.product_name}</option>)}</select></label>
          <label>How did this booking come in?<select value={manualSource} onChange={(event) => setManualSource(event.target.value)}><option value="phone">Phone call</option><option value="email">Email</option><option value="whatsapp">WhatsApp</option><option value="walk_in">Walk-in</option><option value="owner_referral">Owner referral / friend</option></select></label>
          <label>Check-in<input type="date" value={manualCheckIn} onChange={(event) => { const nextCheckIn = event.target.value; setManualCheckIn(nextCheckIn); if (manualCheckOut && manualCheckOut <= nextCheckIn) setManualCheckOut('') }} required /></label><label>Check-out<input type="date" min={manualCheckIn || undefined} value={manualCheckOut} onChange={(event) => setManualCheckOut(event.target.value)} disabled={!manualCheckIn} required /></label>
          <label>Full guest name<input value={manualGuestName} onChange={(event) => setManualGuestName(event.target.value)} required /></label><label>Phone with country code<input placeholder="+919967786444" value={manualGuestPhone} onChange={(event) => setManualGuestPhone(event.target.value)} /></label>
          <label>Email address<input type="email" value={manualGuestEmail} onChange={(event) => setManualGuestEmail(event.target.value)} /></label><label>Adults<input type="number" min="1" value={manualAdults} onChange={(event) => setManualAdults(event.target.value)} required /></label>
          <label>Children 7–12<input type="number" min="0" value={manualChildren7To12} onChange={(event) => setManualChildren7To12(event.target.value)} /></label><label>Children 0–6<input type="number" min="0" value={manualChildren0To6} onChange={(event) => setManualChildren0To6(event.target.value)} /></label>
          <label>Pets<input type="number" min="0" value={manualPets} onChange={(event) => setManualPets(event.target.value)} /></label><label>Total amount (₹)<input inputMode="decimal" placeholder={isLoadingManualQuote ? 'Calculating…' : 'Suggested price'} value={manualTotal} onChange={(event) => { setManualTotal(event.target.value); setLastAutoManualTotal('') }} /></label>
          {manualQuote && <div className="manual-booking-price"><strong>Suggested booking price: {formatInr(manualQuote.total_paise)}</strong><span>Based on the selected stay, dates, guests, pets and breakfast. You can change the total above if a different price was agreed with the guest.</span></div>}
          <label>Payment status<select value={manualPaymentState} onChange={(event) => setManualPaymentState(event.target.value as 'not_recorded' | 'pending' | 'paid')}><option value="not_recorded">Not recorded</option><option value="pending">Payment pending</option><option value="paid">Already paid</option></select></label><label>Payment/reference note<input placeholder="UPI / cash / reference" value={manualPaymentReference} onChange={(event) => setManualPaymentReference(event.target.value)} /></label>
          <label className="manual-booking-full">Internal note<textarea rows={3} value={manualNote} onChange={(event) => setManualNote(event.target.value)} placeholder="Special requests, source details, or allocation notes" /></label>
          <div className="manual-booking-actions"><button className="primary" type="submit" disabled={isCreatingManual || !manualProductId || !manualCheckIn || !manualCheckOut || manualCheckOut <= manualCheckIn}>{isCreatingManual ? 'Creating…' : 'Create booking request'}</button><button className="secondary" type="button" onClick={resetManualBooking}>Cancel</button></div>
        </form>
      </section>}
      {manualMessage && <p className="workflow-message">{manualMessage}</p>}
      <section className="payment-instructions-card"><div><p className="eyebrow">Payment instructions</p><h2>Saved payment details</h2><p>Enter the UPI ID, payment link, or bank details to include directly in the guest’s payment message.</p></div><textarea rows={3} value={paymentInstructions} onChange={(event) => setPaymentInstructions(event.target.value)} placeholder="Example: UPI ID: sanil.prashant@gmail.com\nPlease send the exact amount and share the payment screenshot here." /><button className="secondary" type="button" onClick={() => void savePaymentInstructions()} disabled={isSavingPaymentInstructions}>{isSavingPaymentInstructions ? 'Saving…' : 'Save payment details'}</button></section>
      {reservationRequests.length > 0 && <section className="request-queue"><div><p className="eyebrow">Needs attention</p><h2>Reservation requests</h2><p>These dates are not blocked until you create a manual-payment hold.</p></div><div className="request-queue-list">{reservationRequests.map((request) => <button key={request.reservation_id} onClick={() => void loadBookingDetail(request.reservation_id)}><span><strong>{request.guest_name ?? 'Guest request'} · {request.product_name ?? 'Stay'}</strong><small>{request.check_in} → {request.check_out} · {request.reference}</small></span><b>{request.status.replaceAll('_', ' ')}</b></button>)}</div></section>}
      <section className="calendar-toolbar">
        <label>From<input type="date" value={start} onChange={(event) => setStart(event.target.value)} /></label>
        <label>To<input type="date" value={end} onChange={(event) => setEnd(event.target.value)} /></label>
        <button className="primary" onClick={() => void loadCalendar()} disabled={isLoading}>{isLoading ? 'Loading…' : 'Refresh calendar'}</button>
      </section>
      {calendarError && <section className="owner-callout"><h2>Dashboard access is not enabled for this account</h2><p>{calendarError}</p></section>}
      {!calendarError && <section className="dashboard-layout">
        <section className="owner-reservations-main">
          <section className="reservation-agenda">
            <header><div><p className="eyebrow">Stay agenda</p><h2>Upcoming stays &amp; payment holds</h2><p>Each booking appears once, even when it occupies multiple rooms.</p></div><b>{bookingAgenda.length}</b></header>
            {bookingAgenda.length === 0 ? <p className="agenda-empty">No confirmed stays or active payment holds in this date range.</p> : <div>{bookingAgenda.map(({ row, resources }) => <button key={row.reservation_id} className="agenda-row" onClick={() => void loadBookingDetail(row.reservation_id!)}><span><strong>{row.guest_name ?? row.reservation_reference ?? 'Guest stay'}</strong><small>{formatOwnerDate(row.check_in!)} → {formatOwnerDate(row.check_out!)} · {resources.length === 1 ? resources[0] : `${resources.length} rooms`}</small></span><b className={row.allocation_state === 'hold' ? 'hold' : ''}>{row.allocation_state === 'hold' ? 'Payment hold' : 'Confirmed'}</b></button>)}</div>}
          </section>
          {blockAgenda.length > 0 && <section className="reservation-block-summary"><header><div><p className="eyebrow">Availability blocks</p><h2>Owner and maintenance use</h2></div><b>{blockAgenda.length}</b></header><div>{blockAgenda.map(({ row, resources }) => <article key={row.block_id}><span><strong>{row.block_reason ?? 'Operational block'}</strong><small>{formatOwnerDate(row.check_in!)} → {formatOwnerDate(row.check_out!)} · {resources.length} {resources.length === 1 ? 'room' : 'rooms'}</small></span></article>)}</div></section>}
          <section className="inventory-ledger">
            <header><div><p className="eyebrow">Detailed inventory</p><h2>Room-by-room allocation</h2><p>Use this audit view only when you need to inspect individual rooms.</p></div><button className="secondary" onClick={() => setShowInventoryLedger((shown) => !shown)}>{showInventoryLedger ? 'Hide room detail' : 'Show room detail'}</button></header>
            {showInventoryLedger && <div className="calendar-list">{Object.entries(resourceGroups).map(([kind, rows]) => <section key={kind}>
              <p className="eyebrow">{kind}s</p>
              {rows.map((row) => <article className="calendar-row" key={row.resource_id + '-' + (row.allocation_id ?? 'empty')}>
                <div><strong>{row.resource_name}</strong><span>{row.allocation_id ? row.check_in + ' → ' + row.check_out : 'Available in selected range'}</span></div>
                {row.allocation_id && <div className={'calendar-status ' + row.allocation_state}>
                  <strong>{row.allocation_state === 'hold' ? 'Payment hold' : row.allocation_state}</strong>
                  <span>{row.reservation_reference ?? row.block_reason ?? 'Operational block'}</span>
                  {row.guest_name && <span>{row.guest_name}</span>}
                  {row.reservation_id && <button className="booking-link" onClick={() => void loadBookingDetail(row.reservation_id as string)}>View booking</button>}
                </div>}
              </article>)}
            </section>)}</div>}
          </section>
        </section>
        <aside className="booking-detail-panel">
          {isLoadingDetail && <p>Loading booking…</p>}
          {detailError && <p className="form-error">{detailError}</p>}
          {!isLoadingDetail && !detailError && !selectedBooking && <><p className="eyebrow">Booking details</p><h2>Select a booking</h2><p>Choose “View booking” beside a reservation to see its full operational summary.</p></>}
          {selectedBooking && <>
            <div className="detail-heading"><div><p className="eyebrow">{selectedBooking.reservation.status.replace('_', ' ')}</p><h2>{selectedBooking.reservation.reference}</h2></div><button className="secondary" onClick={() => setSelectedBooking(null)}>Close</button></div>
            {workflowMessage && <p className="workflow-message">{workflowMessage}</p>}
            {['requested', 'in_conversation', 'alternative_offered'].includes(selectedBooking.reservation.status) && !selectedBooking.reservation.requested_stay_available && <div className="availability-blocked"><strong>These requested dates cannot be booked</strong><span>The stay selected by the guest is no longer available. Do not place a payment hold or confirm this request. You can offer different dates below or contact the guest to explain.</span><div>{selectedBooking.reservation.guest_phone && <a className="secondary" target="_blank" rel="noreferrer" href={`https://wa.me/${selectedBooking.reservation.guest_phone.replace(/\D/g, '')}?text=${encodeURIComponent(guestUnavailableMessage())}`}>Open WhatsApp message</a>}{selectedBooking.reservation.guest_email && <a className="secondary" href={`mailto:${selectedBooking.reservation.guest_email}?subject=${encodeURIComponent('Update on your Breathe Woods request')}&body=${encodeURIComponent(guestUnavailableMessage())}`}>Open email message</a>}<button className="secondary" onClick={() => void recordOperationalEvent('guest_contacted')} disabled={isUpdatingReservation}>Mark guest contacted</button><button className="text-button" onClick={() => void runWorkflowAction('decline')} disabled={isUpdatingReservation}>Close request</button></div></div>}
            <div className="detail-section"><strong>{selectedBooking.reservation.product_name ?? 'Stay'}</strong><span>{selectedBooking.reservation.check_in} → {selectedBooking.reservation.check_out}</span></div>
            <div className="detail-section"><strong>{selectedBooking.reservation.guest_name ?? 'Guest details unavailable'}</strong>{selectedBooking.reservation.guest_phone && <span>{selectedBooking.reservation.guest_phone}</span>}{selectedBooking.reservation.guest_email && <span>{selectedBooking.reservation.guest_email}</span>}</div>
            <div className="detail-section"><strong>Guests</strong><span>{selectedBooking.reservation.adults} adults · {selectedBooking.reservation.children_7_to_12} children 7–12 · {selectedBooking.reservation.children_0_to_6} children 0–6 · {selectedBooking.reservation.pets} pets</span></div>
            <div className="detail-section"><strong>Payment</strong><span>{selectedBooking.payment ? selectedBooking.payment.provider + ' · ' + selectedBooking.payment.state + ' · ' + formatInr(selectedBooking.payment.amount_paise) : 'Payment has not been created yet.'}</span></div>
            {['requested', 'in_conversation', 'alternative_offered'].includes(selectedBooking.reservation.status) && selectedBooking.reservation.requested_stay_available && selectedBooking.reservation.source !== 'website' && <div className="detail-section workflow-actions"><strong>Confirm this booking</strong><span>First check the dates. If payment is already received, confirm it here. Otherwise use the payment-hold option below.</span><button className="primary" onClick={() => void confirmAssistedPayment()} disabled={isUpdatingReservation}>Payment already received — confirm booking</button></div>}
            {selectedBooking.reservation.status === 'confirmed' && (selectedBooking.reservation.guest_phone || selectedBooking.reservation.guest_email) && <div className="detail-section guest-message-actions"><strong>Send booking details to guest</strong><span>Open a ready-to-send message. You will review and press Send in WhatsApp or email.</span><label>Payment details<textarea rows={3} value={paymentInstructions} onChange={(event) => setPaymentInstructions(event.target.value)} placeholder="UPI ID, payment link, or instructions" /></label><div><button className="secondary" type="button" onClick={() => void savePaymentInstructions()} disabled={isSavingPaymentInstructions}>{isSavingPaymentInstructions ? 'Saving…' : savedPaymentInstructions === paymentInstructions ? 'Saved for future bookings' : 'Save payment details'}</button>{selectedBooking.reservation.guest_phone && <a className="secondary" target="_blank" rel="noreferrer" href={`https://wa.me/${selectedBooking.reservation.guest_phone.replace(/\D/g, '')}?text=${encodeURIComponent(guestConfirmationMessage())}`}>Open WhatsApp message</a>}{selectedBooking.reservation.guest_email && <a className="secondary" href={`mailto:${selectedBooking.reservation.guest_email}?subject=${encodeURIComponent(guestConfirmationEmail().subject)}&body=${encodeURIComponent(guestConfirmationEmail().body)}`}>Open email message</a>}</div></div>}
            {['requested', 'in_conversation', 'alternative_offered'].includes(selectedBooking.reservation.status) && selectedBooking.reservation.requested_stay_available && <div className="detail-section workflow-actions"><strong>Request actions</strong><span>These dates are available. You can hold them while waiting for payment.</span><div><button className="secondary" onClick={() => void runWorkflowAction('start_conversation')} disabled={isUpdatingReservation}>Mark in conversation</button><button className="secondary" onClick={() => void recordOperationalEvent('guest_contacted')} disabled={isUpdatingReservation}>Guest contacted</button><button className="primary" onClick={() => void runWorkflowAction('hold_for_manual_payment')} disabled={isUpdatingReservation}>{isUpdatingReservation ? 'Updating…' : 'Hold for manual payment (12h)'}</button><button className="text-button" onClick={() => void runWorkflowAction('decline')} disabled={isUpdatingReservation}>Close request</button></div></div>}
            {selectedBooking.reservation.status === 'awaiting_manual_payment' && <div className="detail-section workflow-actions"><strong>Waiting for payment</strong><span>The dates are held for 12 hours. Open a ready-to-send payment message, then confirm the booking after payment is verified.</span><div>{selectedBooking.reservation.guest_phone && <a className="secondary" target="_blank" rel="noreferrer" href={`https://wa.me/${selectedBooking.reservation.guest_phone.replace(/\D/g, '')}?text=${encodeURIComponent(guestPaymentMessage())}`}>Open WhatsApp payment message</a>}{selectedBooking.reservation.guest_email && <a className="secondary" href={`mailto:${selectedBooking.reservation.guest_email}?subject=${encodeURIComponent('Payment details for your Breathe Woods stay — ' + selectedBooking.reservation.reference)}&body=${encodeURIComponent(guestPaymentMessage())}`}>Open payment email</a>}<button className="secondary" onClick={() => void recordOperationalEvent('payment_requested')} disabled={isUpdatingReservation}>Mark payment details sent</button><button className="primary" onClick={() => void runWorkflowAction('confirm_manual_payment')} disabled={isUpdatingReservation}>{isUpdatingReservation ? 'Confirming…' : 'Payment received — confirm booking'}</button></div></div>}
            {['requested', 'in_conversation', 'alternative_offered'].includes(selectedBooking.reservation.status) && <div className="detail-section alternative-dates"><strong>Offer alternative dates</strong><span>Uses the same stay and guest choices, then recalculates the total using the live daily rates.</span><div><label>Check-in<input type="date" value={alternativeCheckIn} onChange={(event) => setAlternativeCheckIn(event.target.value)} /></label><label>Check-out<input type="date" value={alternativeCheckOut} onChange={(event) => setAlternativeCheckOut(event.target.value)} /></label></div><button className="secondary" onClick={() => void repriceAlternativeDates()} disabled={isUpdatingReservation || !alternativeCheckIn || !alternativeCheckOut}>Offer recalculated dates</button></div>}
            {['requested', 'in_conversation', 'alternative_offered'].includes(selectedBooking.reservation.status) && <div className="detail-section stay-alternatives"><strong>Available stays for these dates</strong><span>Use this if the requested stay is no longer available. The total below retains the guest’s party and meal choices.</span>{isLoadingAlternatives ? <span>Checking alternatives…</span> : stayAlternatives.length ? <div>{stayAlternatives.map((alternative) => <article key={alternative.product_id}><span><b>{alternative.product_name}</b><small>{alternative.sellable_kind.replace('_', ' ')} · {formatInr(alternative.total_paise)}</small></span><button className="secondary" onClick={() => void offerSelectedAlternative(alternative)} disabled={isUpdatingReservation}>Offer this stay</button></article>)}</div> : <span className={!selectedBooking.reservation.requested_stay_available ? 'availability-none' : ''}>No alternative stay is currently available for these exact dates.</span>}</div>}
            {selectedBooking.reservation.status === 'alternative_offered' && (selectedBooking.reservation.guest_phone || selectedBooking.reservation.guest_email) && <div className="detail-section guest-message-actions"><strong>Send the guest the alternative</strong><span>The alternative is saved but not held. Send this message, wait for approval, then create the payment hold.</span><div>{selectedBooking.reservation.guest_phone && <a className="secondary" target="_blank" rel="noreferrer" href={`https://wa.me/${selectedBooking.reservation.guest_phone.replace(/\D/g, '')}?text=${encodeURIComponent(guestAlternativeMessage())}`}>WhatsApp guest</a>}{selectedBooking.reservation.guest_email && <a className="secondary" href={`mailto:${selectedBooking.reservation.guest_email}?subject=${encodeURIComponent('Your Breathe Woods stay alternative')}&body=${encodeURIComponent(guestAlternativeMessage())}`}>Email guest</a>}</div></div>}
            {selectedBooking.cancellation_policy && <div className="detail-section cancellation-policy"><strong>Cancellation &amp; refund guidance</strong><span>{selectedBooking.cancellation_policy.message}</span><b>Expected refund: {formatInr(selectedBooking.cancellation_policy.refund_paise)} ({selectedBooking.cancellation_policy.refund_percent}%)</b><button className="text-button" onClick={() => void runWorkflowAction('cancel')} disabled={isUpdatingReservation || selectedBooking.reservation.status === 'cancelled'}>{selectedBooking.reservation.status === 'cancelled' ? 'Cancelled' : 'Cancel reservation'}</button></div>}
            {appConfig.environment === 'uat' && selectedBooking.reservation.status === 'pending_payment' && <div className="detail-section"><strong>UAT test control</strong><span>Uses the real confirmation path without sending a payment to PhonePe.</span><button className="secondary" onClick={() => void simulatePayment()} disabled={isSimulatingPayment}>{isSimulatingPayment ? 'Confirming test payment…' : 'Simulate successful payment'}</button></div>}
            <div className="detail-section"><strong>Price summary</strong>{selectedBooking.items.map((item) => <span key={item.label + '-' + item.item_type}>{item.label} × {item.quantity} — {formatInr(item.amount_paise)}</span>)}<b>Total — {formatInr(selectedBooking.reservation.total_paise)}</b></div>
            {selectedBooking.reservation.internal_note && <div className="detail-section"><strong>Internal note</strong><span>{selectedBooking.reservation.internal_note}</span></div>}
          </>}
        </aside>
      </section>}
    </>}
  </main>
}
