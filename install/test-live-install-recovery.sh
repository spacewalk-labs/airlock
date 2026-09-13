#!/usr/bin/env bash
# Source/mock controls for the disposable R1-R3 live driver. No network, LXD,
# key mint, service, or host database is touched by this suite.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Repo-wide render parity requires every suite that reaches the installer path to
# pin the machine-sized paseo share. The mock SSH stops before a real install, but
# carrying the standard 32 GiB pin keeps this suite deterministic if that boundary
# is extended later.
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok() { printf 'ok   live-install-recovery: %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL live-install-recovery: %s\n' "$1"; fail=$((fail+1)); }

# Deterministic seed and online-backup observation, without importing a test module.
mkdir -p "$TMP/db"
if python3 "$ROOT/live/install-recovery-db.py" seed-legacy "$TMP/db/messages.db" \
    > "$TMP/seed.json" \
   && python3 "$ROOT/live/install-recovery-db.py" snapshot "$TMP/db/messages.db" \
      "$TMP/db/observed.db" > "$TMP/observed.json" \
   && python3 - "$TMP/seed.json" "$TMP/observed.json" <<'PY'
import json, sys
seed, observed = (json.load(open(path)) for path in sys.argv[1:])
assert seed["schema"] == observed["schema"] == "legacy"
assert seed["integrity"] == observed["integrity"] == "ok"
assert seed["ids"] == observed["ids"] == ["recovery-seed-action", "recovery-seed-info"]
assert seed["raw_sha256"] == observed["raw_sha256"]
assert len(observed["online_backup_sha256"]) == 64
PY
then
  ok "DB helper seeds non-empty legacy state and records a stable online backup"
else
  bad "DB helper seed/snapshot failed"
fi

if python3 "$ROOT/live/install-recovery-db.py" seed-legacy "$TMP/db/messages.db" \
    > /dev/null 2> "$TMP/replace.err"; then
  bad "DB helper replaced an existing database"
elif grep -q 'refusing to replace existing database' "$TMP/replace.err"; then
  ok "DB helper refuses to replace existing state"
else
  bad "DB helper refusal did not name the boundary"
fi

