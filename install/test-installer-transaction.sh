#!/usr/bin/env bash
# Installer ordering/rollback regression fixtures. Everything is scratch + shims.
set -uo pipefail

# Package digests must not depend on whether an earlier suite warmed Python's
# ignored bytecode cache in the source checkout. The fixture executes Python
# from inside its candidate tree, so suppress runtime cache writes as well.
export PYTHONDONTWRITEBYTECODE=1

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
# A real backend start is a DB write even when no message arrives: init_db() in
# apps/dev-monitor/backend/devmon_messages.py switches a canonical DB to WAL,
# which rewrites the header bytes a conversion marker hashed. The 2026-09-11
# incident was exactly this; a stub that only records the start cannot see it.
devmon_backend_opens_db() {
  case "\$*" in *airlock-dev-monitor.service*) ;; *) return 0 ;; esac
  [ -n "\${AIRLOCK_FIXTURE_DB:-}" ] && [ -e "\$AIRLOCK_FIXTURE_DB" ] || return 0
  [ "\$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" \
    --schema-state "\$AIRLOCK_FIXTURE_DB")" = canonical ] || return 0
  python3 -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("PRAGMA journal_mode=WAL"); c.close()' \
    "\$AIRLOCK_FIXTURE_DB"
}
case "\${1:-}:\${2:-}" in --user:start|--user:restart) devmon_backend_opens_db "\$@" ;; esac
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
    corrupt)
      # Not a canonical database any more: the exact-schema check must refuse it.
      python3 -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("DROP INDEX cards_send"); c.commit(); c.close()' \
        "$AIRLOCK_FIXTURE_DB"
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
case "$*" in
  *http_code*127.0.0.1:*/api/overview*) printf '%s' "${AIRLOCK_FIXTURE_BACKEND_HTTP_CODE:-200}" ;;
  *http_code*) printf 200 ;;
esac
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
  (
    [ "${AIRLOCK_FIXTURE_UNSET_STATE_DIR:-0}" != 1 ] || unset AIRLOCK_STATE_DIR
    HOME="$FAKEHOME" AIRLOCK_CONFIG="$1" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
      AIRLOCK_SELFKILL_CGROUP_FILE="$TMP/cgroup" \
      bash "$ROOT/install/airlock-install.sh"
  )
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
  find "$TMP/devmon-v2" -type d -name __pycache__ -prune -exec rm -rf -- {} +
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

db_sha() { sha256sum "$1" | cut -d' ' -f1; }

activation_record() { printf '%s/dev-monitor-activation.json\n' "${1:-$STATE}"; }

devmon_nginx_failure() {
  reset_fixture
  local cfg="$TMP/devmon.toml" rc=0 db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db" before
  prepare_devmon_migration "$cfg" \
    || { bad "devmon-nginx-failure: setup failed"; tail -30 "$TMP/devmon-first.log"; return; }
  before="$(db_sha "$db")"
  printf 'rc77\n' >"$TMP/devmon-nginx-fail"
  : >"$TMP/systemctl.log"
  AIRLOCK_FIXTURE_NGINX_FAIL="$TMP/devmon-nginx-fail" \
    devmon_orch "$cfg" >"$TMP/devmon-nginx.log" 2>&1 || rc=$?
  # The candidate never ran: no canonical start, and the old backend is back on legacy.
  if [ "$rc" = 77 ] && [ "$(tx_phase)" = rolled_back ] \
      && [ "$(db_sha "$db")" = "$before" ] \
      && [ ! -e "${db}.pre-endstate" ] \
      && [ ! -e "$(activation_record)" ] \
      && ! grep -q '^start-schema=canonical ' "$TMP/systemctl.log" \
      && grep -q '^start-schema=legacy airlock-dev-monitor.service' "$TMP/systemctl.log" \
      && [ "$(stat -c %a "${db%/messages.db}/spool/tmp")" = 3770 ] \
      && ! find "$STATE/install-checkpoints" -name dev-monitor-migration.json -print -quit | grep -q .; then
    ok "devmon-nginx-failure: a pre-commit failure rolls back with the legacy DB byte-identical and the old backend restarted"
  else
    bad "devmon-nginx-failure: rc=$rc phase=$(tx_phase 2>/dev/null || echo none) same_db=$([ "$(db_sha "$db")" = "$before" ] && echo y || echo n) record=$([ -e "$(activation_record)" ] && echo present || echo none)"
    grep -E '^start-schema=' "$TMP/systemctl.log" | sed 's/^/    /'
    tail -20 "$TMP/devmon-nginx.log" | sed 's/^/    /'
  fi
}

devmon_write_survives_rollback() {
  reset_fixture
  local cfg="$TMP/devmon-refused.toml" rc=0
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db"
  prepare_devmon_migration "$cfg" \
    || { bad "devmon-write-survives-rollback: setup failed"; tail -30 "$TMP/devmon-first.log"; return; }
  # A writer outside the installer's control lands a row mid-transaction. Before
  # activation was deferred this is the state that could only end in `degraded`.
  printf 'modify\n' >"$TMP/devmon-nginx-fail"
  AIRLOCK_FIXTURE_NGINX_FAIL="$TMP/devmon-nginx-fail" \
    devmon_orch "$cfg" >"$TMP/devmon-refused.log" 2>&1 || rc=$?
  local current
  current="$(python3 - "$db" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
print(db.execute("SELECT title FROM cards WHERE card_id='card-safe'").fetchone()[0])
db.close()
PY
)"
  if [ "$rc" = 77 ] && [ "$(tx_phase)" = rolled_back ] \
      && [ "$current" = later-write ] \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "$db")" = legacy ] \
      && [ ! -e "$(activation_record)" ] \
      && [ "$(stat -c %a "${db%/messages.db}/spool/tmp")" = 3770 ]; then
    ok "devmon-write-survives-rollback: a mid-transaction write is kept and the rollback still completes"
  else
    bad "devmon-write-survives-rollback: rc=$rc phase=$(tx_phase 2>/dev/null || echo none) title=$current"
    tail -35 "$TMP/devmon-refused.log" | sed 's/^/    /'
  fi
}

