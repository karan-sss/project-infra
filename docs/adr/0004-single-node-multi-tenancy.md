# ADR-0004: Single-node multi-tenancy

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
Several small projects need hosting, but running one server each multiplies cost.

## Decision
Host every project on one server. All projects share one PostgreSQL and one Redis, separated by database/role and ACL user/key prefix. Sablier stops idle apps (scale-to-zero). Each container has a `mem_limit`. A 4 GB swap file is the emergency buffer.

## Consequences
Cheap and efficient. Blast radius: one server outage takes everything down. This is accepted for personal projects and mitigated by IaC rebuilds (ADR-0005) and tested backups (ADR-0012).
