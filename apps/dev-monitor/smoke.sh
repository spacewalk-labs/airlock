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

# With the existing owner console enabled, a direct loopback POST cannot forge nginx's
# secret and an unknown timer must be rejected without mutation. With it disabled, cron
# writes stay behind the same fail-closed 404 as every other owner-only route.
c_cron_direct=$(code -X POST -H 'Content-Type: application/json' \
  -H 'Origin: http://127.0.0.1' -H "X-Devmon-Owner: ${OWNER}" \
  --data '{"unit":"airlock-not-a-real-user.timer"}' \
  "http://127.0.0.1:${BACKEND}/api/owner/cron/pause")
c_cron_refuse=$(code -X POST -H "${HDR}: ${OWNER}" -H 'Content-Type: application/json' \
  -H "Origin: http://127.0.0.1:${HUB}" --data '{"unit":"airlock-not-a-real-user.timer"}' \
  "http://127.0.0.1:${HUB}/monitor/api/owner/cron/pause")
if [ "$want" = true ]; then
  echo "[dev-monitor smoke] cron controls: direct=${c_cron_direct}/403 unknown-user-timer=${c_cron_refuse}/403"
  [ "$c_cron_direct" = 403 ] || { echo "FAIL direct loopback bypassed the cron owner gate"; fail=1; }
  [ "$c_cron_refuse" = 403 ] || { echo "FAIL cron mutation allowlist did not refuse an unknown user timer"; fail=1; }
else
  echo "[dev-monitor smoke] cron controls off: direct=${c_cron_direct}/404 hub=${c_cron_refuse}/404"
  [ "$c_cron_direct" = 404 ] || { echo "FAIL messages is off but direct cron control answered ${c_cron_direct}"; fail=1; }
  [ "$c_cron_refuse" = 404 ] || { echo "FAIL messages is off but hub cron control answered ${c_cron_refuse}"; fail=1; }
fi

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
  # A 200 says the gate let us in; it says nothing about what came back. The badge on every
  # tool in this hub is drawn from this one response, so its SHAPE is the contract: a missing
  # needs_action_count reads as zero at the widget and is indistinguishable from "nothing to
  # do" — the exact failure this phase exists to remove.
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
for key in ('needs_action_count', 'unread_count'):
    if not isinstance(d.get(key), int) or isinstance(d.get(key), bool):
        print('FAIL preview %s is %r, want an integer' % (key, d.get(key))); raise SystemExit
if not isinstance(d.get('messages'), list):
    print('FAIL preview messages is %r, want a list' % type(d.get('messages'))); raise SystemExit
for card in d['messages']:
    for key in ('needs_action', 'task_state'):
        if key not in card:
            print('FAIL preview card %s has no %s' % (card.get('card_id'), key)); raise SystemExit
    if card['needs_action'] not in (True, False, None):
        print('FAIL preview needs_action is %r' % card['needs_action']); raise SystemExit
# The preview is capped, so its cards cannot prove the total — but a total below what is
# visible here can only be a broken count.
visible = sum(1 for c in d['messages']
              if c['needs_action'] and c.get('task_state') in (None, 'todo'))
if d['needs_action_count'] < visible:
    print('FAIL preview needs_action_count=%d but %d of the returned cards need a person'
          % (d['needs_action_count'], visible)); raise SystemExit
print('OK needs-me=%d unread=%d cards=%d' % (d['needs_action_count'], d['unread_count'],
                                             len(d['messages'])))
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

# The scalar above says whether the console started; this object proves each independent
# delivery lane is wired and that its DB-derived values are internally consistent.
lane_result=$(python3 - "$want" "$HOME/.config/airlock/dev-monitor.env" "$BACKEND" "$HERE/backend" 2>&1 <<'PY'
import datetime as dt
import json
import sqlite3
import sys
import time
import urllib.request

sys.path.insert(0, sys.argv[4])
import devmon_email
import devmon_messages as messages

configured = {}
try:
    with open(sys.argv[2], encoding="utf-8") as env_file:
        for raw in env_file:
            key, separator, value = raw.rstrip("\n").partition("=")
            if separator:
                configured[key] = value.strip()
except FileNotFoundError:
    pass
off = "off: no webhook configured"
expected_workers = {
    "slack-urgent": off,
    "slack-routine": off,
    "email": "off: no transport configured",
}
if sys.argv[1] == "true":
    if configured.get("AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT") or configured.get("AIRLOCK_DEVMON_SLACK_WEBHOOK"):
        expected_workers["slack-urgent"] = "on"
    if configured.get("AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE"):
        expected_workers["slack-routine"] = "on"
    if devmon_email.config_from_env(configured) is not None:
        expected_workers["email"] = "on"
fields = {
    "worker_state", "delivery_state", "last_success_at", "last_success_age_seconds", "pending_count",
    "oldest_pending_age_seconds", "last_error", "last_error_at",
    "consecutive_failures", "terminal_failures_since_success",
    "ledger_error_count",
}

def check_once():
    now = dt.datetime.now(dt.timezone.utc)
    expected_delivery = None
    if sys.argv[1] == "true":
        db_path = configured.get("DEV_MONITOR_DB")
        assert db_path, "missing DB path"
        messages._local.__dict__.clear()
        messages._DB_PATH = db_path
        try:
            expected_delivery = {
                lane: messages.delivery_lane_health(lane, now)
                for lane in expected_workers
            }
        finally:
            messages._local.__dict__.clear()
    with urllib.request.urlopen(
            "http://127.0.0.1:%s/api/health" % sys.argv[3], timeout=6) as response:
        health = json.load(response)
    lanes = health.get("message_lanes")
    assert isinstance(lanes, dict) and set(lanes) == set(expected_workers), "lane keys"
    for lane, worker in expected_workers.items():
        value = lanes[lane]
        assert isinstance(value, dict) and set(value) == fields, lane + " shape"
        assert value["worker_state"] == worker, lane + " worker_state"
        if expected_delivery is None:
            expected = {
                "delivery_state": "idle", "last_success_at": None,
                "last_success_age_seconds": None,
                "pending_count": 0, "oldest_pending_age_seconds": None,
                "last_error": None, "last_error_at": None,
                "consecutive_failures": 0,
                "terminal_failures_since_success": 0,
                "ledger_error_count": 0,
            }
        else:
            expected = expected_delivery[lane]
        for key, expected_value in expected.items():
            actual = value[key]
            if key == "oldest_pending_age_seconds" and actual is not None:
                assert expected_value is not None and abs(actual - expected_value) <= 3, lane + " pending age"
            else:
                assert actual == expected_value, lane + " " + key

failure = "unknown mismatch"
for _ in range(3):
    try:
        check_once()
        print("ok")
        break
    except (AssertionError, OSError, sqlite3.Error, ValueError) as exc:
        failure = str(exc) or type(exc).__name__
        time.sleep(0.1)
else:
    print(failure)
    raise SystemExit(1)
PY
)
lane_rc=$?
echo "[dev-monitor smoke] message lanes: ${lane_result}"
[ "$lane_rc" = 0 ] || { echo "FAIL per-lane health shape/value mismatch"; fail=1; }
[ "$fail" = 0 ]
