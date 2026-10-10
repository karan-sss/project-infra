# ADR-0005: Terraform in CI with state in Cloudflare R2

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
Infrastructure must be reproducible and reviewable, and applied from CI rather than a laptop.

## Decision
Terraform manages Hetzner, Cloudflare and Tailscale. State lives in a private Cloudflare R2 bucket through the S3 backend with native lockfile locking (`use_lockfile`, Terraform ≥ 1.10). PRs run `plan`; only `main` runs `apply`, behind the `production` environment approval.

## Consequences
Free (R2 10 GB tier). State contains secrets, so the bucket is private and its credentials live only in GitHub Secrets. The server has `delete_protection`, `rebuild_protection` and `ignore_changes` on `user_data`/`image`, so routine changes never replace it.