# The exact R2 shim boundary: a committed transaction plus its activation record
# consumes one token and fails once. A non-target argv delegates to real systemctl.
SHIM_STATE="$TMP/shim-state"
mkdir -p "$SHIM_STATE"
tx=0123456789abcdef0123456789abcdef
printf '{"id":"%s","phase":"committed"}\n' "$tx" > "$SHIM_STATE/install-transaction.json"
printf '{"transaction_id":"%s"}\n' "$tx" > "$SHIM_STATE/dev-monitor-activation.json"
: > "$SHIM_STATE/token"
chmod 0600 "$SHIM_STATE"/*
shim_rc=0
AIRLOCK_INSTALL_RECOVERY_SCENARIO=r2 \
AIRLOCK_INSTALL_RECOVERY_STATE_DIR="$SHIM_STATE" \
AIRLOCK_INSTALL_RECOVERY_FAULT_TOKEN="$SHIM_STATE/token" \
AIRLOCK_INSTALL_RECOVERY_FAULT_MARKER="$SHIM_STATE/marker" \
  bash "$ROOT/live/install-recovery-systemctl-shim.sh" \
    --user start airlock-dev-monitor.service > /dev/null 2> "$TMP/shim.err" || shim_rc=$?
if [ "$shim_rc" = 86 ] && [ -f "$SHIM_STATE/marker" ] \
    && grep -qx 'argv=--user start airlock-dev-monitor.service' "$SHIM_STATE/marker" \
    && [ -f "$SHIM_STATE/token.consumed" ]; then
  ok "R2 shim fires once only at the committed activation start"
else
  bad "R2 shim missed its exact boundary (rc=$shim_rc)"
fi

second_rc=0
AIRLOCK_INSTALL_RECOVERY_SCENARIO=r2 \
AIRLOCK_INSTALL_RECOVERY_STATE_DIR="$SHIM_STATE" \
AIRLOCK_INSTALL_RECOVERY_FAULT_TOKEN="$SHIM_STATE/token" \
AIRLOCK_INSTALL_RECOVERY_FAULT_MARKER="$SHIM_STATE/marker" \
  bash "$ROOT/live/install-recovery-systemctl-shim.sh" --version \
    > "$TMP/systemctl-version" 2>&1 || second_rc=$?
if [ "$second_rc" = 0 ] && grep -qi systemd "$TMP/systemctl-version"; then
  ok "R2 shim delegates non-target argv to the real systemctl"
else
  bad "R2 shim did not delegate non-target argv (rc=$second_rc)"
fi

# Recovery verdict positive and one-field negative boundaries.
verdict_cases_rc=0
python3 - "$ROOT/live/install-recovery-verdict.py" <<'PY' \
  > "$TMP/verdict-cases" 2>&1 || verdict_cases_rc=$?
import copy
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("recovery_verdict", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sha = "a" * 40
digest = "b" * 64
base_snapshot = {
    "schema": "legacy", "integrity": "ok",
    "ids": ["recovery-seed-action", "recovery-seed-info"],
    "raw_sha256": digest, "online_backup_sha256": digest,
}
protected = {
    "dev-monitor/messages.db.pre-endstate": digest,
    "dev-monitor/messages.db.pre-endstate.manifest.json": digest,
    "dev-monitor/messages.db.pre-endstate.target.json": digest,
}
canonical = dict(base_snapshot, schema="canonical", protected=protected)

def unit_observation(active, sub, show_rc=0, output=None):
    if output is None:
        output = f"ActiveState={active}\nSubState={sub}\n"
    return {"show_rc": show_rc, "output": output}

def outer(scenario, facts):
    return {
        "schema": 1, "commit": sha, "inner_rc": 0,
        "inner": {
            "schema": 1, "scenario": scenario, "candidate_commit": sha,
            "producer_commit": "c" * 40,
            "timezone": {"name": "Asia/Seoul", "offset": "+0900"},
            "evidence_sha256": "d" * 64, "evidence_mode": "0600",
            "steps": [{"name": "fixture", "rc": 0}], "facts": facts,
        },
    }

cases = {
    "r1": {
        "install_rc": 86, "before": base_snapshot,
        "after": dict(base_snapshot, unit_observation=unit_observation("active", "running")),
        "tx_phase": "rolled_back", "restore_status": "restored",
        "activation_records": 0, "migration_receipts": 0, "pre_endstate_files": 0,
        "unit_fragment_path": "/opt/airlock-baseline",
        "overview_http": 200, "spool_modes": {"new": "3770", "tmp": "3770"},
        "late_marker": True, "smoke_reached": False,
    },
    "r2": {
        "first_rc": 1, "resume_rc": 0,
        "after_fault": dict(canonical, unit_observation=unit_observation("inactive", "dead")),
        "after_resume": dict(canonical, unit_observation=unit_observation("active", "running")),
        "first_tx_phase": "committed",
        "final_tx_phase": "committed", "first_activation": True,
        "final_activation": False,
        "shim": {"argv": "--user start airlock-dev-monitor.service", "count": 1, "scenario": "r2"},
        "health_http": 200, "overview_http": 200, "protected_hashes_equal": True,
        "spool_modes": {"new": "3770", "tmp": "3770"},
    },
    "r3-forward": {
        "producer_rc": 86, "producer_phase": "degraded", "producer_receipts": 1,
        "heartbeat_id": "heartbeat:2026-09-12", "forward_check": "forward=1 backup_sha256=x target_sha256=y",
        "degraded": dict(canonical, ids=canonical["ids"] + ["heartbeat:2026-09-12"]),
        "recovered": dict(canonical, ids=canonical["ids"] + ["heartbeat:2026-09-12"],
                          unit_observation=unit_observation("active", "running")),
        "final": dict(canonical, ids=canonical["ids"] + ["heartbeat:2026-09-12"],
                      unit_observation=unit_observation("active", "running")),
        "observe_stop_rc": 2, "recovered_phase": "rolled_back",
        "forward_keep_app": "dev-monitor", "restore_status": "kept-forward-active",
        "recovered_receipts": 0, "protected_hashes_equal": True,
        "final_rc": 0, "final_phase": "committed",
        "overview_http": 200,
    },
    "r3-refuse": {
        "producer_rc": 86, "producer_phase": "degraded",
        "heartbeat_id": "heartbeat:2026-09-12", "forward_check": "forward=1 backup_sha256=x target_sha256=y",
        "before_refusal": canonical,
        "after_refusal": dict(canonical, unit_observation=unit_observation("inactive", "dead")),
        "sentinel_added": True, "recovery_rc": 1, "final_phase": "degraded",
        "forward_keep_present": False, "migration_receipts": 1,
        "protected_hashes_equal": True, "candidate_tree_mismatch_logged": True,
    },
}
for scenario, facts in cases.items():
    record = outer(scenario, facts)
    value, reason = module.calculate(record)
    assert value == 0, (scenario, reason)
    mismatch = copy.deepcopy(record)
    mismatch["inner"]["candidate_commit"] = "e" * 40
    value, reason = module.calculate(mismatch)
    assert value == 1 and "candidate" in reason, (scenario, reason)
    bool_rc = copy.deepcopy(record)
    bool_rc["inner"]["steps"][0]["rc"] = True
    value, reason = module.calculate(bool_rc)
    assert value == 1 and "integer" in reason, (scenario, reason)
    semantic = copy.deepcopy(record)
    field, bad_value = {
        "r1": ("tx_phase", "committed"),
        "r2": ("first_activation", False),
        "r3-forward": ("producer_receipts", 0),
        "r3-refuse": ("forward_keep_present", True),
    }[scenario]
    semantic["inner"]["facts"][field] = bad_value
    value, reason = module.calculate(semantic)
    assert value == 1, (scenario, field, reason)

bad_unit_observations = {
    "unknown": unit_observation("unknown", "unknown"),
    "missing": {"show_rc": 0, "output": "SubState=dead\n"},
    "error-output": {
        "show_rc": 1,
        "output": "Failed to connect to bus: No medium found\n",
    },
}
for scenario, state_name in (("r2", "after_fault"), ("r3-refuse", "after_refusal")):
    for boundary, observation in bad_unit_observations.items():
        rejected = outer(scenario, copy.deepcopy(cases[scenario]))
        rejected["inner"]["facts"][state_name]["unit_observation"] = observation
        value, reason = module.calculate(rejected)
        assert value == 1 and "unit" in reason, (scenario, boundary, reason)
    allowed_failed = outer(scenario, copy.deepcopy(cases[scenario]))
    allowed_failed["inner"]["facts"][state_name]["unit_observation"] = unit_observation(
        "failed", "failed")
    value, reason = module.calculate(allowed_failed)
    assert value == 0, (scenario, "failed allowlist", reason)
print("unit observation boundaries ok")
print("verdict boundaries ok")
PY
if [ "$verdict_cases_rc" = 0 ] \
   && grep -q 'unit observation boundaries ok' "$TMP/verdict-cases" \
   && grep -q 'verdict boundaries ok' "$TMP/verdict-cases"; then
  ok "R2/R3-refuse reject unknown, missing, and failed unit observations"
else
  bad "recovery verdict boundary cases failed"; sed 's/^/    /' "$TMP/verdict-cases"
fi

if python3 - "$ROOT/live/verify.sh" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"RECOVERY_PATH_HASHES'\n(.*?)\nRECOVERY_PATH_HASHES", text, re.S)
assert match, "historical hash block missing"
rows = dict(line.split() for line in match.group(1).splitlines())
assert rows == {
    "install/airlock-install.sh": "be98fa1d126461562e30f5f4620ce09ddd01ac8832bf64f28d7df1ac5f7902dc",
    "install/lib.sh": "08fe8c0a0c2249db314d951c30626f4d65ea103e96fd867b044b07ee5492cdc9",
    "apps/dev-monitor/install.sh": "c396473eb9ff72e5d4e883e29309e1195e2bdcdcf98c00b90a23e25dcb7b1005",
    "apps/dev-monitor/migration-lifecycle.sh": "b8f87350672671dc3261fdc838f43702edba3027846770577368e797adb160b9",
    "apps/dev-monitor/migrate-legacy-state.py": "3690d70bb76bb4b2dd2bf10f89f9eb8be103eab4c7dfbbc26a0c8cda140e3e54",
    "bin/airlock-ledger": "335052b70dca191d9969e523b876293cbfb4235ff544bc725bbecf82e11045b7",
}
PY
then
  ok "historical producer gate fixes one full ref slice with six exact path hashes"
else
  bad "historical producer hash manifest drifted"
fi

# Fake SSH/LXD drives the real host runner. It records commands, owns instances
# by the real nonce, returns fixed inner JSON, and supplies a private bundle.
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/ssh" <<'SH'
#!/usr/bin/env bash
command=${!#}
printf '%s\n' "$command" >> "$MOCK_COMMANDS"
case "$command" in
  "command -v lxc >/dev/null") exit 0 ;;
  "lxc launch "*)
    name="$(printf '%s\n' "$command" | sed -n 's/^lxc launch [^ ]* \([^ ]*\) .*/\1/p')"
    nonce="$(printf '%s\n' "$command" | sed -n 's/.*user\.airlock_live_owner_nonce=\([^ ]*\).*/\1/p')"
    printf '%s\n' "$name" > "$MOCK_STATE/name"
    printf '%s\n' "$nonce" > "$MOCK_STATE/nonce"
    ;;
  "lxc config get "*" volatile.base_image") printf '%s\n' fixture-image-fingerprint ;;
  "lxc config get "*" user.airlock_live_owner_nonce") cat "$MOCK_STATE/nonce" ;;
  "lxc exec "*" systemctl is-system-running --wait") exit 0 ;;
  "cat > /tmp/"*) cat > /dev/null ;;
  "lxc file push "*) exit 0 ;;
  "lxc exec "*"install-recovery-in-container.sh"*)
    cat "$MOCK_RECOVERY_INNER"
    exit "${MOCK_RECOVERY_RC:-0}"
    ;;
  "lxc exec "*"/live/in-container.sh"*) cat "$MOCK_FRESH_INNER" ;;
  "lxc exec "*) exit 0 ;;
  "lxc file pull "*"evidence.tar"*) cat "$MOCK_BUNDLE" ;;
  "lxc delete --force "*) rm -f "$MOCK_STATE/name" "$MOCK_STATE/nonce" ;;
  *) printf 'unexpected mock ssh command: %s\n' "$command" >&2; exit 90 ;;
