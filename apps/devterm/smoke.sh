#!/usr/bin/env bash
# devterm smoke — run against a live install (after the orchestrator rendered +
# reloaded nginx). Verifies the layered gate: ttyd (PTY) -> devterm-gate (client+API)
# -> nginx owner-gate, and that identity is owner-only at every gated layer.
set -uo pipefail
# ABI (D5): prefer the orchestrator-supplied AIRLOCK_ROOT/AIRLOCK_APP_ID,
# falling back to $0-relative computation for a standalone invocation.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:-$(cd "$HERE/../.." && pwd)}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-devterm}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

airlock_load devterm
TTYD="$AIRLOCK_DEVTERM_TTYD_PORT"
BACKEND="$AIRLOCK_DEVTERM_BACKEND_PORT"
GATE="$AIRLOCK_DEVTERM_GATE_PORT"
HDR="$AIRLOCK_IDENTITY_HEADER"
OWNER="${AIRLOCK_OWNER%%,*}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }
c_ttyd=$(code "http://127.0.0.1:${TTYD}/")
# devterm-gate (loopback) re-checks identity as defense-in-depth
c_bown=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${BACKEND}/")
c_bdeny=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${BACKEND}/")
c_bno=$(code                                    "http://127.0.0.1:${BACKEND}/")
# devterm-gate serves the custom client (/sessions is one of its API endpoints)
c_sess=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${BACKEND}/sessions")
# nginx owner-gate (the primary access control)
c_gown=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${GATE}/")
c_gdeny=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${GATE}/")
c_gno=$(code                                    "http://127.0.0.1:${GATE}/")

# accounts feature (only when enabled): the account/login API must be live, not a
# silent "disabled" — that is what a missing claude-switch would look like.
acct_note=""
if [ "${AIRLOCK_DEVTERM_ACCOUNTS:-false}" = true ]; then
  acct_body=$(curl -s --max-time 8 -H "${HDR}: ${OWNER}" "http://127.0.0.1:${BACKEND}/accounts")
  c_adeny=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${BACKEND}/accounts")
  case "$acct_body" in
    *'"enabled": true'*|*'"enabled":true'*) acct_ok=1 ;;
    *) acct_ok=0 ;;
  esac
  acct_note=" | accounts enabled=${acct_ok}/1 deny=${c_adeny}/403"
fi
xai_note=""
if [ "${AIRLOCK_DEVTERM_XAI:-false}" = true ]; then
  xai_body=$(curl -s --max-time 8 -H "${HDR}: ${OWNER}" "http://127.0.0.1:${BACKEND}/xai-status")
  c_xdeny=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${BACKEND}/xai-status")
  case "$xai_body" in
    *'"enabled": true'*|*'"enabled":true'*) xai_ok=1 ;;
    *) xai_ok=0 ;;
  esac
  xai_note=" | xai enabled=${xai_ok}/1 deny=${c_xdeny}/403"
fi

echo "[devterm smoke] ttyd=${c_ttyd}/200 | backend owner=${c_bown}/200 deny=${c_bdeny}/403 no=${c_bno}/403 sessions=${c_sess}/200 | gate owner=${c_gown}/200 deny=${c_gdeny}/403 no=${c_gno}/403${acct_note}${xai_note}"
fail=0
if [ "${AIRLOCK_DEVTERM_ACCOUNTS:-false}" = true ]; then
  [ "${acct_ok:-0}" = 1 ] || { echo "FAIL /accounts reports disabled (claude-switch missing?)"; fail=1; }
  [ "${c_adeny:-}" = 403 ] || { echo "FAIL /accounts other identity not denied (GATE HOLE)"; fail=1; }
fi
if [ "${AIRLOCK_DEVTERM_XAI:-false}" = true ]; then
  [ "${xai_ok:-0}" = 1 ] || { echo "FAIL /xai-status reports disabled (claude-status missing/broken?)"; fail=1; }
  [ "${c_xdeny:-}" = 403 ] || { echo "FAIL /xai-status other identity not denied (GATE HOLE)"; fail=1; }
fi
[ "$c_ttyd"  = 200 ] || { echo "FAIL ttyd direct"; fail=1; }
[ "$c_bown"  = 200 ] || { echo "FAIL backend owner not allowed"; fail=1; }
[ "$c_bdeny" = 403 ] || { echo "FAIL backend other identity not denied (GATE HOLE)"; fail=1; }
[ "$c_bno"   = 403 ] || { echo "FAIL backend missing header not denied (GATE HOLE)"; fail=1; }
[ "$c_sess"  = 200 ] || { echo "FAIL backend /sessions API"; fail=1; }
[ "$c_gown"  = 200 ] || { echo "FAIL nginx gate owner not allowed"; fail=1; }
[ "$c_gdeny" = 403 ] || { echo "FAIL nginx gate other identity not denied (GATE HOLE)"; fail=1; }
[ "$c_gno"   = 403 ] || { echo "FAIL nginx gate missing header not denied (GATE HOLE)"; fail=1; }
[ "$fail" = 0 ]
