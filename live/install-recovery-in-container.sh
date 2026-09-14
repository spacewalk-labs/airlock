#!/usr/bin/env bash
# Real R1-R3 installer recovery scenarios, inside one disposable LXD guest.
# stdout is one JSON document; all prose goes to stderr.
set -uo pipefail

say() { printf '%s\n' "$*" >&2; }
die() { say "FATAL: $*"; exit 1; }

: "${LIVE_USER:?}" "${LIVE_OWNER:?}" "${LIVE_HOSTNAME:?}" "${LIVE_TAG:?}"
: "${LIVE_SHA:?}" "${LIVE_RECOVERY_SCENARIO:?}" "${LIVE_BASE_SHA:?}"
case "$LIVE_RECOVERY_SCENARIO" in r1|r2|r3-forward|r3-refuse) ;; *) die "bad recovery scenario" ;; esac
[[ "$LIVE_SHA" =~ ^[0-9a-f]{40}$ ]] || die "LIVE_SHA must be a full SHA"
[[ "$LIVE_BASE_SHA" =~ ^[0-9a-f]{40}$ ]] || die "LIVE_BASE_SHA must be a full SHA"

SRC=/opt/airlock-src
BASE=/opt/airlock-baseline
[ -f "$SRC/install/airlock-install.sh" ] || die "candidate payload missing"
[ -f "$BASE/install/airlock-install.sh" ] || die "baseline payload missing"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 || die "apt-get update failed"
apt-get install -y -qq curl ca-certificates gnupg sudo systemd-container >/dev/null 2>&1 \
  || die "base package install failed"
id -u "$LIVE_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$LIVE_USER"
usermod -aG sudo "$LIVE_USER"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$LIVE_USER" > "/etc/sudoers.d/90-$LIVE_USER"
chmod 0440 "/etc/sudoers.d/90-$LIVE_USER"
loginctl enable-linger "$LIVE_USER" || die "could not enable linger"

say "== joining disposable guest to tailnet =="
curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || die "tailscale install failed"
systemctl enable --now tailscaled >/dev/null 2>&1 || die "tailscaled did not start"
if [ ! -f /run/live-tskey ] || [ -L /run/live-tskey ]; then
  die "mode-600 auth key missing"
fi
[ "$(stat -c %a /run/live-tskey)" = 600 ] || die "auth key is not mode 600"
TSKEY="$(cat /run/live-tskey)"
rm -f /run/live-tskey
ts_ok=0
ts_err=""
for attempt in 1 2 3 4 5; do
  if ts_err="$(tailscale up --hostname="$LIVE_HOSTNAME" --authkey="$TSKEY" \
      --advertise-tags="$LIVE_TAG" --ssh --accept-routes --timeout=45s \
      </dev/null 2>&1 >/dev/null)"; then
    ts_ok=1
    break
  fi
  say "tailscale up attempt $attempt failed: ${ts_err:-(no diagnostic)}"
  sleep 5
done
unset TSKEY
[ "$ts_ok" = 1 ] || die "tailscale up never succeeded: ${ts_err:-(no diagnostic)}"
TS_FQDN="$(tailscale status --json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' \
  2>/dev/null || true)"
[ -n "$TS_FQDN" ] || die "could not read guest FQDN"

timedatectl set-timezone Asia/Seoul || die "could not set guest timezone"
[ ! -e /etc/timezone ] || printf '%s\n' Asia/Seoul > /etc/timezone \
  || die "could not update guest timezone metadata"
TZ_NAME="$(timedatectl show -p Timezone --value 2>/dev/null)"
TZ_OFFSET="$(date +%z)"
TZ_METADATA=ABSENT
if [ -e /etc/timezone ]; then
  IFS= read -r TZ_METADATA < /etc/timezone || TZ_METADATA=""
fi
TZ_LOCALTIME="$(readlink /etc/localtime 2>/dev/null || true)"
if [ "$TZ_NAME" != Asia/Seoul ] || [ "$TZ_OFFSET" != +0900 ] \
    || { [ "$TZ_METADATA" != Asia/Seoul ] && [ "$TZ_METADATA" != ABSENT ]; } \
    || [ "$TZ_LOCALTIME" != /usr/share/zoneinfo/Asia/Seoul ]; then
  die "guest timezone gate failed: name=$TZ_NAME offset=$TZ_OFFSET metadata=$TZ_METADATA localtime=$TZ_LOCALTIME"
