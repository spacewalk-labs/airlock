#!/usr/bin/env bash
# live/alarm.sh — what happens when the weekly verification does not succeed.
#
# Started by systemd through `OnFailure=` on airlock-live-verify.service, i.e.
# AFTER that unit has already failed. That is the whole design: anything that had
# to run inside the failing unit would have died with it.
#
# It has two jobs, and it must do the first even when it cannot do the second.
#
#   1. Leave evidence on this box, in a file, that a watchdog somewhere else can
#      see. `LAST-RUN` is written by every run whatever the verdict; `LAST-GREEN`
#      only by a run that passed. A stale LAST-RUN and a fresh-but-red one are
#      different failures and the split is the only way to tell them apart.
#   2. Say so where people already look.
#
# Job 2 is allowed to fail. Job 1 is not, so it happens first.
#
# This fleet has seven recorded cases of a scheduled job dying silently — 29 days,
# 9 days, three weeks. One of them was a timer that had been committed and never
# installed. An alarm that has never been fired on purpose is a belief, so
# install/test-live-timer.sh fires this one deliberately.
set -uo pipefail

RESULT_DIR="${AIRLOCK_LIVE_RESULT_DIR:-$HOME/.local/state/airlock-live}"
mkdir -p "$RESULT_DIR"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- job 1: the local evidence -------------------------------------------------
{
  printf 'airlock-live-verify.service failed at %s\n' "$NOW"
  printf '\n'
  printf 'last run:   %s\n' "$(cat "$RESULT_DIR/LAST-RUN" 2>/dev/null || echo '(never)')"
  printf 'last green: %s\n' "$(cat "$RESULT_DIR/LAST-GREEN" 2>/dev/null || echo '(never)')"
  printf '\n'
  printf 'journal:\n'
  # --user, because this is a user unit. Without it journalctl reads the system
  # journal, finds nothing, and the alarm arrives empty — which reads exactly like
  # "the failure left no trace".
  journalctl --user -u airlock-live-verify.service -n 60 --no-pager 2>&1 \
    || printf '  (journal unreadable)\n'
} > "$RESULT_DIR/LAST-FAILURE"
printf '%s\n' "$NOW" > "$RESULT_DIR/FAILING"

# --- job 2: tell someone -------------------------------------------------------
# Best effort by design. If this cannot reach GitHub, the file above is still
# there and the freshness check that runs on GitHub's side will notice the missing
# result on its own schedule. Two independent paths, neither trusted to be the one
# that works.
if [ -n "${AIRLOCK_LIVE_ISSUE:-}" ] && command -v gh >/dev/null 2>&1; then
  body="$RESULT_DIR/alarm-comment.md"
  {
    printf '## ⚠️ weekly live verification FAILED\n\n'
    printf '`airlock-live-verify.service` failed at `%s`.\n\n' "$NOW"
    printf '| | |\n|---|---|\n'
    printf '| last run | `%s` |\n' "$(cat "$RESULT_DIR/LAST-RUN" 2>/dev/null || echo 'never')"
    printf '| last green | `%s` |\n' "$(cat "$RESULT_DIR/LAST-GREEN" 2>/dev/null || echo 'never')"
    printf '\n'
    printf 'The unredacted journal and result are on the box that ran it, at\n'
    printf '`LAST-FAILURE` in the result directory. They are not posted here: a failed\n'
    printf 'run tends to fail loudly, and loud output on this box contains hostnames.\n'
  } > "$body"
  gh issue comment "$AIRLOCK_LIVE_ISSUE" --body-file "$body" >/dev/null 2>&1 \
    || printf 'could not post the alarm to issue %s at %s\n' "$AIRLOCK_LIVE_ISSUE" "$NOW" \
         >> "$RESULT_DIR/PUBLISH-FAILING"
fi

# Exit 0. This unit's job is to report a failure, and a reporter that fails because
# the thing it reported failed is just noise in the journal.
exit 0
