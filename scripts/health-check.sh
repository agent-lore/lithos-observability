#!/usr/bin/env bash
# =============================================================================
# Local OTEL Stack — Health Check
# =============================================================================
# Quick spot-check that the stack is running cleanly and data is flowing.
# Run daily after a version bump or when something feels off.
#
# Exits non-zero if any critical check fails.
# =============================================================================

set -u

# ── Colors ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

ok()   { echo "  ${GREEN}✓${RESET} $1"; }
warn() { echo "  ${YELLOW}!${RESET} $1"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail() { echo "  ${RED}✗${RESET} $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
section() { echo; echo "${BOLD}${BLUE}── $1 ${RESET}"; }

WARN_COUNT=0
FAIL_COUNT=0

# ── Locate repo root ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

# ── Grafana auth: allow override via env ──────────────────────────────────────
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"
GRAFANA_AUTH="${GRAFANA_USER}:${GRAFANA_PASSWORD}"

# ── 1. Containers ─────────────────────────────────────────────────────────────
section "Containers"

EXPECTED=(otel-collector prometheus tempo loki grafana)
for name in "${EXPECTED[@]}"; do
    status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$name" 2>/dev/null || echo "n/a")
    image=$(docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null || echo "?")

    if [ "$status" = "missing" ]; then
        fail "$name: container not found"
    elif [ "$status" != "running" ]; then
        fail "$name: status=$status  image=$image"
    elif [ "$health" = "unhealthy" ]; then
        fail "$name: unhealthy  image=$image"
    elif [ "$health" = "starting" ]; then
        warn "$name: still starting  image=$image"
    else
        ok "$name: $status/$health  ${image##*/}"
    fi
done

# ── 2. Collector ──────────────────────────────────────────────────────────────
section "OTEL Collector"

# Docker healthcheck status already checked in section 1; skip raw endpoint
# probe since the distroless image returns unusual responses that confuse curl.

# Recent errors in the last hour
errors=$(docker logs otel-collector --since 1h 2>&1 | grep -ciE 'error|failed' || true)
if [ "$errors" -gt 10 ]; then
    warn "$errors error/failure log lines in last hour (may be fine if restarting) — inspect: docker logs otel-collector --since 1h | grep -iE 'error|failed'"
elif [ "$errors" -gt 0 ]; then
    ok "$errors error/failure log lines in last hour (low)"
else
    ok "no errors in last hour"
fi

# Ingestion rate (any one of the three signals should be >0 if anything is instrumented)
spans_rate=$(curl -sf "http://localhost:9090/api/v1/query?query=rate(otelcol_receiver_accepted_spans%5B5m%5D)" | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(max([float(x['value'][1]) for x in r]) if r else 0)" 2>/dev/null || echo 0)
metrics_rate=$(curl -sf "http://localhost:9090/api/v1/query?query=rate(otelcol_receiver_accepted_metric_points%5B5m%5D)" | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(max([float(x['value'][1]) for x in r]) if r else 0)" 2>/dev/null || echo 0)
logs_rate=$(curl -sf "http://localhost:9090/api/v1/query?query=rate(otelcol_receiver_accepted_log_records%5B5m%5D)" | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(max([float(x['value'][1]) for x in r]) if r else 0)" 2>/dev/null || echo 0)
printf "  %-30s spans=%s/s  metrics=%s/s  logs=%s/s\n" "ingestion rate (5m)" "$spans_rate" "$metrics_rate" "$logs_rate"

# Export failures
export_fails=$(curl -sf "http://localhost:9090/api/v1/query?query=sum(rate(otelcol_exporter_send_failed_spans%5B5m%5D)%20%2B%20rate(otelcol_exporter_send_failed_metric_points%5B5m%5D)%20%2B%20rate(otelcol_exporter_send_failed_log_records%5B5m%5D))" | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(float(r[0]['value'][1]) if r else 0)" 2>/dev/null || echo 0)
if python3 -c "import sys; sys.exit(0 if float('$export_fails') > 0.01 else 1)" 2>/dev/null; then
    fail "export failures: $export_fails/s — downstream (Prometheus/Tempo/Loki) may be rejecting data"
else
    ok "no export failures"
fi

# ── 3. Prometheus ─────────────────────────────────────────────────────────────
section "Prometheus"

if curl -sf -m 3 http://localhost:9090/-/ready >/dev/null; then
    ok "ready endpoint responding"
else
    fail "not ready"
fi

# Recent sample ingest
samples=$(curl -sf "http://localhost:9090/api/v1/query?query=rate(prometheus_tsdb_head_samples_appended_total%5B5m%5D)" | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(float(r[0]['value'][1]) if r else 0)" 2>/dev/null || echo 0)
printf "  %-30s %s/s\n" "sample ingest rate (5m)" "$samples"

# Active series
series=$(curl -sf "http://localhost:9090/api/v1/query?query=prometheus_tsdb_head_series" | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(int(float(r[0]['value'][1]))) if r else print(0)" 2>/dev/null || echo 0)
printf "  %-30s %s\n" "active series" "$series"

# Disk usage
if docker exec prometheus du -sh /prometheus 2>/dev/null | awk '{print "  " "'"$GREEN"'" "✓" "'"$RESET"'" " disk usage: " $1}'; then :; else warn "could not read disk usage"; fi

# Scrape targets healthy
down_targets=$(curl -sf http://localhost:9090/api/v1/targets | python3 -c "import json,sys; d=json.load(sys.stdin)['data']['activeTargets']; print(sum(1 for t in d if t['health']!='up'))" 2>/dev/null || echo "?")
if [ "$down_targets" = "0" ]; then
    ok "all scrape targets healthy"
else
    warn "$down_targets scrape target(s) not 'up'"
fi

# ── 4. Tempo ──────────────────────────────────────────────────────────────────
section "Tempo"

if curl -sf -m 3 http://localhost:3200/ready >/dev/null; then
    ok "ready endpoint responding"
else
    fail "not ready"
fi

# Span metrics are flowing (takes ~1min after traces arrive)
spanmetrics_count=$(curl -sf "http://localhost:9090/api/v1/query?query=count(traces_spanmetrics_calls_total)" | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(int(float(r[0]['value'][1])) if r else 0)" 2>/dev/null || echo 0)
if [ "$spanmetrics_count" -gt 0 ]; then
    ok "span metrics generating: $spanmetrics_count series"
else
    warn "no span metrics series yet (normal if no spans received recently)"
fi

# WAL health — look for recent WAL replay failures
wal_errors=$(docker logs tempo --since 10m 2>&1 | grep -ciE 'wal replay|permission denied|fatal' || true)
if [ "$wal_errors" -gt 0 ]; then
    warn "$wal_errors WAL-related error lines in last 10m — inspect: docker logs tempo --since 10m | grep -iE 'wal|permission'"
else
    ok "no WAL errors in last 10m"
fi

# ── 5. Loki ───────────────────────────────────────────────────────────────────
section "Loki"

if curl -sf -m 3 http://localhost:3100/ready >/dev/null; then
    ok "ready endpoint responding"
else
    fail "not ready"
fi

# Labels available
label_count=$(curl -sf http://localhost:3100/loki/api/v1/labels | python3 -c "import json,sys; print(len(json.load(sys.stdin)['data']))" 2>/dev/null || echo 0)
printf "  %-30s %s\n" "label count" "$label_count"

# Has logs in the last hour?
log_count=$(curl -sGf http://localhost:3100/loki/api/v1/query_range \
    --data-urlencode 'query={job=~".+"}' \
    --data-urlencode "start=$(date -u -d '1 hour ago' +%s)000000000" \
    --data-urlencode "end=$(date -u +%s)000000000" \
    --data-urlencode 'limit=1' 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(len(s['values']) for s in d['data']['result']))" 2>/dev/null || echo 0)
if [ "$log_count" -gt 0 ]; then
    ok "logs flowing (last-hour sample returned entries)"
else
    warn "no log entries in last hour"
fi

# ── 6. Grafana ────────────────────────────────────────────────────────────────
section "Grafana"

gf_health=$(curl -sf -m 3 http://localhost:3000/api/health | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('database','?'),'/',d.get('version','?'))" 2>/dev/null || echo "?")
if [ "$gf_health" != "?" ]; then
    ok "API health: $gf_health"
else
    fail "API health endpoint not responding"
fi

# Dashboards provisioned
dash_count=$(curl -sf -u "$GRAFANA_AUTH" "http://localhost:3000/api/search?type=dash-db" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
if [ "$dash_count" = "?" ]; then
    warn "could not query dashboards (auth?). Set GRAFANA_PASSWORD env var."
elif [ "$dash_count" -lt 3 ]; then
    warn "only $dash_count dashboard(s) provisioned (expected 3)"
else
    ok "$dash_count dashboards provisioned"
fi

# Datasources reachable via Grafana proxy. We hit a simple known-good endpoint
# on each since the `/api/datasources/uid/<uid>/health` shape differs per
# plugin and per Grafana version.
probe_prometheus() { curl -sf -u "$GRAFANA_AUTH" "http://localhost:3000/api/datasources/proxy/uid/prometheus/api/v1/query?query=up" >/dev/null; }
probe_tempo()      { curl -sf -u "$GRAFANA_AUTH" "http://localhost:3000/api/datasources/proxy/uid/tempo/api/echo" >/dev/null || curl -sf -u "$GRAFANA_AUTH" "http://localhost:3000/api/datasources/proxy/uid/tempo/ready" >/dev/null; }
probe_loki()       { curl -sf -u "$GRAFANA_AUTH" "http://localhost:3000/api/datasources/proxy/uid/loki/loki/api/v1/labels" >/dev/null; }

for ds in prometheus tempo loki; do
    if "probe_$ds"; then
        ok "datasource '$ds': reachable"
    else
        warn "datasource '$ds': could not reach via Grafana proxy"
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo
if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
    echo "${GREEN}${BOLD}All checks passed.${RESET}"
    exit 0
elif [ "$FAIL_COUNT" -eq 0 ]; then
    echo "${YELLOW}${BOLD}$WARN_COUNT warning(s) — review but not critical.${RESET}"
    exit 0
else
    echo "${RED}${BOLD}$FAIL_COUNT failure(s), $WARN_COUNT warning(s).${RESET}"
    exit 1
fi
