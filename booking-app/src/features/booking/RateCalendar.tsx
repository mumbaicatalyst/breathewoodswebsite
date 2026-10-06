import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { formatInrFromPaise } from './availability'

type DailyRate = { stay_date: string; couple_room_paise: number; tier_code: string; promotion_label: string | null; promotion_discount_bps: number | null; promotional_couple_room_paise: number | null }

type RateCalendarProps = {
  checkIn: string
  checkOut: string
  onChange: (checkIn: string, checkOut: string) => void
}

const shortWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']

function asIsoDate(date: Date) {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return year + '-' + month + '-' + day
}

function fromIsoDate(value: string) {
  const [year, month, day] = value.split('-').map(Number)
  return new Date(year, month - 1, day, 12)
}

function startOfMonth(date: Date) {
  return new Date(date.getFullYear(), date.getMonth(), 1, 12)
}

function addMonths(date: Date, amount: number) {
  return new Date(date.getFullYear(), date.getMonth() + amount, 1, 12)
}

function monthEnd(date: Date) {
  return new Date(date.getFullYear(), date.getMonth() + 1, 0, 12)
}

function dayOffsetMonday(date: Date) {
  return (date.getDay() + 6) % 7
}

function monthLabel(date: Date) {
  return new Intl.DateTimeFormat('en-IN', { month: 'long', year: 'numeric' }).format(date)
}

function dateIsWithin(value: string, start: string, end: string) {
  return Boolean(start && end && value > start && value < end)
}

export function RateCalendar({ checkIn, checkOut, onChange }: RateCalendarProps) {
  const today = useMemo(() => new Date(new Date().getFullYear(), new Date().getMonth(), new Date().getDate(), 12), [])
  const [visibleMonth, setVisibleMonth] = useState(() => startOfMonth(checkIn ? fromIsoDate(checkIn) : today))
  const [rates, setRates] = useState<Record<string, DailyRate>>({})
  const [hasPublishedRates, setHasPublishedRates] = useState(false)

  const secondMonth = addMonths(visibleMonth, 1)
  const earliestVisible = asIsoDate(visibleMonth)
  const latestVisible = asIsoDate(monthEnd(secondMonth))
  const canGoBack = visibleMonth > startOfMonth(today)
  const canGoForward = visibleMonth < startOfMonth(addMonths(today, 11))

  useEffect(() => {
    let active = true
    async function loadRates() {
      if (!supabase) return
      const { data, error } = await supabase.rpc('get_public_rate_calendar_with_offers', {
        p_start_date: earliestVisible,
        p_end_date: latestVisible,
      })
      if (!active || error) return
      const nextRates = Object.fromEntries((data as DailyRate[]).map((rate) => [rate.stay_date, rate]))
      setRates(nextRates)
      setHasPublishedRates(Object.keys(nextRates).length > 0)
    }
    loadRates()
    return () => { active = false }
  }, [earliestVisible, latestVisible])

  function chooseDay(value: string) {
    if (value < asIsoDate(today)) return
    if (!checkIn || checkOut) {
      onChange(value, '')
      return
    }
    if (value <= checkIn) {
      onChange(value, '')
      return
    }
    onChange(checkIn, value)
  }

  function renderMonth(month: Date) {
    const first = startOfMonth(month)
    const days = monthEnd(month).getDate()
    const cells = Array.from({ length: dayOffsetMonday(first) + days }, (_, index) => {
      if (index < dayOffsetMonday(first)) return null
      const date = new Date(month.getFullYear(), month.getMonth(), index - dayOffsetMonday(first) + 1, 12)
      return { date, value: asIsoDate(date) }
    })

    return <section className="rate-calendar-month" key={asIsoDate(first)} aria-label={monthLabel(month)}>
      <h3>{monthLabel(month)}</h3>
      <div className="rate-calendar-weekdays">{shortWeekdays.map((day) => <span key={day}>{day}</span>)}</div>
      <div className="rate-calendar-days">
        {cells.map((cell, index) => {
          if (!cell) return <span className="rate-calendar-empty" key={'empty-' + index} />
          const { date, value } = cell
          const rate = rates[value]
          const isPast = value < asIsoDate(today)
          const isStart = value === checkIn
          const isEnd = value === checkOut
          const isInRange = dateIsWithin(value, checkIn, checkOut)
          const unavailable = hasPublishedRates && !rate
          const classNames = [
            'rate-calendar-day',
            isPast ? 'is-past' : '',
            unavailable ? 'is-unpublished' : '',
            isStart ? 'is-start' : '',
            isEnd ? 'is-end' : '',
            isInRange ? 'is-in-range' : '',
          ].filter(Boolean).join(' ')
          const displayedRate = rate?.promotional_couple_room_paise ?? rate?.couple_room_paise
          return <button type="button" key={value} className={classNames} disabled={isPast || unavailable} onClick={() => chooseDay(value)}>
            <span>{date.getDate()}</span>
            {rate ? <><small>{formatInrFromPaise(displayedRate ?? null)}</small>{rate.promotion_discount_bps && <small className="rate-calendar-offer">{rate.promotion_discount_bps / 100}% off</small>}</> : <small>{hasPublishedRates ? '—' : 'Select'}</small>}
          </button>
        })}
      </div>
    </section>
  }

  return <section className="rate-calendar" aria-label="Choose your stay dates">
    <div className="rate-calendar-heading">
      <div>
        <h2>Choose your dates</h2>
        <p>{checkIn && checkOut ? new Intl.DateTimeFormat('en-IN', { day: 'numeric', month: 'short' }).format(fromIsoDate(checkIn)) + ' – ' + new Intl.DateTimeFormat('en-IN', { day: 'numeric', month: 'short' }).format(fromIsoDate(checkOut)) : checkIn ? 'Now choose your check-out date.' : 'Select check-in, then check-out.'}</p>
      </div>
      <div className="rate-calendar-controls">
        <button type="button" aria-label="Previous month" disabled={!canGoBack} onClick={() => setVisibleMonth(addMonths(visibleMonth, -1))}>‹</button>
        <button type="button" aria-label="Next month" disabled={!canGoForward} onClick={() => setVisibleMonth(addMonths(visibleMonth, 1))}>›</button>
      </div>
    </div>
    <div className="rate-calendar-months">{renderMonth(visibleMonth)}{renderMonth(secondMonth)}</div>
    <p className="rate-calendar-note">{hasPublishedRates ? 'Rates shown are the nightly breakfast-included rate for two guests in one room. Green offer labels show eligible couple offers; your exact stay price updates after you choose a stay and guest details.' : 'Select your dates. Published nightly rates will appear here once the daily rate calendar is activated.'}</p>
  </section>
}
