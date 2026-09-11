#!/usr/bin/env bash
# dev-monitor smoke — against a live install (after orchestrator render + reload).
# Same-origin subpath, so the gate under test is the HUB nginx server.
set -uo pipefail
# ABI (D5): prefer the orchestrator-supplied AIRLOCK_ROOT/AIRLOCK_APP_ID,
# falling back to $0-relative computation for a standalone invocation.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-dev-monitor}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

airlock_load dev-monitor
BACKEND="$AIRLOCK_DEV_MONITOR_BACKEND_PORT"
airlock_load hub
HUB="$AIRLOCK_HUB_NGINX_PORT"
HDR="$AIRLOCK_IDENTITY_HEADER"
OWNER="${AIRLOCK_OWNER%%,*}"
want="${AIRLOCK_DEV_MONITOR_MESSAGES:-false}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@"; }
c_be=$(code                                    "http://127.0.0.1:${BACKEND}/api/overview")
c_ui=$(code   -H "${HDR}: ${OWNER}"            "http://127.0.0.1:${HUB}/monitor/")
c_api=$(code  -H "${HDR}: ${OWNER}"            "http://127.0.0.1:${HUB}/monitor/api/overview")
c_cron=$(curl -s -o /dev/null -w '%{http_code}' --max-time 35 -H "${HDR}: ${OWNER}" \
         "http://127.0.0.1:${HUB}/monitor/api/cron/jobs")
c_deny=$(code -H "${HDR}: nobody@example.com"  "http://127.0.0.1:${HUB}/monitor/api/overview")
c_no=$(code                                     "http://127.0.0.1:${HUB}/monitor/api/overview")

echo "[dev-monitor smoke] backend=${c_be}/200 ui=${c_ui}/200 api=${c_api}/200 cron=${c_cron}/200 deny=${c_deny}/403 no-header=${c_no}/403"
fail=0
[ "$c_be"   = 200 ] || { echo "FAIL backend overview"; fail=1; }
[ "$c_ui"   = 200 ] || { echo "FAIL dashboard UI"; fail=1; }
[ "$c_api"  = 200 ] || { echo "FAIL hub api overview"; fail=1; }
[ "$c_cron" = 200 ] || { echo "FAIL cron snapshot"; fail=1; }
[ "$c_deny" = 403 ] || { echo "FAIL other identity not denied (GATE HOLE)"; fail=1; }
[ "$c_no"   = 403 ] || { echo "FAIL missing header not denied (GATE HOLE)"; fail=1; }

# --- cron/timer health + bounded owner controls ---
cron_body=$(curl -s --max-time 35 -H "${HDR}: ${OWNER}" \
            "http://127.0.0.1:${HUB}/monitor/api/cron/jobs" || true)
cron_shape=$(python3 - "$cron_body" <<'PY' 2>&1 || true
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception as exc:
    print('FAIL cron snapshot is not JSON: %s' % exc); raise SystemExit
if data.get('schemaVersion') != 3:
    print('FAIL cron schemaVersion=%r' % data.get('schemaVersion')); raise SystemExit
if not isinstance(data.get('jobs'), list) or not isinstance(data.get('counts'), dict):
    print('FAIL cron jobs/counts shape'); raise SystemExit
if not isinstance(data.get('sources'), list) or not data['sources']:
    print('FAIL cron sources are absent'); raise SystemExit
print('OK jobs=%d sources=%d' % (len(data['jobs']), len(data['sources'])))
PY
)
echo "[dev-monitor smoke] cron shape: ${cron_shape}"
case "$cron_shape" in OK*) ;; *) fail=1 ;; esac

# Scheduled jobs are read-only: the dashboard shows them and never starts, pauses or
# resumes them. This asserts the absence, because absence is what can silently regress.
# The request below clears every gate the owner console has — ingress owner identity,
# nginx-injected proxy secret, same origin, JSON body — so with the console enabled a
# 404 can only mean the route is not there; a restored route would answer 200/400/403
# from its own handler. With the console disabled the same 404 arrives one gate earlier,
# so the check is correct either way and needs no branch.
c_cron_write=$(code -X POST -H "${HDR}: ${OWNER}" -H 'Content-Type: application/json' \
  -H "Origin: http://127.0.0.1:${HUB}" --data '{"unit":"airlock-not-a-real-user.timer"}' \
  "http://127.0.0.1:${HUB}/monitor/api/owner/cron/pause")