esac
SH
chmod +x "$MOCK_BIN/ssh"
make_inner_fixtures() {
  local bundle_sha sha
  bundle_sha="$(sha256sum "$MOCK_BUNDLE" | awk '{print $1}')"
  sha="$(git -C "$ROOT" rev-parse HEAD)"
  python3 - "$MOCK_RECOVERY_INNER" "$MOCK_FRESH_INNER" "$bundle_sha" "$sha" <<'PY'
import json, sys
recovery_path, fresh_path, bundle_sha, sha = sys.argv[1:]
digest = "b" * 64
snapshot = {"schema":"legacy", "integrity":"ok",
            "ids":["recovery-seed-action", "recovery-seed-info"],
            "raw_sha256":digest, "online_backup_sha256":digest}
after = dict(snapshot, unit_observation={
    "show_rc": 0, "output": "ActiveState=active\nSubState=running\n"})
recovery = {
    "schema":1, "scenario":"r1", "candidate_commit":sha, "producer_commit":"c"*40,
    "fqdn":"fixture.example.ts.net", "timezone":{"name":"Asia/Seoul","offset":"+0900"},
    "evidence_sha256":bundle_sha, "evidence_mode":"0600",
    "steps":[{"name":"fixture","rc":0}],
    "facts":{"install_rc":86, "before":snapshot, "after":after,
             "tx_phase":"rolled_back", "restore_status":"restored",
             "activation_records":0, "migration_receipts":0, "pre_endstate_files":0,
             "unit_fragment_path":"/opt/airlock-baseline",
             "overview_http":200, "spool_modes":{"new":"3770","tmp":"3770"},
             "late_marker":True, "smoke_reached":False},
}
fresh = {
    "commit":sha, "fqdn":"fixture.example.ts.net", "install_rc":0, "smoke_rc":0,
    "dev_monitor_messages_requested":False,
    "units_late":[{"id":"airlock-fixture.service","type":"simple","active":"active",
                   "sub":"running","exec_status":"0","restarts":"0"}],
    "smoke_lines":["[fixture smoke] backend=200"],
    "external_packages":["fixture"], "external_gate_line_found":True,
    "acceptance":{"rc":0,"passed":25,"failed":0},
    "devmon_no_webhook":{"rc":0,"observation":{"skipped":True}},
}
open(recovery_path,"w").write(json.dumps(recovery))
open(fresh_path,"w").write(json.dumps(fresh))
PY
}

