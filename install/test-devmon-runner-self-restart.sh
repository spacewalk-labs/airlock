#!/usr/bin/env bash
# A dev-monitor-launched install must outlive restarting dev-monitor itself.
#
# This fixture creates its own disposable airlock-*.service and isolated tmux socket;
# it never touches the installed airlock-dev-monitor.service.  The positive case runs
# the product backend unchanged.  The negative case copies that source again and
# mutates only the new-session isolation back to the old same-cgroup launch.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REVISION="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || printf unknown)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/airlock-devmon-restart.XXXXXX")"
declare -a OUTER_UNITS=() TMUX_DIRS=() TMUX_SESSIONS=()

cleanup() {
  local i
  for ((i=0; i<${#TMUX_DIRS[@]}; i++)); do
    TMUX_TMPDIR="${TMUX_DIRS[$i]}" tmux kill-session -t "${TMUX_SESSIONS[$i]}" \
      >/dev/null 2>&1 || true
  done
  for unit in "${OUTER_UNITS[@]}"; do
    systemctl --user stop "$unit" >/dev/null 2>&1 || true
    systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

emit_unmeasured() {
  printf 'AC-AST-R5-RUNNER | expected: host_restart == 1 && runner_survival == 1 && same_cgroup_mutation_rejected == 1 | observed: host_restart=UNMEASURED,runner_survival=UNMEASURED,same_cgroup_mutation_rejected=UNMEASURED | verdict: UNMEASURED | signal: fixture | evidence: install/test-devmon-runner-self-restart.sh@%s\n' "$REVISION"
  exit 1
}

command -v tmux >/dev/null 2>&1 || emit_unmeasured
command -v systemd-run >/dev/null 2>&1 || emit_unmeasured
systemctl --user show-environment >/dev/null 2>&1 || emit_unmeasured

cat >"$TMP/probe.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
trace="$1"
host_unit="$2"
printf 'runner-started=1\n' >>"$trace"
# Let the host process record the tmux server's cgroup before restarting it.
sleep 2
systemctl --user restart "$host_unit"
printf 'runner-survived=1\n' >>"$trace"
EOF
chmod +x "$TMP/probe.sh"

cat >"$TMP/host.py" <<'PY'
#!/usr/bin/env python3
import importlib.util
import os
import pathlib
import sys
import time

backend, case_dir, session, host_unit, probe = sys.argv[1:]
case = pathlib.Path(case_dir)
trace = case / 'trace'
generation = case / 'generation'

if generation.exists():
    with trace.open('a') as stream:
        stream.write('host-restarted=1\n')
        stream.flush()
        os.fsync(stream.fileno())
    time.sleep(30)
    raise SystemExit(0)

generation.write_text('first\n')
sys.path.insert(0, backend)
spec = importlib.util.spec_from_file_location(
    'airlock_dev_monitor_fixture', os.path.join(backend, 'airlock-dev-monitor.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

plan_dir = case / 'plans'
sentinel_dir = case / 'sentinels'
plan_dir.mkdir()
sentinel_dir.mkdir()
cfg = {
    'cwd_root': str(case),
    'session': session,
    'agent': {},
    'runner': os.path.join(backend, 'action_runner.py'),
    'plan_dir': str(plan_dir),
    'sentinel_dir': str(sentinel_dir),
}
run_id = 'self-restart'
plan = {'cwd': str(case), 'exec': ['/bin/bash', probe, str(trace), host_unit]}
outcome, target = module._launch_run(run_id, plan, cfg, run_id)
server_pid = target.split(':', 1)[0] if target else ''
try:
    cgroup = pathlib.Path('/proc', server_pid, 'cgroup').read_text().strip()
except OSError:
    cgroup = '<unreadable>'
with trace.open('a') as stream:
    stream.write('launch=%s\n' % outcome)
    stream.write('server-pid=%s\n' % server_pid)
    stream.write('server-cgroup=%s\n' % cgroup)
    stream.flush()
    os.fsync(stream.fileno())
time.sleep(30)
PY
chmod +x "$TMP/host.py"

run_case() { # fixed|mutant
  local mode="$1" case_dir="$TMP/$1" stamp outer session tmux_dir i
  mkdir -p "$case_dir/tmux"
  chmod 700 "$case_dir/tmux"
  cp -a "$ROOT/apps/dev-monitor/backend" "$case_dir/backend"
  if [ "$mode" = mutant ]; then
    python3 - "$case_dir/backend/airlock-dev-monitor.py" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
old = '            isolate_unit = _tmux_scope_unit(run_id) if host_unit else None\n'
new = '            isolate_unit = None  # fixture mutation: old same-cgroup launch\n'
if source.count(old) != 1:
    raise SystemExit('fixture mutation target count was not exactly one')
path.write_text(source.replace(old, new))
PY
  fi

  stamp="${$}-$(date +%s)-$mode"
  outer="airlock-r5-runner-$stamp.service"
  session="airlock-r5-runner-$stamp"
  tmux_dir="$case_dir/tmux"
  OUTER_UNITS+=("$outer")
  TMUX_DIRS+=("$tmux_dir")
  TMUX_SESSIONS+=("$session")

  systemd-run --user --unit="${outer%.service}" --service-type=simple --quiet \
    --setenv="HOME=$HOME" --setenv="PATH=$PATH" --setenv="TMUX_TMPDIR=$tmux_dir" \
    --working-directory="$case_dir" -- \
    python3 "$TMP/host.py" "$case_dir/backend" "$case_dir" "$session" "$outer" \
      "$TMP/probe.sh"

  for ((i=0; i<30; i++)); do
    grep -q '^host-restarted=1$' "$case_dir/trace" 2>/dev/null && break
    sleep 1
  done
  # Give the surviving runner enough time to write its sentinel after restart.
  for ((i=0; i<10; i++)); do
    [ -f "$case_dir/sentinels/self-restart.done" ] && break
    sleep 1
  done
  systemctl --user stop "$outer" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$outer" >/dev/null 2>&1 || true
}

run_case fixed
run_case mutant

fixed_trace="$TMP/fixed/trace"
mutant_trace="$TMP/mutant/trace"
host_restart=0
runner_survival=0
same_cgroup_mutation_rejected=0

if grep -q '^host-restarted=1$' "$fixed_trace" 2>/dev/null \
    && grep -q '^host-restarted=1$' "$mutant_trace" 2>/dev/null; then
  host_restart=1
fi
if grep -q '^launch=ok$' "$fixed_trace" 2>/dev/null \
    && grep -qE '^server-cgroup=.*airlock-devmon-run-.*\.scope$' "$fixed_trace" 2>/dev/null \
    && grep -q '^runner-started=1$' "$fixed_trace" 2>/dev/null \
    && grep -q '^runner-survived=1$' "$fixed_trace" 2>/dev/null \
    && [ -f "$TMP/fixed/sentinels/self-restart.done" ]; then
  runner_survival=1
fi
if grep -q '^launch=ok$' "$mutant_trace" 2>/dev/null \
    && grep -qE '^server-cgroup=.*airlock-r5-runner-.*\.service$' "$mutant_trace" 2>/dev/null \
    && grep -q '^runner-started=1$' "$mutant_trace" 2>/dev/null \
    && ! grep -q '^runner-survived=1$' "$mutant_trace" 2>/dev/null \
    && [ ! -f "$TMP/mutant/sentinels/self-restart.done" ]; then
  same_cgroup_mutation_rejected=1
fi

verdict=FAIL
if [ "$host_restart" = 1 ] && [ "$runner_survival" = 1 ] \
    && [ "$same_cgroup_mutation_rejected" = 1 ]; then
  verdict=PASS
fi
printf 'AC-AST-R5-RUNNER | expected: host_restart == 1 && runner_survival == 1 && same_cgroup_mutation_rejected == 1 | observed: host_restart=%s,runner_survival=%s,same_cgroup_mutation_rejected=%s | verdict: %s | signal: fixture | evidence: install/test-devmon-runner-self-restart.sh@%s\n' \
  "$host_restart" "$runner_survival" "$same_cgroup_mutation_rejected" "$verdict" "$REVISION"
[ "$verdict" = PASS ]
