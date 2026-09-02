#!/usr/bin/env bash
# install/test-state-dir-mode.sh — the orchestrator may CHOOSE the mode of a state
# directory it creates; it may not keep re-imposing one on a directory that already
# exists.
#
# The distinction is not academic. dev-monitor writes its spool from a second uid, so
# that uid has to traverse Airlock's state directory, and apps/dev-monitor/install.sh
# adds the one bit that allows it. `install -d -m 0700` on every run took the bit back
# every time — so the cross-UID check in install-spool-hardening.sh could never pass,
# the install died there, and (measured 2026-08-22, on a real box) setting the mode by
# hand did not survive a single re-run.
#
# Two properties, and the second is why the first is safe:
#   1. an existing state directory keeps its mode across a run
#   2. a state directory the run CREATES is still 0700
#
# Offline: a scratch HOME and a scratch state directory. The orchestrator is expected to
# fail further down (there is no box to install onto) — that is fine and deliberate,
# because the line under test runs early and the assertion is about the filesystem, not
# about the exit code. What would NOT be fine is asserting a mode after a run that never
# reached the line, so each case proves the line ran by checking its own side effect.
set -uo pipefail
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

scratch="$(mktemp -d)"
trap 'chmod -R u+rwX "$scratch" 2>/dev/null; rm -rf "$scratch"' EXIT

cfg="$scratch/airlock.toml"
cat > "$cfg" <<'TOML'
[airlock]
config_version = 2
[site]
name = "Mode Test"
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[paths]
[apps.hub]
TOML

run_orchestrator() {   # run_orchestrator <state-dir>
  AIRLOCK_CONFIG="$cfg" \
  AIRLOCK_TS_FQDN=test.example.ts.net \
  AIRLOCK_STATE_DIR="$1" \
  AIRLOCK_CONFD="$scratch/confd" \
  AIRLOCK_WEBROOT="$scratch/webroot" \
  HOME="$scratch/home" \
  timeout 120 bash "$ROOT/install/airlock-install.sh" >"$scratch/run.log" 2>&1
  return 0
}
mkdir -p "$scratch/home" "$scratch/confd" "$scratch/webroot"

# ---- 1) an existing directory keeps its mode
state="$scratch/state-existing"
install -d -m 0701 "$state"
# A ledger file is what makes the orchestrator reach the line at all (see the guard
# above it): without one, and with no packages, it never touches the state directory.
printf '{"version": 5, "entries": {}, "events": []}\n' > "$state/app-ledger.json"
run_orchestrator "$state"
if [ ! -e "$state/app-ledger.lock" ]; then
  bad "the orchestrator never reached the state-directory step — this case proves nothing"
else
  ok "positive control: the run really did reach the state-directory step"
  got="$(stat -c %a "$state")"
  [ "$got" = 701 ] && ok "an existing state directory keeps its mode (0701)" \
                   || bad "the run reset an existing state directory to 0$got — dev-monitor's writer loses traversal"
fi

# ---- 2) a directory it creates is still private
fresh="$scratch/state-fresh"
printf '' > /dev/null
mkdir -p "$(dirname "$fresh")"
# No directory, but a package set is what makes the guard fire on a fresh box; hub is
# enabled in the config above, so the run creates it.
run_orchestrator "$fresh"
if [ ! -d "$fresh" ]; then
  bad "the orchestrator did not create the state directory — case 2 proves nothing"
else
  got2="$(stat -c %a "$fresh")"
  [ "$got2" = 700 ] && ok "a state directory the run creates is 0700" \
                    || bad "a freshly created state directory is 0$got2, not 0700"
fi

# ---- 3) no shipped app may narrow the SHARED state directory
#
# Case 1 only exercises the orchestrator, because the fixture enables `hub` and nothing
# else. That is not enough: publish also pointed its STATE_DIR at the shared directory
# and chmod'ed it 0700 on every install, which closed it again after dev-monitor opened
# it — and the failure was at RUNTIME (the spool writer could not write), not at install
# time, so no install-time assertion would have seen it.
#
# A census rather than a run: enabling every app here would turn this into an
# integration suite. What it asks is narrow — does an app declare the shared directory
# as its own state directory AND set a mode on it.
shared_re='\$HOME/\.local/state/airlock"?$'
offenders=""
for inst in "$ROOT"/apps/*/install.sh; do
  [ -f "$inst" ] || continue
  grep -qE "STATE_DIR=\"?$shared_re" "$inst" || continue
  grep -qE '(chmod|install -d -m)[^|]*"\$STATE_DIR"' "$inst" \
    && offenders="$offenders $(basename "$(dirname "$inst")")"
done
if [ -n "$offenders" ]; then
  bad "these apps set a mode on the SHARED state directory:$offenders — it holds the ledger and another app's spool"
else
  ok "no shipped app sets a mode on the shared state directory"
fi
# Positive control: the scan must be able to see such a line at all.
probe="$scratch/probe-install.sh"
printf '%s\n' 'STATE_DIR="$HOME/.local/state/airlock"' 'airlock_run chmod 700 "$STATE_DIR"' > "$probe"
if grep -qE "STATE_DIR=\"?$shared_re" "$probe" \
   && grep -qE '(chmod|install -d -m)[^|]*"\$STATE_DIR"' "$probe"; then
  ok "positive control: the census does detect a shared-directory chmod"
else
  bad "positive control: the census cannot see a shared-directory chmod — case 3 proves nothing"
fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
