#!/usr/bin/env bash
# Fail if any given file contains secret material (ADR-0014).
# Run on plan text BEFORE it is posted to PR comments or issues of this public repo.
# Values Terraform generates (e.g. the tailnet key) are not GitHub secrets, so
# Actions cannot mask them; this check is the safety net.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 FILE..." >&2; exit 2; }

# shellcheck disable=SC2016  # literal regexes, no expansion intended
patterns=(
  'tskey-'
  '\$6\$'
  '\$y\$'
  '-----BEGIN [A-Z ]*PRIVATE KEY'
  'hc-ping\.com/[A-Za-z0-9_-]{16,}'
  'AKIA[0-9A-Z]{16}'
)

found=0
for p in "${patterns[@]}"; do
  if grep -Eq -- "$p" "$@"; then
    echo "::error::leak_check: pattern '$p' found in output" >&2
    found=1
  fi
done

# Exact values of secret-looking env vars (never echoed).
while IFS='=' read -r name _; do
  case "$name" in
    *_TOKEN|*_SECRET|*_PASSWORD|*_KEY|*_HASH)
      value="${!name}"
      if [ "${#value}" -ge 8 ] && grep -Fq -- "$value" "$@"; then
        echo "::error::leak_check: value of \$$name found in output" >&2
        found=1
      fi
      ;;
  esac
done < <(env)

if [ "$found" -ne 0 ]; then
  echo "leak_check: FAILED — output not published." >&2
  exit 1
fi
echo "leak_check: clean"
