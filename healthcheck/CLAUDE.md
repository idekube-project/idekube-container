# CLAUDE.md

## Purpose

idekube-container-healthcheck is a lightweight Go microservice that aggregates the health status of backend services in an IDEKube container environment. It probes configured services and exposes a consolidated HTTP health endpoint on port 9999.

## Tech Stack

- Go 1.25
- Gin v1.10.0 (HTTP framework)
- Gorilla WebSocket v1.5.3 (WebSocket probing)
- Module: `github.com/davidliyutong/idekube-container/tools/idekube-healthcheck`

## Key Commands

```bash
# Build
go build -o idekube-healthcheck .

# Run (requires /etc/idekube/health.json)
./idekube-healthcheck
```

## File Overview

| File | Lines | Purpose |
|------|-------|---------|
| `main.go` | 24 | Gin server setup, listens on `:9999` in release mode |
| `handler.go` | ~80 | `healthHandler`: loads config, probes all services concurrently, returns aggregated JSON response |
| `config.go` | 36 | `HealthConfig`/`ServiceConfig` structs, JSON loading from `/etc/idekube/health.json` |
| `probe.go` | ~95 | `Prober` interface with `HTTPProber`, `WebSocketProber`, `TCPProber`, `FallbackProber`, and `ProberForMethod` selector |

## Architecture

- **Prober interface pattern**: `Prober` defines a single method `Probe(svc ServiceConfig) bool`. Four implementations exist:
  - `HTTPProber` - HTTP GET to `http://127.0.0.1:<port><probePath>`, healthy if status 200-399
  - `WebSocketProber` - WebSocket handshake to `ws://127.0.0.1:<port><probePath>`, healthy if connection succeeds
  - `TCPProber` - TCP dial to `127.0.0.1:<port>`, healthy if connection succeeds (used for SSH)
  - `FallbackProber` - tries each child prober in order, returns true on first success
- **ProberForMethod(method)** selects the right prober based on `probeMethod` in health.json: `"http"`, `"ws"`/`"websocket"`, `"tcp"`, or empty (FallbackProber for backward compat).
- **Concurrent probing**: all services are probed in parallel via goroutines, so total probe time is bounded by the slowest single service, not the sum.
- **Probe timeout**: 1 second per probe.
- **Health aggregation**: config designates a `main` service. If the main service is unhealthy, HTTP 502 is returned. If only secondary services are unhealthy, HTTP 200 with status `"degraded"`. If all healthy, HTTP 200 with status `"healthy"`.
- **Config is re-read on every request** (no caching).

## Response Codes

| HTTP Code | Status Field | Condition |
|-----------|-------------|-----------|
| 200 | `"healthy"` | All services healthy |
| 200 | `"degraded"` | Main service healthy, one or more secondary services unhealthy |
| 502 | `"degraded"` | Main service unhealthy |
| 500 | n/a | Config file read/parse error |