devmon_later_app_fails() {
  # The 2026-09-11 shape: dev-monitor converts, a later app's install fails.
  reset_fixture
  local cfg="$TMP/devmon-late.toml" rc=0 before
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db"
  prepare_devmon_migration "$cfg" \
    || { bad "devmon-later-app-fails: setup failed"; tail -30 "$TMP/devmon-first.log"; return; }
  mkpkg "$TMP/late-v1" late 1
  printf '%s\n' '[apps.late]' '[packages.late]' "path = \"$TMP/late-v1\"" >>"$cfg"
  before="$(db_sha "$db")"
  : >"$TMP/systemctl.log"
  devmon_orch "$cfg" >"$TMP/devmon-late.log" 2>&1 || rc=$?
  if [ "$rc" = 42 ] && [ "$(tx_phase)" = rolled_back ] \
      && grep -q "installing packaged app: late" "$TMP/devmon-late.log" \
      && [ "$(db_sha "$db")" = "$before" ] \
      && [ ! -e "$(activation_record)" ] \
      && grep -q '^start-schema=legacy airlock-dev-monitor.service' "$TMP/systemctl.log" \
      && ! grep -q '^start-schema=canonical ' "$TMP/systemctl.log"; then
    ok "devmon-later-app-fails: a later app's failure rolls back instead of stranding the box degraded"
  else
    bad "devmon-later-app-fails: rc=$rc phase=$(tx_phase 2>/dev/null || echo none)"
    tail -25 "$TMP/devmon-late.log" | sed 's/^/    /'
  fi
}

devmon_activation_resume() {
  reset_fixture
  local cfg="$TMP/devmon-resume.toml" rc=0 retry_rc=0
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db"
  prepare_devmon_migration "$cfg" \
    || { bad "devmon-activation-resume: setup failed"; tail -30 "$TMP/devmon-first.log"; return; }
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$TMP/devmon-v2/smoke.sh"
  chmod +x "$TMP/devmon-v2/smoke.sh"
  AIRLOCK_FIXTURE_BACKEND_HTTP_CODE=503 \
    devmon_orch "$cfg" >"$TMP/devmon-resume-first.log" 2>&1 || rc=$?
  local phase_after_first record_after_first status_after_first
  phase_after_first="$(tx_phase)"
  record_after_first="$([ -e "$(activation_record)" ] && echo present || echo none)"
  status_after_first="$(HOME="$FAKEHOME" AIRLOCK_CONFIG="$cfg" python3 "$ROOT/bin/airlock-status" 2>&1 || true)"
  # As if the run had been killed between fencing the spool and reopening it: the
  # lanes are shut to the writer group. The resume must not adopt that as their mode.
  chmod 3750 "${db%/messages.db}/spool/tmp" "${db%/messages.db}/spool/new"
  devmon_orch "$cfg" >"$TMP/devmon-resume-second.log" 2>&1 || retry_rc=$?
  if [ "$rc" = 1 ] && [ "$phase_after_first" = committed ] && [ "$record_after_first" = present ] \
      && grep -q 'dev-monitor activation did not finish' "$TMP/devmon-resume-first.log" \
      && printf '%s\n' "$status_after_first" | grep -q 'dev-monitor activation for committed transaction .* is still owed' \
      && [ "$retry_rc" = 0 ] \
      && grep -q 'dev-monitor activated' "$TMP/devmon-resume-second.log" \
      && [ ! -e "$(activation_record)" ] \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "$db")" = canonical ] \
      && [ "$(stat -c %a "${db%/messages.db}/spool/tmp")" = 3770 ] \
      && [ "$(stat -c %a "${db%/messages.db}/spool/new")" = 3770 ]; then
    ok "devmon-activation-resume: a failed post-commit activation stays owed, is reported, and the next run finishes it without inheriting a crashed fence"
  else
    bad "devmon-activation-resume: rc=$rc phase=$phase_after_first record=$record_after_first retry_rc=$retry_rc"
    printf '%s\n' "$status_after_first" | grep -i 'activation' | sed 's/^/    status: /'
    tail -15 "$TMP/devmon-resume-first.log" | sed 's/^/    first: /'
    tail -15 "$TMP/devmon-resume-second.log" | sed 's/^/    second: /'
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

