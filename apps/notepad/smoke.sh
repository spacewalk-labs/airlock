#!/usr/bin/env bash
# notepad smoke — against a live install (after orchestrator render + reload).
# Static page behind the hub; upload API is covered by the publish smoke.
set -uo pipefail
# ABI (D5): the caller sets AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID and runs
# this script with cwd = AIRLOCK_APP_DIR. AIRLOCK_ROOT is REQUIRED: the platform
# root cannot be derived from $0, because "$0/../.." is only the platform when the
# package happens to sit in the platform's own apps/ tree — the arrangement the
# apps/ cutover ends. $0-relative self-location (this file's own directory) stays
# fine and is what AIRLOCK_APP_DIR falls back to.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-notepad}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

airlock_load hub
HUB="$AIRLOCK_HUB_NGINX_PORT"
HDR="$AIRLOCK_IDENTITY_HEADER"
OWNER="${AIRLOCK_OWNER%%,*}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@"; }
c_ui=$(code   -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/notepad/")
c_deny=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${HUB}/notepad/")
c_no=$(code                                    "http://127.0.0.1:${HUB}/notepad/")

echo "[notepad smoke] ui=${c_ui}/200 deny=${c_deny}/403 no-header=${c_no}/403"
fail=0
[ "$c_ui"   = 200 ] || { echo "FAIL notepad UI"; fail=1; }
[ "$c_deny" = 403 ] || { echo "FAIL other identity not denied (GATE HOLE)"; fail=1; }
[ "$c_no"   = 403 ] || { echo "FAIL missing header not denied (GATE HOLE)"; fail=1; }
[ "$fail" = 0 ]
