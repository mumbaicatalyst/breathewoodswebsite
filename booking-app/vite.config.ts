import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, '.', '')
  return {
    // Local development runs at the root. The live app is packaged beneath
    // breathewoods.com/book/, so asset URLs remain correct after deployment.
    base: env.VITE_APP_BASE_PATH || '/',
    plugins: [react()],
  }
})
