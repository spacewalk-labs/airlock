#!/usr/bin/env bash
# code-server smoke — against a live install (after orchestrator render + reload).
# Covers the owner gate, per-slot routing (/s/1/), a real WebSocket handshake,
# the slot manager API (/api/list), and that the shell embeds the return widget.
set -uo pipefail
# ABI (D5): prefer the orchestrator-supplied AIRLOCK_ROOT/AIRLOCK_APP_ID,
# falling back to $0-relative computation for a standalone invocation.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:-$(cd "$HERE/../.." && pwd)}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-code-server}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# lib.sh turns on `set -e`. This smoke aggregates failures itself (via `fail`
# below) and deliberately issues a WebSocket-upgrade curl that curl reports as a
# timeout (exit 28) — it holds the 101 connection open until --max-time. Restore
# `-e` off (matching the header's `set -uo pipefail`) so that expected-non-zero
# curl does not abort the smoke before it evaluates and prints its results.
set +e

airlock_load code-server
GATE="$AIRLOCK_CODE_SERVER_GATE_PORT"
BACKEND="$AIRLOCK_CODE_SERVER_BACKEND_PORT"       # slot 1
MANAGER="$AIRLOCK_CODE_SERVER_MANAGER_PORT"
HDR="$AIRLOCK_IDENTITY_HEADER"
OWNER="${AIRLOCK_OWNER%%,*}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@"; }
body() { curl -s --max-time 6 "$@"; }

c_be=$(code   "http://127.0.0.1:${BACKEND}/")
c_own=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${GATE}/")
c_deny=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${GATE}/")
c_no=$(code                                    "http://127.0.0.1:${GATE}/")
c_slot1=$(code -H "${HDR}: ${OWNER}"          "http://127.0.0.1:${GATE}/s/1/")
c_api_own=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${GATE}/api/list")
c_api_no=$(code                                    "http://127.0.0.1:${GATE}/api/list")
c_api_mgr=$(code                                   "http://127.0.0.1:${MANAGER}/api/list")

# WebSocket handshake through the gate to slot 1 (proves Upgrade is forwarded).
c_ws=$(code --http1.1 \
  -H "${HDR}: ${OWNER}" \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "http://127.0.0.1:${GATE}/s/1/")

# The gate must serve the shell (embedding the return widget) at "/" and serve the
# widget itself at /airlock-return.js. Both sit behind the server-level owner guard
# (the shell embeds <script src="/airlock-return.js">, which the authenticated
# browser fetches with the injected identity header) — so send the owner header.
shell_html=$(body -H "${HDR}: ${OWNER}" "http://127.0.0.1:${GATE}/")
c_widget=$(code -H "${HDR}: ${OWNER}" "http://127.0.0.1:${GATE}/airlock-return.js")

echo "[code-server smoke] backend=${c_be}/200|302 owner=${c_own}/200|302 deny=${c_deny}/403 no-header=${c_no}/403"
echo "[code-server smoke] slot1=${c_slot1}/200|302 ws=${c_ws}/101 api:owner=${c_api_own}/200 api:no-header=${c_api_no}/403 api:mgr-loopback=${c_api_mgr}/403 widget=${c_widget}/200"
fail=0
{ [ "$c_be" = 200 ] || [ "$c_be" = 302 ]; }   || { echo "FAIL backend"; fail=1; }
{ [ "$c_own" = 200 ] || [ "$c_own" = 302 ]; } || { echo "FAIL owner"; fail=1; }
[ "$c_deny" = 403 ] || { echo "FAIL deny (gate hole)"; fail=1; }
[ "$c_no"   = 403 ] || { echo "FAIL no-header (gate hole)"; fail=1; }
{ [ "$c_slot1" = 200 ] || [ "$c_slot1" = 302 ]; } || { echo "FAIL /s/1/ routing"; fail=1; }
[ "$c_ws"   = 101 ] || { echo "FAIL websocket 101"; fail=1; }
[ "$c_api_own" = 200 ] || { echo "FAIL /api/list owner 200"; fail=1; }
[ "$c_api_no"  = 403 ] || { echo "FAIL /api/list no-header (gate hole)"; fail=1; }
[ "$c_api_mgr" = 403 ] || { echo "FAIL manager loopback not owner-checked (gate hole)"; fail=1; }
[ "$c_widget"  = 200 ] || { echo "FAIL /airlock-return.js not served"; fail=1; }
[[ "$shell_html" == *"/airlock-return.js"* ]] || { echo "FAIL shell does not load return widget"; fail=1; }
[ "$fail" = 0 ]