fi

chown -R "$LIVE_USER:$LIVE_USER" "$SRC" "$BASE"
HOME_DIR="$(getent passwd "$LIVE_USER" | cut -d: -f6)"
DRIVER_STATE="$HOME_DIR/.local/state/airlock-install-recovery-driver"
AIRLOCK_STATE="$HOME_DIR/.local/state/airlock"
DEVMON_STATE="$AIRLOCK_STATE/dev-monitor"
DB="$DEVMON_STATE/messages.db"
FAIL_PACKAGE="$SRC/live/install-recovery-packages/late-failure"
EVIDENCE_ROOT=/var/lib/airlock-install-recovery
EVIDENCE="$EVIDENCE_ROOT/run"
rm -rf "$EVIDENCE_ROOT"

prepare_recovery_dirs() {
  local live_group
  live_group="$(id -gn "$LIVE_USER")" || return 1
  chmod o+x "$HOME_DIR" || return 1
  install -d -m 0755 -o "$LIVE_USER" -g "$live_group" \
    "$HOME_DIR/.local" "$HOME_DIR/.local/state" || return 1
  install -d -m 0700 -o "$LIVE_USER" -g "$live_group" \
    "$DRIVER_STATE" "$EVIDENCE"
}

prepare_recovery_dirs || die "could not prepare recovery state directories"
STEPS="$EVIDENCE/steps.tsv"
: > "$STEPS"
chown "$LIVE_USER:$LIVE_USER" "$STEPS"
chmod 0600 "$STEPS"

write_config() {
  local path="$1" messages="$2" enable_fail="$3"
  cat > "$path" <<TOML
[airlock]
config_version = 2

[site]
name = "Airlock install recovery verification"

[auth]
provider = "tailscale"
owner = "$LIVE_OWNER"
collaborators = []

[paths]
wiki = ""

[apps.hub]
[apps.dev-monitor]
messages = $messages
TOML
  if [ "$enable_fail" = 1 ]; then
    cat >> "$path" <<TOML

[apps.zz-install-recovery-fail]
[packages.zz-install-recovery-fail]
path = "$FAIL_PACKAGE"
TOML
  fi
  chown "$LIVE_USER:$LIVE_USER" "$path"
  chmod 0600 "$path"
}

BASE_CONFIG="$HOME_DIR/recovery-baseline.toml"
FAIL_CONFIG="$HOME_DIR/recovery-fail.toml"
CURRENT_CONFIG="$HOME_DIR/recovery-current.toml"
STOP_CONFIG="$HOME_DIR/recovery-observation-stop.toml"
write_config "$BASE_CONFIG" false 0
write_config "$FAIL_CONFIG" true 1
write_config "$CURRENT_CONFIG" true 0
printf '%s\n' 'this is the deliberate post-recovery observation stop' > "$STOP_CONFIG"
chown "$LIVE_USER:$LIVE_USER" "$STOP_CONFIG"
chmod 0600 "$STOP_CONFIG"

as_user() {
  su - "$LIVE_USER" -c "$1"
}

record_step() {
  printf '%s\t%s\n' "$1" "$2" >> "$STEPS"
}

assert_order() {
  local root="$1" config="$2" expected="$3" actual
  actual="$(as_user "cd '$root' && AIRLOCK_CONFIG='$config' python3 bin/airlock-config package-info" \
    | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["order"]))')" \
    || die "cannot resolve package order"
  [ "$actual" = "$expected" ] || die "package order $actual != $expected"
}

run_prerequisites() {
  local fixes
  fixes="$({
    as_user "cd '$BASE' && AIRLOCK_CONFIG='$BASE_CONFIG' python3 bin/airlock-config prereqs"
    as_user "cd '$SRC' && AIRLOCK_CONFIG='$FAIL_CONFIG' python3 bin/airlock-config prereqs"
  } 2>"$EVIDENCE/prerequisites.err" \
    | awk -F '\t' 'NF >= 5 && $5 != "" && $5 != "-" {print $5}' | sort -u)" \
    || die "could not resolve prerequisites"
  [ -n "$fixes" ] || die "no prerequisite fixes were declared"
  while IFS= read -r fix; do
    [ -n "$fix" ] || continue
    say "-- prerequisite: $fix"
    bash -c "$fix" >> "$EVIDENCE/prerequisites.log" 2>&1 \
      || die "prerequisite fix failed"
  done <<< "$fixes"
}

