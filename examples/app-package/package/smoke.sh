#!/usr/bin/env bash
# Verify the loopback backend and the hub gate after Airlock reloads nginx.
set -euo pipefail

: "${AIRLOCK_ROOT:?AIRLOCK_ROOT is required (run through Airlock)}"
: "${AIRLOCK_APP_DIR:?AIRLOCK_APP_DIR is required (run through Airlock)}"
: "${AIRLOCK_APP_ID:?AIRLOCK_APP_ID is required (run through Airlock)}"

# shellcheck source=/dev/null
. "$AIRLOCK_ROOT/install/lib.sh"

require_cmd curl
airlock_load hello-example
BACKEND_PORT="${AIRLOCK_HELLO_EXAMPLE_BACKEND_PORT:?}"
airlock_load hub
HUB_PORT="${AIRLOCK_HUB_NGINX_PORT:?}"
HEADER="${AIRLOCK_IDENTITY_HEADER:?}"
OWNER="${AIRLOCK_OWNER%%,*}"

status() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 6 "$@" 2>/dev/null || true
}

backend="$(status "http://127.0.0.1:${BACKEND_PORT}/health")"
allowed="$(status -H "${HEADER}: ${OWNER}" "http://127.0.0.1:${HUB_PORT}/hello-example/")"
denied="$(status -H "${HEADER}: nobody@example.com" "http://127.0.0.1:${HUB_PORT}/hello-example/")"
anonymous="$(status "http://127.0.0.1:${HUB_PORT}/hello-example/")"

printf '[hello-example smoke] backend=%s/200 allowed=%s/200 denied=%s/403 anonymous=%s/403\n' \
  "$backend" "$allowed" "$denied" "$anonymous"

failed=0
[ "$backend" = 200 ] || { printf 'FAIL backend health\n' >&2; failed=1; }
[ "$allowed" = 200 ] || { printf 'FAIL owner request through hub\n' >&2; failed=1; }
[ "$denied" = 403 ] || { printf 'FAIL other identity was not denied\n' >&2; failed=1; }
[ "$anonymous" = 403 ] || { printf 'FAIL missing identity was not denied\n' >&2; failed=1; }
exit "$failed"
