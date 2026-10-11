#!/usr/bin/env bash
# Render redis/users.acl from /opt/platform/.env and hot-reload it (ADR-0014).
# Runs on the server as `deployer`, from /opt/platform, BEFORE `docker compose up`
# (otherwise Docker would create users.acl as a directory).
#
# Env (from .env): REDIS_ADMIN_PASSWORD, PROJECTS, REDIS_PASS_<NAME> per project.
# Projects without REDIS_PASS_<NAME> get no Redis user.
# Passwords are stored as SHA-256 hashes (#<hex>), never in plaintext.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${REDIS_ADMIN_PASSWORD:?REDIS_ADMIN_PASSWORD missing in .env}"

sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

umask 077
tmp="$(mktemp redis/users.acl.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

{
  echo "user default off"
  echo "user admin on #$(sha "$REDIS_ADMIN_PASSWORD") ~* &* +@all"
  IFS=',' read -r -a projects <<< "${PROJECTS:-}"
  for p in "${projects[@]}"; do
    p="${p//[[:space:]]/}"
    [ -z "$p" ] && continue
    if [[ ! "$p" =~ ^[a-z][a-z0-9_]*$ ]] || [ "$p" = admin ] || [ "$p" = default ]; then
      echo "render-acl: invalid project name '$p'" >&2
      exit 1
    fi
    var="REDIS_PASS_${p^^}"
    [ -z "${!var:-}" ] && continue
    echo "user $p on #$(sha "${!var}") ~$p:* &$p:* +@all -@dangerous"
  done
} > "$tmp"

# Overwrite in place (same inode): users.acl is a single-file bind mount, and
# a rename would leave the running container reading the old file on ACL LOAD.
touch redis/users.acl
chmod 600 redis/users.acl
cat "$tmp" > redis/users.acl
rm -f "$tmp"
trap - EXIT
echo "render-acl: wrote redis/users.acl"

if [ "$(docker inspect -f '{{.State.Running}}' redis 2>/dev/null || true)" = "true" ]; then
  docker exec -e REDISCLI_AUTH="$REDIS_ADMIN_PASSWORD" redis \
    redis-cli --no-auth-warning --user admin ACL LOAD
  echo "render-acl: ACL reloaded"
fi
