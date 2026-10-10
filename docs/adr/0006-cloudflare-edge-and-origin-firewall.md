# ADR-0006: Cloudflare edge + origin firewall that only allows Cloudflare

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
The origin should not be attackable directly, bypassing the CDN/WAF.

## Decision
All web DNS records are proxied, with SSL mode Full (strict). The Hetzner Cloud Firewall allows 80/443 only from Cloudflare's published IP ranges (`cloudflare_ip_ranges` data source). UFW on the host is a second layer. Free-plan WAF custom rules + one rate-limit rule are managed in Terraform. Bot Fight Mode is **off** because it can't be scoped on the free plan and would break monitors, CI smoke tests and APIs.

## Consequences
Direct-to-origin traffic is dropped before it reaches the host. Docker-published ports bypass UFW, which is why the cloud firewall (outside the host) is the primary control.
