# ADR-0009: Supply-chain security

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
Images and Actions come from third parties and are deployed automatically.

## Decision
All Actions are pinned by commit SHA and all images by digest. Renovate keeps them updated. Images are built with SBOM + provenance, signed with cosign keyless (GitHub OIDC), and scanned with Trivy (SARIF to code scanning). The deploy runs `cosign verify` before rollout.

## Consequences
An attacker can't silently swap a tag or Action version; every update arrives as a reviewable PR.