devmon_owed_activation_does_not_block_others() {
  # An activation still owed means dev-monitor is stopped. A later run that does not
  # reinstall it must not fail its smoke and roll back unrelated apps.
  reset_fixture
  local cfg="$TMP/devmon-owed.toml" rc=0 second_rc=0
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db"
  prepare_devmon_migration "$cfg" \
    || { bad "devmon-owed-activation: setup failed"; tail -30 "$TMP/devmon-first.log"; return; }
  AIRLOCK_FIXTURE_BACKEND_HTTP_CODE=503 \
    devmon_orch "$cfg" >"$TMP/devmon-owed-first.log" 2>&1 || rc=$?
  [ -e "$(activation_record)" ] \
    || { bad "devmon-owed-activation: the first run left no owed activation"; return; }
  mkpkg "$TMP/other-v1" other 0
  printf '%s\n' '[apps.other]' '[packages.other]' "path = \"$TMP/other-v1\"" >>"$cfg"
  AIRLOCK_FIXTURE_BACKEND_HTTP_CODE=503 \
    devmon_orch "$cfg" >"$TMP/devmon-owed-second.log" 2>&1 || second_rc=$?
  if [ "$rc" = 1 ] && [ "$second_rc" = 1 ] && [ "$(tx_phase)" = committed ] \
      && ledger_has_committed other \
      && grep -q 'smoke: dev-monitor deferred until its post-commit activation' "$TMP/devmon-owed-second.log" \
      && [ -e "$(activation_record)" ]; then
    ok "devmon-owed-activation: an owed activation keeps itself owed without rolling back an unrelated app"
  else
    bad "devmon-owed-activation: rc=$rc second_rc=$second_rc phase=$(tx_phase 2>/dev/null || echo none) other_committed=$(ledger_has_committed other && echo y || echo n)"
    tail -20 "$TMP/devmon-owed-second.log" | sed 's/^/    /'
  fi
}

devmon_activation_record_contract() {
  # The record decides whether an app skips its pre-commit smoke and whether a
  # committed conversion is still owed, so its refusals are part of the contract.
  reset_fixture
  local tool="$ROOT/apps/dev-monitor/activation-record.py" st="$TMP/rec-state" tx=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db" rc=0 checks=0
  mkdir -p "$st/install-checkpoints/$tx" "$(dirname "$db")"
  write_tx() { printf '{"id": "%s", "phase": "%s", "planned": ["dev-monitor"]}\n' "$tx" "$1" >"$st/install-transaction.json"; }
  record_tx() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["transaction_id"])' "$st/dev-monitor-activation.json"; }

  write_tx installing
  HOME="$FAKEHOME" python3 "$tool" write "$st" "$tx" "$db" fixture_writer 19923 dev-monitor >/dev/null 2>&1 \
    && checks=$((checks + 1))
  # Another package holding the same transaction id cannot claim the exemption.
  HOME="$FAKEHOME" python3 "$tool" write "$st" "$tx" "$db" fixture_writer 19923 other >/dev/null 2>&1 \
    || checks=$((checks + 1))
  # A refused write must not have published anything: the record still names this run.
  [ "$(HOME="$FAKEHOME" record_tx)" = "$tx" ] && checks=$((checks + 1))
  # Owed only once the transaction is durably committed.
  HOME="$FAKEHOME" python3 "$tool" due "$st" >/dev/null 2>&1 || checks=$((checks + 1))
  write_tx committed
  HOME="$FAKEHOME" python3 "$tool" due "$st" >/dev/null 2>&1 && checks=$((checks + 1))
  # The durable phase, not the caller, decides: a committed record is never taken back.
  HOME="$FAKEHOME" python3 "$tool" compensate "$st" "$tx" >/dev/null 2>&1 \
    && [ -e "$st/dev-monitor-activation.json" ] && checks=$((checks + 1))
  # An uncommitted one is.
  write_tx installing
  HOME="$FAKEHOME" python3 "$tool" compensate "$st" "$tx" >/dev/null 2>&1 \
    && [ ! -e "$st/dev-monitor-activation.json" ] && checks=$((checks + 1))
  if [ "$checks" = 7 ]; then
    ok "devmon-activation-record: refuses a foreign app, publishes nothing it would refuse, and never takes back a committed record"
  else
    bad "devmon-activation-record: $checks/7 contract checks held"
  fi
}

devmon_fence_recovery() {
  # A run killed between the fence and the reopen leaves the lanes shut. The next
  # activation must not read that back as the mode to preserve. (End to end this is
  # masked whenever dev-monitor is reinstalled in the same run, since its spool
  # hardening rewrites the modes -- so the rule is measured directly.)
  local checks=0
  # shellcheck disable=SC1090
  . "$ROOT/apps/dev-monitor/migration-lifecycle.sh"
  DEVMON_MIGRATION_TMP_MODE=3750 DEVMON_MIGRATION_NEW_MODE=1750
  devmon_activation_forget_fenced_modes >/dev/null 2>&1
  [ "$DEVMON_MIGRATION_TMP_MODE" = - ] && [ "$DEVMON_MIGRATION_NEW_MODE" = - ] && checks=$((checks + 1))
  DEVMON_MIGRATION_TMP_MODE=3770 DEVMON_MIGRATION_NEW_MODE=1770
  devmon_activation_forget_fenced_modes >/dev/null 2>&1
  [ "$DEVMON_MIGRATION_TMP_MODE" = 3770 ] && [ "$DEVMON_MIGRATION_NEW_MODE" = 1770 ] && checks=$((checks + 1))
  DEVMON_MIGRATION_TMP_MODE=- DEVMON_MIGRATION_NEW_MODE=-
  devmon_activation_forget_fenced_modes >/dev/null 2>&1
  [ "$DEVMON_MIGRATION_TMP_MODE" = - ] && checks=$((checks + 1))
  # ...and that the activation path actually asks. The end-to-end run cannot prove it:
  # dev-monitor is a same-digest reinstall on every run, so its spool hardening rewrites
  # the modes afterwards and hides the difference.
  grep -q 'devmon_activation_forget_fenced_modes$' "$ROOT/apps/dev-monitor/migration-lifecycle.sh" \
    && checks=$((checks + 1))
  if [ "$checks" = 4 ]; then
    ok "devmon-fence-recovery: a lane the writer group cannot write is never preserved as its mode"
  else
    bad "devmon-fence-recovery: $checks/4 (tmp=$DEVMON_MIGRATION_TMP_MODE new=$DEVMON_MIGRATION_NEW_MODE)"
  fi
}

