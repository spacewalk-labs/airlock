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

# Exercise the real config writer without crossing the host boundary. Baseline and
# current recovery must not accidentally configure the late-failure package; the
# failure scenario must configure both its app and package tables. The explicit
# orphan mutation pins the F2 boundary that stopped the first live R1 run.
CONFIG_MATRIX="$TMP/config-matrix"
mkdir -p "$CONFIG_MATRIX"
LIVE_USER="$(id -un)"
LIVE_OWNER=owner@example.test
FAIL_PACKAGE="$ROOT/live/install-recovery-packages/late-failure"
export LIVE_USER LIVE_OWNER FAIL_PACKAGE
eval "$(sed -n '/^write_config() {/,/^}/p' "$ROOT/live/install-recovery-in-container.sh")"
write_config "$CONFIG_MATRIX/baseline.toml" false 0
write_config "$CONFIG_MATRIX/failure.toml" true 1
write_config "$CONFIG_MATRIX/current.toml" true 0
config_matrix_rc=0
python3 - "$ROOT" "$CONFIG_MATRIX" "$FAIL_PACKAGE" <<'PY' \
  > "$TMP/config-matrix.out" 2>&1 || config_matrix_rc=$?
import os
from pathlib import Path
import subprocess
import sys
import tomllib

root, matrix, fail_package = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
expected = {
    "baseline.toml": ["hub", "dev-monitor"],
    "failure.toml": ["hub", "dev-monitor", "zz-install-recovery-fail"],
    "current.toml": ["hub", "dev-monitor"],
}
for name, order in expected.items():
    path = matrix / name
    with path.open("rb") as stream:
        config = tomllib.load(stream)
    has_app = "zz-install-recovery-fail" in config.get("apps", {})
    has_package = "zz-install-recovery-fail" in config.get("packages", {})
    assert (has_app, has_package) == (name == "failure.toml", name == "failure.toml"), name
    env = dict(os.environ, AIRLOCK_CONFIG=str(path))
    result = subprocess.run(
        [sys.executable, str(root / "bin/airlock-config"), "package-info"],
        cwd=root, env=env, text=True, capture_output=True)
    assert result.returncode == 0, (name, result.stderr)
    import json
    assert json.loads(result.stdout)["order"] == order, name

orphan = matrix / "baseline-orphan.toml"
orphan.write_text(
    (matrix / "baseline.toml").read_text()
    + f'\n[packages.zz-install-recovery-fail]\npath = "{fail_package}"\n')
env = dict(os.environ, AIRLOCK_CONFIG=str(orphan))
result = subprocess.run(
    [sys.executable, str(root / "bin/airlock-config"), "package-info"],
    cwd=root, env=env, text=True, capture_output=True)
assert result.returncode != 0
assert "has no [apps.zz-install-recovery-fail] table" in result.stderr
print("config matrix and orphan mutation ok")
PY
if [ "$config_matrix_rc" = 0 ] \
   && grep -q 'config matrix and orphan mutation ok' "$TMP/config-matrix.out"; then
  ok "config writer omits inactive failure package and rejects orphan mutation"
else
  bad "config writer matrix/orphan mutation failed"
  sed 's/^/    /' "$TMP/config-matrix.out"
fi

# The fresh driver must make the guest OS KST before any repository lifecycle
# command, and retain the four independent OS observations in its result.
fresh_timezone_rc=0
python3 - "$ROOT/live/in-container.sh" <<'PY' > "$TMP/fresh-timezone.out" 2>&1 || fresh_timezone_rc=$?
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
install = text.index("# ---------------------------------------------------------------- 3. install")
required = (
    "timedatectl set-timezone Asia/Seoul",
    "TZ_NAME=",
    "TZ_OFFSET=",
    "TZ_METADATA=",
    "TZ_LOCALTIME=",
    '"timezone": {"name": tz_name, "offset": tz_offset,',
)
assert all(item in text for item in required)
assert text.index("timedatectl set-timezone Asia/Seoul") < install
print("fresh KST gate and result evidence are present before install")
PY
if [ "$fresh_timezone_rc" = 0 ] \
   && grep -q 'fresh KST gate and result evidence are present before install' "$TMP/fresh-timezone.out"; then
  ok "fresh driver sets and records KST before installing Airlock"
else
  bad "fresh driver omitted a pre-install KST gate or its evidence"
  sed 's/^/    /' "$TMP/fresh-timezone.out"
fi

# The fresh collector must query the same resolved backend port that the
# installed dev-monitor service receives. A non-default port is the negative
# control: a stale literal can pass at the default and fail only on this path.
collector_port_rc=0
python3 - "$ROOT" "$CONFIG_MATRIX" <<'PY' > "$TMP/collector-port.out" 2>&1 || collector_port_rc=$?
from pathlib import Path
import os
import subprocess
import sys

root, matrix = map(Path, sys.argv[1:])
driver = (root / "live/in-container.sh").read_text(encoding="utf-8")
assert "18804" not in driver
assert "bin/airlock-config get apps.dev-monitor.backend_port" in driver
assert 'DEVMON_HEALTH_URL="http://127.0.0.1:${DEVMON_BACKEND_PORT}/api/health"' in driver

