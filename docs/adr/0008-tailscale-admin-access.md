# ADR-0008: Tailscale for admin and CI access; no public SSH

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
SSH open to the internet attracts constant brute-force traffic, and GitHub runner IPs can't be allow-listed.

## Decision
The server joins a Tailscale tailnet as `tag:server`. CI runners join as ephemeral `tag:ci` nodes through an OAuth client. The tailnet ACL (managed in Terraform) only allows `tag:ci` → `tag:server:22`. Port 22 is closed in the Hetzner firewall. Break-glass: the Terraform var `ssh_public_access=true`, or the Hetzner web console with the admin password (SSH password auth stays disabled).

## Consequences
Zero public SSH attack surface on the free Tailscale plan. Depends on Tailscale availability, which the break-glass paths cover.