devmon_spool_mode_restore() {
  # An operator who owns a lane but is not a member of its group can get rc=0 from
  # chmod while Linux silently clears setgid. Restoration must verify the exact mode,
  # retry through the established operator-UID/writer-GID boundary, and fail closed if
  # even that path does not restore the requested bits.
  local state="$TMP/devmon-spool-mode-restore" checks=0
  rm -rf "$state"
  mkdir -p "$state/spool/tmp" "$state/spool/new"
  /usr/bin/chmod 3750 "$state/spool/tmp" "$state/spool/new"

  # shellcheck disable=SC1090
  . "$ROOT/apps/dev-monitor/migration-lifecycle.sh"
  DEVMON_MIGRATION_TMP_MODE=3770 DEVMON_MIGRATION_NEW_MODE=3770

  # Normal path: an exact ordinary chmod needs no privileged retry.
  if (
    sudo() { return 99; }
    devmon_migration_restore_spool "$state"
  ) && [ "$(stat -c %a "$state/spool/tmp")" = 3770 ] \
      && [ "$(stat -c %a "$state/spool/new")" = 3770 ]; then
    checks=$((checks + 1))
  fi

  /usr/bin/chmod 3750 "$state/spool/tmp" "$state/spool/new"
  # Model the kernel outcome from the live incident: chmod says success but leaves
  # 1770. The retry runs with the lane GID and must restore both lanes exactly.
  if (
    chmod() { /usr/bin/chmod "$@" && /usr/bin/chmod g-s "${@: -1}"; }
    sudo() {
      local target="${!#}" expected_gid expected
      expected_gid="$(stat -c %g "$target")"
      expected="-u root -g root /usr/bin/setpriv --reuid $(id -u) --regid $expected_gid --clear-groups -- /usr/bin/chmod 3770 -- $target"
      [ "$*" = "$expected" ] || return 98
      while [ "$#" -gt 0 ]; do
        case "$1" in -u|-g) shift 2 ;; *) break ;; esac
      done
      if [ "${1:-}" = /usr/bin/setpriv ]; then
        while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
        [ "${1:-}" != -- ] || shift
      fi
      "$@"
    }
    devmon_migration_restore_spool "$state"
  ) && [ "$(stat -c %a "$state/spool/tmp")" = 3770 ] \
      && [ "$(stat -c %a "$state/spool/new")" = 3770 ]; then
    checks=$((checks + 1))
  fi

  /usr/bin/chmod 3750 "$state/spool/tmp" "$state/spool/new"
  # A retry that returns success without restoring the bits must still be rejected.
  if ! (
    chmod() { /usr/bin/chmod "$@" && /usr/bin/chmod g-s "${@: -1}"; }
    sudo() { return 0; }
    devmon_migration_restore_spool "$state"
  ); then
    checks=$((checks + 1))
  fi

  if [ "$checks" = 3 ]; then
    ok "devmon-spool-mode-restore: exact normal, setgid retry, and failed restoration are enforced"
  else
    bad "devmon-spool-mode-restore: $checks/3 mode restoration checks held"
  fi
}

# The pre-#450 orchestrated shape, as a fixture package: convert inside the transaction,
# leave the receipt beside the checkpoint, start the candidate (which opens the DB).
# A box that stopped mid-transaction on an installer of that generation looks like this.
prepare_devmon_receipt_flow() {
  local cfg="$1"
  prepare_devmon_migration "$cfg" || return 1
  cat > "$TMP/devmon-v2/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
. "\$AIRLOCK_ROOT/apps/dev-monitor/migration-lifecycle.sh"
state="\$HOME/.local/state/airlock/dev-monitor"; db="\$state/messages.db"
mkdir -p "\$AIRLOCK_UNIT_DIR_USER"
for unit in airlock-devmon-heartbeat.timer airlock-devmon-heartbeat.service airlock-dev-monitor.service; do
  printf '[Unit]\n' > "\$AIRLOCK_UNIT_DIR_USER/\$unit"
done
bash "\$AIRLOCK_APP_DIR/install-spool-hardening.sh" --state "\$state"
devmon_migration_snapshot "\$state"
receipt="\$AIRLOCK_STATE_DIR/install-checkpoints/\$AIRLOCK_INSTALL_TRANSACTION_ID/dev-monitor-migration.json"
( umask 077; printf '{"version": 1, "transaction_id": "%s", "database": "%s", "writer_user": "fixture_writer", "spool_modes": {"tmp": "3770", "new": "3770"}, "active_units": []}\n' \
  "\$AIRLOCK_INSTALL_TRANSACTION_ID" "\$db" > "\$receipt" )
devmon_migration_quiesce
devmon_migration_fence "\$state" fixture_writer true
python3 "\$AIRLOCK_APP_DIR/migrate-legacy-state.py" --endstate "\$db" --offline >/dev/null
devmon_migration_restore_spool "\$state"
systemctl --user start airlock-dev-monitor.service
mkdir -p "\$AIRLOCK_WEBROOT/dev-monitor"; printf 'v2\n' > "\$AIRLOCK_WEBROOT/dev-monitor/marker"
EOF
  chmod +x "$TMP/devmon-v2/install.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$TMP/devmon-v2/smoke.sh"
  chmod +x "$TMP/devmon-v2/smoke.sh"
}