changed = matrix / "collector-port-change.toml"
changed.write_text(
    (matrix / "baseline.toml").read_text(encoding="utf-8").replace(
        "[apps.dev-monitor]\nmessages = false",
        "[apps.dev-monitor]\nbackend_port = 19924\nmessages = false",
    ),
    encoding="utf-8",
)
result = subprocess.run(
    [sys.executable, str(root / "bin/airlock-config"), "get",
     "apps.dev-monitor.backend_port"],
    cwd=root, env=dict(os.environ, AIRLOCK_CONFIG=str(changed)),
    text=True, capture_output=True,
)
assert result.returncode == 0, result.stderr
assert result.stdout.strip() == "19924", result.stdout
print("collector resolves the changed effective backend port")
PY
if [ "$collector_port_rc" = 0 ] \
   && grep -q 'collector resolves the changed effective backend port' "$TMP/collector-port.out"; then
  ok "collector resolves the configured backend port instead of a stale literal"
else
  bad "collector health URL ignored a changed configured backend port"
  sed 's/^/    /' "$TMP/collector-port.out"
fi

# Root runs the inner driver, while the historical installer runs as LIVE_USER.
# Exercise the real directory-preparation helper and require every XDG parent it
# creates to be traversable and owned by that installer user.
DIR_HOME="$TMP/recovery-home"
HOME_DIR="$DIR_HOME"
DRIVER_STATE="$HOME_DIR/.local/state/airlock-install-recovery-driver"
EVIDENCE="$TMP/recovery-evidence"
mkdir -p "$HOME_DIR"
chmod 0750 "$HOME_DIR"
dir_setup_rc=0
dir_setup_function="$(sed -n '/^prepare_recovery_dirs() {/,/^}/p' \
  "$ROOT/live/install-recovery-in-container.sh")"
if [ -z "$dir_setup_function" ]; then
  dir_setup_rc=1
else
  eval "$dir_setup_function"
  prepare_recovery_dirs || dir_setup_rc=$?
fi
if [ "$dir_setup_rc" = 0 ] \
   && python3 - "$HOME_DIR" "$DRIVER_STATE" "$EVIDENCE" "$(id -u)" "$(id -g)" <<'PY'
from pathlib import Path
import os
import sys

home, driver, evidence = map(Path, sys.argv[1:4])
uid, gid = map(int, sys.argv[4:6])
for path, mode in (
    (home, 0o751),
    (home / ".local", 0o755),
    (home / ".local/state", 0o755),
    (driver, 0o700),
    (evidence, 0o700),
):
    stat = path.stat()
    assert (stat.st_uid, stat.st_gid) == (uid, gid), path
    assert stat.st_mode & 0o7777 == mode, path
os.mkdir(home / ".local/state/airlock", 0o700)
PY
then
  ok "recovery setup gives the writer HOME traversal and installer-owned XDG parents"
else
  bad "recovery setup left an unusable XDG parent"
fi

# The legacy DB must be seeded while the historical consumer is stopped, then the
# consumer must be live again before any recovery scenario captures its baseline.
baseline_sequence_rc=0
python3 - "$ROOT/live/install-recovery-in-container.sh" <<'PY' \
  > "$TMP/baseline-sequence.out" 2>&1 || baseline_sequence_rc=$?
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
restart = text.index('systemctl --user start airlock-dev-monitor.service')
positions = [
    text.index('systemctl --user stop airlock-dev-monitor.service'),
    text.index("seed-legacy '$DB'"),
    restart,
    text.index('case "$LIVE_RECOVERY_SCENARIO" in', restart),
]
assert positions == sorted(positions), positions
print("baseline stop-seed-start sequence ok")
PY
if [ "$baseline_sequence_rc" = 0 ] \
   && grep -q 'baseline stop-seed-start sequence ok' "$TMP/baseline-sequence.out"; then
  ok "recovery scenarios begin with a running historical consumer"
else
  bad "recovery driver did not restart the historical consumer after seeding"
fi

# R3 runs the historical installer after its package digest has been journaled. Both
# its DB migration and its heartbeat producer import modules from that package tree;
# runtime state may change, but the journaled input tree must not.
HEARTBEAT_ROOT="$TMP/heartbeat-root"
HEARTBEAT_HOME="$TMP/heartbeat-home"
HEARTBEAT_MARKERS="$HEARTBEAT_HOME/.local/state/airlock-install-recovery-driver"
HEARTBEAT_STATE="$HEARTBEAT_HOME/.local/state/airlock/dev-monitor"
mkdir -p "$HEARTBEAT_ROOT/apps" "$HEARTBEAT_ROOT/install" "$HEARTBEAT_MARKERS" \
  "$HEARTBEAT_STATE/spool/tmp" "$HEARTBEAT_STATE/spool/new"
cp -a "$ROOT/apps/dev-monitor" "$HEARTBEAT_ROOT/apps/dev-monitor"
find "$HEARTBEAT_ROOT/apps/dev-monitor" -type d -name __pycache__ -prune \
  -exec rm -rf -- {} +
