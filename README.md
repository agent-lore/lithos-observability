# local-otel-stack

A reusable, fully local OpenTelemetry observability stack for development and self-hosted services.

**No cloud. No data leaving your machine. No ongoing costs.**

## What's Included

| Service | Purpose | UI |
|---------|---------|----|
| **OTEL Collector** | Central telemetry hub — receives OTLP, fans out to backends | — |
| **Prometheus** | Metrics storage & alerting | http://localhost:9090 |
| **Grafana Tempo** | Distributed trace storage | via Grafana |
| **Grafana Loki** | Log aggregation | via Grafana |
| **Grafana** | Unified dashboards (metrics + traces + logs) | http://localhost:3000 |
| **Opik** *(optional)* | LLM-specific trace analysis (prompts, tokens, costs) | http://localhost:5173 |

## Quick Start

### 1. Clone and configure

```bash
git clone <this-repo> local-otel-stack
cd local-otel-stack
cp .env.example .env
# Edit .env if you want to change passwords
```

### 2. Start the core stack

```bash
docker compose up -d
```

Grafana will be available at **http://localhost:3000** (admin / admin by default).  
Datasources (Prometheus, Tempo, Loki) and the OTEL overview dashboard are provisioned automatically.

### 3. Point your service at the collector

Set these environment variables in any OTEL-instrumented service:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318   # OTLP/HTTP
OTEL_SERVICE_NAME=my-service
OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp
```

See `examples/` for service-specific env files.

---

## With Opik (LLM Observability)

Opik (by Comet) provides LLM-specific analysis: prompt/completion viewer, token usage,  
cost tracking, and evaluation scores. It receives the same traces as Tempo via the  
OTEL Collector, so LLM spans appear in **both** Grafana and Opik.

### Start with Opik

```bash
docker compose -f docker-compose.yml -f docker-compose.opik.yml up -d
```

Opik UI: **http://localhost:5173**

> **Note:** Opik adds MySQL, ClickHouse, and Redis — allow 60-90 seconds for first startup.

### Instrument your LLM calls

Install [OpenLIT](https://github.com/openlit/openlit) in your Python service:

```bash
pip install openlit
```

```python
import openlit

# Call once after OTEL SDK is initialised.
# Auto-instruments OpenAI, Anthropic, LiteLLM, ChromaDB, and more.
openlit.init()
```

LLM spans will appear in the same trace tree as your service spans, with `gen_ai.*` attributes  
(model name, token counts, cost, prompt, completion).

---

## Connecting a Dockerised Service

If your service runs in Docker (not on the host network), use `host.docker.internal`  
instead of `localhost`:

```yaml
# In your service's docker-compose.yml
services:
  my-service:
    environment:
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:4318
    extra_hosts:
      - "host.docker.internal:host-gateway"   # Linux only
```

Alternatively, attach your service to the shared `otel-network` and use  
`http://otel-collector:4318` directly:

```yaml
services:
  my-service:
    networks:
      - otel-network

networks:
  otel-network:
    external: true
```

---

## Connecting Lithos

Add the following to the `environment` section of your Lithos `docker-compose.yml`:

```yaml
environment:
  - LITHOS_OTEL_ENABLED=true
  - OTEL_SERVICE_NAME=lithos
  - OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:4318
  - OTEL_TRACES_EXPORTER=otlp
  - OTEL_METRICS_EXPORTER=otlp
  - OTEL_LOGS_EXPORTER=otlp
```

See `examples/lithos.env` for the full reference.

---

## Architecture

```
Your Services
  │
  │  OTLP/HTTP (port 4318)  or  OTLP/gRPC (port 4317)
  ▼
┌─────────────────────────────────────────────────────┐
│              OTEL Collector                          │
│  receivers: otlp                                     │
│  processors: memory_limiter → batch                  │
│  exporters:                                          │
│    traces  → Tempo  (+ Opik when enabled)            │
│    metrics → Prometheus                              │
│    logs    → Loki                                    │
└──────────────┬──────────────┬───────────────┬────────┘
               │              │               │
               ▼              ▼               ▼
          Prometheus        Tempo           Loki
               │              │               │
               └──────────────┴───────────────┘
                              │
                              ▼
                          Grafana
                    (unified dashboards)

                      + Opik (optional)
                    (LLM trace analysis)
```

---

## Data Retention

| Backend | Default Retention | Configure via |
|---------|------------------|---------------|
| Prometheus | 30 days | `PROMETHEUS_RETENTION` in `.env` |
| Tempo | 30 days | `compactor.compaction.block_retention` in `tempo/tempo-config.yml` |
| Loki | 31 days | `limits_config.retention_period` in `loki/loki-config.yml` |

---

## Version Pinning

Docker images are pinned via variables in `.env` (see `.env.example`) to keep the
stack reproducible. To upgrade, edit your `.env` and bump versions in one place:

```bash
# Core
OTEL_COLLECTOR_VERSION=0.96.0
PROMETHEUS_VERSION=v2.51.2
GRAFANA_VERSION=10.4.3
TEMPO_VERSION=2.4.1
LOKI_VERSION=2.9.4

# Opik (optional)
OPIK_BACKEND_VERSION=0.9.0
OPIK_FRONTEND_VERSION=0.9.0
OPIK_MYSQL_VERSION=8.0.36
OPIK_CLICKHOUSE_VERSION=24.3-alpine
OPIK_REDIS_VERSION=7.2-alpine
```

After changes, restart the stack:

```bash
docker compose down
docker compose up -d
```

---

## Useful Commands

```bash
# Start core stack
docker compose up -d

# Start with Opik
docker compose -f docker-compose.yml -f docker-compose.opik.yml up -d

# View collector logs (useful for debugging export issues)
docker logs otel-collector -f

# Stop everything (preserves data volumes)
docker compose down

# Stop and wipe all data
docker compose down -v

# Reload Prometheus config without restart
curl -X POST http://localhost:9090/-/reload

# Check collector health
curl http://localhost:13133/   # returns {"status":"Server available"}
```

---

## Grafana Dashboards

The **OTEL Services Overview** dashboard is provisioned automatically and shows:

- Request rate by service
- Error rate by service  
- Latency percentiles (p50 / p95 / p99)
- Total spans by service
- All service logs (live stream)
- Collector health (spans received, memory)

To add more dashboards: drop JSON files into `grafana/dashboards/` — they are  
hot-reloaded every 30 seconds.

Good community dashboards to import from grafana.com:
- **Node Exporter Full** (ID: 1860) — host metrics
- **Tempo / TraceQL** (ID: 16543) — trace explorer
- **Loki Dashboard** (ID: 13639) — log explorer

---

## Troubleshooting

**Spans not appearing in Grafana?**
1. Check the collector received them: `docker logs otel-collector`
2. Verify your service is sending to the right endpoint:
   - OTLP/HTTP expects POST requests. A quick smoke test:
     `curl -v -X POST http://localhost:4318/v1/traces`
3. Tempo span metrics take ~1 minute to appear in Prometheus

**Opik not starting?**
- Allow 60-90 seconds for MySQL and ClickHouse to initialise on first run
- Check: `docker logs opik-backend`

**Port conflicts?**
- Edit the host port mappings in `docker-compose.yml` (left side of `host:container`)

---

## Adding a New Service

1. Instrument your service with the OTEL SDK (see `examples/`)
2. Set `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`
3. Set `OTEL_SERVICE_NAME=your-service-name`
4. That's it — your service appears in Grafana automatically

No collector config changes needed. The collector accepts any OTLP-speaking service.
