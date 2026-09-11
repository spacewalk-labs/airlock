#!/usr/bin/env bash
# Test airlock_sweep_platform_units: platform units this tree no longer declares are
# retired, and nothing else is touched.
#
# Offline by construction. A fake `systemctl` on PATH records its arguments instead of
# talking to a user manager, and AIRLOCK_UNIT_DIR_USER points at a scratch directory — so
# this never reads or writes the box's real units. The pattern (and the reason) is
# install/test-selfkill-escape.sh's fake runner.
#
# The controls matter more than the happy path here. A sweep that deletes nothing passes a
# "did it leave the right files alone?" test perfectly, so T1 fails when nothing is
# removed, and T5 proves the suite itself can go red.
set -euo pipefail

# This suite does NOT run any installer — it sources install/lib.sh and calls one
# function. The pin is here because test-render-parity.sh's RAM-pin gate is a text scan
# for `airlock-install.sh` in non-comment lines, and T7 below names that file in order to
# `grep` it. Satisfying the gate costs one harmless export; teaching it to tell "runs the
# installer" from "reads the installer" would make a deliberately conservative check
# cleverer, and the failure it would gain is the silent kind. If this suite ever does run
# an installer, the pin is already correct.
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
bad() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
ok() { printf 'ok: %s\n' "$*"; }
# A block that loops calls bad() per item and then printed its ok() unconditionally, so a
# failing run said both FAIL and ok for the same check. The exit code was still 1, but the
# output lied about which checks held — and the output is what a person reads.
mark() { _mark=$fails; }
ok_if_clean() { [ "$fails" = "$_mark" ] && ok "$*"; }

# ---- fake systemctl: records the calls, never touches the box ----
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
case "$*" in
  '--user list-timers airlock-live-verify.timer --no-pager --no-legend')
    printf 'Mon 2026-09-14 09:00:00 UTC 6 days left airlock-live-verify.timer\n'
    ;;
esac
exit 0
FAKE
cat > "$TMP/bin/loginctl" <<'FAKE'
#!/usr/bin/env bash
printf 'yes\n'
FAKE
chmod +x "$TMP/bin/systemctl" "$TMP/bin/loginctl"
export PATH="$TMP/bin:$PATH"

# ---- a unit directory holding one of each interesting kind ----
seed_units() {
  local dir="$1"
  rm -rf "$dir"; mkdir -p "$dir"
  # declared, ours -> must survive
  printf '[Unit]\nDescription=d\nX-Airlock-Owner=airlock-install\n' > "$dir/airlock-secret-sweep.service"
  printf '[Unit]\nDescription=d\nX-Airlock-Owner=airlock-install\n' > "$dir/airlock-secret-sweep.timer"
  # ours, NOT declared -> must be removed (this is the whole point)
  printf '[Unit]\nDescription=d\nX-Airlock-Owner=airlock-install\n' > "$dir/airlock-retired-thing.service"
  printf '[Unit]\nDescription=d\nX-Airlock-Owner=airlock-install\n' > "$dir/airlock-retired-thing.timer"
  # another installer's platform unit -> must survive (live/install-timer.sh owns it)
  printf '[Unit]\nDescription=d\nX-Airlock-Owner=airlock-live\n' > "$dir/airlock-live-verify.timer"
  # an APP unit: same airlock- prefix, no marker -> must survive (D6 owns it)
  printf '[Unit]\nDescription=d\n' > "$dir/airlock-devterm.service"
  # a stranger's unit -> must survive
  printf '[Unit]\nDescription=d\n' > "$dir/some-other.service"
}

run_sweep() {
  # shellcheck source=/dev/null
  ( set -euo pipefail
    . "$ROOT/install/lib.sh"
    AIRLOCK_UNIT_DIR_USER="$1" airlock_sweep_platform_units airlock-install \
      airlock-secret-sweep.service airlock-secret-sweep.timer \
      airlock-update-detect.service airlock-update-detect.timer
  ) >"$TMP/out" 2>&1
}

UD="$TMP/units"
export FAKE_SYSTEMCTL_LOG="$TMP/systemctl.log"
: > "$FAKE_SYSTEMCTL_LOG"
seed_units "$UD"
run_sweep "$UD" || bad "sweep exited non-zero: $(cat "$TMP/out")"

# ---- T1 (positive): the undeclared marked units are gone ----
gone=1
for u in airlock-retired-thing.service airlock-retired-thing.timer; do
  [ -e "$UD/$u" ] && { gone=0; bad "T1: $u survived the sweep — an orphan was not retired"; }
done
[ "$gone" = 1 ] && ok "T1: undeclared platform units were removed"