# Match the live sequence: the baseline backend has already populated the cache,
# while the migration-only module has not run yet.
PYTHONPATH="$HEARTBEAT_ROOT/apps/dev-monitor/backend" \
  python3 -c 'import devmon_messages'
python3 "$ROOT/live/install-recovery-db.py" seed-legacy \
  "$HEARTBEAT_STATE/messages.db" >/dev/null
package_digest() {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/bin/airlock-ledger" "$1" <<'PY'
import importlib.machinery
import importlib.util
import sys

module_path, package_path = sys.argv[1:]
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("airlock_ledger_live_probe", module_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
print(module.digest_tree(package_path))
PY
}
heartbeat_digest_before="$(package_digest "$HEARTBEAT_ROOT/apps/dev-monitor")"
FAIL_INSTALL="$ROOT/live/install-recovery-packages/late-failure/install.sh"
PROBE_APP="$HEARTBEAT_ROOT/apps/dev-monitor"
PROBE_DB="$HEARTBEAT_STATE/messages.db"
export FAIL_INSTALL PROBE_APP PROBE_DB
cat > "$HEARTBEAT_ROOT/install/airlock-install.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
python3 "$PROBE_APP/migrate-legacy-state.py" --endstate "$PROBE_DB" --offline >/dev/null
python3 - "$PROBE_DB" <<'PY'
from datetime import datetime, timezone
import sqlite3
import sys
heartbeat_id = "heartbeat:" + datetime.now(timezone.utc).strftime("%Y-%m-%d")
with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute(
        'INSERT INTO ledger(id, "group", source, received_at, payload) VALUES(?,?,?,?,?)',
        (heartbeat_id, "fixture", "fixture", heartbeat_id, "{}"),
    )
PY
AIRLOCK_ROOT="$(cd "$(dirname "$0")/.." && pwd)" \
AIRLOCK_APP_ID=zz-install-recovery-fail exec bash "$FAIL_INSTALL"
SH
chmod 0700 "$HEARTBEAT_ROOT/install/airlock-install.sh"
run_installer_function="$(sed -n '/^run_installer() {/,/^}/p' \
  "$ROOT/live/install-recovery-in-container.sh")"
eval "$run_installer_function"
as_user() { HOME="$HEARTBEAT_HOME" bash -c "$1"; }
DRIVER_STATE="$HEARTBEAT_MARKERS"
export AIRLOCK_STATE="$HEARTBEAT_HOME/.local/state/airlock"
heartbeat_rc=0
heartbeat_rc="$(run_installer "$HEARTBEAT_ROOT" /dev/null r3-forward \
  /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  "$TMP/heartbeat-fixture.out")"
heartbeat_digest_after="$(package_digest "$HEARTBEAT_ROOT/apps/dev-monitor")"
if [ "$heartbeat_rc" = 86 ] \
   && [ -s "$HEARTBEAT_MARKERS/heartbeat-consumed-id.txt" ] \
   && [ "$heartbeat_digest_before" = "$heartbeat_digest_after" ]; then
  ok "R3 historical migration and heartbeat leave the journaled candidate tree unchanged"
else
  bad "R3 historical lifecycle mutated or missed the journaled candidate tree"
  printf '    before=%s after=%s rc=%s\n' \
    "$heartbeat_digest_before" "$heartbeat_digest_after" "$heartbeat_rc"
fi
unset FAIL_INSTALL PROBE_APP PROBE_DB AIRLOCK_STATE

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
            "timezone": {
                "name": "Asia/Seoul", "offset": "+0900",
                "metadata": "Asia/Seoul",
                "localtime": "/usr/share/zoneinfo/Asia/Seoul",
            },
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

timezone_mutations = {
    "name": "Etc/UTC",
    "offset": "+0000",
    "metadata": "Etc/UTC",
    "localtime": "/usr/share/zoneinfo/Etc/UTC",
}
for field, bad_value in timezone_mutations.items():
    rejected = outer("r1", copy.deepcopy(cases["r1"]))
    rejected["inner"]["timezone"][field] = bad_value
    value, reason = module.calculate(rejected)
    assert value == 1 and "timezone" in reason, (field, reason)
absent_metadata = outer("r1", copy.deepcopy(cases["r1"]))
absent_metadata["inner"]["timezone"]["metadata"] = "ABSENT"
value, reason = module.calculate(absent_metadata)
assert value == 0, ("absent metadata", reason)

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
print("timezone mutation boundaries ok")
print("verdict boundaries ok")
PY
if [ "$verdict_cases_rc" = 0 ] \
   && grep -q 'unit observation boundaries ok' "$TMP/verdict-cases" \
   && grep -q 'timezone mutation boundaries ok' "$TMP/verdict-cases" \
   && grep -q 'verdict boundaries ok' "$TMP/verdict-cases"; then
  ok "recovery verdict rejects unit-state and four-field timezone mutations"
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
    "fqdn":"fixture.example.ts.net",
    "timezone":{"name":"Asia/Seoul","offset":"+0900","metadata":"Asia/Seoul",
                "localtime":"/usr/share/zoneinfo/Asia/Seoul"},
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
