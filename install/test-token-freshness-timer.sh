#!/usr/bin/env bash
# install/test-token-freshness-timer.sh — the credential-freshness wiring.
#
# Same rule as install/test-live-timer.sh: **if the absence of a run does not turn
# something red, the run is not implemented.** A token expiry watchdog that dies quietly
# is worse than none at all, because the dashboard card then keeps showing the last
# verdict it managed to write — and the last verdict was green.
#
# So this suite is about the unit templates staying templates, the substitution leaving
# nothing behind, the failure path existing, and the installer refusing the states that
# make a timer fail forever for reasons that have nothing to do with airlock.
#
# Offline: renders into a temp dir, never installs anything and never touches systemd's
# state. `systemd-analyze verify` is used when it is present, and its absence is
# reported rather than skipped in silence.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
UNITS="$ROOT/apps/dev-monitor/systemd"
pass=0; fail=0
ok()  { echo "ok   token-timer: $1"; pass=$((pass+1)); }
bad() { echo "FAIL token-timer: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

S="$UNITS/airlock-token-freshness.service.in"
T="$UNITS/airlock-token-freshness.timer.in"
F="$UNITS/airlock-token-freshness-failed.service.in"

# ---------------------------------------------------------------- the templates
grep -q '^Persistent=true' "$T" \
  && ok "the timer is Persistent — a box that was asleep catches up instead of skipping" \
  || bad "the timer is not Persistent=true: a missed check would be silent, and a missed expiry check is indistinguishable from a passing one"
grep -q '^OnFailure=airlock-token-freshness-failed.service' "$S" \
  && ok "the service has an OnFailure handler" \
  || bad "the service has no OnFailure — the watchdog dying would be silent"
grep -q '^Environment=PATH=' "$S" \
  && ok "the service states its own PATH (a timer-driven session does not inherit one)" \
  || bad "the service inherits PATH from a non-interactive session"
grep -q '^TimeoutStartSec=' "$S" \
  && ok "the service has a timeout — a hung check must not hold the slot forever" \
  || bad "the service has no TimeoutStartSec"
grep -q '^WorkingDirectory=@REPO@' "$F" \
  && ok "the alarm unit has a WorkingDirectory" \
  || bad "the alarm unit has no WorkingDirectory"
for f in "$S" "$T" "$F"; do
  grep -q '@[A-Z]*@' "$f" \
    || bad "$(basename "$f") has no placeholders — a site path may have been baked in"
done
ok "every unit template is still a template (nothing site-specific is committed)"

# A hostname in this tree is a leak — it is mirrored to a public repository. That scan is
# install/check-internal-leaks.sh and it already covers the whole tree; a second copy of
# its pattern list here would be one more place for the list to drift, and (measured)
# would itself trip the real scanner.

# ---------------------------------------------------------------- substitution
# The check the installer performs at wiring time, performed here against the same sed
# so a template that grows a placeholder nobody substitutes is caught before the box is.
render() {
  sed -e "s|@REPO@|/opt/example/airlock|g" -e "s|@SPOOLFLAG@|--spool /tmp/spool|g" \
      -e "s|@SPOOL@|/tmp/spool|g" \
      -e "s|@SNAPSHOT@|/tmp/token-freshness.json|g" -e "s|@PYTHON@|/usr/bin/python3|g" \
      -e "s|@WARNHOURS@|24|g" -e "s|@STALEHOURS@|24|g" -e "s|@ONCALENDAR@|00/12:00:00|g" \
      "$1" > "$2"
}
left=0
for f in "$S" "$T" "$F"; do
  out="$TMP/$(basename "${f%.in}")"
  render "$f" "$out"
  if grep -q '@[A-Z]*@' "$out"; then
    bad "$(basename "$f"): substitution left a placeholder behind: $(grep -o '@[A-Z]*@' "$out" | sort -u | tr '\n' ' ')"
    left=1
  fi
done
[ "$left" = 0 ] && ok "substitution leaves no @PLACEHOLDER@ in any rendered unit"

# A positive control: the assertion above only means something if it can fail.
printf '[Unit]\nDescription=x @NOTSUBSTITUTED@\n' > "$TMP/control.service"
grep -q '@[A-Z]*@' "$TMP/control.service" \
  && ok "the placeholder assertion is capable of failing (positive control)" \
  || bad "the placeholder assertion cannot detect a placeholder"

if command -v systemd-analyze >/dev/null 2>&1; then
  # --user, because these are user units; --recursive-errors=no keeps the verdict about
  # THESE files rather than about whatever they happen to reference on the runner.
  out="$(systemd-analyze --user verify --recursive-errors=no \
          "$TMP/airlock-token-freshness.service" \
          "$TMP/airlock-token-freshness.timer" \
          "$TMP/airlock-token-freshness-failed.service" 2>&1)"
  rc=$?
  # A unit referencing an ExecStart that does not exist on THIS box is expected — the
  # fixture path is fictional. Only syntax/directive complaints are the suite's business.
  filtered="$(printf '%s' "$out" | grep -v 'Command .* is not executable' \
                                 | grep -v 'not found' | grep -v '^$')"
  if [ -z "$filtered" ]; then
    ok "systemd-analyze verify accepts the rendered units"
  else
    bad "systemd-analyze verify complained (rc=$rc): $filtered"
  fi
else
  # Not a silent skip: the gate says out loud that it could not reach a verdict.
  echo "note token-timer: systemd-analyze is absent — unit syntax was NOT verified here"
fi

# ---------------------------------------------------------------- the installer
# It must refuse the states that make a timer fail forever.
out="$(cd "$ROOT" && bash apps/dev-monitor/install-token-timer.sh --warn-hours nope 2>&1)"; rc=$?
[ "$rc" != 0 ] \
  && ok "install-token-timer refuses a non-numeric threshold" \
  || bad "install-token-timer accepted --warn-hours nope"
if [ -f "$ROOT/.git" ]; then
  out="$(cd "$ROOT" && bash apps/dev-monitor/install-token-timer.sh 2>&1)"
  printf '%s' "$out" | grep -q 'worktree' \
    && ok "install-token-timer refuses a git worktree (it gets reclaimed, and then the job fails on every tick)" \
    || bad "install-token-timer did not refuse a worktree: $out"
else
  # A permanent clone: prove the spool refusal instead, which is the other way this
  # timer can be wired into silence.
  out="$(cd "$ROOT" && bash apps/dev-monitor/install-token-timer.sh --spool "$TMP/absent-spool" 2>&1)"
  printf '%s' "$out" | grep -q 'spool not found' \
    && ok "install-token-timer refuses to wire a timer whose loud channel does not exist" \
    || bad "install-token-timer accepted a missing spool: $out"
fi

# ---------------------------------------------------------------- the declarations
# The config keys the unit and the installer read must be DECLARED, or airlock-config
# rejects them in the operator's airlock.toml while the code keeps reading a default.
for key in token_freshness token_freshness_warn_hours token_freshness_stale_hours; do
  grep -q "^$key = " "$ROOT/apps/dev-monitor/airlock-app.toml" \
    && ok "$key is declared in the dev-monitor manifest" \
    || bad "$key is read by the code but not declared in airlock-app.toml"
done

# And CI has to run this file, or none of the above is load-bearing.
grep -q 'install/test-token-freshness-timer.sh' "$ROOT/.github/workflows/ci.yml" \
  && ok "ci.yml runs this suite" \
  || bad "ci.yml does not run install/test-token-freshness-timer.sh"

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
