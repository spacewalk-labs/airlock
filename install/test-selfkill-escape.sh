#!/usr/bin/env bash
# install/test-selfkill-escape.sh — the installer must survive stopping its own host.
#
# On 2026-09-01 one box lost paseo three times in two hours (21:41, 22:01, 23:04) to
# one mechanism: the install was started from inside airlock-paseo.service, reached
# the step that stops that unit, and died in the same cgroup it had just killed. The
# run never got to the step that starts it again, so each attempt left units stopped,
# disabled, and their unit files reclaimed — the box strictly worse than before.
#
# The failure only reproduces INSIDE such a unit, which is exactly why it survived
# three attempts: every check anyone ran was from a normal shell, where it passes.
# So the live case here builds the real shape (a service, with the run as a child
# process, not as MainPID — an installer under paseo is a grandchild of the daemon)
# and drives it both ways. The negative control must die; without it a green
# "SURVIVED" would prove nothing, since a run that never gets killed survives too.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AIRLOCK_ROOT="$ROOT"
export AIRLOCK_ROOT
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

pass=0; fail=0
ok()  { echo "ok   selfkill-escape: $1"; pass=$((pass+1)); }
bad() { echo "FAIL selfkill-escape: $1"; fail=$((fail+1)); }
skip() { echo "skip selfkill-escape: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- detection
# Offline half: which cgroups does the guard consider doomed? Driven through the
# seam so it runs anywhere, including a container with no user manager.
detect() {  # detect <cgroup-line> -> prints the guard's log, rc 0
  printf '%s\n' "$1" > "$TMP/cgroup"
  AIRLOCK_SELFKILL_CGROUP_FILE="$TMP/cgroup" \
  AIRLOCK_SELFKILL_ESCAPED=1 \
    bash -c '. "$AIRLOCK_ROOT/install/lib.sh"; airlock_escape_selfkill_cgroup /bin/true' 2>&1
}

# AIRLOCK_SELFKILL_ESCAPED=1 short-circuits before the cgroup is read, so the
# detection cases below need the loop guard off. Keep them separate.
detect_live() {  # same, but with the move disarmed so nothing actually re-execs
  printf '%s\n' "$1" > "$TMP/cgroup"
  AIRLOCK_SELFKILL_CGROUP_FILE="$TMP/cgroup" \
  AIRLOCK_SELFKILL_SYSTEMD_RUN=airlock-no-such-runner \
    bash -c '. "$AIRLOCK_ROOT/install/lib.sh"; airlock_escape_selfkill_cgroup /bin/true' 2>&1
}

# Same, but with the REAL systemd-run: exercises the manager probe rather than the
# missing-binary branch.
detect_bus() {
  printf '%s\n' "$1" > "$TMP/cgroup"
  AIRLOCK_SELFKILL_CGROUP_FILE="$TMP/cgroup" \
    bash -c '. "$AIRLOCK_ROOT/install/lib.sh"; airlock_escape_selfkill_cgroup /bin/true' 2>&1
}

out="$(detect_live '0::/user.slice/user-1001.slice/user@1001.service/app.slice/airlock-paseo.service')"
case "$out" in
  *"inside airlock-paseo.service"*) ok "detects the paseo host unit" ;;
  *) bad "did not detect airlock-paseo.service; got: $out" ;;
esac
case "$out" in
  *"measured cgroup:"*) ok "prints the cgroup it read (the evidence for the next person)" ;;
  *) bad "did not print the measured cgroup" ;;
esac
case "$out" in
  *WARNING*"not found"*"continuing INSIDE"*) ok "no systemd-run: warns and continues, does not block" ;;
  *) bad "missing systemd-run should warn and continue; got: $out" ;;
esac

out="$(detect_live '0::/user.slice/user-1001.slice/user@1001.service/app.slice/airlock-code-server@1.service')"
case "$out" in
  *"inside airlock-code-server@1.service"*) ok "detects a templated instance (code-server@1)" ;;
  *) bad "templated instance not detected; got: $out" ;;
esac

out="$(detect_live '0::/user.slice/user-1001.slice/user@1001.service/app.slice/tmux-spawn-abc.scope')"
if [ -z "$out" ]; then ok "a normal shell (tmux scope) is left alone"
else bad "should be silent outside an airlock unit; got: $out"; fi

out="$(detect_live '0::/user.slice/user-1001.slice/user@1001.service/app.slice/run-u42.scope')"
if [ -z "$out" ]; then ok "an already-escaped scope is left alone"
else bad "an escaped scope must not re-trigger; got: $out"; fi

out="$(AIRLOCK_DRY_RUN=1 detect_live '0::/user.slice/.../app.slice/airlock-paseo.service')"
if [ -z "$out" ]; then ok "a dry run stops nothing, so it does not move"
else bad "dry run should be silent; got: $out"; fi

# The two false positives CI found the first time this shipped. Both must be silent.
out="$(detect_live '0::/system.slice/actions.runner.example-org-repo.airlock-ci-3.service')"
if [ -z "$out" ]; then ok "a system unit whose NAME contains airlock- is left alone"
else bad "matched a system unit by substring; got: $out"; fi

out="$(detect_live '0::/user.slice/user-1000.slice/user@1000.service/app.slice/not-airlock-paseo.service')"
if [ -z "$out" ]; then ok "matches the leaf unit, not any airlock- text inside the path"
else bad "matched a non-airlock leaf; got: $out"; fi

