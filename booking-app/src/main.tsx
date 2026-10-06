import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './styles.css'
import './calendar-overrides.css'
import { App } from './App'

const analyticsScript = document.createElement('script')
analyticsScript.src = '/analytics.js'
analyticsScript.defer = true
document.head.append(analyticsScript)

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
