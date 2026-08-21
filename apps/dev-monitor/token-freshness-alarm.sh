#!/usr/bin/env bash
# token-freshness-alarm.sh — what happens when the freshness check itself does not run.
#
# Started by systemd through OnFailure= on airlock-token-freshness.service, i.e. AFTER
# that unit has already failed. Anything that had to run inside the failing unit would
# have died with it — the same reasoning live/alarm.sh records.
#
# A watchdog that dies quietly is worse than no watchdog: the dashboard card keeps
# showing the last verdict it ever wrote, and the last verdict was green. So this has
# two jobs, and it must do the first even when it cannot do the second.
#
#   1. Leave evidence in a file on this box. Always.
#   2. Publish an urgent card into the message console, where people already look.
#
# Job 2 is allowed to fail. Job 1 is not, so it happens first.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SNAPSHOT="${DEV_MONITOR_TOKEN_SNAPSHOT:-$HOME/.local/state/airlock/dev-monitor/token-freshness.json}"
RESULT_DIR="$(dirname "$SNAPSHOT")"
mkdir -p "$RESULT_DIR"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- job 1: the local evidence -------------------------------------------------------
{
  printf 'airlock-token-freshness.service failed at %s\n\n' "$NOW"
  printf 'last snapshot: %s\n' \
    "$(stat -c '%y' "$SNAPSHOT" 2>/dev/null || echo '(never written)')"
  printf '\njournal:\n'
  # --user, because this is a user unit. Without it journalctl reads the system journal,
  # finds nothing, and the alarm reads exactly like "the failure left no trace".
  journalctl --user -u airlock-token-freshness.service -n 60 --no-pager 2>&1 \
    || printf '  (journal unreadable)\n'
} > "$RESULT_DIR/TOKEN-FRESHNESS-LAST-FAILURE"

# --- job 2: tell someone -------------------------------------------------------------
# Through the producer contract, not a second copy of it. A missing spool means this box
# has no message console; the evidence file above is then the whole alarm, which is the
# arrangement the operator chose when they left messages off.
if [ -n "${DEV_MONITOR_SPOOL:-}" ] && [ -d "$DEV_MONITOR_SPOOL/new" ]; then
  python3 "$HERE/examples/emit_message.py" \
    --spool "$DEV_MONITOR_SPOOL" \
    --source token-freshness \
    --group-key token-freshness:watchdog \
    --kind info --urgency urgent \
    --title "Credential freshness check FAILED — expiry is no longer being watched" \
    --body "airlock-token-freshness.service failed at ${NOW}. See TOKEN-FRESHNESS-LAST-FAILURE in ${RESULT_DIR}." \
    --outcome "The periodic credential check did not complete." \
    --why "While it is down the dashboard card keeps showing the last verdict it managed to write, and that verdict ages silently." \
    --followup "systemctl --user status airlock-token-freshness.service" \
    >/dev/null 2>>"$RESULT_DIR/TOKEN-FRESHNESS-PUBLISH-FAILING" || true
fi

# Exit 0: a reporter that fails because the thing it reported failed is just noise.
exit 0
