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
| `handler.go` | 65 | `healthHandler`: loads config, probes each service, returns aggregated JSON response |
| `config.go` | 34 | `HealthConfig`/`ServiceConfig` structs, JSON loading from `/etc/idekube/health.json` |
| `probe.go` | 79 | `Prober` interface with `HTTPProber`, `WebSocketProber`, and `FallbackProber` |

## Architecture

- **Prober interface pattern**: `Prober` defines a single method `Probe(svc ServiceConfig) bool`. Three implementations exist:
  - `HTTPProber` - HTTP GET to `http://127.0.0.1:<port><probePath>`, healthy if status 200-399
  - `WebSocketProber` - WebSocket handshake to `ws://127.0.0.1:<port><probePath>`, healthy if connection succeeds
  - `FallbackProber` - tries each child prober in order, returns true on first success
- **DefaultProber()** returns a `FallbackProber` that tries HTTP first, then WebSocket.
- **Probe timeout**: 1 second for both HTTP and WebSocket.
- **Health aggregation**: config designates a `main` service. If the main service is unhealthy, HTTP 502 is returned. If only secondary services are unhealthy, HTTP 200 with status `"degraded"`. If all healthy, HTTP 200 with status `"healthy"`.
- **Config is re-read on every request** (no caching).

## Response Codes

| HTTP Code | Status Field | Condition |
|-----------|-------------|-----------|
| 200 | `"healthy"` | All services healthy |
| 200 | `"degraded"` | Main service healthy, one or more secondary services unhealthy |
| 502 | `"degraded"` | Main service unhealthy |
| 500 | n/a | Config file read/parse error |