run_installer() {
  local root="$1" config="$2" scenario="$3" path_prefix="$4" log="$5" rc=0
  as_user "cd '$root' && env AIRLOCK_CONFIG='$config' \
    PYTHONDONTWRITEBYTECODE=1 \
    AIRLOCK_INSTALL_RECOVERY_SCENARIO='$scenario' \
    AIRLOCK_INSTALL_RECOVERY_MARKER_DIR='$DRIVER_STATE' \
    AIRLOCK_INSTALL_RECOVERY_STATE_DIR='$AIRLOCK_STATE' \
    AIRLOCK_INSTALL_RECOVERY_FAULT_TOKEN='$DRIVER_STATE/r2.token' \
    AIRLOCK_INSTALL_RECOVERY_FAULT_MARKER='$DRIVER_STATE/r2.marker' \
    PATH='$path_prefix' bash install/airlock-install.sh" > "$log" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

protected_hashes() {
  local include_receipt="$1"
  python3 - "$DEVMON_STATE" "$AIRLOCK_STATE" "$include_receipt" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

devmon, state, include_receipt = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3] == "1"
paths = [
    devmon / "messages.db.pre-endstate",
    devmon / "messages.db.pre-endstate.manifest.json",
    devmon / "messages.db.pre-endstate.target.json",
]
if include_receipt:
    paths.extend(sorted((state / "install-checkpoints").glob("*/dev-monitor-migration.json")))
result = {}
for path in paths:
    if path.is_file() and not path.is_symlink():
        result[str(path.relative_to(state))] = hashlib.sha256(path.read_bytes()).hexdigest()
print(json.dumps(result, sort_keys=True))
PY
}

capture_state() {
  local name="$1"
  local db_json="$EVIDENCE/$name.db.json" db_copy="$EVIDENCE/$name.messages.db"
  as_user "python3 '$SRC/live/install-recovery-db.py' snapshot '$DB' '$db_copy'" \
    > "$db_json" 2> "$EVIDENCE/$name.db.err" || die "database snapshot $name failed"
  local unit_show_rc=0
  as_user "systemctl --user show airlock-dev-monitor.service -p ActiveState -p SubState" \
    > "$EVIDENCE/$name.unit" 2>&1 || unit_show_rc=$?
  local health overview
  health="$(as_user "curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:19923/api/health" \
    2>/dev/null || true)"
  overview="$(as_user "curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:19923/api/overview" \
    2>/dev/null || true)"
  case "$health" in ''|*[!0-9]*) health=0 ;; esac
  case "$overview" in ''|*[!0-9]*) overview=0 ;; esac
  python3 - "$name" "$db_json" "$AIRLOCK_STATE" "$DEVMON_STATE" \
    "$HOME_DIR/.config/systemd/user/airlock-dev-monitor.service" "$health" "$overview" \
    "$unit_show_rc" "$(protected_hashes 0)" "$(protected_hashes 1)" <<'PY' \
    > "$EVIDENCE/$name.state.json"
import json
from pathlib import Path
import sys

name, db_json, state_raw, devmon_raw, unit_raw, health, overview, unit_show_rc, protected, protected_receipt = sys.argv[1:]
state, devmon, unit = Path(state_raw), Path(devmon_raw), Path(unit_raw)
try:
    tx = json.loads((state / "install-transaction.json").read_text(encoding="utf-8"))
except (OSError, ValueError):
    tx = {}
unit_text = unit.read_text(encoding="utf-8", errors="replace") if unit.is_file() else ""
unit_source = "/opt/airlock-baseline" if "/opt/airlock-baseline/" in unit_text else (
    "/opt/airlock-src" if "/opt/airlock-src/" in unit_text else "unknown")
try:
    unit_output = Path(f"/var/lib/airlock-install-recovery/run/{name}.unit").read_text(
        encoding="utf-8", errors="replace")
except OSError:
    unit_output = ""
