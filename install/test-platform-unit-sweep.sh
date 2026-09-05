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
exit 0
FAKE
chmod +x "$TMP/bin/systemctl"
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

if [ "$fails" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nall platform unit sweep checks passed\n'
