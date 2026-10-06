import { BookingApp } from './features/booking/BookingApp'
import { OwnerDashboard } from './features/dashboard/OwnerDashboard'
import { PrivacyMessagingNotice } from './features/legal/PrivacyMessagingNotice'
import { CancellationRefundTerms } from './features/legal/CancellationRefundTerms'

const appBasePath = import.meta.env.BASE_URL.replace(/\/$/, '')
const ownerPath = `${appBasePath}/owner`.replace(/^\/\//, '/')
const privacyPath = `${appBasePath}/privacy-and-messaging`.replace(/^\/\//, '/')
const cancellationPath = `${appBasePath}/cancellation-and-refunds`.replace(/^\/\//, '/')

export function App() {
  const isOwnerRoute = window.location.pathname === ownerPath || window.location.pathname.startsWith(ownerPath + '/') || /(?:^|\/)owner(?:\/|$)/.test(window.location.pathname)
  const isPrivacyRoute = window.location.pathname === privacyPath || window.location.pathname.startsWith(privacyPath + '/')
  const isCancellationRoute = window.location.pathname === cancellationPath || window.location.pathname.startsWith(cancellationPath + '/')
  if (isPrivacyRoute) return <PrivacyMessagingNotice />
  if (isCancellationRoute) return <CancellationRefundTerms />
  return isOwnerRoute ? <OwnerDashboard /> : <BookingApp />
}
