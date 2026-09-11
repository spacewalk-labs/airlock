#!/usr/bin/env bash
# Installer ordering/rollback regression fixtures. Everything is scratch + shims.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

case_name="${2:-${1:-all}}"
if [ "${1:-}" = --case ]; then
  case_name="${2:-}"
fi

STATE="$TMP/state"
WEB="$TMP/web"
CONFD="$TMP/confd"
UU="$TMP/units-user"
US="$TMP/units-system"
FAKEHOME="$TMP/home"
DATA="$TMP/data"
SHIM="$TMP/shim"
mkdir -p "$STATE" "$WEB/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d" \
  "$UU" "$US" "$FAKEHOME" "$DATA" "$SHIM"
printf '0::/user.slice/user-1000.slice/session-1.scope\n' > "$TMP/cgroup"

export AIRLOCK_STATE_DIR="$STATE" AIRLOCK_WEBROOT="$WEB" AIRLOCK_CONFD="$CONFD"
export AIRLOCK_UNIT_DIR_USER="$UU" AIRLOCK_UNIT_DIR_SYSTEM="$US"
export AIRLOCK_TS_FQDN="box.example.ts.net" AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

cat > "$SHIM/sudo" <<'STUB'
#!/usr/bin/env bash
runas=
while [ "$#" -gt 0 ]; do
  case "$1" in -n) shift ;; -u) runas="$2"; shift 2 ;; *) break ;; esac
done
if [ "${AIRLOCK_FIXTURE_CROSS_UID:-}" = 1 ] && [ "$runas" = fixture_writer ] \
    && [ "${1:-}" = test ] && [ "${2:-}" = '!' ] && [ "${3:-}" = -w ]; then
  mode="$(stat -c %a "$4")"
  group_digit="${mode: -2:1}"
  (( (8#$group_digit & 2) == 0 ))
  exit
fi
exec "$@"
STUB
cat > "$SHIM/id" <<'STUB'
#!/usr/bin/env bash
if [ "${AIRLOCK_FIXTURE_CROSS_UID:-}" = 1 ] && [ "${1:-}" = fixture_writer ]; then
  exit 0
fi
exec /usr/bin/id "$@"
STUB
cat > "$SHIM/systemctl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/systemctl.log"
if [ -n "\${AIRLOCK_FIXTURE_SYSTEMCTL_STATE:-}" ] \
    && [ "\${1:-}" = --user ] && [ "\${2:-}" = show ]; then
  key="\${3//[^A-Za-z0-9_.-]/_}"
  if [ -e "\$AIRLOCK_FIXTURE_SYSTEMCTL_STATE/\$key.stopped" ]; then
    printf '%s\n' 'LoadState=loaded' 'ActiveState=inactive' 'MainPID=0' 'ControlPID=0' \
      'SubState=dead' 'Result=success' 'Type=simple' 'ExecMainStatus=0' 'UnitFileState=enabled'
  else
    printf '%s\n' 'LoadState=loaded' 'ActiveState=active' 'MainPID=4242' 'ControlPID=0' \
      'SubState=running' 'Result=success' 'Type=simple' 'ExecMainStatus=0' 'UnitFileState=enabled'
  fi
elif [ -n "\${AIRLOCK_FIXTURE_SYSTEMCTL_STATE:-}" ] \
    && [ "\${1:-}" = --user ] && [ "\${2:-}" = stop ]; then
  key="\${3//[^A-Za-z0-9_.-]/_}"
  : >"\$AIRLOCK_FIXTURE_SYSTEMCTL_STATE/\$key.stopped"
elif [ -n "\${AIRLOCK_FIXTURE_SYSTEMCTL_STATE:-}" ] \
    && [ "\${1:-}" = --user ] && [ "\${2:-}" = start ]; then
  key="\${3//[^A-Za-z0-9_.-]/_}"
  rm -f "\$AIRLOCK_FIXTURE_SYSTEMCTL_STATE/\$key.stopped"
  if [ -n "\${AIRLOCK_FIXTURE_DB:-}" ] && [ -e "\$AIRLOCK_FIXTURE_DB" ]; then
    schema="\$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" \
      --schema-state "\$AIRLOCK_FIXTURE_DB")"
    printf 'start-schema=%s %s\n' "\$schema" "\${3:-}" >> "$TMP/systemctl.log"
  fi
elif [ -n "\${AIRLOCK_FIXTURE_SYSTEMCTL_STATE:-}" ] \
    && [ "\${1:-}" = --user ] && [ "\${2:-}" = is-active ]; then
  unit="\${!#}"; key="\${unit//[^A-Za-z0-9_.-]/_}"
  if [ ! -e "\$AIRLOCK_FIXTURE_SYSTEMCTL_STATE/\$key.stopped" ]; then
    [[ "\$*" == *--quiet* ]] || printf '%s\n' active
  else
    [[ "\$*" == *--quiet* ]] || printf '%s\n' inactive
    exit 3
  fi
elif [ -n "\${AIRLOCK_FIXTURE_SYSTEMCTL_STATE:-}" ] \
    && [ "\${1:-}" = --user ] && [ "\${2:-}" = is-enabled ]; then
  [[ "\$*" == *--quiet* ]] || printf '%s\n' enabled
  exit 0
else
  case "\$*" in
    *list-timers*) printf '%s\n' 'Mon 2026-09-02 00:00:00 UTC 1d left airlock-update-detect.timer airlock-update-detect.service' ;;
    *is-active*) printf '%s\n' active ;;
    *is-enabled*) printf '%s\n' enabled ;;
    *show*) printf '%s\n' 'LoadState=loaded' 'ActiveState=active' 'SubState=running' 'Result=success' 'Type=simple' 'ExecMainStatus=0' 'UnitFileState=enabled' ;;
  esac
