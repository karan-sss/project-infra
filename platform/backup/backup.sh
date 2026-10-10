#!/usr/bin/env bash
# Nightly encrypted backup to Cloudflare R2 with restic (PLAN Task 13, ADR-0012).
# Run by backup.service (User=deployer, EnvironmentFile=/opt/platform/backup/.env).
#
# Env: RESTIC_REPOSITORY, RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
#      HC_PING_KEY. Optional: BACKUP_HOST (default core-01).
#
# Postgres is dumped to a local file first, so a failed pg_dumpall can never
# become a truncated snapshot. Docker volumes labelled backup=true are added
# as tar streams.
set -Eeuo pipefail

: "${HC_PING_KEY:?}" "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD:?}"
HOST_TAG="${BACKUP_HOST:-core-01}"
HC_URL="https://hc-ping.com/${HC_PING_KEY}/backup-nightly"
WORK="$(dirname "$0")/tmp"

hc() { curl -fsS -m 10 --retry 3 -o /dev/null "${HC_URL}${1:-}" || true; }
cleanup() { rm -rf "$WORK"; }
trap 'hc /fail' ERR
trap cleanup EXIT

hc /start
umask 077
mkdir -p "$WORK"

restic cat config >/dev/null 2>&1 || restic init

if [ "$(docker inspect -f '{{.State.Running}}' postgres 2>/dev/null || true)" = "true" ]; then
  docker exec postgres pg_dumpall -U postgres > "$WORK/pg_dumpall.sql"
  restic backup --host "$HOST_TAG" --tag nightly --tag postgres \
    --stdin --stdin-filename pg_dumpall.sql < "$WORK/pg_dumpall.sql"
  rm -f "$WORK/pg_dumpall.sql"
else
  echo "backup: postgres not running, skipping database dump"
fi

# App volumes opt in with the label backup=true. Streamed via a throwaway
# container because /var/lib/docker is root-only.
helper_image="$(docker inspect -f '{{.Config.Image}}' postgres 2>/dev/null || echo alpine:3)"
mapfile -t volumes < <(docker volume ls -q --filter label=backup=true)
for v in "${volumes[@]}"; do
  docker run --rm --network none -v "$v:/data:ro" --entrypoint tar "$helper_image" -C /data -cf - . \
    | restic backup --host "$HOST_TAG" --tag nightly --tag volume --tag "$v" \
        --stdin --stdin-filename "volumes/$v.tar"
done

restic forget --host "$HOST_TAG" --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6
restic check --read-data-subset=2%

hc ""
echo "backup: done"
