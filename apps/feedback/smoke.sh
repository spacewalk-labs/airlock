#!/usr/bin/env bash
# feedback smoke — against a live install (after orchestrator render + reload).
# Same-origin subpath, so the gate under test is the HUB nginx server.
set -uo pipefail
# ABI (D5): prefer the orchestrator-supplied AIRLOCK_ROOT/AIRLOCK_APP_ID,
# falling back to $0-relative computation for a standalone invocation.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:-$(cd "$HERE/../.." && pwd)}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-feedback}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

airlock_load feedback
BACKEND="$AIRLOCK_FEEDBACK_BACKEND_PORT"
airlock_load hub
HUB="$AIRLOCK_HUB_NGINX_PORT"
HDR="$AIRLOCK_IDENTITY_HEADER"
OWNER="${AIRLOCK_OWNER%%,*}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@"; }
c_be=$(code                                    "http://127.0.0.1:${BACKEND}/api/health")
c_api=$(code  -H "${HDR}: ${OWNER}"            "http://127.0.0.1:${HUB}/feedback/api/health")
c_deny=$(code -H "${HDR}: nobody@example.com"  "http://127.0.0.1:${HUB}/feedback/api/health")
c_no=$(code                                     "http://127.0.0.1:${HUB}/feedback/api/health")

# Which delivery targets are live (config, not a gate — reported, not asserted:
# an install may legitimately run one target, the other, or neither).
targets=$(curl -s --max-time 6 "http://127.0.0.1:${BACKEND}/api/health" \
  | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: print("unreadable"); raise SystemExit
print(f"enabled={d.get(\"enabled\")} intake={d.get(\"intake\")} mail={d.get(\"mail\")}")' 2>/dev/null)

echo "[feedback smoke] backend=${c_be}/200 api=${c_api}/200 deny=${c_deny}/403 no-header=${c_no}/403"
echo "[feedback smoke] targets: ${targets:-unreadable}"
fail=0
[ "$c_be"   = 200 ] || { echo "FAIL backend health"; fail=1; }
[ "$c_api"  = 200 ] || { echo "FAIL hub api health"; fail=1; }
[ "$c_deny" = 403 ] || { echo "FAIL other identity not denied (GATE HOLE)"; fail=1; }
[ "$c_no"   = 403 ] || { echo "FAIL missing header not denied (GATE HOLE)"; fail=1; }
[ "$fail" = 0 ]
