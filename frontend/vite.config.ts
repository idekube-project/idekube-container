import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { resolve } from 'path'
import type { Plugin } from 'vite'

function mockHealth(): Plugin {
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
  plugins: [vue(), mockHealth()],
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