run_mock() {
  local scenario="$1" result_dir="$2" out="$3"
  rm -rf "$MOCK_STATE"; mkdir -p "$MOCK_STATE" "$result_dir"
  : > "$MOCK_COMMANDS"
  if [ -n "$scenario" ]; then
    env PATH="$MOCK_BIN:$PATH" MOCK_STATE="$MOCK_STATE" MOCK_COMMANDS="$MOCK_COMMANDS" \
      MOCK_BUNDLE="$MOCK_BUNDLE" MOCK_RECOVERY_INNER="$MOCK_RECOVERY_INNER" \
      MOCK_FRESH_INNER="$MOCK_FRESH_INNER" MOCK_RECOVERY_RC="${MOCK_RECOVERY_RC:-0}" \
      AIRLOCK_LIVE_RECOVERY_SCENARIO="$scenario" \
      AIRLOCK_LIVE_SSH=fixture AIRLOCK_LIVE_OWNER=owner@example.test \
      AIRLOCK_LIVE_TSKEY_FILE="$MOCK_KEY" AIRLOCK_LIVE_PUBLISH=none \
      AIRLOCK_LIVE_RESULT_DIR="$result_dir" AIRLOCK_LIVE_ALLOW_DIRTY=1 \
      bash "$ROOT/live/verify.sh" > "$out" 2>&1
  else
    env PATH="$MOCK_BIN:$PATH" MOCK_STATE="$MOCK_STATE" MOCK_COMMANDS="$MOCK_COMMANDS" \
      MOCK_BUNDLE="$MOCK_BUNDLE" MOCK_RECOVERY_INNER="$MOCK_RECOVERY_INNER" \
      MOCK_FRESH_INNER="$MOCK_FRESH_INNER" AIRLOCK_LIVE_SSH=fixture \
      AIRLOCK_LIVE_OWNER=owner@example.test AIRLOCK_LIVE_TSKEY_FILE="$MOCK_KEY" \
      AIRLOCK_LIVE_PUBLISH=none AIRLOCK_LIVE_RESULT_DIR="$result_dir" \
      AIRLOCK_LIVE_ALLOW_DIRTY=1 \
      bash "$ROOT/live/verify.sh" > "$out" 2>&1
  fi
}

