#!/usr/bin/env bash
# orca smoke — against a live install (after orchestrator render + reload).
# orca may answer / with a redirect, so 200 OR 302 both count as reachable.
set -uo pipefail
# ABI (D5): the caller sets AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID and runs
# this script with cwd = AIRLOCK_APP_DIR. AIRLOCK_ROOT is REQUIRED: the platform
# root cannot be derived from $0, because "$0/../.." is only the platform when the
# package happens to sit in the platform's own apps/ tree — the arrangement the
# apps/ cutover ends. $0-relative self-location (this file's own directory) stays
# fine and is what AIRLOCK_APP_DIR falls back to.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-orca}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

airlock_load orca
GATE="$AIRLOCK_ORCA_GATE_PORT"
BACKEND="$AIRLOCK_ORCA_BACKEND_PORT"
HDR="$AIRLOCK_IDENTITY_HEADER"
OWNER="${AIRLOCK_OWNER%%,*}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@"; }
c_be=$(code   "http://127.0.0.1:${BACKEND}/")
c_own=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${GATE}/")
c_deny=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${GATE}/")
c_no=$(code                                    "http://127.0.0.1:${GATE}/")

echo "[orca smoke] backend=${c_be}/200|302 owner=${c_own}/200|302 deny=${c_deny}/403 no-header=${c_no}/403"
fail=0
{ [ "$c_be" = 200 ] || [ "$c_be" = 302 ]; }   || { echo "FAIL backend (orca serve not reachable on 127.0.0.1:${BACKEND})"; fail=1; }
{ [ "$c_own" = 200 ] || [ "$c_own" = 302 ]; } || { echo "FAIL owner"; fail=1; }
[ "$c_deny" = 403 ] || { echo "FAIL deny (gate hole)"; fail=1; }
[ "$c_no"   = 403 ] || { echo "FAIL no-header (gate hole)"; fail=1; }

# Patched web client (vendored dist served at /orca-web/). If absent (upstream-only
# mode), owner gets 404 -> warn, don't fail. If present, it must be gated + widget-injected.
p_own=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${GATE}/orca-web/web-index.html")
if [ "$p_own" = 404 ]; then
  echo "[orca smoke] /orca-web/=404 — upstream client only (web-bundle not vendored)"
else
  p_deny=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${GATE}/orca-web/web-index.html")
  p_no=$(code                                    "http://127.0.0.1:${GATE}/orca-web/web-index.html")
  v_own=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${GATE}/web-index.html")   # vendor -> 302 patched
  body=$(curl -s --max-time 6 -H "${HDR}: ${OWNER}" "http://127.0.0.1:${GATE}/orca-web/web-index.html")
  echo "[orca smoke] patched: owner=${p_own}/200 deny=${p_deny}/403 no-header=${p_no}/403 vendor-redirect=${v_own}/301|302"
  [ "$p_own" = 200 ]  || { echo "FAIL patched client not served (200) at /orca-web/web-index.html"; fail=1; }
  [ "$p_deny" = 403 ] || { echo "FAIL /orca-web/ deny (gate hole in added location)"; fail=1; }
  [ "$p_no"   = 403 ] || { echo "FAIL /orca-web/ no-header (gate hole in added location)"; fail=1; }
  { [ "$v_own" = 301 ] || [ "$v_own" = 302 ]; } || { echo "FAIL vendor /web-index.html not redirected to patched client"; fail=1; }
  [[ "$body" == *"airlock-return.js"* ]] || { echo "FAIL return-widget not injected into patched client"; fail=1; }
fi
[ "$fail" = 0 ]
