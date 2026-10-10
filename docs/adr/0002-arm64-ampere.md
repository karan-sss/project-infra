# ADR-0002: ARM64 (Ampere Altra CAX11) over x86

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
Hetzner offers x86 (CX) and ARM64 (CAX) servers at similar prices.

## Decision
Use the CAX11 (2 dedicated Ampere cores, 4 GB).

## Consequences
Dedicated physical cores avoid noisy-neighbour hyperthread variance, and it matches the industry move to ARM (AWS Graviton, GCP Tau). The dev workstation is x86_64, so every image is built multi-arch with `docker buildx` (ADR-0007). Images without an arm64 variant can't be used.