receipts = sorted((state / "install-checkpoints").glob("*/dev-monitor-migration.json"))
result = json.loads(Path(db_json).read_text(encoding="utf-8"))
result.update({
    "tx": tx,
    "activation": (state / "dev-monitor-activation.json").is_file(),
    "receipt_count": len(receipts),
    "pre_endstate_count": len(list(devmon.glob("messages.db.pre-endstate*"))),
    "unit_observation": {"show_rc": int(unit_show_rc), "output": unit_output},
    "unit_source": unit_source,
    "health_http": int(health),
    "overview_http": int(overview),
    "spool_modes": {
        lane: (oct((devmon / "spool" / lane).stat().st_mode & 0o7777)[2:]
               if (devmon / "spool" / lane).is_dir() else "missing")
        for lane in ("tmp", "new")
    },
    "protected": json.loads(protected),
    "protected_with_receipt": json.loads(protected_receipt),
})
print(json.dumps(result, sort_keys=True))
PY
  chmod 0600 "$EVIDENCE/$name."* 2>/dev/null || true
}

run_prerequisites
assert_order "$BASE" "$BASE_CONFIG" "hub,dev-monitor"
DEFAULT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
baseline_rc="$(run_installer "$BASE" "$BASE_CONFIG" baseline "$DEFAULT_PATH" \
  "$EVIDENCE/baseline-install.log")"
record_step baseline-install "$baseline_rc"
[ "$baseline_rc" = 0 ] || die "baseline install failed"

as_user "systemctl --user stop airlock-dev-monitor.service" \
  > "$EVIDENCE/baseline-stop.log" 2>&1 || die "could not stop baseline dev-monitor"
install -d -m 0700 -o "$LIVE_USER" -g "$LIVE_USER" "$DEVMON_STATE"
[ ! -e "$DB" ] || die "messages database existed before deterministic seed"
as_user "python3 '$SRC/live/install-recovery-db.py' seed-legacy '$DB'" \
  > "$EVIDENCE/seed.json" 2> "$EVIDENCE/seed.err" || die "legacy seed failed"
record_step seed-legacy 0
as_user "systemctl --user start airlock-dev-monitor.service" \
  > "$EVIDENCE/baseline-start.log" 2>&1 || die "could not restart baseline dev-monitor"
as_user "systemctl --user is-active --quiet airlock-dev-monitor.service" \
  >> "$EVIDENCE/baseline-start.log" 2>&1 || die "baseline dev-monitor is not active"
record_step baseline-restart 0

case "$LIVE_RECOVERY_SCENARIO" in
  r1)
    assert_order "$SRC" "$FAIL_CONFIG" "hub,dev-monitor,zz-install-recovery-fail"
    capture_state before
    install_rc="$(run_installer "$SRC" "$FAIL_CONFIG" r1 "$DEFAULT_PATH" \
      "$EVIDENCE/r1-install.log")"
    record_step candidate-install "$install_rc"
    capture_state after
    ;;
  r2)
    assert_order "$SRC" "$CURRENT_CONFIG" "hub,dev-monitor"
    install -d -m 0755 /opt/airlock-recovery-bin
    install -m 0755 -o root -g root "$SRC/live/install-recovery-systemctl-shim.sh" \
      /opt/airlock-recovery-bin/systemctl
    install -m 0600 -o "$LIVE_USER" -g "$LIVE_USER" /dev/null "$DRIVER_STATE/r2.token"
    first_rc="$(run_installer "$SRC" "$CURRENT_CONFIG" r2 \
      "/opt/airlock-recovery-bin:$DEFAULT_PATH" "$EVIDENCE/r2-first.log")"
    record_step candidate-fault "$first_rc"
    capture_state after_fault
    resume_rc="$(run_installer "$SRC" "$CURRENT_CONFIG" r2 "$DEFAULT_PATH" \
      "$EVIDENCE/r2-resume.log")"
    record_step candidate-resume "$resume_rc"
    capture_state after_resume
    ;;
  r3-forward|r3-refuse)
    assert_order "$BASE" "$FAIL_CONFIG" "hub,dev-monitor,zz-install-recovery-fail"
    producer_rc="$(run_installer "$BASE" "$FAIL_CONFIG" "$LIVE_RECOVERY_SCENARIO" \
      "$DEFAULT_PATH" "$EVIDENCE/r3-producer.log")"
    record_step historical-producer "$producer_rc"
    capture_state degraded
    forward_rc=0
    as_user "python3 '$SRC/apps/dev-monitor/migrate-legacy-state.py' --forward-check '$DB' --offline" \
      > "$EVIDENCE/forward-check.txt" 2> "$EVIDENCE/forward-check.err" || forward_rc=$?
    record_step forward-check "$forward_rc"
    [ "$forward_rc" = 0 ] || die "historical producer was not forward-classifiable"
    if [ "$LIVE_RECOVERY_SCENARIO" = r3-forward ]; then
      observe_stop_rc="$(run_installer "$SRC" "$STOP_CONFIG" r3-forward "$DEFAULT_PATH" \
        "$EVIDENCE/r3-recover.log")"
      record_step current-recovery-observe "$observe_stop_rc"
      capture_state recovered
      final_rc="$(run_installer "$SRC" "$CURRENT_CONFIG" r3-forward "$DEFAULT_PATH" \
        "$EVIDENCE/r3-final.log")"
      record_step current-final "$final_rc"
      capture_state final
    else
      # Refusal compares the state immediately after the current forward-check
      # with the state after refusal. The check itself may checkpoint SQLite WAL,
      # so reusing the earlier degraded snapshot would make that observation look
      # like a mutation by the refusing installer.
      capture_state before_refusal
      touch "$BASE/apps/dev-monitor/.install-recovery-intent-mismatch"
      chown "$LIVE_USER:$LIVE_USER" "$BASE/apps/dev-monitor/.install-recovery-intent-mismatch"
      chmod 0600 "$BASE/apps/dev-monitor/.install-recovery-intent-mismatch"
      recovery_rc="$(run_installer "$SRC" "$STOP_CONFIG" r3-refuse "$DEFAULT_PATH" \
        "$EVIDENCE/r3-refuse.log")"
      record_step current-refusal "$recovery_rc"
      capture_state after_refusal
    fi
    ;;
