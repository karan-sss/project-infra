# ADR-0010: Plan guard: budget and replacement protection

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
Infracost doesn't price Hetzner or Cloudflare, and an accidental server replacement would cause downtime and data loss.

## Decision
`scripts/plan_guard.py` reads the plan JSON. It prices it with the live Hetzner pricing API and fails above €7/month. It also fails on any delete/replace of `hcloud_server`, `hcloud_primary_ip` or `cloudflare_r2_bucket` unless the PR has the `allow-replace` label. It runs on the PR and again before apply.

## Consequences
Three layers stand before a destructive change: CI guard, Hetzner delete/rebuild protection, and human approval of the `production` environment.
