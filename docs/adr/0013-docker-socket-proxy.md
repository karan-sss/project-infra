# ADR-0013: Docker socket proxy

- **Status:** Accepted
- **Date:** 2026-10-11

## Context
Sablier and Alloy need Docker API access. Mounting `/var/run/docker.sock` (even `:ro`) is root-equivalent on the host.

## Decision
Only `tecnativa/docker-socket-proxy` mounts the socket. It exposes container read, events, and start/stop with `POST=0`, on an internal network shared only with Sablier and Alloy.

## Consequences
A compromise of Sablier or Alloy can't create privileged containers or exec into others.
