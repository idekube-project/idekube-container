# idekube-container-healthcheck

A lightweight Go microservice that aggregates the health status of backend services in an IDEKube container environment. It probes multiple configured services via HTTP and WebSocket and exposes a single consolidated health endpoint, designed for use as a Kubernetes liveness or readiness probe target.

## Features

- Consolidated health endpoint for multiple backend services
- HTTP and WebSocket probe support with automatic fallback
- Configurable per-service probe paths and ports
- Distinguishes between main and secondary service failures
- 1-second probe timeout to keep responses fast
- Minimal footprint with no background goroutines -- probes run on demand per request

## Prerequisites

- Go 1.25 or later
- A configuration file at `/etc/idekube/health.json`

## Quick Start

### Build

```bash
go build -o idekube-healthcheck .
```

### Run

```bash
# Ensure /etc/idekube/health.json exists (see Configuration below)
./idekube-healthcheck
```

The server starts on port **9999** in Gin release mode.

## Configuration

The service reads its configuration from `/etc/idekube/health.json` on every incoming request.

### Format

```json
{
  "branch": "main",
  "entry": "https://example.com/workspace",
  "main": "code-server",
  "services": {
    "code-server": {
      "port": 8080,
      "path": "/",
      "probePath": "/healthz"
    },
    "terminal": {
      "port": 8081,
      "path": "/terminal",
      "probePath": "/"
    }
  }
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `branch` | string | Branch identifier, returned in health response |
| `entry` | string | Entry URL, returned in health response |
| `main` | string | Name of the main service (key in `services`). If this service is unhealthy, the endpoint returns HTTP 502 |
| `services` | object | Map of service name to service configuration |

### Service Configuration

| Field | Type | Description |
|-------|------|-------------|
| `port` | int | Port the service listens on (probed at `127.0.0.1:<port>`) |
| `path` | string | Informational path included in the response |
| `probePath` | string | (Optional) Path used for health probing. Defaults to `"/"` if omitted |

## API Reference

### `GET /`

Returns the aggregated health status of all configured services.

#### Response Format

```json
{
  "status": "healthy",
  "branch": "main",
  "entry": "https://example.com/workspace",
  "services": {
    "code-server": {
      "port": 8080,
      "path": "/",
      "healthy": true
    },
    "terminal": {
      "port": 8081,
      "path": "/terminal",
      "healthy": true
    }
  }
}
```

#### Status Codes

| HTTP Code | `status` Field | Condition |
|-----------|---------------|-----------|
| 200 | `"healthy"` | All services are healthy |
| 200 | `"degraded"` | Main service is healthy but one or more secondary services are unhealthy |
| 502 | `"degraded"` | The main service is unhealthy |
| 500 | n/a | Configuration file could not be read or parsed |

## Architecture

### Prober Pattern

The probing system uses a `Prober` interface with a single method:

```go
type Prober interface {
    Probe(svc ServiceConfig) bool
}
```

Three implementations are provided:

- **HTTPProber** -- Sends an HTTP GET request to `http://127.0.0.1:<port><probePath>`. The service is considered healthy if the response status code is in the range 200-399.
- **WebSocketProber** -- Attempts a WebSocket handshake at `ws://127.0.0.1:<port><probePath>`. The service is considered healthy if the connection succeeds.
- **FallbackProber** -- Wraps multiple probers and tries each in order, returning healthy on the first success.

### Fallback Strategy

The default prober (`DefaultProber()`) is a `FallbackProber` that:

1. Tries an HTTP GET first
2. If HTTP fails, attempts a WebSocket handshake
3. If both fail, the service is marked unhealthy

Both probes use a **1-second timeout**.

### Health Aggregation

On each request the handler:

1. Reads the configuration from disk
2. Probes every configured service using the default prober
3. If all services are healthy, returns status `"healthy"` with HTTP 200
4. If only secondary services are unhealthy, returns status `"degraded"` with HTTP 200
5. If the main service (specified by the `main` config field) is unhealthy, returns status `"degraded"` with HTTP 502

## Project Structure

```
idekube-container-healthcheck/
  main.go       -- Gin server setup, listens on :9999
  handler.go    -- Health endpoint handler with aggregation logic
  config.go     -- Configuration structs and JSON loader
  probe.go      -- Prober interface and HTTP/WebSocket/Fallback implementations
  go.mod        -- Go module definition
  go.sum        -- Dependency checksums
```

## Deployment

This service is designed to run inside an IDEKube container alongside the services it monitors. A typical deployment pattern:

- Mount the configuration file at `/etc/idekube/health.json` via a ConfigMap or init container
- Run `idekube-healthcheck` as a sidecar or entrypoint wrapper process
- Configure Kubernetes probes to target the health endpoint:

```yaml
livenessProbe:
  httpGet:
    path: /
    port: 9999
  initialDelaySeconds: 5
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /
    port: 9999
  initialDelaySeconds: 3
  periodSeconds: 5
```

The 502 response for main service failure ensures that Kubernetes will detect the pod as not ready, while secondary service degradation (200 with `"degraded"` status) keeps the pod in service but signals a need for attention through the response body.
