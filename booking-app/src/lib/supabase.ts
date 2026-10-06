import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { appConfig, isSupabaseConfigured } from './config'

// This client uses only the browser-safe publishable key. Booking writes,
// price calculation, payment creation and owner actions remain server-side.
export const supabase: SupabaseClient | null = isSupabaseConfigured
  ? createClient(appConfig.supabaseUrl, appConfig.supabaseAnonKey, {
      auth: { persistSession: true, autoRefreshToken: true },
    })
  : null
