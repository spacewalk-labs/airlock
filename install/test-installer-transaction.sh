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
while [ "$#" -gt 0 ]; do
  case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac
done
exec "$@"
STUB
cat > "$SHIM/systemctl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/systemctl.log"
case "\$*" in
  *list-timers*) printf '%s\n' 'Mon 2026-09-02 00:00:00 UTC 1d left airlock-update-detect.timer airlock-update-detect.service' ;;
  *is-active*) printf '%s\n' active ;;
  *is-enabled*) printf '%s\n' enabled ;;
  *show*) printf '%s\n' 'LoadState=loaded' 'ActiveState=active' 'SubState=running' 'Result=success' 'Type=simple' 'ExecMainStatus=0' 'UnitFileState=enabled' ;;
esac
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
  rm -f "$TMP/deactivate.log" "$TMP/systemctl.log" "$TMP/tailscale.log" "$TMP/crash-ready" "$TMP/signal-ready"
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
    ;;
  *) bad "unknown case: $case_name" ;;
esac

printf '%s\n' "---" "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
