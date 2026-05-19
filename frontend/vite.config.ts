import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { resolve } from 'path'
import type { Plugin } from 'vite'

// Dev-only /health mock. Enabled by default so `npm run dev` shows the
// SSH/coder/jupyter cards without a backend. Opt out to exercise the real
// probe path (failure → "no services") with:
//   MOCK_HEALTH=0 npm run dev      (or "off" / "false")
function mockHealth(): Plugin | false {
  const flag = (process.env.MOCK_HEALTH ?? '').toLowerCase()
  if (flag === '0' || flag === 'off' || flag === 'false') return false
  return {
    name: 'mock-health',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use('/health', (_req, res) => {
        res.setHeader('content-type', 'application/json')
        res.end(
          JSON.stringify({
            status: 'ok',
            branch: 'dev',
            entry: '/',
            services: {
              ssh: { port: 22, path: '/ssh', healthy: true },
              coder: { port: 8080, path: '/coder', healthy: true },
              jupyter: { port: 8888, path: '/jupyter', healthy: true },
            },
          }),
        )
      })
    },
  }
}

export default defineConfig({
  plugins: [vue(), mockHealth()].filter(Boolean) as Plugin[],
  build: {
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
        auth: resolve(__dirname, '401.html'),
      },
    },
    outDir: 'dist',
    emptyOutDir: true,
  },
})
