import { useEffect, useRef, useState } from 'react'
import type { BookingDraft, BookingStage } from '../../lib/types'
import { isSupabaseConfigured } from '../../lib/config'
import { formatInrFromPaise, getAvailableProducts, type AvailableProduct } from './availability'
import { getBookingQuote, type BookingQuote, type QuoteInput } from './quote'
import { createReservationRequest, type ReservationRequest } from './hold'
import { experiencePriceLabel, getGuestExperiences, type ExperienceSelection, type GuestExperience } from './experiences'
import { RateCalendar } from './RateCalendar'
import { PrivacyMessagingContent } from '../legal/PrivacyMessagingNotice'
import { CancellationRefundContent } from '../legal/CancellationRefundTerms'

const initialDraft: BookingDraft = {
  checkIn: '',
  checkOut: '',
  party: { adults: 2, children7To12: 0, children0To6: 0, pets: 0 },
}

const stages: { id: BookingStage; label: string }[] = [
  { id: 'search', label: 'Find a stay' },
  { id: 'personalise', label: 'Choose your stay' },
  { id: 'details', label: 'Your details' },
  { id: 'request', label: 'Request sent' },
]

const countryCodes = [
  { label: 'India', value: '+91' },
  { label: 'United Arab Emirates', value: '+971' },
  { label: 'United Kingdom', value: '+44' },
  { label: 'United States / Canada', value: '+1' },
  { label: 'Australia', value: '+61' },
  { label: 'Singapore', value: '+65' },
]

const bookingAsset = (fileName: string) => `${import.meta.env.BASE_URL}${fileName}`

function stayKindLabel(kind: string) {
  if (kind === 'entire_property') return 'Entire property'
  if (kind === 'room_bundle') return 'Two bedrooms'
  if (kind === 'room') return 'Room'
  return 'Villa'
}

function stayCapacityLabel(product: AvailableProduct) {
  if (product.sellableKind === 'room_bundle') return 'Best for 2 adults + 1 child'
  return `Sleeps up to ${product.maxOvernightGuests} guests`
}

function formatStayDate(value: string) {
  return new Intl.DateTimeFormat('en-IN', { weekday: 'short', day: 'numeric', month: 'short' }).format(new Date(`${value}T12:00:00`))
}

function formatMealPlan(value: QuoteInput['mealPlan']) {
  if (value === 'all_meals') return 'All meals'
  if (value === 'breakfast_plus_one') return 'Breakfast + 1 meal'
  return 'Breakfast only'
}

type NumericFieldProps = {
  label: string
  value: number
  min: number
  max: number
  onCommit: (value: number) => void
  help?: string
}

type LegalDocument = 'privacy' | 'cancellation'

function LegalOverlay({ document, onClose }: { document: LegalDocument; onClose: () => void }) {
  const title = document === 'privacy' ? 'Privacy & messaging notice' : 'Cancellation & refund terms'
  return <div className="legal-overlay" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose() }}>
    <section className="legal-overlay-card" role="dialog" aria-modal="true" aria-label={title}>
      <header><span className="eyebrow">Breathe Woods</span><button className="secondary legal-overlay-close" type="button" autoFocus onClick={onClose}>Close</button></header>
      <div className="legal-overlay-content">
        {document === 'privacy' ? <PrivacyMessagingContent /> : <CancellationRefundContent />}
      </div>
    </section>
  </div>
}

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value))
}

function bookingPrefillFromUrl() {
  const params = new URLSearchParams(window.location.search)
  const checkIn = params.get('checkIn') ?? ''
  const checkOut = params.get('checkOut') ?? ''
  const guests = clamp(Number.parseInt(params.get('guests') ?? '2', 10) || 2, 1, 15)
  const rooms = clamp(Number.parseInt(params.get('rooms') ?? '1', 10) || 1, 1, 5)
  const validDates = /^\d{4}-\d{2}-\d{2}$/.test(checkIn) && /^\d{4}-\d{2}-\d{2}$/.test(checkOut) && checkOut > checkIn
  const preferredStay = ['zen-villa', 'bougan-villa'].includes(params.get('stay') ?? '') ? params.get('stay')! : ''
  return { checkIn: validDates ? checkIn : '', checkOut: validDates ? checkOut : '', guests, rooms, preferredStay, shouldSearch: validDates }
}

function publicSiteHref() {
  return ['localhost', '127.0.0.1'].includes(window.location.hostname)
    ? 'http://127.0.0.1:4173/'
    : '/'
}

