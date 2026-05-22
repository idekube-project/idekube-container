import { ref, computed, onScopeDispose } from 'vue'
import { serviceConfigs } from '../config/services'
import { landingTranslations } from '../config/translations'
import { useLanguage } from './useLanguage'

const HEALTH_TIMEOUT_MS = 5000
const SERVICE_PROBE_TIMEOUT_MS = 2000
const REFRESH_INTERVAL_MS = 10_000

export interface DetectedService {
  path: string
  icon: string
  name: string
  description: string
  healthy: boolean
  action?: string
}

interface HealthService {
  port: number
  path: string
  healthy: boolean
}

interface HealthResponse {
  status: string
  branch: string
  entry: string
  services: Record<string, HealthService>
}

export function useServiceDetection() {
  const { lang } = useLanguage()
  // Raw detection results are language-independent; translations are derived below.
  const detectedServices = ref<{ path: string; icon: string; healthy: boolean }[]>([])
  const loading = ref(true)
  let refreshTimer: ReturnType<typeof setTimeout> | null = null

  // Derive translated service list reactively — no re-probe on lang change
  const services = computed<DetectedService[]>(() =>
    detectedServices.value.map((d) => {
      const t = landingTranslations[lang.value]?.services[d.path]
      return {
        path: d.path,
        icon: d.icon,
        name: t?.name ?? d.path,
        description: t?.description ?? '',
        healthy: d.healthy,
        action: t?.action,
      }
    }),
  )

  function iconForPath(path: string): string {
    return serviceConfigs.find((c) => c.path === path)?.icon ?? '🔧'
  }

  function pathKey(path: string): string {
    return path.replace(/^\/+/, '').replace(/\/+$/, '')
  }

  async function detectViaHealth(): Promise<boolean> {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), HEALTH_TIMEOUT_MS)
    try {
      const resp = await fetch('/health', { signal: controller.signal, cache: 'no-store' })
      clearTimeout(timer)
      const data: HealthResponse = await resp.json()
      if (!data.services) return false
      const detected: { path: string; icon: string; healthy: boolean }[] = []
      for (const [, svc] of Object.entries(data.services)) {
        // Use the service path without leading/trailing slash as the translation key.
        const key = pathKey(svc.path)
        detected.push({ path: key, icon: iconForPath(key), healthy: svc.healthy })
      }
      detectedServices.value = detected
      return true
    } catch {
      clearTimeout(timer)
      return false
    }
  }

  async function probeServiceHttp(path: string): Promise<boolean> {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), SERVICE_PROBE_TIMEOUT_MS)
    try {
      const response = await fetch(`/${path}/`, {
        method: 'GET',
        signal: controller.signal,
      })
      clearTimeout(timer)
      const finalUrl = new URL(response.url)
      if (!response.redirected || finalUrl.pathname.startsWith(`/${path}`)) {
        if (response.ok || response.status === 401 || response.status === 403) {
          return true
        }
      }
      return false
    } catch {
      clearTimeout(timer)
      return false
    }
  }

  async function probeServiceWs(path: string): Promise<boolean> {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const host = window.location.host
    return new Promise<boolean>((resolve) => {
      const socket = new WebSocket(`${protocol}//${host}/${path}/`)
      const timer = setTimeout(() => {
        socket.close()
        resolve(false)
      }, SERVICE_PROBE_TIMEOUT_MS)
      socket.onopen = () => {
        clearTimeout(timer)
        socket.close()
        resolve(true)
      }
      socket.onerror = () => {
        clearTimeout(timer)
        resolve(false)
      }
    })
  }

  async function detectViaProbes(): Promise<void> {
    const results = await Promise.allSettled(
      serviceConfigs.map(async (config) => {
        const available =
          config.detectionMethod === 'websocket'
            ? await probeServiceWs(config.path)
            : await probeServiceHttp(config.path)
        return available ? { path: config.path, icon: config.icon, healthy: true } : null
      }),
    )
    detectedServices.value = results
      .filter(
        (r): r is PromiseFulfilledResult<{ path: string; icon: string; healthy: boolean }> =>
          r.status === 'fulfilled' && r.value !== null,
      )
      .map((r) => r.value)
  }

  function scheduleRefresh() {
    if (refreshTimer !== null) return
    refreshTimer = setTimeout(() => {
      refreshTimer = null
      void detectServices()
    }, REFRESH_INTERVAL_MS)
  }

  function stopRefresh() {
    if (refreshTimer === null) return
    clearTimeout(refreshTimer)
    refreshTimer = null
  }

  async function detectServices() {
    // Only the initial `ref(true)` state should ever render the loading view —
    // subsequent re-probes update `detectedServices` in place so cards don't
    // unmount/remount on every refresh (which caused a visible flicker).
    const healthAvailable = await detectViaHealth()
    if (!healthAvailable) {
      await detectViaProbes()
    }
    loading.value = false

    if (
      healthAvailable &&
      detectedServices.value.length > 0 &&
      detectedServices.value.every((s) => s.healthy)
    ) {
      stopRefresh()
    } else {
      scheduleRefresh()
    }
  }

  detectServices()

  onScopeDispose(stopRefresh)

  return { services, loading }
}
