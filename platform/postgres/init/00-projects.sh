#!/usr/bin/env bash
# Idempotent per-project Postgres setup (PLAN Task 11, ADR-0014).
#
# Runs (1) automatically on first init from /docker-entrypoint-initdb.d and
# (2) on every deploy: docker exec postgres /docker-entrypoint-initdb.d/00-projects.sh
#
# Env (from platform .env):
#   PROJECTS          comma-separated project names, e.g. "portfolio,notes"
#   PG_PASS_<NAME>    password for project <name> (upper-cased), e.g. PG_PASS_PORTFOLIO
#   PG_RO_PASSWORD    password for the read-only human role karan_ro (optional)
#
# For each project: role <name> (LOGIN, password set/rotated), database <name>
# owned by it, CONNECT revoked from PUBLIC. Passwords never appear in argv:
# psql reads them from the environment with \getenv.
set -euo pipefail

PSQL=(psql -v ON_ERROR_STOP=1 --no-psqlrc -q -U "${POSTGRES_USER:-postgres}" -d postgres)
RO_ROLE=karan_ro

projects=()
IFS=',' read -r -a raw <<< "${PROJECTS:-}"
for p in "${raw[@]}"; do
  p="${p//[[:space:]]/}"
  [ -z "$p" ] && continue
  if [[ ! "$p" =~ ^[a-z][a-z0-9_]*$ ]] || [ "$p" = "$RO_ROLE" ] || [ "$p" = postgres ]; then
    echo "00-projects: invalid project name '$p' (want ^[a-z][a-z0-9_]*$)" >&2
    exit 1
  fi
  projects+=("$p")
done

for name in "${projects[@]}"; do
  var="PG_PASS_${name^^}"
  if [ -z "${!var:-}" ]; then
    echo "00-projects: $var not set, skipping '$name'" >&2
    continue
  fi
  PROJECT_PASSWORD="${!var}" "${PSQL[@]}" -v name="$name" <<'SQL'
\getenv pw PROJECT_PASSWORD
SELECT format('CREATE ROLE %I LOGIN', :'name')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'name') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'name', :'pw') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'name', :'name')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'name') \gexec
SELECT format('REVOKE CONNECT, TEMPORARY ON DATABASE %I FROM PUBLIC', :'name') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'name', :'name') \gexec
SQL
  echo "00-projects: ensured project '$name'"
done

if [ -n "${PG_RO_PASSWORD:-}" ]; then
  RO_PASSWORD="$PG_RO_PASSWORD" "${PSQL[@]}" -v name="$RO_ROLE" <<'SQL'
\getenv pw RO_PASSWORD
SELECT format('CREATE ROLE %I LOGIN', :'name')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'name') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD %L', :'name', :'pw') \gexec
SELECT format('GRANT pg_read_all_data TO %I', :'name') \gexec
SQL
  for name in "${projects[@]}"; do
    "${PSQL[@]}" -v name="$name" -v ro="$RO_ROLE" <<'SQL'
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'name', :'ro')
  WHERE EXISTS (SELECT FROM pg_database WHERE datname = :'name') \gexec
SQL
  done
  echo "00-projects: ensured read-only role '$RO_ROLE'"
fi