MOCK_STATE="$TMP/mock-state"
MOCK_COMMANDS="$TMP/mock-commands"
MOCK_BUNDLE="$TMP/private-evidence.tar"
MOCK_RECOVERY_INNER="$TMP/recovery-inner.json"
MOCK_FRESH_INNER="$TMP/fresh-inner.json"
MOCK_KEY="$TMP/key"
printf 'private evidence bytes\n' > "$MOCK_BUNDLE"
printf 'tskey-secret-sentinel\n' > "$MOCK_KEY"
chmod 0600 "$MOCK_KEY"
export MOCK_STATE MOCK_COMMANDS MOCK_BUNDLE MOCK_RECOVERY_INNER MOCK_FRESH_INNER
make_inner_fixtures

if run_mock "" "$TMP/fresh-results" "$TMP/fresh-run.log" \
   && [ -f "$TMP/fresh-results/LAST-GREEN" ] \
   && [ -f "$TMP/fresh-results/LAST-RUN" ] \
   && grep -q '/live/in-container.sh' "$MOCK_COMMANDS" \
   && ! grep -q 'install-recovery-in-container.sh' "$MOCK_COMMANDS"; then
  ok "empty scenario preserves the fresh inner path and freshness markers"
else
  bad "default fresh runner regressed"; tail -20 "$TMP/fresh-run.log" | sed 's/^/    /'
fi

if run_mock r1 "$TMP/recovery-results" "$TMP/recovery-run.log" \
   && [ -f "$(find "$TMP/recovery-results" -name '*.evidence.tar' -print -quit)" ] \
   && [ ! -e "$TMP/recovery-results/LAST-GREEN" ] \
   && [ ! -e "$TMP/recovery-results/LAST-RUN" ] \
   && grep -q 'install-recovery-in-container.sh' "$MOCK_COMMANDS" \
   && [ "$(grep -n 'lxc file pull .*evidence.tar' "$MOCK_COMMANDS" | cut -d: -f1)" \
        -lt "$(grep -n 'lxc delete --force' "$MOCK_COMMANDS" | cut -d: -f1)" ]; then
  ok "recovery bundle is hash-checked and recovered before owned-container cleanup"
else
  bad "recovery result/cleanup ordering failed"; tail -30 "$TMP/recovery-run.log" | sed 's/^/    /'
fi

if MOCK_RECOVERY_RC=88 run_mock r1 "$TMP/failed-recovery-results" \
    "$TMP/failed-recovery-run.log"; then
  bad "failed recovery inner was accepted"
elif [ -f "$(find "$TMP/failed-recovery-results" -name '*.json' -print -quit)" ] \
     && ! grep -q '^lxc delete --force ' "$MOCK_COMMANDS" \
     && grep -q 'keeping .* for evidence recovery' "$TMP/failed-recovery-run.log"; then
  ok "failed recovery inner writes its result and preserves the owned guest"
else
  bad "failed recovery inner lost its result or guest"
fi