devmon_receipt_forward_keep() {
  # #448 as it happened: converted, the candidate started, then a later app failed.
  # The old receipt cannot restore without discarding writes, so the candidate is kept
  # and everything else still rolls back -- no `degraded`, and the next run commits.
  reset_fixture
  local cfg="$TMP/devmon-keep.toml" rc=0 second_rc=0 kept status
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db"
  prepare_devmon_receipt_flow "$cfg" \
    || { bad "devmon-receipt-forward-keep: setup failed"; tail -30 "$TMP/devmon-first.log"; return; }
  mkpkg "$TMP/late-v1" late 1
  printf '%s\n' '[apps.late]' '[packages.late]' "path = \"$TMP/late-v1\"" >>"$cfg"
  devmon_orch "$cfg" >"$TMP/devmon-keep.log" 2>&1 || rc=$?
  kept="$("$ROOT/bin/airlock-ledger" transaction-show \
    | python3 -c 'import json,sys; print((json.load(sys.stdin)["restore_results"].get("dev-monitor") or {}).get("status"))' 2>/dev/null)"
  status="$(HOME="$FAKEHOME" AIRLOCK_CONFIG="$cfg" python3 "$ROOT/bin/airlock-status" 2>&1 || true)"
  mkpkg "$TMP/late-v1" late 0
  devmon_orch "$cfg" >"$TMP/devmon-keep-second.log" 2>&1 || second_rc=$?
  if [ "$rc" = 42 ] && [ "$kept" = kept-forward-active ] \
      && grep -q "keeping it" "$TMP/devmon-keep.log" \
      && grep -q "rolled_back" "$TMP/devmon-keep.log" \
      && printf '%s\n' "$status" | grep -q 'dev-monitor kept its candidate' \
      && ! find "$STATE/install-checkpoints" -name dev-monitor-migration.json -print -quit | grep -q . \
      && [ "$second_rc" = 0 ] && [ "$(tx_phase)" = committed ] \
      && ledger_has_committed dev-monitor && ledger_has_committed late \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "$db")" = canonical ] \
      && [ "$(stat -c %a "${db%/messages.db}/spool/tmp")" = 3770 ]; then
    ok "devmon-receipt-forward-keep: an old-receipt refusal keeps the candidate, rolls the rest back, and the next run commits"
  else
    bad "devmon-receipt-forward-keep: rc=$rc kept=$kept second_rc=$second_rc phase=$(tx_phase 2>/dev/null || echo none)"
    tail -20 "$TMP/devmon-keep.log" | sed 's/^/    first: /'
    tail -12 "$TMP/devmon-keep-second.log" | sed 's/^/    second: /'
  fi
}

devmon_receipt_degraded_reentry() {
  # The box #448 left behind: an old-generation transaction already marked degraded,
  # its receipt still beside the checkpoint, the converted DB written to. The next
  # installer must get past the refusal on its own and go on to commit.
  reset_fixture
  local cfg="$TMP/devmon-reentry.toml" rc=0 second_rc=0 pidfile="$TMP/devmon-reentry.pid"
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db"
  prepare_devmon_receipt_flow "$cfg" \
    || { bad "devmon-receipt-degraded-reentry: setup failed"; return; }
  printf 'crash\n' >"$TMP/devmon-nginx-fail"
  HOME="$FAKEHOME" AIRLOCK_CONFIG="$cfg" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
    AIRLOCK_SELFKILL_CGROUP_FILE="$TMP/cgroup" \
    AIRLOCK_FIXTURE_SYSTEMCTL_STATE="$TMP/devmon-systemctl-state" \
    AIRLOCK_FIXTURE_DB="$db" AIRLOCK_FIXTURE_CROSS_UID=1 \
    AIRLOCK_FIXTURE_NGINX_FAIL="$TMP/devmon-nginx-fail" \
    AIRLOCK_FIXTURE_CRASH_PID_FILE="$pidfile" \
    bash -c 'printf "%s\n" "$$" > "$AIRLOCK_FIXTURE_CRASH_PID_FILE"; exec bash "$1"' \
      -- "$ROOT/install/airlock-install.sh" >"$TMP/devmon-reentry-first.log" 2>&1 || rc=$?
  find "$STATE/install-checkpoints" -name dev-monitor-migration.json -print -quit | grep -q . \
    || { bad "devmon-receipt-degraded-reentry: the crash left no receipt to refuse"; return; }
  # As the old installer's cleanup would have left it.
  AIRLOCK_TRANSACTION_ERROR="fixture: old-generation compensation refused" \
    "$ROOT/bin/airlock-ledger" transaction-fail final-render dev-monitor >/dev/null 2>&1 \
    || { bad "devmon-receipt-degraded-reentry: could not mark the transaction degraded"; return; }
  rm -f "$TMP/devmon-nginx-fail"
  devmon_orch "$cfg" >"$TMP/devmon-reentry-second.log" 2>&1 || second_rc=$?
  if [ "$rc" != 0 ] && [ "$second_rc" = 0 ] && [ "$(tx_phase)" = committed ] \
      && grep -q 'recovering unfinished install transaction' "$TMP/devmon-reentry-second.log" \
      && grep -q 'keeping it' "$TMP/devmon-reentry-second.log" \
      && ledger_has_committed dev-monitor \
      && ! find "$STATE/install-checkpoints" -name dev-monitor-migration.json -print -quit | grep -q . \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "$db")" = canonical ]; then
    ok "devmon-receipt-degraded-reentry: a box left degraded by an old receipt recovers forward and the retry commits"
  else
    bad "devmon-receipt-degraded-reentry: crash_rc=$rc second_rc=$second_rc phase=$(tx_phase 2>/dev/null || echo none)"
    grep -nE 'recovering|keeping|kept|schema|compensat|WARN' "$TMP/devmon-reentry-second.log" | head -12 | sed 's/^/    /'
  fi
}

