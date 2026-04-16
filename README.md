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
Datasources (Prometheus, Tempo, Loki) and dashboards are provisioned automatically.

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

## Multi-Environment Monitoring

You can monitor multiple instances of the same service (e.g. production, staging, dev)
through a single observability stack. Each instance is distinguished by the
`deployment.environment` resource attribute using the standard OTEL environment variable:

```bash
# Production
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production

# Staging
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=staging

# Dev
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev
```

No code changes are needed — the OTEL SDK reads `OTEL_RESOURCE_ATTRIBUTES` automatically.

### How the attribute flows through the stack

| Backend | How it arrives | Configuration |
|---------|---------------|---------------|
| **Prometheus** | Becomes a `deployment_environment` metric label | Automatic — `resource_to_telemetry_conversion` is enabled on the collector's Prometheus exporter |
| **Tempo** | Stored as a resource attribute on every span, and included as a dimension in span metrics | Configured in `tempo/tempo-config.yml` under `span_metrics.dimensions` |
| **Loki** | Promoted to a log stream label `deployment_environment` | Configured in `otel-collector/config.yml` under `loki.resource_attributes` |

### Dashboard filtering

All three Grafana dashboards include an **Environment** dropdown that filters by
`deployment.environment`. When "All" is selected, data from every environment is shown.
When no environments have been configured yet, the dropdown is empty and all data is
shown — existing setups continue to work without changes.

### Naming conventions

`deployment.environment` is a free-form string in the OTEL spec, but downstream
tooling treats it as an opaque exact-match label. Keep names consistent or your
filters will silently split data across variants (e.g. `prod` vs `production`).

Recommended practices:

- **Lowercase, no spaces.** `fuzzing` not `Fuzzing` not `Fuzz Testing`.
- **Pick full words** unless the abbreviation is universally understood (`prod`, `dev`).
- **Use the same value across all services and restarts** — once you've chosen `production`, don't also tag instances as `prod`.
- **Avoid values that may collide with tooling defaults:** `all`, `none`, `default`.
- **Prefer specific over generic** when the workload profile matters. `fuzzing` conveys "expect bad numbers, don't alert" better than a generic `testing`.

Common values: `production`, `staging`, `development` (or `dev`), `testing`, `qa`,
`canary`, `fuzzing`, `load-test`.

### Example: Lithos with environment

```yaml
environment:
  - LITHOS_OTEL_ENABLED=true
  - OTEL_SERVICE_NAME=lithos
  - OTEL_EXPORTER_OTLP_ENDPOINT=http://host.docker.internal:4318
  - OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production
  - OTEL_TRACES_EXPORTER=otlp
  - OTEL_METRICS_EXPORTER=otlp
  - OTEL_LOGS_EXPORTER=otlp
```

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

## Grafana Dashboards

Three dashboards are provisioned automatically:

### Service Health

Generic RED (Rate, Errors, Duration) dashboard for any OTEL-instrumented service.

- Request rate, error rate, and latency percentiles (p50 / p95 / p99)
- Top span names by call rate
- Live service logs with health-check noise filtered out
- OTEL Collector ingestion rate, export failures, and memory usage
- Filterable by **Service** and **Environment** dropdowns

### Lithos Operations

Deep dive into Lithos-specific custom metrics:

- **Knowledge Store** — document count, stale documents, CRUD rates, write latency
- **Search** — search rate and latency by type (fulltext / semantic / hybrid / graph), index sizes
- **Cache** — hit rate, lookup outcomes, lookup latency
- **Tool Usage** — MCP tool call rates, errors, and totals by tool name
- **Graph & Coordination** — knowledge graph size, task operations, active claims
- **Event Bus & SSE** — event activity, active SSE clients, buffer utilization

### LCMA Performance

Lithos LCMA retrieval pipeline performance:

- **Retrieval** — end-to-end retrieval latency, candidates-vs-results funnel
- **Scouts** — per-scout latency and candidate counts (all 10 scouts)
- **Enrich Queue** — queue depth, processing lag, attempt distribution
- **Working Memory** — coactivation pairs, active tasks, state trends over time

All dashboards cross-link to each other and share the time range and variable selections.

To add more dashboards: drop JSON files into `grafana/dashboards/` — they are  
hot-reloaded every 30 seconds.

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
OTEL_COLLECTOR_VERSION=0.113.0
PROMETHEUS_VERSION=v2.55.1
GRAFANA_VERSION=11.4.0
TEMPO_VERSION=2.7.1
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

# Reload Grafana dashboard provisioning without restart
curl -X POST -u admin:admin http://localhost:3000/api/admin/provisioning/dashboards/reload

# Check collector health
curl http://localhost:13133/   # returns {"status":"Server available"}

# Run the full health check — containers, ingestion rates, export failures,
# dashboards, datasources. Expects GRAFANA_PASSWORD in the environment.
GRAFANA_PASSWORD=<your-password> ./scripts/health-check.sh
```

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
4. Optionally set `OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev` for environment filtering
5. That's it — your service appears in Grafana automatically

No collector config changes needed. The collector accepts any OTLP-speaking service.