mark
# ---- T2: the sweep actually asked systemd to stop them, not just unlinked ----
for u in airlock-retired-thing.service airlock-retired-thing.timer; do
  grep -q -- "--user disable --now $u" "$FAKE_SYSTEMCTL_LOG" \
    || bad "T2: no 'disable --now $u' — the file went away but the unit could still be loaded"
done
grep -q -- "--user daemon-reload" "$FAKE_SYSTEMCTL_LOG" \
  || bad "T2: no daemon-reload after removing units"
ok_if_clean "T2: disable --now + daemon-reload were issued"

mark
# ---- T3 (negative): declared units, another owner's unit, and unmarked units survive ----
for u in airlock-secret-sweep.service airlock-secret-sweep.timer \
         airlock-live-verify.timer airlock-devterm.service some-other.service; do
  [ -e "$UD/$u" ] || bad "T3: $u was deleted and must not have been"
done
ok_if_clean "T3: declared, other-owner, and unmarked units all survived"

# ---- T4: timers are disabled before services ----
t_line="$(grep -n -- "disable --now airlock-retired-thing.timer" "$FAKE_SYSTEMCTL_LOG" | cut -d: -f1 | head -1)"
s_line="$(grep -n -- "disable --now airlock-retired-thing.service" "$FAKE_SYSTEMCTL_LOG" | cut -d: -f1 | head -1)"
if [ -n "$t_line" ] && [ -n "$s_line" ] && [ "$t_line" -lt "$s_line" ]; then
  ok "T4: the timer was disabled before its service"
else
  bad "T4: expected the timer disabled before the service (timer=$t_line service=$s_line)"
fi

# ---- T5 (the control on the controls): an empty declared set is fatal, not a wipe ----
seed_units "$UD"
if ( set -euo pipefail
     # shellcheck source=/dev/null
     . "$ROOT/install/lib.sh"
     AIRLOCK_UNIT_DIR_USER="$UD" airlock_sweep_platform_units airlock-install
   ) >/dev/null 2>&1; then
  bad "T5: an empty declared set was accepted — a caller bug would have wiped every marked unit"
else
  survived=1
  for u in airlock-secret-sweep.service airlock-retired-thing.service; do
    [ -e "$UD/$u" ] || { survived=0; bad "T5: $u was removed before the refusal"; }
  done
  [ "$survived" = 1 ] && ok "T5: an empty declared set is refused and nothing is touched"
fi