devmon_keep_forward_is_bound() {
  # The decision that exempts an app from rollback must not be mintable by anyone who
  # merely knows the transaction id, and must not outlive the evidence it rests on.
  reset_fixture
  local cfg="$TMP/devmon-bound.toml" rc=0 checks=0 out
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db"
  prepare_devmon_receipt_flow "$cfg" \
    || { bad "devmon-keep-forward-bound: setup failed"; return; }
  # A package installer that tries to keep itself: rejected by name and by transaction.
  cat > "$TMP/devmon-v2/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"\$AIRLOCK_ROOT/bin/airlock-ledger" transaction-keep-forward late "$db" \
  0000000000000000000000000000000000000000000000000000000000000000 \
  0000000000000000000000000000000000000000000000000000000000000000 2>>"$TMP/keep-attempts.log" \
  && printf 'late-kept\n' >>"$TMP/keep-attempts.log" || true
"\$AIRLOCK_ROOT/bin/airlock-ledger" transaction-keep-forward dev-monitor "$db" \
  0000000000000000000000000000000000000000000000000000000000000000 \
  0000000000000000000000000000000000000000000000000000000000000000 2>>"$TMP/keep-attempts.log" \
  && printf 'devmon-kept\n' >>"$TMP/keep-attempts.log" || true
mkdir -p "\$AIRLOCK_UNIT_DIR_USER"; printf '[Unit]\n' > "\$AIRLOCK_UNIT_DIR_USER/airlock-dev-monitor.service"
mkdir -p "\$AIRLOCK_WEBROOT/dev-monitor"; printf 'v2\n' > "\$AIRLOCK_WEBROOT/dev-monitor/marker"
EOF
  mkpkg "$TMP/late-v1" late 1
  printf '%s\n' '[apps.late]' '[packages.late]' "path = \"$TMP/late-v1\"" >>"$cfg"
  devmon_orch "$cfg" >"$TMP/devmon-bound.log" 2>&1 || rc=$?
  out="$(cat "$TMP/keep-attempts.log" 2>/dev/null)"
  # Neither attempt produced a decision: a foreign app is refused by name, and a
  # dev-monitor decision with hashes the database does not bear is refused as evidence.
  ! grep -q 'kept$' <<<"$out" && checks=$((checks + 1))
  grep -q 'only dev-monitor can be kept forward' <<<"$out" && checks=$((checks + 1))
  grep -q 'refusing to keep dev-monitor forward' <<<"$out" && checks=$((checks + 1))
  # ...and the run rolled back normally, with the previous dev-monitor restored.
  [ "$rc" = 42 ] && [ "$(tx_phase)" = rolled_back ] \
    && [ "$("$ROOT/bin/airlock-ledger" transaction-show | python3 -c 'import json,sys; print("forward_keep" in json.load(sys.stdin))')" = False ] \
    && checks=$((checks + 1))
  if [ "$checks" = 4 ]; then
    ok "devmon-keep-forward-bound: a transaction id alone cannot mint a keep decision, for any app or any hash"
  else
    bad "devmon-keep-forward-bound: $checks/4 (rc=$rc phase=$(tx_phase 2>/dev/null || echo none))"
    printf '%s\n' "$out" | sed 's/^/    attempt: /'
  fi
}

