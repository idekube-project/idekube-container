import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { resolve } from 'path'
import type { Plugin } from 'vite'

// Dev-only middleware. Two jobs:
//   1. Block vite's SPA fallback (which serves index.html with status 200) on
//      the known service-probe paths, so `useServiceDetection`'s HTTP probes
//      don't false-positive every service into existence.
//   2. Either mock /health with a fixed service list (default), or 503 it so
//      the "no services" empty state can be exercised. Toggle the mock with:
//        MOCK_HEALTH=0 npm run dev    (or "off" / "false")
const PROBE_PATHS = ['vnc', 'coder', 'jupyter', 'ssh', 'agent', 'terminal']

function devHealth(): Plugin {
  const flag = (process.env.MOCK_HEALTH ?? '').toLowerCase()
  const mockEnabled = flag !== '0' && flag !== 'off' && flag !== 'false'
  return {
    name: 'dev-health',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use('/health', (_req, res) => {
        if (!mockEnabled) {
          res.statusCode = 503
          res.end('mock disabled')
          return
        }
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
      // Block SPA-fallback false-positives on the service-probe paths. These
      // would otherwise return 200 + index.html and trick the HTTP probe.
      for (const p of PROBE_PATHS) {
        server.middlewares.use(`/${p}`, (_req, res) => {
          res.statusCode = 503
          res.end('no dev backend')
        })
      }
    },
  }
}

export default defineConfig({
  plugins: [vue(), devHealth()],
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