mark
# ---- T6: every shipped platform unit template carries an owner marker ----
for f in "$ROOT"/install/systemd/*.in; do
  grep -qx 'X-Airlock-Owner=airlock-install' "$f" \
    || bad "T6: $(basename "$f") has no X-Airlock-Owner=airlock-install — it would never be swept"
done
for f in "$ROOT"/live/systemd/*.in; do
  grep -qx 'X-Airlock-Owner=airlock-live' "$f" \
    || bad "T6: $(basename "$f") has no X-Airlock-Owner=airlock-live — the install sweep could claim it"
done
ok_if_clean "T6: all platform unit templates are marked with their owning installer"

mark
# ---- T7: the installer's declared set matches what it installs ----
# The sweep deletes what is not declared, so a unit shipped in install/systemd/ but
# missing from the call site would be removed on the next run — by us, silently.
#
# 🔴 Derived from the directory, NOT a hard-coded list. The first version of this check
# named two units by hand, and when airlock-accounts-api.service was added it passed
# without ever looking at the new unit. A list that has to be edited alongside the thing
# it checks is not a check.
t7_units=0
for f in "$ROOT"/install/systemd/*.service.in "$ROOT"/install/systemd/*.timer.in; do
  [ -f "$f" ] || continue
  u="$(basename "$f" .in)"
  t7_units=$((t7_units + 1))
  grep -q -- "$u" "$ROOT/install/airlock-install.sh" \
    || bad "T7: $u is shipped in install/systemd/ but is not in the installer's declared set — the next run would delete it"
done
# Positive control on the scan: if the glob ever stops matching, the loop above reports
# nothing wrong while having looked at nothing.
[ "$t7_units" -ge 4 ] \
  || bad "T7: only $t7_units platform unit templates found — the glob is broken, not the tree"
ok_if_clean "T7: all $t7_units shipped install/systemd units appear in the installer's declared set"

# ---- live/install-timer.sh: drive the real installer against an isolated HOME ----
# Copying live/ to a scratch repository does two things: it avoids this worktree's
# deliberate installation refusal, and makes every path the installer can write or read
# disposable. Fake systemctl/loginctl keep the user manager and linger checks offline.
LIVE_REPO="$TMP/live-repo"
LIVE_HOME="$TMP/live-home"
LIVE_ENV="$LIVE_HOME/.config/airlock-live/env"
LIVE_UD="$LIVE_HOME/.config/systemd/user"

seed_live_install() {
  rm -rf "$LIVE_REPO" "$LIVE_HOME"
  mkdir -p "$LIVE_REPO" "$(dirname "$LIVE_ENV")" "$LIVE_UD"
  cp -R "$ROOT/live" "$LIVE_REPO/live"
  printf '%s\n' \
    'AIRLOCK_LIVE_SSH=example.invalid' \
    'AIRLOCK_LIVE_OWNER=example' \
    'AIRLOCK_LIVE_TSKEY_FILE=/nonexistent/test-key' > "$LIVE_ENV"
  chmod 600 "$LIVE_ENV"

  # Ours, no longer declared: the positive case that proves the sweep does work.
  printf '[Unit]\nX-Airlock-Owner=airlock-live\n' > "$LIVE_UD/airlock-live-retired.timer"
  printf '[Unit]\nX-Airlock-Owner=airlock-live\n' > "$LIVE_UD/airlock-live-retired.service"
  # Another installer and an app with the same prefix: both are out of reach.
  printf '[Unit]\nX-Airlock-Owner=airlock-install\n' > "$LIVE_UD/airlock-secret-sweep.timer"
  printf '[Unit]\nDescription=app unit\n' > "$LIVE_UD/airlock-devterm.service"
}

run_live_install() {
  HOME="$LIVE_HOME" USER=airlock-test \
    bash "$LIVE_REPO/live/install-timer.sh" --envfile "$LIVE_ENV"
}

: > "$FAKE_SYSTEMCTL_LOG"
seed_live_install
mark
run_live_install >"$TMP/live.out" 2>&1 \
  || bad "T8: live installer exited non-zero: $(cat "$TMP/live.out")"

for u in airlock-live-retired.timer airlock-live-retired.service; do
  [ ! -e "$LIVE_UD/$u" ] || bad "T8: $u survived the live sweep"
  grep -q -- "--user disable --now $u" "$FAKE_SYSTEMCTL_LOG" \
    || bad "T8: live sweep did not disable --now $u"
done
for u in airlock-secret-sweep.timer airlock-devterm.service; do
  [ -e "$LIVE_UD/$u" ] || bad "T8: live sweep deleted protected unit $u"
done
live_t_line="$(grep -n -- 'disable --now airlock-live-retired.timer' "$FAKE_SYSTEMCTL_LOG" | cut -d: -f1 | head -1)"
live_s_line="$(grep -n -- 'disable --now airlock-live-retired.service' "$FAKE_SYSTEMCTL_LOG" | cut -d: -f1 | head -1)"
if [ -z "$live_t_line" ] || [ -z "$live_s_line" ] || [ "$live_t_line" -ge "$live_s_line" ]; then
  bad "T8: live timer must be disabled before its service (timer=$live_t_line service=$live_s_line)"
fi
ok_if_clean "T8: live sweep removes only its undeclared marked units, timer first"

mark
# Derived from the shipped directory, so a newly added template cannot be silently
# omitted from UNITS and then swept from an installed box.
t9_units=0
for f in "$ROOT"/live/systemd/*.service.in "$ROOT"/live/systemd/*.timer.in; do
  [ -f "$f" ] || continue
  u="$(basename "$f" .in)"
  t9_units=$((t9_units + 1))
  [ -f "$LIVE_UD/$u" ] \
    || bad "T9: shipped live unit $u was not rendered by the installer's declared set"
done
[ "$t9_units" -ge 3 ] || bad "T9: only $t9_units live unit templates found — the glob is broken"
ok_if_clean "T9: all $t9_units shipped live units are in the installer's declared set"

# The control on the controls: mutate only the scratch copy to simulate a caller bug.
# Refusal must happen before any marked unit can be removed.
mark
seed_live_install
sed -i 's/^UNITS=(.*)$/UNITS=()/' "$LIVE_REPO/live/install-timer.sh"
if run_live_install >"$TMP/live-empty.out" 2>&1; then
  bad "T10: live installer accepted an empty declared set"
else
  grep -q 'refusing to sweep with an empty declared set' "$TMP/live-empty.out" \
    || bad "T10: empty set failed without the sweep refusal diagnostic: $(cat "$TMP/live-empty.out")"
  for u in airlock-live-retired.timer airlock-live-retired.service; do
    [ -e "$LIVE_UD/$u" ] || bad "T10: $u was removed before empty-set refusal"
  done
fi
ok_if_clean "T10: live empty declared set is refused before anything is touched"

if [ "$fails" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nall platform unit sweep checks passed\n'