function bookingReturnHref() {
  const defaultHref = publicSiteHref()
  const returnTo = new URLSearchParams(window.location.search).get('returnTo')
  if (!returnTo) return defaultHref

  try {
    const candidate = new URL(returnTo, window.location.origin)
    const isSameSite = candidate.origin === window.location.origin
    const isLocalWebsite = ['localhost', '127.0.0.1'].includes(candidate.hostname) && candidate.port === '4173'
    return isSameSite || isLocalWebsite ? candidate.href : defaultHref
  } catch {
    return defaultHref
  }
}

/**
 * Keeps a temporary text value while someone is editing. The booking model only
 * receives a valid, clamped integer when they finish editing or use +/-.
 */
function NumericField({ label, value, min, max, onCommit, help }: NumericFieldProps) {
  const [rawValue, setRawValue] = useState(String(value))
  const [isEditing, setIsEditing] = useState(false)

  useEffect(() => {
    if (!isEditing) setRawValue(String(value))
  }, [value, isEditing])

  function commit() {
    const parsed = rawValue === '' ? min : Number.parseInt(rawValue, 10)
    const nextValue = clamp(Number.isFinite(parsed) ? parsed : min, min, max)
    setRawValue(String(nextValue))
    setIsEditing(false)
    onCommit(nextValue)
  }

  return <label className="numeric-field">{label}
    <span className="numeric-control">
      <button type="button" aria-label={`Decrease ${label}`} disabled={value <= min} onClick={() => onCommit(value - 1)}>−</button>
      <input
        type="text"
        inputMode="numeric"
        pattern="[0-9]*"
        aria-label={label}
        value={rawValue}
        onFocus={(event) => { setIsEditing(true); event.currentTarget.select() }}
        onChange={(event) => { if (/^\d*$/.test(event.target.value)) setRawValue(event.target.value) }}
        onBlur={commit}
        onKeyDown={(event) => { if (event.key === 'Enter') event.currentTarget.blur() }}
      />
      <button type="button" aria-label={`Increase ${label}`} disabled={value >= max} onClick={() => onCommit(value + 1)}>+</button>
    </span>
    {help && <small>{help}</small>}
  </label>
}

