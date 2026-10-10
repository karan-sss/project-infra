# ADR-0001: Hetzner Cloud over AWS/GCP

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
The platform must host a portfolio, several side projects, a database and an edge proxy for under €7/month.

## Decision
Run one unmanaged Hetzner Cloud server instead of AWS EC2 / GCP Compute Engine.

## Consequences
AWS/GCP micro instances (`t4g.micro`, `e2-micro`) give 1–2 GB RAM and cost $15–20/month once IPv4, disk and egress are included; 1 GB is not enough for a database, proxy and apps without OOM kills. Hetzner gives 4 GB RAM, NVMe and 20 TB traffic for about €6.49. In exchange we run the OS ourselves: patching, hardening, backups and monitoring are our job, and this repo shows how.