if ! grep -Rqs 'tskey-secret-sentinel' "$TMP/fresh-results" "$TMP/recovery-results" \
      "$TMP/fresh-run.log" "$TMP/recovery-run.log" "$MOCK_COMMANDS"; then
  ok "the real-key sentinel is absent from commands, logs, and results"
else
  bad "the real-key sentinel leaked into durable output"
fi

gate_combinations_ok=1
for gate_case in publish update evidence; do
  : > "$MOCK_COMMANDS"
  gate_log="$TMP/gate-$gate_case.log"
  gate_env=(
    PATH="$MOCK_BIN:$PATH"
    MOCK_COMMANDS="$MOCK_COMMANDS"
    AIRLOCK_LIVE_RECOVERY_SCENARIO=r1
    AIRLOCK_LIVE_SSH=fixture
    AIRLOCK_LIVE_OWNER=owner@example.test
    AIRLOCK_LIVE_TSKEY_FILE="$MOCK_KEY"
  )
  case "$gate_case" in
    publish) gate_env+=(AIRLOCK_LIVE_PUBLISH=gh) ;;
    update) gate_env+=(AIRLOCK_LIVE_PUBLISH=none AIRLOCK_LIVE_UPDATE=1) ;;
    evidence) gate_env+=(AIRLOCK_LIVE_PUBLISH=none AIRLOCK_LIVE_EVIDENCE_DIR="$TMP/public") ;;
  esac
  if env "${gate_env[@]}" bash "$ROOT/live/verify.sh" > "$gate_log" 2>&1 \
      || [ -s "$MOCK_COMMANDS" ]; then
    gate_combinations_ok=0
  fi
done
if [ "$gate_combinations_ok" = 1 ]; then
  ok "recovery publish/update/public-evidence combinations fail before SSH/LXD"
else
  bad "a forbidden recovery mode crossed the host boundary"
fi

# Invalid modes must fail before SSH; a locally corrupted historical hash must
# pass SSH reachability but fail before lxc launch.
: > "$MOCK_COMMANDS"
if env PATH="$MOCK_BIN:$PATH" MOCK_COMMANDS="$MOCK_COMMANDS" \
    AIRLOCK_LIVE_RECOVERY_SCENARIO='r1,r2' AIRLOCK_LIVE_SSH=fixture \
    AIRLOCK_LIVE_OWNER=owner@example.test AIRLOCK_LIVE_TSKEY_FILE="$MOCK_KEY" \
    AIRLOCK_LIVE_PUBLISH=none bash "$ROOT/live/verify.sh" \
      > "$TMP/invalid.log" 2>&1; then
  bad "invalid scenario was accepted"
elif [ ! -s "$MOCK_COMMANDS" ] && grep -q 'must be empty, r1, r2' "$TMP/invalid.log"; then
  ok "unknown or multiple scenarios fail before SSH/LXD"
else
  bad "invalid scenario crossed the host boundary"
fi

git clone -q --shared "$ROOT" "$TMP/corrupt-repo"
git -C "$TMP/corrupt-repo" checkout -q "$(git -C "$ROOT" rev-parse HEAD)"
cp "$ROOT/live/verify.sh" "$TMP/corrupt-repo/live/verify.sh"
sed -i 's/be98fa1d126461562e30f5f4620ce09ddd01ac8832bf64f28d7df1ac5f7902dc/0e98fa1d126461562e30f5f4620ce09ddd01ac8832bf64f28d7df1ac5f7902dc/' \
  "$TMP/corrupt-repo/live/verify.sh"
: > "$MOCK_COMMANDS"
if env PATH="$MOCK_BIN:$PATH" MOCK_STATE="$MOCK_STATE" MOCK_COMMANDS="$MOCK_COMMANDS" \
    AIRLOCK_LIVE_RECOVERY_SCENARIO=r1 AIRLOCK_LIVE_SSH=fixture \
    AIRLOCK_LIVE_OWNER=owner@example.test AIRLOCK_LIVE_TSKEY_FILE="$MOCK_KEY" \
    AIRLOCK_LIVE_PUBLISH=none AIRLOCK_LIVE_ALLOW_DIRTY=1 \
    bash "$TMP/corrupt-repo/live/verify.sh" > "$TMP/hash-negative.log" 2>&1; then
  bad "corrupted historical path hash was accepted"
elif grep -q 'historical recovery producer path changed' "$TMP/hash-negative.log" \
     && ! grep -q '^lxc launch ' "$MOCK_COMMANDS"; then
  ok "historical producer path hash mismatch fails before lxc launch"
else
  bad "historical producer hash gate failed at the wrong boundary"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
