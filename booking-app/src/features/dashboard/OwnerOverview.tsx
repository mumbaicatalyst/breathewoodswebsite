import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { createOwnerInventoryBlock, getOwnerBlockTargets, getOwnerCalendar, getOwnerOpenReservationRequests, removeOwnerInventoryBlock, type BlockTarget, type CalendarRow, type ReservationRequestRow } from './calendar'

type DailyRate = { stay_date: string; couple_room_paise: number; tier_code: string }

type OwnerOverviewProps = {
  onOpenReservations: (start: string, end: string, reservationId?: string) => void
}

const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']

function localIso(date: Date) {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function fromIso(value: string) {
  const [year, month, day] = value.split('-').map(Number)
  return new Date(year, month - 1, day, 12)
}

function addMonths(date: Date, amount: number) { return new Date(date.getFullYear(), date.getMonth() + amount, 1, 12) }
function monthLabel(date: Date) { return new Intl.DateTimeFormat('en-IN', { month: 'long', year: 'numeric' }).format(date) }
function dateLabel(value: string) { return new Intl.DateTimeFormat('en-IN', { weekday: 'short', day: 'numeric', month: 'short' }).format(fromIso(value)) }
function isHighDemand(tier: string | undefined) { return Boolean(tier && /(peak|premium|ultra|holiday)/i.test(tier)) }
function isPaymentHold(status: string | null) { return status === 'pending_payment' || status === 'awaiting_manual_payment' }

function compactDayRanges(dates: string[]) {
  const days = dates.map((date) => fromIso(date).getDate()).sort((a, b) => a - b)
  const groups: number[][] = []
  for (const day of days) {
    const current = groups.at(-1)
    if (current && current.at(-1) === day - 1) current.push(day)
    else groups.push([day])
  }
  return groups.map((group) => group.length === 1 ? String(group[0]) : `${group[0]}–${group.at(-1)}`).join(', ')
}

function uniqueBookings(rows: CalendarRow[]) {
  const seen = new Set<string>()
  return rows.filter((row) => {
    if (!row.reservation_id || seen.has(row.reservation_id)) return false
    seen.add(row.reservation_id)
    return true
  })
}

export function OwnerOverview({ onOpenReservations }: OwnerOverviewProps) {
  const [visibleMonth, setVisibleMonth] = useState(() => new Date(new Date().getFullYear(), new Date().getMonth(), 1, 12))
  const [selectedDay, setSelectedDay] = useState(localIso(new Date()))
  const [rows, setRows] = useState<CalendarRow[]>([])
  const [rates, setRates] = useState<Record<string, DailyRate>>({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [blockTargets, setBlockTargets] = useState<BlockTarget[]>([])
  const [reservationRequests, setReservationRequests] = useState<ReservationRequestRow[]>([])
  const [blockTargetId, setBlockTargetId] = useState('')
  const [blockCheckIn, setBlockCheckIn] = useState(localIso(new Date()))
  const [blockCheckOut, setBlockCheckOut] = useState(localIso(new Date(Date.now() + 86400000)))
  const [blockReason, setBlockReason] = useState('Owner use')
  const [showBlockForm, setShowBlockForm] = useState(false)
  const [isSavingBlock, setIsSavingBlock] = useState(false)

  const start = localIso(visibleMonth)
  const end = localIso(addMonths(visibleMonth, 1))
  const today = localIso(new Date())

  async function load() {
    if (!supabase) return
    setLoading(true)
    setError(null)
    try {
      const [calendarResult, rateResult, targetsResult, requestsResult] = await Promise.all([
        getOwnerCalendar(start, end),
        supabase.rpc('get_public_daily_rate_calendar', { p_start_date: start, p_end_date: localIso(new Date(visibleMonth.getFullYear(), visibleMonth.getMonth() + 1, 0, 12)) }),
        getOwnerBlockTargets(),
        getOwnerOpenReservationRequests(),
      ])
      if (rateResult.error) throw new Error(rateResult.error.message)
      setRows(calendarResult)
      setRates(Object.fromEntries(((rateResult.data ?? []) as DailyRate[]).map((rate) => [rate.stay_date, rate])))
      setBlockTargets(targetsResult)
      setReservationRequests(requestsResult.filter((request) => ['requested', 'in_conversation', 'alternative_offered'].includes(request.status)))
      setBlockTargetId((current) => current || targetsResult[0]?.target_id || '')
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Unable to load the owner overview.')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { void load() }, [start, end])
  useEffect(() => {
    const interval = window.setInterval(() => void load(), 60_000)
    return () => window.clearInterval(interval)
  }, [start, end])

  const dayBookings = useMemo(() => uniqueBookings(rows.filter((row) => Boolean(row.reservation_id) && Boolean(row.check_in) && Boolean(row.check_out) && row.check_in! <= selectedDay && row.check_out! > selectedDay)), [rows, selectedDay])
  const currentMonthBookings = useMemo(() => uniqueBookings(rows.filter((row) => Boolean(row.reservation_id))), [rows])
  const activeHolds = currentMonthBookings.filter((row) => row.reservation_status === 'awaiting_manual_payment' || row.reservation_status === 'pending_payment').length
  const confirmedBookings = currentMonthBookings.filter((row) => row.reservation_status === 'confirmed').length
  const arrivalsToday = uniqueBookings(rows.filter((row) => row.check_in === today)).length
  const departuresToday = uniqueBookings(rows.filter((row) => row.check_out === today)).length
  const upcoming = currentMonthBookings
    .filter((row) => row.check_out! > today && row.reservation_status !== 'cancelled')
    .sort((a, b) => a.check_in!.localeCompare(b.check_in!))
    .slice(0, 6)

  const first = new Date(visibleMonth.getFullYear(), visibleMonth.getMonth(), 1, 12)
  const dayCount = new Date(visibleMonth.getFullYear(), visibleMonth.getMonth() + 1, 0, 12).getDate()
  const leadingEmpty = (first.getDay() + 6) % 7
  const calendarCells = Array.from({ length: leadingEmpty + dayCount }, (_, index) => index < leadingEmpty ? null : localIso(new Date(visibleMonth.getFullYear(), visibleMonth.getMonth(), index - leadingEmpty + 1, 12)))
  const highDemandDays = Object.values(rates).filter((rate) => isHighDemand(rate.tier_code)).map((rate) => rate.stay_date)
  const dayBlocks = useMemo(() => {
    const seen = new Set<string>()
    return rows.filter((row) => row.allocation_state === 'block' && row.block_id && row.check_in && row.check_out && row.check_in <= selectedDay && row.check_out > selectedDay && !seen.has(row.block_id) && Boolean(seen.add(row.block_id)))
  }, [rows, selectedDay])

  function daySummary(date: string) {
    const active = rows.filter((row) => row.check_in && row.check_out && row.check_in <= date && row.check_out > date && row.allocation_state)
    const zen = new Set(active.filter((row) => row.resource_kind === 'room' && row.resource_name.startsWith('Zen')).map((row) => row.resource_id)).size
    const bougan = new Set(active.filter((row) => row.resource_kind === 'room' && row.resource_name.startsWith("Bougan'villa")).map((row) => row.resource_id)).size
    const reservations = uniqueBookings(active).length
    const holds = uniqueBookings(active.filter((row) => isPaymentHold(row.reservation_status))).length
    const blocks = active.filter((row) => row.allocation_state === 'block').length
    return { zen, bougan, reservations, holds, blocks, full: active.some((row) => row.resource_kind === 'property') }
  }

  function selectDay(date: string) {
    setSelectedDay(date)
    setBlockCheckIn(date)
    setBlockCheckOut(localIso(new Date(fromIso(date).getTime() + 86400000)))
  }

  async function saveBlock() {
    const target = blockTargets.find((item) => item.target_id === blockTargetId)
    if (!target) return
    setIsSavingBlock(true); setError(null)
    try {
      await createOwnerInventoryBlock(target.target_id, target.scope, blockCheckIn, blockCheckOut, blockReason)
      setShowBlockForm(false)
      await load()
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Unable to create this block.') }
    finally { setIsSavingBlock(false) }
  }

  async function removeBlock(blockId: string) {
    if (!window.confirm('Remove this availability block? Those dates will become available again.')) return
    setIsSavingBlock(true); setError(null)
    try { await removeOwnerInventoryBlock(blockId); await load() }
    catch (caught) { setError(caught instanceof Error ? caught.message : 'Unable to remove this block.') }
    finally { setIsSavingBlock(false) }
  }

  return <section className="owner-overview">
    <section className="owner-overview-heading"><div><p className="eyebrow">Daily operations</p><h2>See the property at a glance.</h2><p>Confirmed bookings, temporary payment holds and availability update automatically every minute.</p></div><button className="secondary" onClick={() => void load()} disabled={loading}>{loading ? 'Updating…' : 'Refresh now'}</button></section>
    {error && <p className="form-error">{error}</p>}
    <section className="owner-metrics" aria-label="Booking summary"><article><span>Arrivals today</span><strong>{arrivalsToday}</strong></article><article><span>Departures today</span><strong>{departuresToday}</strong></article><article><span>Confirmed this month</span><strong>{confirmedBookings}</strong></article><article><span>Live payment holds</span><strong>{activeHolds}</strong></article></section>
    {reservationRequests.length > 0 && <section className="owner-attention"><header><div><p className="eyebrow">Needs attention</p><h2>{reservationRequests.length} reservation {reservationRequests.length === 1 ? 'request' : 'requests'} awaiting a response</h2></div><button className="text-button" onClick={() => onOpenReservations(today, localIso(new Date(fromIso(today).getTime() + 31 * 86400000)))}>Review requests</button></header><div>{reservationRequests.slice(0, 3).map((request) => <button key={request.reservation_id} onClick={() => onOpenReservations(request.check_in, request.check_out, request.reservation_id)}><span><strong>{request.guest_name ?? 'Guest request'} · {request.product_name ?? 'Stay'}</strong><small>{request.check_in} → {request.check_out} · {request.reference}</small></span><b>{request.status.replaceAll('_', ' ')}</b></button>)}</div></section>}
    <section className="owner-overview-grid">
      <section className="owner-month-calendar">
        <header><div><p className="eyebrow">Planning calendar</p><h2>{monthLabel(visibleMonth)}</h2></div><div className="owner-month-controls"><button className="secondary" aria-label="Previous month" onClick={() => setVisibleMonth(addMonths(visibleMonth, -1))}>‹</button><button className="secondary" aria-label="Next month" onClick={() => setVisibleMonth(addMonths(visibleMonth, 1))}>›</button></div></header>
        <div className="owner-calendar-weekdays">{weekdays.map((day) => <span key={day}>{day}</span>)}</div>
        <div className="owner-calendar-days">{calendarCells.map((date, index) => {
          if (!date) return <span className="owner-calendar-empty" key={`empty-${index}`} />
          const summary = daySummary(date)
          const rate = rates[date]
          const selected = date === selectedDay
          const hasActivity = summary.reservations > 0 || summary.blocks > 0
          return <button type="button" key={date} className={`owner-calendar-day ${selected ? 'is-selected' : ''} ${hasActivity ? 'has-activity' : ''}`} onClick={() => selectDay(date)}>
            <strong>{fromIso(date).getDate()}</strong>
            {summary.full ? <small className="full-day">Full property</small> : <small>{summary.zen || summary.bougan ? `Z ${summary.zen}/2 · B ${summary.bougan}/3` : 'Available'}</small>}
            {summary.holds > 0 && <i title="Payment hold">H</i>}
            {summary.blocks > 0 && <i title="Owner or maintenance block">B</i>}
          </button>
        })}</div>
        <footer><span><b>H</b> payment hold</span><span><b>B</b> owner/maintenance block</span>{highDemandDays.length > 0 && <span className="demand-summary"><b>High-demand dates:</b> {compactDayRanges(highDemandDays)}</span>}</footer>
      </section>
      <aside className="owner-day-drawer"><p className="eyebrow">Selected day</p><h2>{dateLabel(selectedDay)}</h2>{isHighDemand(rates[selectedDay]?.tier_code) && <p className="demand-note">High-demand date: consider keeping this available for guests unless there is a clear reason to block it.</p>}{dayBookings.length === 0 ? <p>No guest bookings on this date. Review blocks and room availability before allocating it.</p> : <div className="owner-day-bookings">{dayBookings.map((booking) => <button key={booking.reservation_id} onClick={() => onOpenReservations(booking.check_in!, booking.check_out!)}><span><strong>{booking.reservation_reference}</strong><small>{booking.guest_name ?? 'Guest'} · {booking.check_in} → {booking.check_out}</small></span><b className={isPaymentHold(booking.reservation_status) ? 'hold' : ''}>{isPaymentHold(booking.reservation_status) ? 'Payment hold' : 'Confirmed'}</b></button>)}</div>}{dayBlocks.length > 0 && <div className="owner-day-blocks">{dayBlocks.map((block) => <div key={block.block_id}><span><strong>Blocked</strong><small>{block.block_reason ?? 'Owner or maintenance block'} · {block.check_in} → {block.check_out}</small></span><button className="text-button" onClick={() => void removeBlock(block.block_id!)} disabled={isSavingBlock}>Remove</button></div>)}</div>}<button className="secondary drawer-action" onClick={() => setShowBlockForm((open) => !open)}>{showBlockForm ? 'Close block form' : 'Block availability'}</button>{showBlockForm && <section className="block-form"><label>What should be blocked?<select value={blockTargetId} onChange={(event) => setBlockTargetId(event.target.value)}>{blockTargets.map((target) => <option key={target.target_id} value={target.target_id}>{target.label}</option>)}</select></label><div><label>From<input type="date" value={blockCheckIn} onChange={(event) => setBlockCheckIn(event.target.value)} /></label><label>To<input type="date" value={blockCheckOut} onChange={(event) => setBlockCheckOut(event.target.value)} /></label></div><label>Reason<input value={blockReason} onChange={(event) => setBlockReason(event.target.value)} placeholder="Owner use, maintenance…" /></label><button className="primary" onClick={() => void saveBlock()} disabled={isSavingBlock || !blockTargetId || !blockReason.trim()}>{isSavingBlock ? 'Saving…' : 'Save availability block'}</button></section>}<button className="text-button drawer-operations" onClick={() => onOpenReservations(selectedDay, localIso(new Date(fromIso(selectedDay).getTime() + 86400000)))}>Open day operations</button></aside>
    </section>
    <section className="owner-upcoming"><header><div><p className="eyebrow">Upcoming stays</p><h2>Next arrivals and bookings</h2></div><button className="text-button" onClick={() => onOpenReservations(start, end)}>View all reservations</button></header>{upcoming.length === 0 ? <p>No upcoming stays in this month yet.</p> : <div className="owner-upcoming-list">{upcoming.map((booking) => <button key={booking.reservation_id} className="owner-upcoming-row" onClick={() => onOpenReservations(booking.check_in!, booking.check_out!)}><span><strong>{booking.guest_name ?? booking.reservation_reference}</strong><small>{booking.check_in} → {booking.check_out} · {booking.reservation_reference}</small></span><b className={isPaymentHold(booking.reservation_status) ? 'hold' : ''}>{isPaymentHold(booking.reservation_status) ? 'Payment hold' : 'Confirmed'}</b></button>)}</div>}</section>
  </section>
}