esac

python3 - "$LIVE_RECOVERY_SCENARIO" "$LIVE_SHA" "$LIVE_BASE_SHA" "$TZ_NAME" "$TZ_OFFSET" \
  "$TZ_METADATA" "$TZ_LOCALTIME" "$TS_FQDN" "$EVIDENCE" "$DRIVER_STATE" \
  <<'PY' > "$EVIDENCE/result-without-evidence-hash.json"
import json
from pathlib import Path
import sys

scenario, candidate, producer, tz_name, tz_offset, tz_metadata, tz_localtime, \
    fqdn, evidence_raw, driver_raw = sys.argv[1:]
evidence, driver = Path(evidence_raw), Path(driver_raw)
states = {p.name.removesuffix(".state.json"): json.loads(p.read_text())
          for p in evidence.glob("*.state.json")}
steps = []
for line in (evidence / "steps.tsv").read_text().splitlines():
    name, rc = line.split("\t")
    steps.append({"name": name, "rc": int(rc)})

def tx(stage):
    return states[stage].get("tx") or {}

def restore(stage):
    return (tx(stage).get("restore_results") or {}).get("dev-monitor") or {}

if scenario == "r1":
    facts = {
        "install_rc": next(s["rc"] for s in steps if s["name"] == "candidate-install"),
        "before": states["before"], "after": states["after"],
        "tx_phase": tx("after").get("phase"),
        "restore_status": restore("after").get("status"),
        "activation_records": int(states["after"]["activation"]),
        "migration_receipts": states["after"]["receipt_count"],
        "pre_endstate_files": states["after"]["pre_endstate_count"],
        "unit_fragment_path": states["after"]["unit_source"],
        "overview_http": states["after"]["overview_http"],
        "spool_modes": states["after"]["spool_modes"],
        "late_marker": (driver / "late-package-r1.txt").is_file(),
        "smoke_reached": (driver / "smoke-reached.txt").is_file(),
    }