echo "[dev-monitor smoke] cron is read-only: write route=${c_cron_write}/404 (console=${want})"
[ "$c_cron_write" = 404 ] || {
  echo "FAIL a cron write route answered ${c_cron_write}; scheduled jobs must stay read-only"; fail=1; }

# --- credential freshness ---
# Same shape as the console check below: `state` is what the backend actually managed to
# start, not what the config asked for, so a requested-but-broken feature reads as off
# here and is caught. The route is asserted both ways round — with the feature off it must
# 404 rather than answer an empty provider list, which would render as "nothing wrong".
tok_state=$(curl -s --max-time 6 "http://127.0.0.1:${BACKEND}/api/health" \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token_freshness","?"))' 2>/dev/null || echo '?')
tok_want="${AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS:-false}"
c_tok=$(code -H "${HDR}: ${OWNER}" "http://127.0.0.1:${HUB}/monitor/api/tokens")
echo "[dev-monitor smoke] token freshness: configured=${tok_want} running=${tok_state} route=${c_tok}"
if [ "$tok_want" = true ]; then
  [ "$tok_state" = on ] || { echo "FAIL token_freshness = true but the checker did not load (see journalctl --user -u airlock-dev-monitor)"; fail=1; }
  [ "$c_tok" = 200 ] || { echo "FAIL token_freshness is on but /monitor/api/tokens answered ${c_tok}"; fail=1; }
  # The card is on; the CHECKING is separate. A card that only ever shows a live reading
  # looks identical whether the timer ran this morning or was never installed.
  systemctl --user list-timers airlock-token-freshness.timer --no-pager --no-legend 2>/dev/null | grep -q . \
    || echo "WARN token_freshness is on but no airlock-token-freshness.timer is wired — the card shows a live reading and nothing checks on a schedule (bash apps/dev-monitor/install-token-timer.sh)"
else
  [ "$c_tok" = 404 ] || { echo "FAIL token freshness is off but its route answered ${c_tok}"; fail=1; }
fi

# --- message/action console ---
# `messages` here is what the backend actually managed to start, not what the config
# asked for; a requested-but-unconfigured install reports "off" and is caught below.
health_json=$(curl -s --max-time 6 "http://127.0.0.1:${BACKEND}/api/health" || true)
state=$(printf '%s' "$health_json" \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("messages","?"))' 2>/dev/null || echo '?')
echo "[dev-monitor smoke] messages: configured=${want} running=${state}"
if [ "$want" = true ]; then
  [ "$state" = on ] || { echo "FAIL messages = true but the console did not start (see journalctl --user -u airlock-dev-monitor)"; fail=1; }
  # The whole point of the proxy secret: reaching the loopback port directly must not be
  # enough, even while carrying a correct-looking owner header. If this returns 200 the
  # nginx fragment and the running backend disagree about the secret, or the gate is off.
  c_direct=$(code -H 'X-Devmon-Owner: '"${OWNER}" "http://127.0.0.1:${BACKEND}/api/owner/messages/preview")
  c_owner=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/monitor/api/owner/messages/preview")
  c_other=$(code  -H "${HDR}: nobody@example.com" "http://127.0.0.1:${HUB}/monitor/api/owner/messages/preview")
  # Client-supplied X-Devmon-* must not survive nginx, which REPLACES both headers.
  # Sent with the owner's own identity on purpose: a non-owner identity is rejected by the
  # hub's server-level gate before any location is chosen, so that probe would prove the hub
  # gate works and say nothing about the override. Here nginx must overwrite the forged
  # owner with the real one and the forged secret with the real one — so a 200 is the pass.
  # If either header were passed through, the backend would see owner=nobody and answer 403.
  c_forge=$(code  -H "${HDR}: ${OWNER}" -H 'X-Devmon-Owner: nobody@example.com' \
                  -H 'X-Devmon-Proxy-Secret: forged' "http://127.0.0.1:${HUB}/monitor/api/owner/messages/preview")
  echo "[dev-monitor smoke] owner routes: direct=${c_direct}/403 owner=${c_owner}/200 other=${c_other}/403 forged=${c_forge}/200"
  [ "$c_direct" = 403 ] || { echo "FAIL loopback bypassed the proxy secret (GATE HOLE)"; fail=1; }
  [ "$c_owner"  = 200 ] || { echo "FAIL owner cannot read the console through the hub"; fail=1; }
  [ "$c_other"  = 403 ] || { echo "FAIL a non-owner reached the console (GATE HOLE)"; fail=1; }
  [ "$c_forge"  = 200 ] || { echo "FAIL nginx did not replace a client-supplied X-Devmon-* header (GATE HOLE)"; fail=1; }
  # Verify the unread badge and the card contract through the authenticated API.
  preview_body=$(curl -s --max-time 6 -H "${HDR}: ${OWNER}" \
                 "http://127.0.0.1:${HUB}/monitor/api/owner/messages/preview" || true)
  # The body arrives as argv, not on stdin: the heredoc IS stdin for `python3 -`, so a pipe
  # into it would be swallowed and every card would look absent.
  preview_check=$(python3 - "$preview_body" <<'PY' 2>&1 || true
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception as e:
    print('FAIL preview is not JSON: %s' % e); raise SystemExit
if type(d.get('unread_count')) is not int or d['unread_count'] < 0:
    print('FAIL preview unread_count must be a nonnegative integer'); raise SystemExit
if not isinstance(d.get('messages'), list):
    print('FAIL preview messages must be a list'); raise SystemExit
for card in d['messages']:
    if card.get('level') not in ('normal', 'urgent') or not isinstance(card.get('body'), str):
        print('FAIL preview card level/body contract'); raise SystemExit
    if any(key in card for key in ('needs_action', 'task_state', 'urgency')):
        print('FAIL preview contains retired card fields'); raise SystemExit
visible = sum(c.get('read_at') is None for c in d['messages'])
if d['unread_count'] < visible:
    print('FAIL preview unread count is below visible unread cards'); raise SystemExit
print('OK unread=%d cards=%d' % (d['unread_count'], len(d['messages'])))
PY
)
  echo "[dev-monitor smoke] preview shape: ${preview_check}"
  case "$preview_check" in OK*) ;; *) fail=1 ;; esac
  command -v tmux >/dev/null || echo "WARN tmux is absent — cards still arrive, but approved actions cannot run"
