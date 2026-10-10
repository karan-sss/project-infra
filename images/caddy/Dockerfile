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

# Fail the build early if a plugin is missing.
RUN caddy list-modules | grep -q '^dns.providers.cloudflare$' \
 && caddy list-modules | grep -q '^http.ip_sources.cloudflare$' \
 && caddy list-modules | grep -q '^http.handlers.sablier$'
