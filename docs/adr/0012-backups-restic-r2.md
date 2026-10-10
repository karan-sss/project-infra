# ADR-0012: Encrypted backups to R2 with an automated restore drill

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
Hetzner backups/snapshots cost extra, and backups that are never restored can't be trusted.

## Decision
A nightly systemd timer runs restic: `pg_dumpall` plus app volumes, encrypted, to a dedicated R2 bucket, with retention 7 daily / 4 weekly / 6 monthly. A monthly GitHub Actions workflow restores the latest dump into a throwaway Postgres and checks it.

## Consequences
RPO 24 h, target RTO 30 min. The restic password must be kept outside the platform (password manager); losing it makes the backups unrecoverable.