elif scenario == "r2":
    marker_values = {}
    marker_path = driver / "r2.marker"
    if marker_path.is_file():
        marker_values = dict(line.split("=", 1) for line in marker_path.read_text().splitlines() if "=" in line)
    facts = {
        "first_rc": next(s["rc"] for s in steps if s["name"] == "candidate-fault"),
        "resume_rc": next(s["rc"] for s in steps if s["name"] == "candidate-resume"),
        "after_fault": states["after_fault"], "after_resume": states["after_resume"],
        "first_tx_phase": tx("after_fault").get("phase"),
        "final_tx_phase": tx("after_resume").get("phase"),
        "first_activation": states["after_fault"]["activation"],
        "final_activation": states["after_resume"]["activation"],
        "shim": {"argv": marker_values.get("argv"), "count": int(marker_path.is_file()),
                 "scenario": marker_values.get("scenario")},
        "health_http": states["after_resume"]["health_http"],
        "overview_http": states["after_resume"]["overview_http"],
        "protected_hashes_equal": states["after_fault"]["protected"] == states["after_resume"]["protected"],
        "spool_modes": states["after_resume"]["spool_modes"],
    }
else:
    heartbeat_path = driver / "heartbeat-consumed-id.txt"
    common = {
        "producer_rc": next(s["rc"] for s in steps if s["name"] == "historical-producer"),
        "producer_phase": tx("degraded").get("phase"),
        "heartbeat_id": heartbeat_path.read_text().strip() if heartbeat_path.is_file() else None,
        "forward_check": (evidence / "forward-check.txt").read_text().strip(),
    }
    if scenario == "r3-forward":
        facts = common | {
            "producer_receipts": states["degraded"]["receipt_count"],
            "degraded": states["degraded"], "recovered": states["recovered"], "final": states["final"],
            "observe_stop_rc": next(s["rc"] for s in steps if s["name"] == "current-recovery-observe"),
            "recovered_phase": tx("recovered").get("phase"),
            "forward_keep_app": (tx("recovered").get("forward_keep") or {}).get("app"),
            "restore_status": restore("recovered").get("status"),
            "recovered_receipts": states["recovered"]["receipt_count"],
            "protected_hashes_equal": states["degraded"]["protected"] == states["recovered"]["protected"],
            "final_rc": next(s["rc"] for s in steps if s["name"] == "current-final"),
            "final_phase": tx("final").get("phase"),
            "overview_http": states["final"]["overview_http"],
        }
    else:
        log = (evidence / "r3-refuse.log").read_text(encoding="utf-8", errors="replace")
        facts = common | {
            "before_refusal": states["before_refusal"], "after_refusal": states["after_refusal"],
            "sentinel_added": Path("/opt/airlock-baseline/apps/dev-monitor/.install-recovery-intent-mismatch").is_file(),
            "recovery_rc": next(s["rc"] for s in steps if s["name"] == "current-refusal"),
            "final_phase": tx("after_refusal").get("phase"),
            "forward_keep_present": "forward_keep" in tx("after_refusal"),
            "migration_receipts": states["after_refusal"]["receipt_count"],
            "protected_hashes_equal": states["before_refusal"]["protected_with_receipt"] == states["after_refusal"]["protected_with_receipt"],
            "candidate_tree_mismatch_logged": "candidate tree no longer matches its journaled intent" in log,
        }

print(json.dumps({"schema": 1, "scenario": scenario, "candidate_commit": candidate,
                  "producer_commit": producer, "fqdn": fqdn,
                  "timezone": {"name": tz_name, "offset": tz_offset,
                               "metadata": tz_metadata, "localtime": tz_localtime},
                  "steps": steps, "facts": facts}, sort_keys=True))
PY

chown -R root:root "$EVIDENCE_ROOT"
find "$EVIDENCE_ROOT" -type d -exec chmod 0700 {} +
find "$EVIDENCE_ROOT" -type f -exec chmod 0600 {} +
tar -C "$EVIDENCE_ROOT" -cf "$EVIDENCE_ROOT/evidence.tar" run \
  || die "could not assemble recovery evidence"
chmod 0600 "$EVIDENCE_ROOT/evidence.tar"
EVIDENCE_SHA="$(sha256sum "$EVIDENCE_ROOT/evidence.tar" | awk '{print $1}')"
python3 - "$EVIDENCE/result-without-evidence-hash.json" "$EVIDENCE_SHA" \
  "$(stat -c %a "$EVIDENCE_ROOT/evidence.tar")" <<'PY'
import json
from pathlib import Path
import sys

result = json.loads(Path(sys.argv[1]).read_text())
result["evidence_sha256"] = sys.argv[2]
result["evidence_mode"] = sys.argv[3].zfill(4)
print(json.dumps(result, sort_keys=True))
PY
