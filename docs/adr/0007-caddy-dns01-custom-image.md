# ADR-0007: Custom Caddy image with DNS-01 wildcard TLS

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
Origin TLS must be valid for Full (strict) and cover `*.domain` for new projects without any per-app work.

## Decision
Build Caddy with `xcaddy` + `caddy-dns/cloudflare` (+ the Sablier plugin) in GitHub Actions for linux/arm64 and linux/amd64. Push it to GHCR with SBOM, provenance and a cosign signature. Caddy gets a wildcard Let's Encrypt cert by DNS-01 using a DNS-only Cloudflare token.

## Consequences
No HTTP-01 dependency on the proxy path; new subdomains get TLS instantly. This is also the first real use of the multi-arch pipeline. The Caddy DNS token is scoped to Zone Read + DNS Edit on one zone.