# No user manager: warn-and-continue, never abort. Getting this wrong turned every
# CI install into a failed one. An unreachable bus address cannot touch a real
# manager, which is what makes this safe to drive here.
out="$(DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/airlock-selfkill-probe \
       XDG_RUNTIME_DIR="$TMP/no-runtime" \
       detect_bus '0::/user.slice/user-1000.slice/user@1000.service/app.slice/airlock-paseo.service')"
case "$out" in
  *"no systemd --user manager reachable"*) ok "no user manager: continues in place, does not abort" ;;
  *) bad "unreachable manager must warn and continue; got: ${out:-<empty>}" ;;
esac

out="$(detect '0::/user.slice/.../app.slice/airlock-paseo.service')"
if [ -z "$out" ]; then ok "the loop guard makes a second pass a no-op"
else bad "AIRLOCK_SELFKILL_ESCAPED should short-circuit; got: $out"; fi

# ---------------------------------------------------------------- live
# The half that actually proves the defect is fixed. Needs a user manager.
if ! systemctl --user show-environment >/dev/null 2>&1 || ! command -v systemd-run >/dev/null 2>&1; then
  skip "live reproduction (no systemd --user manager here)"
else
  UNIT=airlock-selfkill-escape-test
  probe="$TMP/probe.sh"
  # KILL says which coupling to sever after the guard has moved (or not moved) the
  # run. The first version of this guard only survived "cgroup"; "pgroup" and "pipe"
  # killed it in the field, so all three are driven here.
  #
  # pgroup kills the group the run STARTED in, recorded by the launcher below. Killing
  # "-$$" instead only lands when the probe happens to lead its own group, which is
  # true exactly when the guard already moved it — that scores the axis backwards,
  # passing the control and failing the guard.
  cat > "$probe" <<EOF
#!/usr/bin/env bash
set -uo pipefail
OUT="\$1"; MODE="\$2"; KILL="\$3"
export AIRLOCK_ROOT="$ROOT"
if [ "\$MODE" = on ]; then
  . "$ROOT/install/lib.sh"
  airlock_escape_selfkill_cgroup "\$0" "\$OUT" "\$MODE" "\$KILL" 2>/dev/null
fi
echo "reached-stop" >> "\$OUT"
case "\$KILL" in
  cgroup) systemctl --user stop ${UNIT}.service >/dev/null 2>&1 & ;;
  pgroup) ( sleep 1; kill -9 -"\$(cat "\$OUT.pgid")" >/dev/null 2>&1 ) & ;;
  pipe)   ( sleep 1; systemctl --user stop ${UNIT}.service >/dev/null 2>&1 ) & ;;
esac
sleep 6
echo "reached-restart" >> "\$OUT"
EOF
  chmod +x "$probe"

  live_case() {  # live_case <on|off> <cgroup|pgroup|pipe> -> prints the probe's trace
    local mode="$1" kill="$2" out="$TMP/live-$1-$2.out"
    rm -f "$out"
    # The run is a CHILD of the unit's main process, matching an installer started
    # from an agent session: exec'ing it as MainPID would let systemd kill it by PID
    # regardless of cgroup, and the test would pass for the wrong reason.
    #
    # For the pipe case the probe's stdout is a pipe whose reader goes away with the
    # unit — the shape that produced rc=141 in the field.
    if [ "$kill" = pipe ]; then
      systemd-run --user --unit="$UNIT" --service-type=simple --quiet --collect \
        bash -c "awk '{print \$5}' /proc/self/stat > '$out.pgid'; '$probe' '$out' '$mode' '$kill' | cat & wait" >/dev/null 2>&1
    else
      systemd-run --user --unit="$UNIT" --service-type=simple --quiet --collect \
        bash -c "awk '{print \$5}' /proc/self/stat > '$out.pgid'; '$probe' '$out' '$mode' '$kill' & wait" >/dev/null 2>&1
    fi
    # Poll for the outcome on a clock, not on the unit's state: the guarded run
    # severs the coupling almost immediately and then keeps working for several more
    # seconds, so "unit is gone" is not "the run is done" — reading the trace there
    # scores the guarded case as dead and the test passes for the wrong reason.
    local i=0
    while [ $i -lt 25 ]; do
      grep -q reached-restart "$out" 2>/dev/null && break
      sleep 1; i=$((i+1))
    done
    systemctl --user stop "${UNIT}.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "${UNIT}.service" >/dev/null 2>&1 || true
    cat "$out" 2>/dev/null
  }

  # Every axis carries its own negative control. Without one, a green "survived"
  # proves nothing: a run that was never killed survives too.
  for axis in cgroup pgroup pipe; do
    case "$axis" in
      cgroup) what="the stop of its own host unit" ;;
      pgroup) what="its process group being killed" ;;
      pipe)   what="its stdout pipe closing (the rc=141 shape)" ;;
    esac

    neg="$(live_case off "$axis")"
    case "$neg" in
      *reached-restart*) bad "NEGATIVE CONTROL ($axis) did not die — that axis is not reproducing" ;;
      *reached-stop*)    ok  "negative control ($axis): unguarded run dies at $what" ;;
      *)                 bad "negative control ($axis) never reached the kill; got: ${neg:-<empty>}" ;;
    esac

    pos="$(live_case on "$axis")"
    case "$pos" in
      *reached-restart*) ok "guarded run survives $what" ;;
      *)                 bad "guarded run died like the control ($axis); got: ${pos:-<empty>}" ;;
    esac
  done
fi

echo
echo "selfkill-escape: $pass ok, $fail failed"
[ "$fail" -eq 0 ]
