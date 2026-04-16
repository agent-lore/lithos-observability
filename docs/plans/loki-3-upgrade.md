# Plan: Upgrade Loki 2.9.4 → 3.x (Phase 2 of stack version bumps)

**Status:** Not started. Wait until Phase 1 (Collector/Prometheus/Tempo/Grafana bumps on `chore/bump-stack-versions`) has been merged and stable for 2–3 days.

**Owner:** Dave
**Branch to create when starting:** `chore/bump-loki-3`
**Last updated:** 2026-04-16

---

## Context

Phase 1 of the stack version bumps (branch `chore/bump-stack-versions`) left Loki on 2.9.4 because the 2.x → 3.x transition carries higher risk than the other components. This document captures what's known about that upgrade so we can resume without re-researching.

Current Loki version: **2.9.4**
Target Loki version: **3.3.2** (stable 3.x, avoids bleeding edge 3.4.x)

## Why this is risky

1. **Config field removals.** Loki 3.x removed several fields that were deprecated in 2.9. Our config needs to be audited.
2. **Image may be distroless.** Tempo 2.7.1 was a reminder that a distroless image switch can break volume permissions (old data written as root, new process running as a non-root UID). Loki 3.x is similarly affected.
3. **Schema stability.** Our existing config already uses TSDB + v13 schema, which is what Loki 3.x expects — this is the single biggest migration pain most users hit, and we've already paid it. But we have 2.9.4-era chunks on disk; those should be readable by 3.x but we cannot assume this without testing.

## What we already have in our favour

Reading `loki/loki-config.yml` (as of 2026-04-16):

- `store: tsdb`
- `object_store: filesystem`
- `schema: v13`
- `from: 2024-01-01` (no older schema entries to migrate)
- No `shared_store`, no `query_timeout` in `querier`, no deprecated cache fields (`enable`, `type`, `fifo`)
- `auth_enabled: false` (single-tenant, local dev — no multitenancy migration concerns)

So our config is 90% of the way there already.

## Known breaking changes to verify against our config

From the Loki 3.0 release notes:

| Removed field | Our config has it? | Action |
|---------------|-------------------|--------|
| `storage.Config.shared_store` | No | — |
| `querier.Config.query_timeout` | No | — |
| `cache.Config.enable` / `.type` / `.fifo` | No (we only use `embedded_cache`) | — |
| `boltdb` store | No (we use `tsdb`) | — |

At time of writing there are no known blockers in our config. Execute the plan below and re-check against the then-current Loki 3.x release notes before starting.

## Plan

### Step 0 — Pre-flight (before creating the branch)

- [ ] Verify Phase 1 has been stable for ≥2 days (no container restarts, no export failures in `scripts/health-check.sh`).
- [ ] Re-read the latest Loki 3.x release notes for any new breaking changes since 2026-04-16.
- [ ] Take a backup of the `loki_data` volume if you care about retaining historical logs:
  ```bash
  docker run --rm -v lithos-observability_loki_data:/src -v "$PWD/backups":/dst alpine tar -czf /dst/loki_data-$(date +%Y%m%d).tar.gz -C /src .
  ```
  (Local dev logs are usually disposable — skip this if you don't care.)

### Step 1 — Create branch and bump version

- [ ] `git checkout main && git pull && git checkout -b chore/bump-loki-3`
- [ ] Update `LOKI_VERSION` in both `.env.example` and the default in `docker-compose.yml` (currently `2.9.4`) to `3.3.2`.
- [ ] Run `docker compose pull loki` to confirm the tag exists.

### Step 2 — Try starting with existing config

- [ ] `docker compose up -d loki`
- [ ] Watch logs: `docker logs loki -f`
- [ ] Likely outcomes:
  - **Best case:** Loki starts cleanly. Move to Step 4.
  - **Config complains:** Note the removed/renamed fields and fix them. See "Known breaking changes" above.
  - **Permission denied on `/loki`:** Loki 3.x runs as non-root UID (usually 10001). Same problem Tempo 2.7 had. Options:
    1. Wipe the volume: `docker compose stop loki && docker compose rm -f loki && docker volume rm lithos-observability_loki_data && docker compose up -d loki`
    2. `chown -R 10001:10001` the contents inside a temporary privileged container.

### Step 3 — Verify collector can still push logs

- [ ] Confirm `otel-collector` is still healthy: `docker logs otel-collector --tail 20`
- [ ] Watch for Loki exporter errors. The Loki exporter API (OTLP-over-HTTP-to-Loki) should be backward compatible, but verify.
- [ ] Confirm logs are landing:
  ```bash
  curl -sGf http://localhost:3100/loki/api/v1/query_range \
    --data-urlencode 'query={job=~".+"}' \
    --data-urlencode "start=$(date -u -d '10 min ago' +%s)000000000" \
    --data-urlencode 'limit=5'
  ```

### Step 4 — Check dashboards

- [ ] Open Grafana. Service Health dashboard → logs panel should populate.
- [ ] Trace → log linking from Tempo should still work (uses Loki datasource UID `loki`, unchanged).

### Step 5 — Run the health check

- [ ] `GRAFANA_PASSWORD=<pw> ./scripts/health-check.sh`
- [ ] All checks should pass or warn-only.

### Step 6 — If everything works

- [ ] Commit with message like `chore: bump Loki 2.9.4 → 3.3.2`
- [ ] Open PR
- [ ] Let it soak for a day before merging

### Step 7 — If it doesn't work

Rollback is one command: edit `.env.example` + `docker-compose.yml` back to `LOKI_VERSION=2.9.4`, then `docker compose up -d loki`. If you wiped the volume in Step 2, historical logs are gone — collector will continue writing fresh logs to the restored 2.9.4 Loki.

## Open questions to answer during execution

1. **Does the distroless image break shell access?** Loki 2.9.4 has a shell; 3.x may not. If you rely on `docker exec loki sh` for debugging, expect that to disappear.
2. **Is there any usable data migration path?** If the answer in step 2 is "permission denied", is there a cleaner fix than wipe-or-chown? Last time we hit this with Tempo we just wiped.
3. **Does `retention_period: 744h` still work?** It's one of the areas Loki 3.x reorganised — verify in logs at startup that retention is enabled and scheduled correctly.

## Success criteria

- [ ] Loki container running healthy on 3.3.2
- [ ] `./scripts/health-check.sh` passes (no failures)
- [ ] Grafana log panel on Service Health dashboard shows recent entries
- [ ] No new errors or warnings in collector logs
- [ ] README `Version Pinning` section updated to reflect `LOKI_VERSION=3.3.2`
