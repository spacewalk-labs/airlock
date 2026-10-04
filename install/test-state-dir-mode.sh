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
# Offline: call the engine's state-directory helper and actual atomic writer
# with scratch paths. Each writer case proves the helper ran and reads back the
# stored row, so an untouched directory cannot produce a vacuous pass.
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"
airlock_pin_paseo_mem

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

airlock_test_counters_init

scratch="$(mktemp -d)"
trap 'chmod -R u+rwX "$scratch" 2>/dev/null; rm -rf "$scratch"' EXIT
chmod 700 "$scratch"

run_engine_case() {
  AIRLOCK_STATE_DIR="$2" python3 - "$ROOT/bin/airlock-ledger" "$1" <<'PY'
import importlib.machinery, importlib.util, os, stat, sys
from pathlib import Path

loader = importlib.machinery.SourceFileLoader("_airlock_ledger", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
engine = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
loader.exec_module(engine)
state = Path(os.environ["AIRLOCK_STATE_DIR"])
case = sys.argv[2]

if case == "read":
    before = state.stat().st_mode
    assert engine.load_installed() == {}
    assert state.stat().st_mode == before
    assert list(state.iterdir()) == []
elif case == "ensure":
    before = state.stat().st_mode
    assert engine._ensure_state_dir() == state
    assert state.stat().st_mode == before
    assert list(state.iterdir()) == []
else:
    expected_mode = 0o701 if case == "existing-write" else 0o700
    if case == "fresh-write":
        assert not state.exists()
    original = engine._ensure_state_dir
    calls = []
    def observed_ensure():
        calls.append(True)
        return original()
    engine._ensure_state_dir = observed_ensure
    row = {"mode-probe": {"repo": str(state.parent / "app"),
                          "commit": "", "artifacts": []}}
    engine.write_installed(row)
    assert calls, "write_installed never called the state-directory helper"
    assert engine.installed_path().exists(), "the atomic writer never wrote its record"
    assert engine.load_installed() == row
    assert stat.S_IMODE(state.stat().st_mode) == expected_mode
PY
}

# ---- 1) reads and directory preparation preserve an existing mode and write nothing
state="$scratch/state-existing"
install -d -m 0701 "$state"
if run_engine_case read "$state"; then
  ok "load_installed preserves existing 0701 and writes nothing"
else
  bad "read changed state-directory permissions or created state"
fi
if run_engine_case ensure "$state"; then
  ok "_ensure_state_dir preserves existing 0701 and creates no state record"
else
  bad "directory preparation narrowed existing permissions or wrote a state record"
fi

# ---- 2) the real writer keeps existing mode and creates a fresh private directory
if run_engine_case existing-write "$state"; then
  ok "write_installed invokes the helper, persists its row, and preserves existing 0701"
else
  bad "writing an engine row narrowed existing permissions or skipped the helper"
fi
fresh="$scratch/state-fresh"
if run_engine_case fresh-write "$fresh"; then
  ok "write_installed invokes the helper, persists its row, and creates fresh 0700"
else
  bad "the engine writer did not create a private state directory with a readable row"
fi

# ---- 3) no shipped app may narrow the SHARED state directory
#
# The engine writer is not the only consumer: publish also pointed its STATE_DIR at the shared directory
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
