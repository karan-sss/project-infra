# ADR-0011: Off-box observability and status page

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
Monitoring that runs on the box it monitors goes down with it.

## Decision
Grafana Alloy ships host/container metrics and logs to the Grafana Cloud free tier, where alerting lives. Upptime (GitHub Actions + Pages) serves `status.<domain>`. healthchecks.io provides dead-man switches for the heartbeat, backups and the restore drill. Cloudflare Web Analytics replaces cookie-based analytics.

## Consequences
€0 cost. Alloy is the main RAM cost (~150–250 MB, capped). Cardinality must stay under 10k series.