devmon_keep_forward_evidence_rechecked() {
  # A decision is only as good as the bytes it was made on. If the database changes
  # between the decision and the restore, nothing is kept and nothing is restored.
  reset_fixture
  local cfg="$TMP/devmon-recheck.toml" rc=0 second_rc=0 pidfile="$TMP/devmon-recheck.pid"
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db"
  prepare_devmon_receipt_flow "$cfg" \
    || { bad "devmon-keep-forward-evidence: setup failed"; return; }
  printf 'crash\n' >"$TMP/devmon-nginx-fail"
  HOME="$FAKEHOME" AIRLOCK_CONFIG="$cfg" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
    AIRLOCK_SELFKILL_CGROUP_FILE="$TMP/cgroup" \
    AIRLOCK_FIXTURE_SYSTEMCTL_STATE="$TMP/devmon-systemctl-state" \
    AIRLOCK_FIXTURE_DB="$db" AIRLOCK_FIXTURE_CROSS_UID=1 \
    AIRLOCK_FIXTURE_NGINX_FAIL="$TMP/devmon-nginx-fail" \
    AIRLOCK_FIXTURE_CRASH_PID_FILE="$pidfile" \
    bash -c 'printf "%s\n" "$$" > "$AIRLOCK_FIXTURE_CRASH_PID_FILE"; exec bash "$1"' \
      -- "$ROOT/install/airlock-install.sh" >"$TMP/devmon-recheck-first.log" 2>&1 || rc=$?
  # Decide forward-keep the way recovery would, then change the database underneath it.
  local verdict backup_sha target_sha
  verdict="$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --forward-check "$db" --offline 2>&1)"
  backup_sha="${verdict#forward=1 backup_sha256=}"; backup_sha="${backup_sha%% *}"
  target_sha="${verdict##* target_sha256=}"
  "$ROOT/bin/airlock-ledger" transaction-keep-forward dev-monitor "$db" "$backup_sha" "$target_sha" >/dev/null 2>&1 \
    || { bad "devmon-keep-forward-evidence: could not record a genuine decision (verdict: $verdict)"; return; }
  rm -f "$STATE"/install-checkpoints/*/dev-monitor-migration.json
  python3 -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("UPDATE cards SET title=\"changed-after-decision\""); c.commit(); c.close()' "$db"
  rm -f "$TMP/devmon-nginx-fail"
  devmon_orch "$cfg" >"$TMP/devmon-recheck-second.log" 2>&1 || second_rc=$?
  if [ "$second_rc" != 0 ] && [ "$(tx_phase)" = degraded ] \
      && grep -q 'forward-keep evidence changed' "$TMP/devmon-recheck-second.log" \
      && ! grep -q '^start-schema=legacy ' "$TMP/systemctl.log"; then
    ok "devmon-keep-forward-evidence: a decision whose database evidence changed restores nothing and stays degraded"
  else
    bad "devmon-keep-forward-evidence: second_rc=$second_rc phase=$(tx_phase 2>/dev/null || echo none)"
    grep -nE 'forward-keep|degraded|kept|restor' "$TMP/devmon-recheck-second.log" | head -8 | sed 's/^/    /'
  fi
}

devmon_receipt_refuses_unsound() {
  # Same shape, but the converted database is damaged: nothing is proven sound, so
  # the refusal stands and the box stays degraded rather than keeping a bad candidate.
  reset_fixture
  local cfg="$TMP/devmon-unsound.toml" rc=0
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db"
  prepare_devmon_receipt_flow "$cfg" \
    || { bad "devmon-receipt-refuses-unsound: setup failed"; return; }
  printf 'corrupt\n' >"$TMP/devmon-nginx-fail"
  AIRLOCK_FIXTURE_NGINX_FAIL="$TMP/devmon-nginx-fail" \
    devmon_orch "$cfg" >"$TMP/devmon-unsound.log" 2>&1 || rc=$?
  if [ "$rc" = 77 ] && [ "$(tx_phase)" = degraded ] \
      && ! grep -q "keeping it" "$TMP/devmon-unsound.log" \
      && find "$STATE/install-checkpoints" -name dev-monitor-migration.json -print -quit | grep -q .; then
    ok "devmon-receipt-refuses-unsound: a damaged converted database is never kept forward"
  else
    bad "devmon-receipt-refuses-unsound: rc=$rc phase=$(tx_phase 2>/dev/null || echo none)"
    tail -15 "$TMP/devmon-unsound.log" | sed 's/^/    /'
  fi
}

devmon_standalone_after_writer() {
  reset_fixture
  local cfg="$TMP/devmon-standalone-late.toml" rc=0
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db"
  prepare_devmon_migration "$cfg" \
    || { bad "devmon-standalone-after-writer: setup failed"; tail -30 "$TMP/devmon-first.log"; return; }
  # The UI copy right after the service restart fails: the canonical writer has run.
  mkdir -p "$WEB"; : >"$WEB/monitor"
  HOME="$FAKEHOME" AIRLOCK_CONFIG="$cfg" AIRLOCK_TS_FQDN=box.example.ts.net \
    AIRLOCK_FIXTURE_SYSTEMCTL_STATE="$TMP/devmon-systemctl-state" \
    AIRLOCK_FIXTURE_DB="$db" AIRLOCK_FIXTURE_CROSS_UID=1 \
    AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$TMP/devmon-v2" AIRLOCK_APP_ID=dev-monitor \
    bash "$TMP/devmon-v2/install.sh" >"$TMP/devmon-standalone-late.log" 2>&1 || rc=$?
  if [ "$rc" != 0 ] \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "$db")" = canonical ] \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "${db}.pre-endstate")" = legacy ] \
      && grep -q 'converted database is kept' "$TMP/devmon-standalone-late.log" \
      && [ "$(stat -c %a "${db%/messages.db}/spool/tmp")" = 3770 ]; then
    ok "devmon-standalone-after-writer: once the canonical writer ran, a standalone failure keeps the converted DB"
  else
    bad "devmon-standalone-after-writer: rc=$rc schema=$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "$db" 2>&1)"
    tail -25 "$TMP/devmon-standalone-late.log" | sed 's/^/    /'
  fi
}

devmon_default_state_dir() {
  reset_fixture
  local cfg="$TMP/devmon-default-state.toml" rc=0 phase
  local state="$FAKEHOME/.local/state/airlock"
  local db="$state/dev-monitor/messages.db"
  AIRLOCK_FIXTURE_UNSET_STATE_DIR=1 prepare_devmon_migration "$cfg" \
    || { bad "devmon-default-state-dir: setup failed"; tail -30 "$TMP/devmon-first.log"; return; }
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$TMP/devmon-v2/smoke.sh"
  chmod +x "$TMP/devmon-v2/smoke.sh"
  AIRLOCK_FIXTURE_UNSET_STATE_DIR=1 \
    devmon_orch "$cfg" >"$TMP/devmon-default-state.log" 2>&1 || rc=$?
  phase="$(env -u AIRLOCK_STATE_DIR HOME="$FAKEHOME" \
    "$ROOT/bin/airlock-ledger" transaction-show \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["phase"])' 2>/dev/null)"
  if [ "$rc" = 0 ] && [ "$phase" = committed ] \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "$db")" = canonical ] \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "${db}.pre-endstate")" = legacy ] \
      && [ ! -e "$(activation_record "$state")" ] \
      && grep -q 'dev-monitor activated' "$TMP/devmon-default-state.log" \
      && ! find "$state/install-checkpoints" -name dev-monitor-migration.json -print -quit | grep -q .; then
    ok "devmon-default-state-dir: unset state uses the shared default through commit and activation"
  else
    bad "devmon-default-state-dir: rc=$rc phase=${phase:-none}"
    tail -35 "$TMP/devmon-default-state.log" | sed 's/^/    /'
  fi
}

devmon_crash_reentry() {
  reset_fixture
  local cfg="$TMP/devmon-crash.toml" rc=0 retry_rc=0 before
  local db="$FAKEHOME/.local/state/airlock/dev-monitor/messages.db" pidfile="$TMP/devmon.pid"
  prepare_devmon_migration "$cfg" \
    || { bad "devmon-crash-reentry: setup failed"; tail -30 "$TMP/devmon-first.log"; return; }
  before="$(db_sha "$db")"
  printf 'crash\n' >"$TMP/devmon-nginx-fail"
  HOME="$FAKEHOME" AIRLOCK_CONFIG="$cfg" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
    AIRLOCK_SELFKILL_CGROUP_FILE="$TMP/cgroup" \
    AIRLOCK_FIXTURE_SYSTEMCTL_STATE="$TMP/devmon-systemctl-state" \
    AIRLOCK_FIXTURE_DB="$db" AIRLOCK_FIXTURE_CROSS_UID=1 \
    AIRLOCK_FIXTURE_NGINX_FAIL="$TMP/devmon-nginx-fail" \
    AIRLOCK_FIXTURE_CRASH_PID_FILE="$pidfile" \
    bash -c 'printf "%s\n" "$$" > "$AIRLOCK_FIXTURE_CRASH_PID_FILE"; exec bash "$1"' \
      -- "$ROOT/install/airlock-install.sh" >"$TMP/devmon-crash-first.log" 2>&1 || rc=$?
  if [ ! -e "$(activation_record)" ] || [ "$(db_sha "$db")" != "$before" ]; then
    bad "devmon-crash-reentry: the crash did not leave a durable deferral over an untouched DB"
    return
  fi
  rm -f "$TMP/devmon-nginx-fail"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$TMP/devmon-v2/smoke.sh"
  chmod +x "$TMP/devmon-v2/smoke.sh"
  : >"$TMP/systemctl.log"
  devmon_orch "$cfg" >"$TMP/devmon-crash-second.log" 2>&1 || retry_rc=$?
  if [ "$rc" != 0 ] && [ "$retry_rc" = 0 ] && [ "$(tx_phase)" = committed ] \
      && grep -q 'recovering unfinished install transaction' "$TMP/devmon-crash-second.log" \
      && grep -q '^start-schema=legacy airlock-dev-monitor.service' "$TMP/systemctl.log" \
      && grep -q 'dev-monitor activated' "$TMP/devmon-crash-second.log" \
      && [ ! -e "$(activation_record)" ] \
      && [ "$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" --schema-state "$db")" = canonical ] \
      && ! find "$STATE/install-checkpoints" -name dev-monitor-migration.json -print -quit | grep -q .; then
    ok "devmon-crash-reentry: recovery takes back the deferral and restores the old package, then the retry commits and activates"
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
  devmon-write-survives-rollback) devmon_write_survives_rollback ;;
  devmon-later-app-fails) devmon_later_app_fails ;;
  devmon-activation-resume) devmon_activation_resume ;;
  devmon-owed-activation) devmon_owed_activation_does_not_block_others ;;
  devmon-activation-record) devmon_activation_record_contract ;;
  devmon-fence-recovery) devmon_fence_recovery ;;
  devmon-spool-mode-restore) devmon_spool_mode_restore ;;
  devmon-receipt-forward-keep) devmon_receipt_forward_keep ;;
  devmon-receipt-refuses-unsound) devmon_receipt_refuses_unsound ;;
  devmon-receipt-degraded-reentry) devmon_receipt_degraded_reentry ;;
  devmon-keep-forward-bound) devmon_keep_forward_is_bound ;;
  devmon-keep-forward-evidence) devmon_keep_forward_evidence_rechecked ;;
  devmon-standalone-fallback) devmon_standalone_fallback ;;
  devmon-standalone-after-writer) devmon_standalone_after_writer ;;
  devmon-default-state-dir) devmon_default_state_dir ;;
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
    devmon_write_survives_rollback
    devmon_later_app_fails
    devmon_activation_resume
    devmon_owed_activation_does_not_block_others
    devmon_activation_record_contract
    devmon_fence_recovery
    devmon_spool_mode_restore
    devmon_receipt_forward_keep
    devmon_receipt_refuses_unsound
    devmon_receipt_degraded_reentry
    devmon_keep_forward_is_bound
    devmon_keep_forward_evidence_rechecked
    devmon_standalone_fallback
    devmon_standalone_after_writer
    devmon_default_state_dir
    devmon_crash_reentry
    ;;
  *) bad "unknown case: $case_name" ;;
esac

printf '%s\n' "---" "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
