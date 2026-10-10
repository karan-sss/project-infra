# Custom Caddy for karan-s.com (ADR-0007).
# Built natively for linux/amd64 + linux/arm64 by .github/workflows/build-caddy.yml.
# Base images are pinned by digest; Renovate proposes updates.

FROM caddy:2.11.7-builder@sha256:b25f47453fa02f7e66c0828b4b1343658808b9000950b6825c4a1cb0c988f5f8 AS build

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare@v0.2.4 \
    --with github.com/WeidiDeng/caddy-cloudflare-ip \
    --with github.com/sablierapp/sablier-caddy-plugin@v1.0.2

FROM caddy:2.11.7-alpine@sha256:d8542f48d34a9cf4e4c11a478865229840e87e4c96ea3f439101f31a5d35f75f

LABEL org.opencontainers.image.title="caddy-cloudflare" \
      org.opencontainers.image.description="Caddy with Cloudflare DNS-01, Cloudflare trusted proxies and Sablier plugins" \
      org.opencontainers.image.source="https://github.com/karan-sss/project-infra" \
      org.opencontainers.image.licenses="Apache-2.0"

COPY --from=build /usr/bin/caddy /usr/bin/caddy

# Run as an unprivileged user. Binding 80/443 needs no capability because
# Docker sets net.ipv4.ip_unprivileged_port_start=0 inside the container
# (also set explicitly in platform/compose.yaml).
RUN addgroup -S -g 10001 caddy \
 && adduser -S -D -H -u 10001 -G caddy caddy \
 && chown -R caddy:caddy /data /config
USER 10001:10001

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:2019/config/ >/dev/null || exit 1

# Fail the build early if a plugin is missing.
RUN caddy list-modules | grep -q '^dns.providers.cloudflare$' \
 && caddy list-modules | grep -q '^http.ip_sources.cloudflare$' \
 && caddy list-modules | grep -q '^http.handlers.sablier$'
