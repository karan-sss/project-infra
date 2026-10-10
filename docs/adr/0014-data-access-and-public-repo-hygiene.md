# ADR-0014: Loopback-only data access and public-repo hygiene

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
The repo is public; Postgres/Redis must be inspectable by the owner but never reachable from the internet.

## Decision
Postgres/Redis publish only on `127.0.0.1` and are reached via an SSH tunnel over Tailscale. Per-project roles/ACL users isolate projects, and `karan_ro` (`pg_read_all_data`) is used for browsing. Containers can't reach the Hetzner metadata service. Rendered cloud-init is `sensitive()`. `leak_check.sh` scans plan text before it lands in logs, comments or issues. Secret scanning + push protection are on. Workflows never use `pull_request_target`.

## Consequences
Publishing the code costs nothing in security; secrets live only in GitHub Secrets, the private R2 state and server-side `.env` files.
