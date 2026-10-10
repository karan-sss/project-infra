# Security Policy

## Reporting a vulnerability

Please report security issues **privately** via GitHub's
[private vulnerability reporting](https://github.com/karan-sss/project-infra/security/advisories/new).
Please do not open public issues for vulnerabilities.

## What is public and what is secret

| Public (this repo) | Secret (never committed) |
|---|---|
| Terraform code, cloud-init template, Compose files, workflows | API tokens (Hetzner, Cloudflare, Tailscale, Grafana) → GitHub Secrets |
| SSH **public** keys | SSH private keys, admin password hash → GitHub Secrets |
| Architecture, ADRs, runbook | Terraform state → private Cloudflare R2 bucket |
| Origin IP (harmless: firewall allows Cloudflare only) | Database/Redis passwords, restic password → GitHub Secrets + server `.env` (mode 600) |

## Threat model (summary)

| Threat | Controls |
|---|---|
| Attacks on the origin bypassing the CDN | Hetzner firewall allows 80/443 from Cloudflare IPs only; no public SSH |
| SSH brute force | Port 22 closed publicly; Tailscale-only, key-only, no root login |
| Compromised app container | No published ports, no Docker socket, per-project DB/Redis credentials, metadata service blocked, `mem_limit` per container |
| Malicious dependency / image swap | SHA-pinned Actions, digest-pinned images, cosign verify before deploy, Trivy scans, Renovate PRs |
| Secrets leaked via public CI logs | `sensitive()` values, `leak_check.sh` before posting plan output, secret scanning + push protection |
| Malicious fork PR | `pull_request` only (no secrets for forks), approval required for outside contributors |
| Accidental destruction | Plan guard (`allow-replace` label), Hetzner delete/rebuild protection, approval-gated apply, tested backups |
