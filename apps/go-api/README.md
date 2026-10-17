# Go API - Minimal HTTP Server

A lightweight HTTP server in Go with health checks, readiness probes, and Prometheus metrics.

## Features

- **Health Check** (`/health`) - Always returns 200 OK
- **Readiness Probe** (`/ready`) - Can simulate failures for testing
- **Prometheus Metrics** (`/metrics`) - HTTP request metrics in Prometheus format
- **Graceful Shutdown** - Handles SIGINT and SIGTERM signals cleanly
- **Environment Variable Configuration** - Customize behavior via env vars
- **Optional Failure Simulation** - Simulate readiness failures for testing

## Quick Start

### Running Locally

```bash
# Install dependencies
go mod download

# Run the server
go run main.go

# Or with flags to simulate readiness failure
go run main.go -failure
```

### Using Docker

```bash
# Build
docker build -t go-api .

# Run
docker run -p 8080:8080 go-api

# Run with readiness failure simulation
docker run -p 8080:8080 -e READINESS_FAILURE=true go-api
```

## Configuration

### Environment Variables

- `PORT` - Server port (default: `8080`)
- `READINESS_FAILURE` - Simulate readiness failures (default: `false`)
- `SHUTDOWN_TIMEOUT` - Graceful shutdown timeout (default: `30s`)

Three behaviour switches exist for faults and scenarios. Each is off by
default, and the app behaves exactly as above until one is set:

- `UPSTREAM_URL` - a dependency `/` and `/ready` call on every request. When
  the call fails or answers 5xx, `/` answers 502 with the error
  (`{"error":"upstream: ..."}`) and logs it. `/ready` reports the result in an
  `upstream` field and stays 200, so a dependency outage does not take every
  replica out of the Service. `/` waits up to 8s for the upstream, under the
  server's 10s write timeout; `/ready` waits up to 1s, under any probe's
  timeout.
- `STARTUP_DELAY_SECONDS` - how long the app waits before it listens, as a
  slow start would. Probes get `connection refused` until then.
- `CPU_WORK_MS` - CPU work `/` does per request, measured in milliseconds of
  an unthrottled core at startup. Under a CPU limit the same work takes longer.

The chart sets them with `upstreamURL`, `startupDelaySeconds` and `cpuWorkMs`.

### Command-line Flags

- `-failure` - Enable readiness check failure simulation

## API Endpoints

### Health Check
```bash
curl http://localhost:8080/health
# {"status":"ok"}
```

### Readiness Check
```bash
curl http://localhost:8080/ready
# {"status":"ready"}

# With failure simulation:
curl http://localhost:8080/ready
# HTTP 503
# {"status":"not_ready","reason":"simulated failure"}
```

### Metrics (Prometheus format)
```bash
curl http://localhost:8080/metrics
```

Available metrics:
- `http_server_request_duration_seconds` - Request latency histogram, OpenTelemetry
  semantic conventions. Its `_count` series is the request count: semconv defines
  no separate counter. Labels: `http_request_method`, `http_route`,
  `http_response_status_code`, `app`.

## Graceful Shutdown

The server gracefully handles shutdown signals:
- Listens for SIGINT (Ctrl+C) and SIGTERM
- Provides 30 seconds (configurable) to complete in-flight requests
- Logs shutdown events

## Example: Kubernetes Probes

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5

readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5
```