fi
exit 0
STUB
cat > "$SHIM/tailscale" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = status ] && [ "\${2:-}" = --json ]; then
  printf '%s\n' '{"BackendState":"Running","CertDomains":["box.example.ts.net"],"Self":{"DNSName":"box.example.ts.net."},"Health":[]}'
elif [ "\${1:-}" = serve ] && [ "\${2:-}" = status ]; then
  printf '%s\n' '{"TCP":{}}'
else
  printf '%s\n' "\$*" >> "$TMP/tailscale.log"
fi
exit 0
STUB
cat > "$SHIM/nginx" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = -t ] && [ -n "${AIRLOCK_FIXTURE_NGINX_FAIL:-}" ]; then
  case "$(cat "$AIRLOCK_FIXTURE_NGINX_FAIL")" in
    modify)
      python3 - "$AIRLOCK_FIXTURE_DB" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
db.execute("UPDATE cards SET title='later-write' WHERE card_id='card-safe'")
db.commit()
db.close()
PY
      exit 77
      ;;
    crash)
      kill -9 "$(cat "$AIRLOCK_FIXTURE_CRASH_PID_FILE")"
      exit 137
      ;;
    *) exit 77 ;;
  esac
fi
exit 0
STUB
cat > "$SHIM/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in *http_code*) printf 200 ;; esac
exit 0
STUB
chmod +x "$SHIM"/*
PATH="$SHIM:$PATH"; export PATH

mkpkg() {
  local dir="$1" id="$2" fail_install="${3:-0}" fail_smoke="${4:-0}" corrupt_restore="${5:-0}" crash_parent="${6:-0}" wait_signal="${7:-0}"
  mkdir -p "$dir"
  cat > "$dir/airlock-app.toml" <<EOF
contract = 1
id = "$id"
[artifacts]
webroot = ["$id/"]
EOF
  cat > "$dir/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
if [ "$corrupt_restore" = 1 ]; then
  _archive="\$(find "\$AIRLOCK_STATE_DIR/install-checkpoints" -name '*.tar' -print -quit)"
  printf 'fixture-corruption\n' >> "\$_archive"
fi
if [ "$crash_parent" = 1 ]; then
  printf 'ready\n' > "$TMP/crash-ready"
  kill -9 "\$(cat "\${AIRLOCK_FIXTURE_CRASH_PID_FILE:?}")"
  exit 137
fi
if [ "$wait_signal" = 1 ]; then
  printf 'ready\n' > "$TMP/signal-ready"
  sleep 2
fi
if [ "$fail_install" = 1 ]; then
  printf 'fixture install failure: %s\n' "\$AIRLOCK_APP_ID" >&2
  exit 42
fi
mkdir -p "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID"
printf 'version=%s\n' "$(basename "$dir")" > "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID/marker"
EOF
  cat > "$dir/smoke.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ -f "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID/marker" ]
if [ "$fail_smoke" = 1 ]; then exit 43; fi
EOF
  cat > "$dir/deactivate.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$AIRLOCK_APP_ID" >> "$TMP/deactivate.log"
rm -f "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID/marker"
rmdir "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID" 2>/dev/null || true
EOF
  chmod +x "$dir"/*.sh
}

reset_fixture() {
  rm -rf "$STATE" "$WEB" "$CONFD" "$UU" "$US" "$FAKEHOME" "$DATA"
  rm -rf "$TMP/devmon-v2" "$TMP/devmon-systemctl-state"
  rm -f "$TMP/deactivate.log" "$TMP/systemctl.log" "$TMP/tailscale.log" \
    "$TMP/crash-ready" "$TMP/signal-ready" "$TMP/devmon-nginx-fail"
  mkdir -p "$STATE" "$WEB/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d" \
    "$UU" "$US" "$FAKEHOME" "$DATA"
}

mkcfg() {
  local path="$1" failer_dir="$2" victim_dir="$3"
  cat > "$path" <<EOF
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
[apps.failer]
[packages.failer]
path = "$failer_dir"
[apps.victim]
[packages.victim]
path = "$victim_dir"
EOF
}

orch() {
  HOME="$FAKEHOME" AIRLOCK_CONFIG="$1" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
    AIRLOCK_SELFKILL_CGROUP_FILE="$TMP/cgroup" \
    bash "$ROOT/install/airlock-install.sh"
}

ledger_has_committed() {
  python3 - "$STATE/app-ledger.json" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if (d.get("entries", {}).get(sys.argv[2]) or {}).get("committed") else 1)
PY
}

tx_phase() {
  "$ROOT/bin/airlock-ledger" transaction-show \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["phase"])' 2>/dev/null
}

install_v1_pair() {
  local cfg="$1"
  mkpkg "$TMP/failer-v1" failer 0
  mkpkg "$TMP/victim-v1" victim 0
  mkcfg "$cfg" "$TMP/failer-v1" "$TMP/victim-v1"
  orch "$cfg" > "$TMP/first.log" 2>&1
}

prepare_devmon_migration() {
  local cfg="$1" db_state="$FAKEHOME/.local/state/airlock/dev-monitor"
  mkpkg "$TMP/devmon-v1" dev-monitor 0
  cp "$ROOT/apps/dev-monitor/airlock-app.toml" "$TMP/devmon-v1/airlock-app.toml"
  python3 - "$TMP/devmon-v1/airlock-app.toml" "$TMP/devmon-v1/install.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace(
    ',\n         { name = "airlock-dev-monitor-spool-firewall.service", scope = "system" }',
    '').replace(
        'rooted = ["/etc/airlock/dev-monitor-spool.nft",\n'
        '          "/opt/airlock/libexec/airlock-dev-monitor-spool-firewall"]',
        'rooted = []'))
install = Path(sys.argv[2])
install.write_text(install.read_text().replace(
    'set -euo pipefail\n',
    'set -euo pipefail\n'
    'backend_port="${AIRLOCK_DEV_MONITOR_BACKEND_PORT:-19923}"\n'
    'mkdir -p "$AIRLOCK_UNIT_DIR_USER"\n'
    'for unit in airlock-devmon-heartbeat.timer airlock-devmon-heartbeat.service '
    'airlock-dev-monitor.service; do printf "[Unit]\\n" > '
    '"$AIRLOCK_UNIT_DIR_USER/$unit"; done\n', 1))
PY
  cat > "$cfg" <<EOF
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
[apps.dev-monitor]
[packages.dev-monitor]
path = "$TMP/devmon-v1"
EOF
  orch "$cfg" >"$TMP/devmon-first.log" 2>&1 || return 1

  cp -a "$ROOT/apps/dev-monitor" "$TMP/devmon-v2"
  cp "$TMP/devmon-v1/airlock-app.toml" "$TMP/devmon-v2/airlock-app.toml"
  cat > "$TMP/devmon-v2/install-spool-hardening.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
state=
while [ "$#" -gt 0 ]; do
  case "$1" in --state) state="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$state/spool/tmp" "$state/spool/new"
chmod 3770 "$state/spool/tmp" "$state/spool/new"
STUB
  chmod +x "$TMP/devmon-v2/install-spool-hardening.sh"
  python3 - "$ROOT/apps/dev-monitor/test-migrate-legacy-state.py" "$db_state" <<'PY'
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location('migration_fixture', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.make_legacy(Path(sys.argv[2])).close()
PY
  mkdir -p "$db_state/spool/tmp" "$db_state/spool/new" "$TMP/devmon-systemctl-state"
  chmod 3770 "$db_state/spool/tmp" "$db_state/spool/new"
  cat > "$cfg" <<EOF
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
[apps.dev-monitor]
messages = true
spool_writer_user = "fixture_writer"
spool_writer_group = "fixture_writers"
[packages.dev-monitor]
path = "$TMP/devmon-v2"
EOF
}

devmon_orch() {
  AIRLOCK_FIXTURE_SYSTEMCTL_STATE="$TMP/devmon-systemctl-state" \
  AIRLOCK_FIXTURE_DB="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db" \
  AIRLOCK_FIXTURE_CROSS_UID=1 \
  AIRLOCK_FIXTURE_NGINX_FAIL="${AIRLOCK_FIXTURE_NGINX_FAIL:-}" \
    orch "$1"
}

unchanged() {
  reset_fixture
  local cfg="$TMP/unchanged.toml" rc=0
  install_v1_pair "$cfg" || { bad "unchanged: setup failed"; return; }
  orch "$cfg" > "$TMP/unchanged.log" 2>&1 || rc=$?
  if [ "$rc" = 0 ] && [ "$(tx_phase)" = committed ] \
      && ledger_has_committed failer && ledger_has_committed victim; then
    ok "unchanged: reconcile commits a terminal transaction without deactivation"
  else
    bad "unchanged: rc=$rc phase=$(tx_phase 2>/dev/null || echo none)"
  fi
}

upgrade_success() {
  reset_fixture
  local cfg="$TMP/upgrade.toml" rc=0
  install_v1_pair "$cfg" || { bad "upgrade-success: setup failed"; return; }
  : > "$TMP/deactivate.log"
  mkpkg "$TMP/failer-v2" failer 0
  mkpkg "$TMP/victim-v2" victim 0
  mkcfg "$cfg" "$TMP/failer-v2" "$TMP/victim-v2"
  orch "$cfg" > "$TMP/upgrade.log" 2>&1 || rc=$?
  if [ "$rc" = 0 ] && [ "$(tx_phase)" = committed ] \
      && grep -qx 'version=failer-v2' "$WEB/failer/marker" \
      && grep -qx 'version=victim-v2' "$WEB/victim/marker"; then
    ok "upgrade-success: each changed app deactivates at its turn and the transaction commits"
  else
    bad "upgrade-success: rc=$rc phase=$(tx_phase 2>/dev/null || echo none)"
  fi
}

fail_before_mutation() {
  reset_fixture
  local cfg="$TMP/preflight-fail.toml" rc=0
  install_v1_pair "$cfg" || { bad "fail-before-mutation: setup failed"; return; }
  : > "$TMP/deactivate.log"
  mkpkg "$TMP/failer-v2" failer 0
  cat >> "$TMP/failer-v2/airlock-app.toml" <<'EOF'
[[prerequisites]]
command = "airlock-fixture-command-that-does-not-exist"
predicate = "present"
expected = "-"
fix = "install fixture"
note = "negative control"
EOF
  mkpkg "$TMP/victim-v2" victim 0
  mkcfg "$cfg" "$TMP/failer-v2" "$TMP/victim-v2"
  orch "$cfg" > "$TMP/preflight-fail.log" 2>&1 || rc=$?
  if [ "$rc" != 0 ] && [ ! -s "$TMP/deactivate.log" ] \
      && grep -qx 'version=failer-v1' "$WEB/failer/marker" \
      && grep -qx 'version=victim-v1' "$WEB/victim/marker"; then
    ok "fail-before-mutation: candidate prerequisite failure leaves both committed apps untouched"
  else
    bad "fail-before-mutation: rc=$rc deactivations=$(wc -l < "$TMP/deactivate.log")"
  fi
}

fail_after_deactivate() {
  reset_fixture
  local cfg="$TMP/fail-install.toml" rc=0
  install_v1_pair "$cfg" || { bad "fail-after-deactivate: setup failed"; return; }
  : > "$TMP/deactivate.log"
  mkpkg "$TMP/failer-v2" failer 1
  mkpkg "$TMP/victim-v2" victim 0
  mkcfg "$cfg" "$TMP/failer-v2" "$TMP/victim-v2"
  orch "$cfg" > "$TMP/fail-install.log" 2>&1 || rc=$?
  if [ "$rc" != 0 ] && [ "$(tx_phase)" = rolled_back ] \
      && grep -qx 'version=failer-v1' "$WEB/failer/marker" \
      && grep -qx 'version=victim-v1' "$WEB/victim/marker" \
      && ledger_has_committed failer && ledger_has_committed victim; then
    ok "fail-after-deactivate: failed app rolls back and the not-yet-visited app stays live"
  else
    bad "fail-after-deactivate: rc=$rc phase=$(tx_phase 2>/dev/null || echo none)"
  fi
}

incident_chain() {
  fail_after_deactivate
}

fail_before_commit() {
  reset_fixture
  local cfg="$TMP/fail-smoke.toml" rc=0
  install_v1_pair "$cfg" || { bad "fail-before-commit: setup failed"; return; }
  mkpkg "$TMP/failer-v2" failer 0 1
  mkpkg "$TMP/victim-v2" victim 0
  mkcfg "$cfg" "$TMP/failer-v2" "$TMP/victim-v2"
  orch "$cfg" > "$TMP/fail-smoke.log" 2>&1 || rc=$?
  if [ "$rc" != 0 ] && [ "$(tx_phase)" = rolled_back ] \
      && grep -qx 'version=failer-v1' "$WEB/failer/marker" \
      && grep -qx 'version=victim-v1' "$WEB/victim/marker"; then
    ok "fail-before-commit: smoke failure compensates every touched app"
  else
    bad "fail-before-commit: rc=$rc phase=$(tx_phase 2>/dev/null || echo none)"
  fi
}

restore_denied() {
  reset_fixture
  local cfg="$TMP/restore-denied.toml" rc=0
  install_v1_pair "$cfg" || { bad "restore-denied: setup failed"; return; }
  mkpkg "$TMP/failer-v2" failer 1 0 1
  mkpkg "$TMP/victim-v2" victim 0
  mkcfg "$cfg" "$TMP/failer-v2" "$TMP/victim-v2"
  orch "$cfg" > "$TMP/restore-denied.log" 2>&1 || rc=$?
  local durable_errors
  durable_errors="$(python3 - "$STATE/install-transaction.json" <<'PY'
import json, sys
tx = json.load(open(sys.argv[1], encoding="utf-8"))
error = tx.get("error") or {}
print(error.get("phase", ""), error.get("app", ""), error.get("message", ""))
print(error.get("restore_message", ""))
PY
)"
  if [ "$rc" != 0 ] && [ "$(tx_phase)" = degraded ] \
      && grep -q 'fixture install failure: failer' "$TMP/restore-denied.log" \
      && grep -q 'checkpoint digest mismatch' "$TMP/restore-denied.log" \
      && grep -q 'result=degraded' "$TMP/restore-denied.log" \
      && [[ "$durable_errors" == *"install failer installer exited rc=42"* ]] \
      && [[ "$durable_errors" == *"checkpoint digest mismatch"* ]]; then
    ok "restore-denied: corrupt checkpoint is durable degraded state, never a false rollback success"
  else
    bad "restore-denied: rc=$rc phase=$(tx_phase 2>/dev/null || echo none)"
  fi
}

deactivate_fails() {
  reset_fixture
  local cfg="$TMP/deactivate-fails.toml" rc=0 flag="$TMP/deactivate-fails"
  mkpkg "$TMP/failer-v1" failer 0
  python3 - "$TMP/failer-v1/deactivate.sh" "$flag" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('set -euo pipefail\n', f'set -euo pipefail\n[ -e "{sys.argv[2]}" ] && exit 41\n', 1))
PY
  mkpkg "$TMP/victim-v1" victim 0
  mkcfg "$cfg" "$TMP/failer-v1" "$TMP/victim-v1"
  orch "$cfg" >/dev/null 2>&1 || { bad "deactivate-fails: setup failed"; return; }
  : > "$flag"
  mkpkg "$TMP/failer-v2" failer 0
  mkpkg "$TMP/victim-v2" victim 0
  mkcfg "$cfg" "$TMP/failer-v2" "$TMP/victim-v2"
  orch "$cfg" > "$TMP/deactivate-fails.log" 2>&1 || rc=$?
  if [ "$rc" != 0 ] && [ "$(tx_phase)" = rolled_back ] \
      && grep -q 'result=rolled_back' "$TMP/deactivate-fails.log" \
      && grep -qx 'version=victim-v1' "$WEB/victim/marker"; then
    ok "deactivate-fails: platform compensation restores the failed app; next app stays live"
  else
    bad "deactivate-fails: rc=$rc phase=$(tx_phase 2>/dev/null || echo none)"
    tail -30 "$TMP/deactivate-fails.log" | sed 's/^/    /'
  fi
}

crash_and_reenter() {
  reset_fixture
  local cfg="$TMP/crash.toml" pidfile="$TMP/orch.pid" rc=0
  install_v1_pair "$cfg" || { bad "crash-and-reenter: setup failed"; return; }
  mkpkg "$TMP/failer-v2" failer 0 0 0 1
  mkpkg "$TMP/victim-v2" victim 0
  mkcfg "$cfg" "$TMP/failer-v2" "$TMP/victim-v2"
  HOME="$FAKEHOME" AIRLOCK_CONFIG="$cfg" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
    AIRLOCK_SELFKILL_CGROUP_FILE="$TMP/cgroup" AIRLOCK_FIXTURE_CRASH_PID_FILE="$pidfile" \
    bash -c 'printf "%s\n" "$$" > "$AIRLOCK_FIXTURE_CRASH_PID_FILE"; exec bash "$1"' \
      -- "$ROOT/install/airlock-install.sh" > "$TMP/crash-first.log" 2>&1 || rc=$?
  # Change the fixture script so the recovery run can proceed after restoring v1.
  mkpkg "$TMP/failer-v2" failer 0
  orch "$cfg" > "$TMP/crash-second.log" 2>&1
  local retry_rc=$?
  if [ "$rc" != 0 ] && [ "$retry_rc" = 0 ] \
      && grep -q 'recovering unfinished install transaction' "$TMP/crash-second.log" \
      && [ "$(tx_phase)" = committed ]; then
    ok "crash-and-reenter: a fresh installer recovers first, then performs the new candidate"
  else
    bad "crash-and-reenter: crash_rc=$rc retry_rc=$retry_rc phase=$(tx_phase 2>/dev/null || echo none)"
  fi
}

signal_term() {
  reset_fixture
  local cfg="$TMP/signal.toml" pidfile="$TMP/signal-orch.pid" runner rc=0 i=0
  install_v1_pair "$cfg" || { bad "signal-term: setup failed"; return; }
  mkpkg "$TMP/failer-v2" failer 0 0 0 0 1
  mkpkg "$TMP/victim-v2" victim 0
  mkcfg "$cfg" "$TMP/failer-v2" "$TMP/victim-v2"
  HOME="$FAKEHOME" AIRLOCK_CONFIG="$cfg" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
    AIRLOCK_SELFKILL_CGROUP_FILE="$TMP/cgroup" AIRLOCK_FIXTURE_CRASH_PID_FILE="$pidfile" \
    bash -c 'printf "%s\n" "$$" > "$AIRLOCK_FIXTURE_CRASH_PID_FILE"; exec bash "$1"' \
      -- "$ROOT/install/airlock-install.sh" > "$TMP/signal.log" 2>&1 &
  runner=$!
  # A full candidate preflight/checkpoint can exceed five seconds on a loaded
  # runner. Wait up to twenty seconds for the deterministic post-deactivation
  # marker; the signal is still injected at the same production boundary.
  while [ "$i" -lt 400 ] && [ ! -e "$TMP/signal-ready" ]; do sleep 0.05; i=$((i + 1)); done
  if [ ! -e "$TMP/signal-ready" ]; then
    kill "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    bad "signal-term: fixture never reached the post-deactivation wait"
    return
  fi
  kill -TERM "$(cat "$pidfile")"
  wait "$runner" || rc=$?
  if [ "$rc" = 143 ] && [ "$(tx_phase)" = rolled_back ] \
      && grep -qx 'version=failer-v1' "$WEB/failer/marker" \
      && grep -qx 'version=victim-v1' "$WEB/victim/marker"; then
    ok "signal-term: SIGTERM exits 143 and compensates the touched app"
  else
    bad "signal-term: rc=$rc phase=$(tx_phase 2>/dev/null || echo none)"
  fi
}

resource_handoff() {
  reset_fixture
  local cfg="$TMP/handoff.toml" rc=0
  mkpkg "$TMP/old-v1" old 0
  cat > "$cfg" <<EOF
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
[apps.old]
[packages.old]
path = "$TMP/old-v1"
EOF
  orch "$cfg" > "$TMP/handoff-first.log" 2>&1 || { bad "resource-handoff: setup failed"; return; }
  mkpkg "$TMP/new-v1" new 0
  python3 - "$TMP/new-v1/airlock-app.toml" "$TMP/new-v1/install.sh" "$TMP/new-v1/smoke.sh" <<'PY'
from pathlib import Path
import sys
manifest, install, smoke = map(Path, sys.argv[1:])
manifest.write_text(manifest.read_text().replace('webroot = ["new/"]', 'webroot = ["old/"]'))
install.write_text(install.read_text().replace('/$AIRLOCK_APP_ID', '/old'))
smoke.write_text(smoke.read_text().replace('/$AIRLOCK_APP_ID', '/old'))
PY
  cat > "$cfg" <<EOF
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
[apps.new]
[packages.new]
path = "$TMP/new-v1"
EOF
  orch "$cfg" > "$TMP/handoff-second.log" 2>&1 || rc=$?
  if [ "$rc" = 0 ] && grep -q "resource handoff: removing 'old' immediately before 'new'" "$TMP/handoff-second.log" \
      && ! ledger_has_committed old && ledger_has_committed new; then
    ok "resource-handoff: only the overlapping old owner yields immediately before its consumer"
  else
    bad "resource-handoff: rc=$rc"
    tail -30 "$TMP/handoff-second.log" | sed 's/^/    /'
  fi
}

devmon_nginx_failure() {
  reset_fixture
  local cfg="$TMP/devmon.toml" rc=0 db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db"
  prepare_devmon_migration "$cfg" \
    || { bad "devmon-nginx-failure: setup failed"; tail -30 "$TMP/devmon-first.log"; return; }
  printf 'rc77\n' >"$TMP/devmon-nginx-fail"
  AIRLOCK_FIXTURE_NGINX_FAIL="$TMP/devmon-nginx-fail" \
    devmon_orch "$cfg" >"$TMP/devmon-nginx.log" 2>&1 || rc=$?
  local starts
  starts="$(grep '^start-schema=' "$TMP/systemctl.log" | tail -6 || true)"
  if [ "$rc" = 77 ] && [ "$(tx_phase)" = rolled_back ] \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "$db")" = legacy ] \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "${db}.pre-endstate")" = legacy ] \
      && [ "$(printf '%s\n' "$starts" | grep -c '^start-schema=legacy ')" = 6 ] \
      && [ "$(stat -c %a "${db%/messages.db}/spool/tmp")" = 3770 ] \
      && ! find "$STATE/install-checkpoints" -name dev-monitor-migration.json -print -quit | grep -q .; then
    ok "devmon-nginx-failure: post-app rc77 restores DB before six old units and ledger"
  else
    bad "devmon-nginx-failure: rc=$rc phase=$(tx_phase 2>/dev/null || echo none)"
    printf '    starts(last6)=%s tmp_mode=%s receipt=%s\n' "$starts" \
      "$(stat -c %a "${db%/messages.db}/spool/tmp" 2>/dev/null || echo missing)" \
      "$(find "$STATE/install-checkpoints" -name dev-monitor-migration.json -print -quit)"
    tail -35 "$TMP/devmon-nginx.log" | sed 's/^/    /'
  fi
}

devmon_restore_refused() {
  reset_fixture
  local cfg="$TMP/devmon-refused.toml" rc=0
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db"
  prepare_devmon_migration "$cfg" \
    || { bad "devmon-restore-refused: setup failed"; tail -30 "$TMP/devmon-first.log"; return; }
  printf 'modify\n' >"$TMP/devmon-nginx-fail"
  AIRLOCK_FIXTURE_NGINX_FAIL="$TMP/devmon-nginx-fail" \
    devmon_orch "$cfg" >"$TMP/devmon-refused.log" 2>&1 || rc=$?
  local current stopped
  current="$(python3 - "$db" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
print(db.execute("SELECT title FROM cards WHERE card_id='card-safe'").fetchone()[0])
db.close()
PY
)"
  stopped="$(find "$TMP/devmon-systemctl-state" -name '*.stopped' | wc -l)"
  if [ "$rc" = 77 ] && [ "$(tx_phase)" = degraded ] \
      && [ "$current" = later-write ] \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "$db")" = canonical ] \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "${db}.pre-endstate")" = legacy ] \
      && [ "$stopped" = 6 ] \
      && [ "$(stat -c %a "${db%/messages.db}/spool/tmp")" = 3750 ] \
      && find "$STATE/install-checkpoints" -name dev-monitor-migration.json -print -quit | grep -q .; then
    ok "devmon-restore-refused: later DB write is preserved and incompatible old writers stay stopped"
  else
    bad "devmon-restore-refused: rc=$rc phase=$(tx_phase 2>/dev/null || echo none) stopped=$stopped"
    tail -35 "$TMP/devmon-refused.log" | sed 's/^/    /'
  fi
}

devmon_standalone_fallback() {
  reset_fixture
  local cfg="$TMP/devmon-standalone.toml" rc=0
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db"
  prepare_devmon_migration "$cfg" \
    || { bad "devmon-standalone-fallback: setup failed"; tail -30 "$TMP/devmon-first.log"; return; }
  printf '%s\n' '#!/usr/bin/env bash' 'exit 77' \
    >"$TMP/devmon-v2/install-spool-hardening.sh"
  chmod +x "$TMP/devmon-v2/install-spool-hardening.sh"
  HOME="$FAKEHOME" AIRLOCK_CONFIG="$cfg" AIRLOCK_TS_FQDN=box.example.ts.net \
    AIRLOCK_FIXTURE_SYSTEMCTL_STATE="$TMP/devmon-systemctl-state" \
    AIRLOCK_FIXTURE_DB="$db" AIRLOCK_FIXTURE_CROSS_UID=1 \
    AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$TMP/devmon-v2" AIRLOCK_APP_ID=dev-monitor \
    bash "$TMP/devmon-v2/install.sh" >"$TMP/devmon-standalone.log" 2>&1 || rc=$?
  local starts
  starts="$(grep '^start-schema=' "$TMP/systemctl.log" | tail -6 || true)"
  if [ "$rc" = 77 ] \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "$db")" = legacy ] \
      && [ "$(printf '%s\n' "$starts" | grep -c '^start-schema=legacy ')" = 6 ] \
      && [ "$(stat -c %a "${db%/messages.db}/spool/tmp")" = 3770 ]; then
    ok "devmon-standalone-fallback: direct D5 install restores DB, spool, and six units"
  else
    bad "devmon-standalone-fallback: rc=$rc"
    tail -35 "$TMP/devmon-standalone.log" | sed 's/^/    /'
  fi
}

devmon_crash_reentry() {
  reset_fixture
  local cfg="$TMP/devmon-crash.toml" rc=0 retry_rc=0
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db" pidfile="$TMP/devmon.pid"
  prepare_devmon_migration "$cfg" \
    || { bad "devmon-crash-reentry: setup failed"; tail -30 "$TMP/devmon-first.log"; return; }
  printf 'crash\n' >"$TMP/devmon-nginx-fail"
  HOME="$FAKEHOME" AIRLOCK_CONFIG="$cfg" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
    AIRLOCK_SELFKILL_CGROUP_FILE="$TMP/cgroup" \
    AIRLOCK_FIXTURE_SYSTEMCTL_STATE="$TMP/devmon-systemctl-state" \
    AIRLOCK_FIXTURE_DB="$db" AIRLOCK_FIXTURE_CROSS_UID=1 \
    AIRLOCK_FIXTURE_NGINX_FAIL="$TMP/devmon-nginx-fail" \
    AIRLOCK_FIXTURE_CRASH_PID_FILE="$pidfile" \
    bash -c 'printf "%s\n" "$$" > "$AIRLOCK_FIXTURE_CRASH_PID_FILE"; exec bash "$1"' \
      -- "$ROOT/install/airlock-install.sh" >"$TMP/devmon-crash-first.log" 2>&1 || rc=$?
  if ! find "$STATE/install-checkpoints" -name dev-monitor-migration.json -print -quit | grep -q .; then
    bad "devmon-crash-reentry: crash left no durable migration receipt"
    return
  fi
  rm -f "$TMP/devmon-nginx-fail"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$TMP/devmon-v2/smoke.sh"
  chmod +x "$TMP/devmon-v2/smoke.sh"
  devmon_orch "$cfg" >"$TMP/devmon-crash-second.log" 2>&1 || retry_rc=$?
  if [ "$rc" != 0 ] && [ "$retry_rc" = 0 ] && [ "$(tx_phase)" = committed ] \
      && grep -q 'recovering unfinished install transaction' "$TMP/devmon-crash-second.log" \
      && grep -q '^start-schema=legacy ' "$TMP/systemctl.log" \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "$db")" = canonical ] \
      && ! find "$STATE/install-checkpoints" -name dev-monitor-migration.json -print -quit | grep -q .; then
    ok "devmon-crash-reentry: recovery compensates DB before ledger, then the retry commits"
  else
    bad "devmon-crash-reentry: crash_rc=$rc retry_rc=$retry_rc phase=$(tx_phase 2>/dev/null || echo none)"
    tail -35 "$TMP/devmon-crash-second.log" | sed 's/^/    /'
  fi
}

current_blast() {
  # Compatibility alias retained for phase-0 evidence consumers. The oracle
  # now proves the regression is closed rather than reproducing the defect.
  fail_after_deactivate
}

case "$case_name" in
  unchanged) unchanged ;;
  upgrade-success) upgrade_success ;;
  fail-before-mutation) fail_before_mutation ;;
  orca-require-fails-after-paseo-planned) incident_chain ;;
  fail-after-deactivate) fail_after_deactivate ;;
  fail-before-commit) fail_before_commit ;;
  restore-denied) restore_denied ;;
  deactivate-fails) deactivate_fails ;;
  crash-and-reenter) crash_and_reenter ;;
  signal-term) signal_term ;;
  resource-handoff) resource_handoff ;;
  devmon-nginx-failure) devmon_nginx_failure ;;
  devmon-restore-refused) devmon_restore_refused ;;
  devmon-standalone-fallback) devmon_standalone_fallback ;;
  devmon-crash-reentry) devmon_crash_reentry ;;
  current-blast) current_blast ;;
  all)
    unchanged
    upgrade_success
    fail_before_mutation
    fail_after_deactivate
    fail_before_commit
    restore_denied
    deactivate_fails
    crash_and_reenter
    signal_term
    resource_handoff
    devmon_nginx_failure
    devmon_restore_refused
    devmon_standalone_fallback
    devmon_crash_reentry
    ;;
  *) bad "unknown case: $case_name" ;;
esac

printf '%s\n' "---" "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