export function BookingApp() {
  const prefill = bookingPrefillFromUrl()
  const [stage, setStage] = useState<BookingStage>('search')
  const [draft, setDraft] = useState<BookingDraft>(() => ({ ...initialDraft, checkIn: prefill.checkIn, checkOut: prefill.checkOut, party: { ...initialDraft.party, adults: prefill.guests } }))
  const [searchAdults, setSearchAdults] = useState(prefill.guests)
  const [searchChildren, setSearchChildren] = useState(0)
  const [requestedRooms, setRequestedRooms] = useState(prefill.rooms)
  const [availability, setAvailability] = useState<AvailableProduct[] | null>(null)
  const [searchError, setSearchError] = useState<string | null>(null)
  const [isSearching, setIsSearching] = useState(false)
  const [mealPlan, setMealPlan] = useState<QuoteInput['mealPlan']>('breakfast')
  const [bonfireSessions, setBonfireSessions] = useState(0)
  const [lakeTripGuests, setLakeTripGuests] = useState(0)
  const [experiences, setExperiences] = useState<GuestExperience[]>([])
  const [experienceSelections, setExperienceSelections] = useState<Record<string, number>>({})
  const [experienceError, setExperienceError] = useState<string | null>(null)
  const [quote, setQuote] = useState<BookingQuote | null>(null)
  const [quoteError, setQuoteError] = useState<string | null>(null)
  const [guestError, setGuestError] = useState<string | null>(null)
  const [isQuoting, setIsQuoting] = useState(false)
  const [guestName, setGuestName] = useState('')
  const [guestEmail, setGuestEmail] = useState('')
  const [guestPhone, setGuestPhone] = useState('')
  const [countryCode, setCountryCode] = useState('+91')
  const [customCountryCode, setCustomCountryCode] = useState('')
  const [marketingOptIn, setMarketingOptIn] = useState(false)
  const [reservationRequest, setReservationRequest] = useState<ReservationRequest | null>(null)
  const [requestError, setRequestError] = useState<string | null>(null)
  const [legalDocument, setLegalDocument] = useState<LegalDocument | null>(null)
  const [isSubmittingRequest, setIsSubmittingRequest] = useState(false)
  const quoteRequestId = useRef(0)
  const wasEligibleForBonfireBenefit = useRef(false)
  const automaticSearchPending = useRef(prefill.shouldSearch)
  const stageIndex = stages.findIndex(({ id }) => id === stage)
  const canSearch = Boolean(draft.checkIn && draft.checkOut && draft.checkOut > draft.checkIn)
  const selectedProduct = availability?.find((product) => product.productId === draft.selectedProductId)
  const effectiveCountryCode = countryCode === 'other' ? customCountryCode : countryCode
  const guestPhoneDigits = guestPhone.replace(/\D/g, '')
  const guestPhoneE164 = `${effectiveCountryCode.replace(/[^0-9+]/g, '')}${guestPhoneDigits}`
  const hasValidMobileNumber = countryCode === '+91'
    ? /^[6-9][0-9]{9}$/.test(guestPhoneDigits)
    : /^\+[1-9][0-9]{7,14}$/.test(guestPhoneE164)
  const phoneValidationMessage = countryCode === '+91'
    ? 'Enter a 10-digit Indian mobile number after +91.'
    : 'Enter a valid mobile number after the country code.'
  const hasValidContactDetails = guestName.trim().length >= 2 && /\S+@\S+\.\S+/.test(guestEmail) && hasValidMobileNumber
  const selectedExperiences: ExperienceSelection[] = Object.entries(experienceSelections)
    .filter(([, quantity]) => quantity > 0)
    .map(([id, quantity]) => ({ id, quantity }))

  const whatsappGuestSummary = [
    `${draft.party.adults} ${draft.party.adults === 1 ? 'adult' : 'adults'}`,
    draft.party.children7To12 > 0 ? `${draft.party.children7To12} child aged 7–12` : null,
    draft.party.children0To6 > 0 ? `${draft.party.children0To6} child aged 0–6` : null,
  ].filter(Boolean).join(', ')
  const whatsappExperienceSummary = selectedExperiences.length
    ? experiences.filter((experience) => (experienceSelections[experience.id] ?? 0) > 0).map((experience) => `${experience.name}${(experienceSelections[experience.id] ?? 0) > 1 ? ` × ${experienceSelections[experience.id]}` : ''}`).join(', ')
    : 'None selected'
  const whatsappMessage = reservationRequest ? [
    'Hello Breathe Woods,',
    '',
    'I’ve sent a reservation request and would like to confirm availability and the payment next steps.',
    '',
    `Guest: ${guestName.trim()}`,
    `Email: ${guestEmail.trim()}`,
    `Mobile / WhatsApp: ${guestPhoneE164}`,
    `Dates: ${formatStayDate(draft.checkIn)} – ${formatStayDate(draft.checkOut)}`,
    `Stay requested: ${selectedProduct?.productName ?? 'Breathe Woods stay'}`,
    `Guests: ${whatsappGuestSummary}`,
    `Meal plan: ${formatMealPlan(mealPlan)}`,
    `Experiences: ${whatsappExperienceSummary}`,
    '',
    `Reference for the Breathe Woods team: ${reservationRequest.reference}`,
  ].join('\n') : ''

  const requestedGuestCount = searchAdults + searchChildren
  const partyTotal = draft.party.adults + draft.party.children7To12 + draft.party.children0To6
  const activityGuestCount = draft.party.adults + draft.party.children7To12
  const hasBonfireMealBenefit = activityGuestCount >= 7 && (mealPlan === 'all_meals' || mealPlan === 'breakfast_plus_one')
  const isRoomStay = selectedProduct?.sellableKind === 'room'
  const selectedStayCapacity = selectedProduct?.maxOvernightGuests ?? 15
  // A room includes a couple; one additional chargeable guest can be either
  // a third adult or one child aged 7–12. Younger children use capacity but
  // are complimentary.
  const maxAdults = isRoomStay
    ? Math.min(draft.party.children7To12 + draft.party.children0To6 > 0 ? 2 : 3, Math.max(1, selectedStayCapacity - draft.party.children7To12 - draft.party.children0To6), 3 - draft.party.children7To12)
    : Math.max(1, selectedStayCapacity - draft.party.children7To12 - draft.party.children0To6)
  const maxChildren7To12 = isRoomStay
    ? Math.min(1, Math.max(0, selectedStayCapacity - draft.party.adults - draft.party.children0To6), Math.max(0, 3 - draft.party.adults))
    : Math.max(0, selectedStayCapacity - draft.party.adults - draft.party.children0To6)
  const maxChildren0To6 = isRoomStay ? Math.min(draft.party.adults >= 3 ? 0 : 2, Math.max(0, selectedStayCapacity - draft.party.adults - draft.party.children7To12)) : Math.max(0, selectedStayCapacity - draft.party.adults - draft.party.children7To12)
  const roomsNeededForAdults = Math.ceil(searchAdults / 3)
  const roomSearchGuidance = requestedRooms === 1 && searchAdults >= 3 && (searchAdults > 3 || searchChildren > 0)
    ? `A private room can accommodate either up to 3 adults, or adults with children — not 3 adults plus a child. Please select at least ${roomsNeededForAdults} rooms for this party.`
    : null
  const displayedAvailability = availability?.filter((product) => {
    if (requestedRooms === 1) {
      const canUseOneFamilyRoom = searchAdults <= 3 && (searchAdults < 3 || searchChildren === 0) && searchChildren <= 2 && requestedGuestCount <= 4
      return canUseOneFamilyRoom
        ? product.sellableKind === 'room' || product.sellableKind === 'villa'
        : ['zen-villa', 'bougan-two-rooms', 'bougan-villa'].includes(product.productCode)
    }
    if (requestedRooms === 2) return ['zen-villa', 'bougan-two-rooms', 'bougan-villa'].includes(product.productCode)
    if (requestedRooms === 3) return product.productCode === 'bougan-villa'
    return product.productCode === 'entire-property'
  }).sort((a, b) => Number(b.productCode === prefill.preferredStay) - Number(a.productCode === prefill.preferredStay))

  useEffect(() => {
    if (stage === 'personalise' && hasBonfireMealBenefit && !wasEligibleForBonfireBenefit.current && bonfireSessions === 0) {
      setBonfireSessions(1)
    }
    wasEligibleForBonfireBenefit.current = stage === 'personalise' && hasBonfireMealBenefit
  }, [stage, hasBonfireMealBenefit, bonfireSessions])

  useEffect(() => {
    if (!legalDocument) return
    const closeOnEscape = (event: KeyboardEvent) => { if (event.key === 'Escape') setLegalDocument(null) }
    window.addEventListener('keydown', closeOnEscape)
    return () => window.removeEventListener('keydown', closeOnEscape)
  }, [legalDocument])

  useEffect(() => {
    if (stage !== 'personalise') return
    let active = true
    void getGuestExperiences()
      .then((catalogue) => { if (active) { setExperiences(catalogue); setExperienceError(null) } })
      .catch(() => { if (active) setExperienceError('Experiences are temporarily unavailable. You can still request your stay.') })
    return () => { active = false }
  }, [stage])

  function invalidateQuote() {
    setQuote(null)
    setQuoteError(null)
  }

  async function searchAvailability() {
    if (!canSearch) return
    setIsSearching(true)
    setSearchError(null)
    try {
      setAvailability(await getAvailableProducts(draft.checkIn, draft.checkOut, requestedGuestCount))
      invalidateQuote()
    } catch (error) {
      setAvailability(null)
      setSearchError(error instanceof Error ? error.message : 'We could not check availability. Please try again.')
    } finally {
      setIsSearching(false)
    }
  }

  useEffect(() => {
    if (!automaticSearchPending.current) return
    automaticSearchPending.current = false
    void searchAvailability()
  }, [])

  useEffect(() => {
    if (stage !== 'personalise' || !draft.selectedProductId) return
    const requestId = ++quoteRequestId.current
    setQuote(null)
    setQuoteError(null)
    const timer = window.setTimeout(async () => {
      setIsQuoting(true)
      try {
        const nextQuote = await getBookingQuote({
          productId: draft.selectedProductId!, checkIn: draft.checkIn, checkOut: draft.checkOut,
          adults: draft.party.adults, children7To12: draft.party.children7To12, children0To6: draft.party.children0To6, pets: draft.party.pets,
          mealPlan, bonfireSessions, lakeTripGuests, experienceSelections: selectedExperiences,
        })
        if (requestId === quoteRequestId.current) setQuote(nextQuote)
      } catch (error) {
        if (requestId === quoteRequestId.current) setQuoteError(error instanceof Error ? error.message : 'We could not update the price. Please review your selections.')
      } finally {
        if (requestId === quoteRequestId.current) setIsQuoting(false)
      }
    }, 300)
    return () => window.clearTimeout(timer)
  }, [stage, draft.selectedProductId, draft.checkIn, draft.checkOut, draft.party.adults, draft.party.children7To12, draft.party.children0To6, draft.party.pets, mealPlan, bonfireSessions, lakeTripGuests, experienceSelections])

  function setPartyBreakdown(category: 'adults' | 'children7To12' | 'children0To6', enteredValue: number) {
    const next = { ...draft.party }
    next[category] = enteredValue
    const nextTotal = next.adults + next.children7To12 + next.children0To6
    const invalidRoomFamily = isRoomStay && (next.adults > 3 || next.children7To12 > 1 || next.children0To6 > 2 || (next.adults >= 3 && next.children7To12 + next.children0To6 > 0))
    if (nextTotal > selectedStayCapacity || invalidRoomFamily) {
      setGuestError(isRoomStay ? 'A room permits up to three adults only. If a child is joining, please choose two adults or add another room.' : 'This stay accommodates up to ' + selectedStayCapacity + ' overnight guests.')
      return
    }
    setGuestError(null)
    invalidateQuote()
    setDraft({ ...draft, party: next })
  }

  function setSearchAdultsCount(adults: number) {
    setSearchAdults(adults)
    if (adults + searchChildren > 15) setSearchChildren(15 - adults)
    invalidateQuote()
    setAvailability(null)
  }

  async function submitReservationRequest() {
    if (!draft.selectedProductId) return
    if (!draft.checkIn || !draft.checkOut || draft.checkOut <= draft.checkIn) {
      setRequestError('Please choose a check-out date after your check-in date.')
      return
    }
    setIsSubmittingRequest(true)
    setRequestError(null)
    try {
      const result = await createReservationRequest({
        productId: draft.selectedProductId, checkIn: draft.checkIn, checkOut: draft.checkOut,
        adults: draft.party.adults, children7To12: draft.party.children7To12, children0To6: draft.party.children0To6, pets: draft.party.pets,
        mealPlan, bonfireSessions, lakeTripGuests, experienceSelections: selectedExperiences, guestName, guestEmail, guestPhone: guestPhoneE164, marketingOptIn,
      })
      setReservationRequest(result)
      setStage('request')
    } catch (error) {
      setRequestError(error instanceof Error ? error.message : 'We could not send your request. Please try again.')
    } finally { setIsSubmittingRequest(false) }
  }

  return (
    <main className="booking-shell">
      <header className="booking-header">
        <a className="booking-wordmark" href={publicSiteHref()} aria-label="Breathe Woods home">
          <picture>
            <source media="(max-width: 700px)" srcSet={bookingAsset('breathe-woods-wordmark-mobile-green.png')} />
            <img src={bookingAsset('breathe-woods-wordmark.png')} alt="Breathe Woods" />
          </picture>
        </a>
        <a className="header-note return-link" href={bookingReturnHref()}>← Back to Breathe Woods</a>
      </header>

      <section className="booking-card" aria-labelledby="booking-title">
        <ol className="progress" aria-label="Booking progress">
          {stages.map(({ id, label }, index) => (
            <li key={id} className={index <= stageIndex ? 'is-active' : ''} aria-current={id === stage ? 'step' : undefined}>
              <span>{index + 1}</span>{label}
            </li>
          ))}
        </ol>

        {stage === 'search' && (
          <section>
            <p className="eyebrow">Private stays in the woods of Raigad</p>
            <h1 id="booking-title">Find your escape</h1>
            <p className="intro">Choose dates and your total party. We’ll show only stays that are genuinely available.</p>
            <RateCalendar
              checkIn={draft.checkIn}
              checkOut={draft.checkOut}
              onChange={(checkIn, checkOut) => {
                invalidateQuote()
                setAvailability(null)
                setDraft({ ...draft, checkIn, checkOut })
              }}
            />
            <div className="form-grid search-guest-count">
              <NumericField label="Rooms" min={1} max={5} value={requestedRooms} onCommit={(value) => { setRequestedRooms(value); setAvailability(null) }} help="Choose how many bedrooms you need." />
              <NumericField label="Adults" min={1} max={15 - searchChildren} value={searchAdults} onCommit={setSearchAdultsCount} help="Ages 13 and above." />
              <NumericField label="Children" min={0} max={15 - searchAdults} value={searchChildren} onCommit={(value) => { setSearchChildren(value); invalidateQuote(); setAvailability(null) }} help="Ages 0–12; you’ll confirm ages next." />
            </div>
            {roomSearchGuidance && <p className="setup-note room-guidance">{roomSearchGuidance}</p>}
            <button className="primary" disabled={!canSearch || !isSupabaseConfigured || isSearching} onClick={searchAvailability}>{isSearching ? 'Checking availability…' : 'Check availability'}</button>
            {!isSupabaseConfigured && <p className="setup-note">Live availability will appear here once the UAT inventory connection is configured. This clean build intentionally contains no seeded stays or test calendar.</p>}
            {isSupabaseConfigured && <p className="setup-note">UAT connection is configured locally. Live availability activates after the booking schema and inventory configuration are applied.</p>}
            {searchError && <p className="form-error">{searchError}</p>}
            {displayedAvailability && (
              <section className="availability-results" aria-live="polite">
                <h2>{displayedAvailability.length ? 'Available stays' : 'No stays available for those dates'}</h2>
                {prefill.preferredStay && displayedAvailability.length > 0 && <p className="setup-note">Your selected villa is shown first when it is available.</p>}
                {displayedAvailability.length === 0 ? <p>Try other dates, a smaller party, or message the host for a special request.</p> : displayedAvailability.map((product) => (
                  <article className="stay-option" key={product.productId}>
                    <div><p className="option-kind">{stayKindLabel(product.sellableKind)}</p><h3>{product.productName}</h3><p>{stayCapacityLabel(product)}{product.sellableKind === 'room_bundle' && ' · 2 of 3 bedrooms; the remaining bedroom may be booked separately.'}</p></div>
                    <div className="option-price">{product.offerDiscountBps && <span className="stay-offer">{product.offerDiscountBps / 100}% offer applied</span>}<strong>From {formatInrFromPaise(product.fromAmountPaise)}</strong>{product.offerDiscountBps && <s>{formatInrFromPaise(product.standardFromAmountPaise)}</s>}<span>{product.sellableKind === 'room_bundle' ? 'per night · two bedrooms' : 'per night'}</span><button className="secondary" onClick={() => { invalidateQuote(); setDraft({ ...draft, selectedProductId: product.productId, party: { ...draft.party, adults: searchAdults, children7To12: Math.min(searchChildren, 1), children0To6: Math.max(searchChildren - 1, 0) } }); setMealPlan(product.sellableKind === 'entire_property' ? 'all_meals' : 'breakfast'); setStage('personalise') }}>Select</button></div>
                  </article>
                ))}
              </section>
            )}
          </section>
        )}

        {stage === 'personalise' && selectedProduct && (
          <section>
            <p className="eyebrow">{stayKindLabel(selectedProduct.sellableKind)}</p>
            <h1>{selectedProduct.productName}</h1>
            <p className="intro">Set the adult and child breakdown for this stay. You can adjust your party here; we’ll always keep it within the stay’s capacity. Children aged 0–6 are complimentary but count toward capacity.</p>
            <div className="form-grid">
              <NumericField label="Adults (13+)" min={1} max={maxAdults} value={draft.party.adults} onCommit={(value) => setPartyBreakdown('adults', value)} />
              <NumericField label="Children (7–12)" min={0} max={maxChildren7To12} value={draft.party.children7To12} onCommit={(value) => setPartyBreakdown('children7To12', value)} help="Charged only when above the included room allowance." />
              <NumericField label="Children (0–6)" min={0} max={maxChildren0To6} value={draft.party.children0To6} onCommit={(value) => setPartyBreakdown('children0To6', value)} help="Complimentary, but included in capacity." />
              <NumericField label="Pets" min={0} max={3} value={draft.party.pets} onCommit={(value) => { invalidateQuote(); setDraft({ ...draft, party: { ...draft.party, pets: value } }) }} />
              <label className="meal-plan-field">Meal plan<select value={mealPlan} onChange={(event) => { invalidateQuote(); setMealPlan(event.target.value as QuoteInput['mealPlan']) }} disabled={selectedProduct.sellableKind === 'entire_property'}>{selectedProduct.sellableKind !== 'entire_property' && <><option value="breakfast">Breakfast only</option><option value="breakfast_plus_one">Breakfast + 1 meal</option></>}<option value="all_meals">All meals</option></select></label>
            </div>
            <section className="enhance-stay" aria-labelledby="enhance-stay-title">
              <header><div><p className="eyebrow">Enhance your stay</p><h2 id="enhance-stay-title">Make the stay your own.</h2></div><p>Optional experiences are added to your estimate now and confirmed with the team.</p></header>
              <div className="experience-options">
                <article className={bonfireSessions > 0 ? 'is-selected' : ''}>
                  <div><h3>Bonfire + barbecue evening</h3><p>{hasBonfireMealBenefit ? 'One evening is included with your qualifying meal plan. Choose additional evenings if you would like them.' : 'A relaxed bonfire and barbecue evening for your party.'}</p><strong>{hasBonfireMealBenefit ? 'First evening included · additional evenings ₹500 per chargeable guest' : '₹500 per chargeable guest, per evening'}</strong><small>Children aged 0–6 join free.</small></div>
                  <div className="experience-selection"><NumericField label="Evenings" min={0} max={Math.max(0, (new Date(draft.checkOut).getTime() - new Date(draft.checkIn).getTime()) / 86400000)} value={bonfireSessions} onCommit={(value) => { invalidateQuote(); setBonfireSessions(value) }} /></div>
                </article>
                <article className={lakeTripGuests > 0 ? 'is-selected' : ''}>
                  <div><h3>Lake trip</h3><p>Join a local lake outing during your stay. Choose the chargeable guests joining the trip.</p><strong>₹500 covers up to 2 guests · ₹250 for each additional guest</strong><small>Children aged 0–6 join free.</small></div>
                  <div className="experience-selection"><NumericField label="Guests joining" min={0} max={activityGuestCount} value={lakeTripGuests} onCommit={(value) => { invalidateQuote(); setLakeTripGuests(value) }} /></div>
                </article>
                {experiences.map((experience) => {
                const quantity = experienceSelections[experience.id] ?? 0
                const selected = quantity > 0
                const quantityLabel = experience.pricingUnit === 'per_session' ? 'Sessions' : experience.maxQuantity > 1 ? 'Quantity' : 'Selected'
                return <article className={selected ? 'is-selected' : ''} key={experience.id}>
                  <div><h3>{experience.name}</h3>{experience.description && <p>{experience.description}</p>}<strong>{experiencePriceLabel(experience)}</strong>{experience.pricingUnit === 'per_guest' && <small>Children aged 0–6 join free.</small>}</div>
                  <div className="experience-selection">
                    {experience.maxQuantity === 1 ? <label className="check-row"><input type="checkbox" checked={selected} onChange={(event) => { invalidateQuote(); setExperienceSelections((current) => ({ ...current, [experience.id]: event.target.checked ? 1 : 0 })) }} />Add</label> : <NumericField label={quantityLabel} min={0} max={experience.maxQuantity} value={quantity} onCommit={(value) => { invalidateQuote(); setExperienceSelections((current) => ({ ...current, [experience.id]: value })) }} />}
                  </div>
                </article>
              })}</div>
            </section>
            <p className="setup-note">{partyTotal} of up to {selectedStayCapacity} guests. Price updates automatically as you make changes.</p>
            {guestError && <p className="form-error">{guestError}</p>}
            {experienceError && <p className="setup-note">{experienceError}</p>}
            {quoteError && <p className="form-error">{quoteError}</p>}
            {isQuoting && <p className="setup-note" aria-live="polite">Updating your price…</p>}
            {quote && <section className="quote-card" aria-live="polite">
              <h2>Your live stay estimate</h2>
              {quote.nightly_breakdown && <section className="nightly-rates" aria-label="Nightly rate breakdown">
                <p className="nightly-rates-heading">Your nightly price</p>
                {quote.nightly_breakdown.map((night) => <div className="nightly-rate" key={night.date}>
                  <span><strong>{formatStayDate(night.date)}</strong><small>{night.tier.replace(/_/g, ' ')}</small></span>
                  <strong>{formatInrFromPaise(night.total_paise)}</strong>
                </div>)}
              </section>}
              {quote.items.filter((item) => item.amount_paise !== 0 || item.label.endsWith('(included)')).map((item) => <div className={`quote-line${item.amount_paise < 0 ? ' quote-discount' : ''}`} key={item.label}><span>{item.label}{item.quantity ? ` × ${item.quantity}` : ''}</span><strong>{item.label.endsWith('(included)') ? 'Included' : formatInrFromPaise(item.amount_paise)}</strong></div>)}
              <div className="quote-total"><span>Total</span><strong>{formatInrFromPaise(quote.total_paise)}</strong></div>
              <p>{quote.notice}</p><button className="secondary" onClick={() => setStage('details')}>Continue</button>
            </section>}
            <button className="text-button" onClick={() => setStage('search')}>Change dates, stay or total guests</button>
          </section>
        )}
        {stage === 'details' && quote && (
          <section><p className="eyebrow">One last step</p><h1>Your details</h1><p className="intro">Send your reservation request and Breathe Woods will personally confirm availability and share payment details. A request is not a confirmed reservation.</p><div className="form-grid"><label>Full name<input autoComplete="name" value={guestName} onChange={(event) => setGuestName(event.target.value)} required /></label><label>Email<input type="email" autoComplete="email" value={guestEmail} onChange={(event) => setGuestEmail(event.target.value)} required /></label><label className="phone-field">Mobile / WhatsApp number<span className="phone-input"><select aria-label="Country calling code" value={countryCode} onChange={(event) => setCountryCode(event.target.value)}>{countryCodes.map((country) => <option value={country.value} key={country.value}>{country.label} ({country.value})</option>)}<option value="other">Other</option></select>{countryCode === 'other' && <input className="custom-country-code" type="tel" inputMode="tel" aria-label="Country calling code" placeholder="+ code" value={customCountryCode} onChange={(event) => setCustomCountryCode(event.target.value)} />}<input type="tel" inputMode="tel" autoComplete="tel-national" placeholder={countryCode === '+91' ? '10-digit mobile number' : 'Mobile number'} value={guestPhone} onChange={(event) => setGuestPhone(event.target.value)} required /></span><small>{countryCode === '+91' ? 'Enter your 10-digit mobile number; +91 is added automatically.' : 'We’ll use this number for stay updates.'}</small></label></div><label className="marketing-consent"><input type="checkbox" checked={marketingOptIn} onChange={(event) => setMarketingOptIn(event.target.checked)} /><span>Yes, I’d like occasional Breathe Woods offers and updates by email and WhatsApp.<small>Optional. Booking and stay updates are sent separately. You can opt out at any time.</small></span></label><p className="policy-link">See our <button type="button" className="inline-link" onClick={() => setLegalDocument('privacy')}>Privacy &amp; Messaging Notice</button> and <button type="button" className="inline-link" onClick={() => setLegalDocument('cancellation')}>Cancellation &amp; Refund Terms</button>.</p><section className="quote-card"><div className="quote-total"><span>Estimated total</span><strong>{formatInrFromPaise(quote.total_paise)}</strong></div><p>By sending this request, you acknowledge the cancellation and refund terms. Availability and payment are confirmed directly by Breathe Woods.</p></section><button className="primary" onClick={submitReservationRequest} disabled={isSubmittingRequest || !hasValidContactDetails}>{isSubmittingRequest ? 'Sending request…' : 'Send reservation request'}</button>{!hasValidContactDetails && <p className="setup-note">{phoneValidationMessage}</p>}{requestError && <p className="form-error">{requestError}</p>}<button className="text-button" onClick={() => setStage('personalise')}>Back to price</button></section>
        )}
        {stage === 'request' && reservationRequest && <section className="empty-state">
          <p className="eyebrow">Request received</p><h1>Thank you — we’ll be in touch shortly.</h1><p>Your reservation request has been sent to Breathe Woods. We’ll confirm the final availability and share payment details before your stay is confirmed.</p>
          <section className="quote-card"><div className="quote-total"><span>Estimated total</span><strong>{formatInrFromPaise(reservationRequest.total_paise)}</strong></div><p>Your Breathe Woods request reference is <strong>{reservationRequest.reference}</strong>.</p></section>
          <a className="whatsapp-button" target="_blank" rel="noreferrer" href={`https://wa.me/919967786444?text=${encodeURIComponent(whatsappMessage)}`}>
            <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M20 11.5a8 8 0 0 1-11.76 7.05L4 20l1.45-4.04A8 8 0 1 1 20 11.5Z" /><path d="M9.2 8.2c.25-.55.5-.55.72-.55h.36c.13 0 .3.05.38.28l.73 1.72c.08.2.04.4-.08.56l-.45.58c.38.75 1 1.37 1.75 1.75l.58-.45c.16-.12.36-.16.56-.08l1.72.73c.23.08.28.25.28.38v.36c0 .22 0 .47-.55.72-.36.16-.88.25-1.47.04-1.06-.37-2.25-1.18-3.25-2.18-1-1-1.8-2.19-2.18-3.25-.21-.59-.12-1.11.04-1.47Z" /></svg>
            <span>Message us on WhatsApp</span>
          </a>
        </section>}
      </section>

      <footer className="booking-footer">Need something specific? <a href="mailto:sanil.prashant@gmail.com">Message the host</a></footer>
      {legalDocument && <LegalOverlay document={legalDocument} onClose={() => setLegalDocument(null)} />}
    </main>
  )
}