else
  c_off=$(code -H "${HDR}: ${OWNER}" "http://127.0.0.1:${HUB}/monitor/api/owner/messages/preview")
  echo "[dev-monitor smoke] console off: owner route=${c_off}/404"
  [ "$c_off" = 404 ] || { echo "FAIL console is off but its route answered ${c_off}"; fail=1; }
fi

# Configuration presence and the single outbox state, without credential output.
delivery_result=$(python3 - "$BACKEND" "$HOME/.config/airlock/dev-monitor.env" "$HERE/check-secrets.py" "$HOME/.config/airlock/dev-monitor-secrets.env" 2>&1 <<'DEVMON_DELIVERY_PY'
import json
import sys
import urllib.request
import subprocess
from pathlib import Path
configured = {}
if Path(sys.argv[2]).exists():
    for line in Path(sys.argv[2]).read_text().splitlines():
        key, separator, value = line.partition('=')
        if separator: configured[key] = value.strip()
selector = configured.get('DEVMON_SLACK_WEBHOOK_NAME', '')
command = [sys.executable, sys.argv[3], '--file', sys.argv[4], '--lane', 'slack-urgent', '--selector', selector]
if selector: command += ['--allow', selector]
result = subprocess.run(command, capture_output=True)
assert result.returncode in (0, 1), 'cannot check app-only credential configuration'
with urllib.request.urlopen('http://127.0.0.1:%s/api/health' % sys.argv[1], timeout=6) as response:
    health = json.load(response)
assert health['slack'] == ('configured' if result.returncode == 0 else 'not configured'), 'Slack configuration mismatch'
for key in ('pending_count', 'failed_count'):
    assert type(health[key]) is int and health[key] >= 0, key
assert health['last_sent_at'] is None or isinstance(health['last_sent_at'], str)
print('single Slack configuration/outbox shape ok')
DEVMON_DELIVERY_PY
)
delivery_rc=$?
echo "[dev-monitor smoke] delivery: ${delivery_result}"
[ "$delivery_rc" = 0 ] || { echo "FAIL delivery health shape mismatch"; fail=1; }
[ "$fail" = 0 ]
