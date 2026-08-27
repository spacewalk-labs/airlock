#!/usr/bin/env bash
# Mode 644, not 755: the orchestrator runs this with `bash <path>` (install/airlock-install.sh, bin/airlock-smoke), so the executable bit
# does nothing — and the cutline policy refuses a NEW 755 file. Older apps
# carry 755 because they predate that rule, not because they need it.
# learning smoke — runs from the orchestrator AFTER nginx reload.
# NOT errexit: a smoke collects status codes and reports them all — dying on the
# first probe would hide every later failure behind the first one.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

airlock_load learning
PORT="${AIRLOCK_LEARNING_BACKEND_PORT:?}"
airlock_load hub
HUB="${AIRLOCK_HUB_NGINX_PORT:?}"
HDR="${AIRLOCK_IDENTITY_HEADER:-Tailscale-User-Login}"
OWNER="${AIRLOCK_OWNER:?}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@"; }

fail=0
note() { printf '  %s\n' "$1"; }

# 1. the backend answers on loopback at all
c_health=$(code "http://127.0.0.1:${PORT}/api/health")
[ "$c_health" = 200 ] || { note "health: expected 200, got $c_health"; fail=1; }

# 2. the list renders. 🔴 An empty library is a SUCCESS, not a failure — a fresh
#    install has no documents and the app must still answer. What would be a
#    failure is 500, which is exactly what the old build did on a folder with no
#    scripts/learn.py in it. This assertion is the ported bug's regression test.
c_items=$(code "http://127.0.0.1:${PORT}/api/items")
[ "$c_items" = 200 ] || { note "items: expected 200 on a possibly-empty library, got $c_items"; fail=1; }

# 3. the hub proxies it, and the gate is in front
c_owner=$(code -H "${HDR}: ${OWNER}" "http://127.0.0.1:${HUB}/learning/api/health")
[ "$c_owner" = 200 ] || { note "hub as owner: expected 200, got $c_owner"; fail=1; }
c_other=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${HUB}/learning/api/health")
case "$c_other" in 200) note "hub as non-owner: got 200 — the gate is not in front of /learning/"; fail=1 ;; esac

# 4. the page itself is served (the app owns its frontend; nginx only proxies)
c_page=$(code -H "${HDR}: ${OWNER}" "http://127.0.0.1:${HUB}/learning/")
[ "$c_page" = 200 ] || { note "page: expected 200, got $c_page"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "learning smoke: ok"
else
  echo "learning smoke: FAILED"
  exit 1
fi
