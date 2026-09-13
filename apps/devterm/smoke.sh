#!/usr/bin/env bash
# devterm smoke — run against a live install (after the orchestrator rendered +
# reloaded nginx). Verifies the layered gate: ttyd (PTY) -> devterm-gate (client+API)
# -> nginx owner-gate, and that identity is owner-only at every gated layer.
set -uo pipefail
# ABI (D5): the caller sets AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID and runs
# this script with cwd = AIRLOCK_APP_DIR. AIRLOCK_ROOT is REQUIRED: the platform
# root cannot be derived from $0, because "$0/../.." is only the platform when the
# package happens to sit in the platform's own apps/ tree — the arrangement the
# apps/ cutover ends. $0-relative self-location (this file's own directory) stays
# fine and is what AIRLOCK_APP_DIR falls back to.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
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

# Retired account routes stay absent even if an older orchestrator still passes the old
# feature flags. The platform service owns their positive probes; this smoke measures
# only devterm's negative side and its retained secret adapter.
c_acct_retired=$(code -H "${HDR}: ${OWNER}" "http://127.0.0.1:${BACKEND}/accounts")
c_xai_retired=$(code -H "${HDR}: ${OWNER}" "http://127.0.0.1:${BACKEND}/xai-status")
c_secret_asset=$(code -H "${HDR}: ${OWNER}" "http://127.0.0.1:${GATE}/secretdrop.js")

# fleet read-open (only when fleet_read_domain is set): the four account-STATE routes
# must answer an in-domain non-owner, and NOTHING else may. /claude-usage-store is the
# probe because it is a local file read — /claude-status and /claude-usage each make a
# live API call and would turn a gate assertion into a network flake. /acct-alert is
# the spread check: it is a GET on the same feature, so if the widening ever leaks past
# the four locations it shows up here first.
fleet_note=""
if [ -n "${AIRLOCK_DEVTERM_FLEET_READ_DOMAIN:-}" ]; then
  FDOM="${AIRLOCK_DEVTERM_FLEET_READ_DOMAIN#@}"
  c_fin=$(code   -H "${HDR}: airlock-smoke@${FDOM}"      "http://127.0.0.1:${GATE}/claude-usage-store")
  c_fout=$(code  -H "${HDR}: airlock-smoke@invalid.test" "http://127.0.0.1:${GATE}/claude-usage-store")
  c_fno=$(code                                            "http://127.0.0.1:${GATE}/claude-usage-store")
  c_fspread=$(code -H "${HDR}: airlock-smoke@${FDOM}"    "http://127.0.0.1:${GATE}/acct-alert")
  c_fbin=$(code  -H "${HDR}: airlock-smoke@${FDOM}"      "http://127.0.0.1:${BACKEND}/claude-usage-store")
  fleet_note=" | fleet-read in=${c_fin}/200 out=${c_fout}/403 no=${c_fno}/403 spread=${c_fspread}/403 backend=${c_fbin}/200"
fi

echo "[devterm smoke] ttyd=${c_ttyd}/200 | backend owner=${c_bown}/200 deny=${c_bdeny}/403 no=${c_bno}/403 sessions=${c_sess}/200 accounts=${c_acct_retired}/404 xai=${c_xai_retired}/404 | gate owner=${c_gown}/200 deny=${c_gdeny}/403 no=${c_gno}/403 secret-adapter=${c_secret_asset}/200${fleet_note}"
fail=0
[ "$c_acct_retired" = 404 ] || { echo "FAIL retired /accounts route returned on devterm"; fail=1; }
[ "$c_xai_retired" = 404 ] || { echo "FAIL retired /xai-status route returned on devterm"; fail=1; }
[ "$c_secret_asset" = 200 ] || { echo "FAIL platform secret adapter is unavailable on devterm"; fail=1; }
if [ -n "${AIRLOCK_DEVTERM_FLEET_READ_DOMAIN:-}" ]; then
  [ "${c_fin:-}"     = 200 ] || { echo "FAIL fleet read-open in-domain identity denied (the console cannot poll this box)"; fail=1; }
  [ "${c_fout:-}"    = 403 ] || { echo "FAIL fleet read-open out-of-domain identity allowed (GATE HOLE)"; fail=1; }
  [ "${c_fno:-}"     = 403 ] || { echo "FAIL fleet read-open missing header allowed (GATE HOLE)"; fail=1; }
  [ "${c_fspread:-}" = 403 ] || { echo "FAIL /acct-alert reachable by a non-owner (read-open SPREAD)"; fail=1; }
  [ "${c_fbin:-}"    = 200 ] || { echo "FAIL fleet read-open stops at the gate's own re-check (nginx says open, backend says 403)"; fail=1; }
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
