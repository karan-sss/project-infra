# ADR-0003: Build in CI, run on the host

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
Compiling on a 2 vCPU / 4 GB server spikes CPU to 100% and risks OOM-killing live services.

## Decision
The server never builds. GitHub Actions builds, tests and packages images and pushes them to GHCR; the server only pulls and runs them.

## Consequences
Deploys are fast and predictable, and the server stays a lean runtime. Native `ubuntu-24.04-arm` runners (free for public repos) build arm64 without QEMU emulation.
