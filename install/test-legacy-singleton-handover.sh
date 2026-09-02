#!/usr/bin/env bash
# Regression coverage for installing over legacy processes that still own a
# singleton resource. Everything runs under a scratch HOME with command shims;
# no live systemd instance, sudo, network, or fixed production display is used.
set -uo pipefail

# This test executes a real installer. Keep the platform-wide Paseo memory
# ceiling explicit so render-parity's real-installer guard remains hermetic.
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
SELF_ROOT="$(cd "$HERE/.." && pwd)"
SUBJECT_ROOT="${AIRLOCK_TEST_SUBJECT_ROOT:-$SELF_ROOT}"
TMP="$(mktemp -d)" || { echo "FAIL legacy-singleton: mktemp" >&2; exit 1; }
HOLDERS=""
cleanup() {
  local holder
  for holder in $HOLDERS; do
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

wait_ready() {
  local ready="$1" pid="$2"
  for _ in $(seq 1 100); do
    [ -e "$ready" ] && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.02
  done
  return 1
}

start_db_holder() {
  local db="$1" ready="$2"
  python3 - "$db" "$ready" <<'PY' &
import fcntl
import pathlib
import sys
import time

db, ready = sys.argv[1:]
with open(db, "r+b", buffering=0) as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    pathlib.Path(ready).touch()
    while True:
        time.sleep(1)
PY
  DB_HOLDER_PID=$!
  HOLDERS="$HOLDERS $DB_HOLDER_PID"
  wait_ready "$ready" "$DB_HOLDER_PID"
}

write_fileview_shims() {
  local dir="$1"
  mkdir -p "$dir"
  for cmd in curl sha256sum tar; do
    cat >"$dir/$cmd" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$dir/$cmd"
  done

  cat >"$dir/systemctl" <<'STUB'
#!/usr/bin/env bash
set -u
log="${AIRLOCK_TEST_EVENT_LOG:?}"
mode="${AIRLOCK_TEST_HOLDER_MODE:?}"
holder="${AIRLOCK_TEST_LEGACY_PID:?}"
[ "${1:-}" = --user ] && shift
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  whoami)
    [ "${1:-}" = "$holder" ] || exit 1
    case "$mode" in
      service) printf '%s\n' filebrowser.service ;;
      child)   printf '%s\n' broad-host.service ;;
      scope)   printf '%s\n' session-legacy-filebrowser.scope ;;
      *)       exit 1 ;;
    esac
    ;;
  show)
    case " $* " in
      *" --property=MainPID "*)
        if [ "$mode" = child ]; then printf '%s\n' "$((holder + 1))"; else printf '%s\n' "$holder"; fi
        ;;
      *) exit 1 ;;
    esac
    ;;
  stop)
    printf 'systemctl stop %s\n' "$*" >>"$log"
    for unit in "$@"; do
      if [ "$unit" = filebrowser.service ]; then
        kill "$holder" 2>/dev/null || true
        sleep 0.05
      fi
    done
    ;;
  daemon-reload|enable|restart)
    printf 'systemctl %s %s\n' "$cmd" "$*" >>"$log"
    ;;
  *)
    printf 'systemctl %s %s\n' "$cmd" "$*" >>"$log"
    ;;
esac
STUB
  chmod +x "$dir/systemctl"
}

write_fake_filebrowser() {
  local path="$1"
  cat >"$path" <<'STUB'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  version)
    echo 'File Browser v2.63.18'
    exit 0
    ;;
  config)
    sub="${2:-}"
    if [ "$sub" = cat ]; then
      echo 'Base URL: /legacy'
      exit 0
    fi
    if [ "$sub" = set ]; then
      db=""; shift 2
      while [ "$#" -gt 0 ]; do
        if [ "$1" = -d ] && [ "$#" -ge 2 ]; then db="$2"; shift 2; else shift; fi
      done
      [ -n "$db" ] || { echo 'fake filebrowser: missing -d' >&2; exit 2; }
      if ! python3 - "$db" <<'PY'
import fcntl
import sys

with open(sys.argv[1], "r+b", buffering=0) as handle:
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit(1)
PY
      then
        echo 'Error: timeout' >&2
        exit 1
      fi
      printf 'filebrowser config set\n' >>"${AIRLOCK_TEST_EVENT_LOG:?}"
      exit 0
    fi
    ;;
esac
echo "fake filebrowser: unexpected argv: $*" >&2
exit 2
STUB
  chmod +x "$path"
}

run_fileview_case() {
  local mode="$1" d="$TMP/fileview-$1" home="$TMP/fileview-$1/home"
  local db="$home/.config/airlock-fileview/fb.db" cfg="$d/airlock.toml"
  local log="$d/events.log" out="$d/install.log" ready="$d/holder.ready"
  local before_hash before_inode after_hash after_inode holder rc=0 stop_line set_line
  mkdir -p "$home/.local/bin" "$home/.config/airlock-fileview" "$d/confd" "$d/web/assets" "$d/shim"
  # The installer dies without the design system: fileview's stylesheet is aliases
  # over it and renders as unstyled HTML if it is absent. The orchestrator puts it
  # in the webroot before any app runs, so the fixture does too.
  : >"$d/web/assets/airlock-tokens.css"
  printf 'legacy-db-sentinel\n' >"$db"
  before_hash="$(sha256sum "$db" | awk '{print $1}')"
  before_inode="$(stat -c '%d:%i' "$db")"
  : >"$log"
  start_db_holder "$db" "$ready" || { bad "fileview $mode: legacy DB holder did not become ready"; return; }
  holder="$DB_HOLDER_PID"

  write_fileview_shims "$d/shim"
  write_fake_filebrowser "$home/.local/bin/filebrowser"
  cat >"$cfg" <<EOF
[site]
name = "LegacySingletonTest"
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.fileview]
EOF

  env HOME="$home" PATH="$d/shim:/usr/bin:/bin" AIRLOCK_CONFIG="$cfg" \
    AIRLOCK_CONFD="$d/confd" AIRLOCK_WEBROOT="$d/web" \
    AIRLOCK_DRY_RUN=0 \
    AIRLOCK_TEST_EVENT_LOG="$log" AIRLOCK_TEST_HOLDER_MODE="$mode" \
    AIRLOCK_TEST_LEGACY_PID="$holder" \
    AIRLOCK_ROOT="$SUBJECT_ROOT" AIRLOCK_APP_DIR="$SUBJECT_ROOT/apps/fileview" \
    AIRLOCK_APP_ID=fileview \
    bash "$SUBJECT_ROOT/apps/fileview/install.sh" >"$out" 2>&1 || rc=$?

  after_hash="$(sha256sum "$db" | awk '{print $1}')"
  after_inode="$(stat -c '%d:%i' "$db")"
  if [ "$mode" = service ]; then
    if [ "$rc" -eq 0 ]; then ok "fileview: real installer succeeds while legacy filebrowser.service initially locks fb.db"
    else bad "fileview: installer failed rc=$rc: $(tail -1 "$out")"; fi
    stop_line="$(grep -n -m1 '^systemctl stop filebrowser\.service$' "$log" | cut -d: -f1 || true)"
    set_line="$(grep -n -m1 '^filebrowser config set$' "$log" | cut -d: -f1 || true)"
    if [ -n "$stop_line" ] && [ -n "$set_line" ] && [ "$stop_line" -lt "$set_line" ]; then
      ok "fileview: measured legacy unit is stopped before DB migration"
    else
      bad "fileview: stop-before-migration ordering absent (events: $(tr '\n' ';' <"$log"))"
    fi
    if [ "$(grep -c '^filebrowser config set$' "$log")" -eq 4 ]; then
      ok "fileview: every filebrowser migration acquired the released DB"
    else
      bad "fileview: expected four successful config-set calls (baseURL, hideDotfiles, perm.share, type detection)"
    fi
    if grep -q '^systemctl restart airlock-fileview.service$' "$log"; then
      ok "fileview: candidate restart is reached after migration"
    else
      bad "fileview: candidate restart was not reached"
    fi
    if kill -0 "$holder" 2>/dev/null; then
      bad "fileview: legacy holder is still running after the install attempt"
      kill "$holder" 2>/dev/null || true
    else
      ok "fileview: stopped legacy holder no longer runs"
    fi
  elif [ "$mode" = scope ]; then
    if [ "$rc" -ne 0 ]; then ok "fileview: ambiguous scope holder fails closed"
    else bad "fileview: ambiguous scope holder was accepted"
    fi
    if kill -0 "$holder" 2>/dev/null; then
      ok "fileview: ambiguous scope remains alive (no arbitrary scope kill)"
    else
      bad "fileview: ambiguous scope holder was killed"
    fi
    if [ ! -s "$log" ]; then ok "fileview: ambiguous scope fails before stop or migration"
    else bad "fileview: ambiguous scope produced mutations: $(tr '\n' ';' <"$log")"
    fi
    if grep -Fq 'refusing to stop a whole scope' "$out"; then
      ok "fileview: ambiguous scope failure explains the refusal"
    else
      bad "fileview: ambiguous scope failure lacks actionable diagnostic"
    fi
    kill "$holder" 2>/dev/null || true
  else
    if [ "$rc" -ne 0 ]; then ok "fileview: child holder in a broad service fails closed"
    else bad "fileview: child holder was accepted as authority to stop a broad service"
    fi
    if kill -0 "$holder" 2>/dev/null; then
      ok "fileview: broad service child remains alive"
    else
      bad "fileview: broad service child was killed"
    fi
    if [ ! -s "$log" ]; then ok "fileview: MainPID mismatch fails before stop or migration"
    else bad "fileview: MainPID mismatch produced mutations: $(tr '\n' ';' <"$log")"
    fi
    if grep -Fq 'refusing to stop the whole service' "$out"; then
      ok "fileview: MainPID mismatch explains the refusal"
    else
      bad "fileview: MainPID mismatch lacks actionable diagnostic"
    fi
    kill "$holder" 2>/dev/null || true
  fi
  wait "$holder" 2>/dev/null || true

  if [ "$before_hash" = "$after_hash" ] && [ "$before_inode" = "$after_inode" ]; then
    ok "fileview $mode: fb.db bytes and inode are preserved"
  else
    bad "fileview $mode: fb.db changed (hash $before_hash->$after_hash inode $before_inode->$after_inode)"
  fi
}

start_x_holder() {
  local path="$1" ready="$2" kind="$3"
  python3 - "$path" "$ready" "$kind" <<'PY' &
import pathlib
import select
import socket
import sys

path, ready, kind = sys.argv[1:]
listener = socket.socket(socket.AF_UNIX)
listener.bind(path if kind == "pathname" else "\0" + path)
listener.listen()
pathlib.Path(ready).touch()
while True:
    readable, _, _ = select.select([listener], [], [], 1)
    for ready_listener in readable:
        connection, _ = ready_listener.accept()
        connection.close()
PY
  X_HOLDER_PID=$!
  HOLDERS="$HOLDERS $X_HOLDER_PID"
  wait_ready "$ready" "$X_HOLDER_PID"
}

start_x_client() {
  local display="$1" ready="$2"
  DISPLAY=":$display" python3 - "$ready" <<'PY' &
import pathlib
import sys
import time

pathlib.Path(sys.argv[1]).touch()
while True:
    time.sleep(1)
PY
  X_CLIENT_PID=$!
  HOLDERS="$HOLDERS $X_CLIENT_PID"
  wait_ready "$ready" "$X_CLIENT_PID"
}

start_named_orca_process() {
  local binary="$1" invocation="$2"
  env INVOCATION_ID="$invocation" "$binary" 1000 &
  NAMED_ORCA_PID=$!
  HOLDERS="$HOLDERS $NAMED_ORCA_PID"
  kill -0 "$NAMED_ORCA_PID" 2>/dev/null
}

run_rendered_prestart() {
  local line="$1" spec payload prefix="/bin/sh -c '"
  local -a command
  spec="${line#ExecStartPre=}"
  spec="${spec#-}"
  case "$spec" in
    "$prefix"*)
      payload="${spec#"$prefix"}"
      payload="${payload%\'}"
      /bin/sh -c "$payload"
      ;;
    *)
      # Rendered unit paths in this hermetic fixture contain no whitespace.
      # Splitting lets the mutation tree execute Paseo's former direct
      # interpreter ExecStartPre without copying its implementation here.
      read -r -a command <<<"$spec"
      "${command[@]}"
      ;;
  esac
}

run_orca_case() {
  local d="$TMP/orca" unit="$TMP/orca/xvfb.service" ready="$TMP/orca/x.ready"
  local abstract_ready="$TMP/orca/abstract.ready" client_ready="$TMP/orca/client.ready" holders
  local display=$((30000 + ($$ % 20000))) path="/tmp/.X11-unix/X$((30000 + ($$ % 20000)))"
  local lock="/tmp/.X$((30000 + ($$ % 20000)))-lock" holder abstract_holder attempt line prestarts=0
  mkdir -p "$d" /tmp/.X11-unix
  printf 'legacy-x-lock-sentinel\n' >"$lock"
  start_x_holder "$path" "$ready" pathname || { bad "orca: legacy pathname listener did not become ready"; return; }
  holder="$X_HOLDER_PID"
  start_x_holder "$path" "$abstract_ready" abstract || { bad "orca: legacy abstract listener did not become ready"; return; }
  abstract_holder="$X_HOLDER_PID"
  start_x_client "$display" "$client_ready" \
    || { bad "orca: legacy DISPLAY client did not become ready"; return; }

  holders="$(python3 "$SUBJECT_ROOT/install/resource-holder-pids.py" x-display "$display" 2>/dev/null || true)"
  if grep -qx "$holder" <<<"$holders" && grep -qx "$abstract_holder" <<<"$holders"; then
    ok "orca: distinct pathname and abstract listener PIDs are both discovered"
  else
    bad "orca: resource discovery missed pathname/abstract listener PIDs (got: $(tr '\n' ' ' <<<"$holders"))"
  fi
  if ! grep -qx "$X_CLIENT_PID" <<<"$holders"; then
    ok "orca: DISPLAY environment alone is not mistaken for resource ownership"
  else
    bad "orca: unconnected DISPLAY process was incorrectly granted stop authority"
  fi
  # Match literal installer source text.
  # shellcheck disable=SC2016
  if grep -Fq 'airlock_handover_user_resource x-display "$XDISP"' "$SUBJECT_ROOT/apps/orca/install.sh" \
     && grep -Fq -- '--required-by' "$SUBJECT_ROOT/apps/orca/install.sh"; then
    ok "orca: real installer wires resource and RequiredBy discovery before candidate restart"
  else
    bad "orca: real installer does not invoke X display handover"
  fi

  # Source the subject renderer itself. The baseline mutation therefore renders
  # its destructive rm and Restart=always rather than testing copied strings.
  # shellcheck source=/dev/null
  . "$SUBJECT_ROOT/apps/orca/render.sh"
  render_orca_unit_xvfb "$display" >"$unit"

  if grep -Eq '^ExecStartPre=.*rm -f .*(\.X|X11-unix)' "$unit"; then
    bad "orca: rendered candidate still unlinks X lock/socket in ExecStartPre"
  else
    ok "orca: rendered candidate has no destructive X cleanup"
  fi
  if grep -qx 'Restart=always' "$unit"; then
    bad "orca: rendered Xvfb candidate still uses Restart=always"
  else
    ok "orca: rendered Xvfb candidate does not use Restart=always"
  fi
  if grep -qx 'Restart=on-abnormal' "$unit"; then
    ok "orca: rendered Xvfb candidate retries abnormal crashes only"
  else
    bad "orca: rendered Xvfb candidate lacks Restart=on-abnormal"
  fi

  mapfile -t lines < <(grep '^ExecStartPre=' "$unit" || true)
  prestarts="${#lines[@]}"
  if [ "$prestarts" -eq 0 ]; then
    ok "orca: rendered unit proves there is no candidate pre-start cleanup"
  else
    ok "orca: exercising $prestarts rendered pre-start command(s)"
  fi
  for attempt in $(seq 1 13); do
    for line in "${lines[@]}"; do run_rendered_prestart "$line" >/dev/null 2>&1 || true; done
    # The legacy abstract listener makes every hypothetical candidate Xvfb
    # start fail even if a destructive pre-start removed the pathname entry.
    grep -Fq "@${path}" /proc/net/unix || bad "orca: legacy abstract listener vanished on attempt $attempt"
  done
  ok "orca: simulated 13 candidate failures while legacy kept the abstract display"

  if [ -f "$lock" ] && grep -qx 'legacy-x-lock-sentinel' "$lock"; then
    ok "orca: legacy X lock survives all 13 attempts"
  else
    bad "orca: legacy X lock was deleted or changed"
  fi
  if [ -S "$path" ]; then ok "orca: legacy pathname socket survives all 13 attempts"
  else bad "orca: legacy pathname socket was deleted"
  fi
  if kill -0 "$holder" 2>/dev/null && kill -0 "$abstract_holder" 2>/dev/null \
     && grep -Fq "@${path}" /proc/net/unix; then
    ok "orca: both legacy X holders and abstract socket remain live"
  else
    bad "orca: legacy X holder or abstract socket did not remain live"
  fi

  kill "$holder" 2>/dev/null || true
  kill "$abstract_holder" 2>/dev/null || true
  kill "$X_CLIENT_PID" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  wait "$abstract_holder" 2>/dev/null || true
  wait "$X_CLIENT_PID" 2>/dev/null || true
  rm -f "$path" "$lock"
}

run_orca_handover_case() {
  local d="$TMP/orca-handover" shim="$TMP/orca-handover/shim"
  local display=$((20000 + ($$ % 9000))) path="/tmp/.X11-unix/X$((20000 + ($$ % 9000)))"
  local path_ready="$d/path.ready" abstract_ready="$d/abstract.ready" log="$d/systemctl.log"
  local path_pid abstract_pid rc=0
  mkdir -p "$d" "$shim" /tmp/.X11-unix
  start_x_holder "$path" "$path_ready" pathname \
    || { bad "orca handover: pathname holder did not become ready"; return; }
  path_pid="$X_HOLDER_PID"
  start_x_holder "$path" "$abstract_ready" abstract \
    || { bad "orca handover: abstract holder did not become ready"; return; }
  abstract_pid="$X_HOLDER_PID"
  : >"$log"

  cat >"$shim/systemctl" <<'STUB'
#!/usr/bin/env bash
set -u
log="${AIRLOCK_TEST_EVENT_LOG:?}"
path_pid="${AIRLOCK_TEST_PATH_PID:?}"
abstract_pid="${AIRLOCK_TEST_ABSTRACT_PID:?}"
[ "${1:-}" = --user ] && shift
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  whoami)
    case "${1:-}" in
      "$path_pid") echo legacy-x-path.service ;;
      "$abstract_pid") echo legacy-x-abstract.service ;;
      *) exit 1 ;;
    esac
    ;;
  show)
    unit="${1:-}"; shift || true
    case " $* " in
      *" --property=MainPID "*)
        case "$unit" in
          legacy-x-path.service) echo "$path_pid" ;;
          legacy-x-abstract.service) echo "$abstract_pid" ;;
          *) exit 1 ;;
        esac
        ;;
      *" --property=RequiredBy "*)
        case "$unit" in
          legacy-x-path.service) echo legacy-orca-path.service ;;
          legacy-x-abstract.service) echo legacy-orca-abstract.service ;;
          *) exit 1 ;;
        esac
        ;;
      *) exit 1 ;;
    esac
    ;;
  stop)
    printf 'systemctl stop %s\n' "$*" >>"$log"
    for unit in "$@"; do
      case "$unit" in
        legacy-x-path.service) kill "$path_pid" 2>/dev/null || true ;;
        legacy-x-abstract.service) kill "$abstract_pid" 2>/dev/null || true ;;
      esac
    done
    sleep 0.05
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$shim/systemctl"

  (
    # Fixture environment is intentionally subshell-local.
    # shellcheck disable=SC2030,SC2031
    export PATH="$shim:/usr/bin:/bin" AIRLOCK_TEST_EVENT_LOG="$log"
    export AIRLOCK_TEST_PATH_PID="$path_pid" AIRLOCK_TEST_ABSTRACT_PID="$abstract_pid"
    # shellcheck source=/dev/null
    . "$SUBJECT_ROOT/install/lib.sh"
    airlock_handover_user_resource x-display "$display" "test X display :$display" \
      --required-by airlock-orca-xvfb.service airlock-orca.service
  ) || rc=$?

  if [ "$rc" -eq 0 ]; then ok "orca handover: measured X services and declared consumers hand over cleanly"
  else bad "orca handover: helper failed rc=$rc"; fi
  if grep -q 'legacy-x-path.service' "$log" \
     && grep -q 'legacy-x-abstract.service' "$log" \
     && grep -q 'legacy-orca-path.service' "$log" \
     && grep -q 'legacy-orca-abstract.service' "$log"; then
    ok "orca handover: stop set comes from socket owners plus systemd RequiredBy edges"
  else
    bad "orca handover: measured stop set incomplete (events: $(tr '\n' ';' <"$log"))"
  fi
  if ! kill -0 "$path_pid" 2>/dev/null && ! kill -0 "$abstract_pid" 2>/dev/null \
     && ! grep -Fq "$path" /proc/net/unix; then
    ok "orca handover: both measured listeners released before candidate start"
  else
    bad "orca handover: listener remained after stop transaction"
  fi
  kill "$path_pid" "$abstract_pid" 2>/dev/null || true
  wait "$path_pid" 2>/dev/null || true
  wait "$abstract_pid" 2>/dev/null || true
  rm -f "$path"
}

run_orca_reaper_case() {
  local d="$TMP/orca-reaper" home="$TMP/orca-reaper/home"
  local daemon_dir="$home/.config/orca/daemon" shim="$d/shim"
  local script="$d/reap.sh" log="$d/systemctl.log"
  local legacy_invocation=legacy-invocation candidate_invocation=candidate-invocation
  local legacy_pid candidate_pid attempt
  mkdir -p "$daemon_dir" "$shim"
  cp /usr/bin/sleep "$d/orca-legacy"
  cp /usr/bin/sleep "$d/orca-candidate"
  start_named_orca_process "$d/orca-legacy" "$legacy_invocation"
  legacy_pid="$NAMED_ORCA_PID"
  start_named_orca_process "$d/orca-candidate" "$candidate_invocation"
  candidate_pid="$NAMED_ORCA_PID"
  printf '{"pid": %s}\n' "$legacy_pid" >"$daemon_dir/daemon-vlegacy.pid"
  printf '{"pid": %s}\n' "$candidate_pid" >"$daemon_dir/daemon-vcandidate.pid"
  : >"$log"

  cat >"$shim/systemctl" <<'STUB'
#!/usr/bin/env bash
set -u
log="${AIRLOCK_TEST_EVENT_LOG:?}"
[ "${1:-}" = --user ] && shift
case "${1:-}" in
  whoami)
    case "${2:-}" in
      "${AIRLOCK_TEST_CANDIDATE_PID:?}") echo app-orca-candidate.scope ;;
      "${AIRLOCK_TEST_LEGACY_PID:?}") echo app-orca-legacy.scope ;;
      *) exit 1 ;;
    esac
    ;;
  stop)
    shift
    printf 'systemctl stop %s\n' "$*" >>"$log"
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$shim/systemctl"

  # Render and execute the subject's actual ExecStopPost helper. The first
  # pass owns the candidate daemon; the remaining 12 simulate repeated failed
  # candidate cleanup while only the legacy state remains.
  # shellcheck source=/dev/null
  . "$SUBJECT_ROOT/apps/orca/render.sh"
  render_orca_reap_script >"$script"
  chmod +x "$script"
  for attempt in $(seq 1 13); do
    env HOME="$home" PATH="$shim:/usr/bin:/bin" \
      INVOCATION_ID="$candidate_invocation" \
      AIRLOCK_TEST_EVENT_LOG="$log" \
      AIRLOCK_TEST_LEGACY_PID="$legacy_pid" \
      AIRLOCK_TEST_CANDIDATE_PID="$candidate_pid" \
      bash "$script"
  done

  if [ ! -e "$daemon_dir/daemon-vcandidate.pid" ] \
     && ! kill -0 "$candidate_pid" 2>/dev/null; then
    ok "orca: reaper removes only its own invocation's daemon state"
  else
    bad "orca: reaper did not clean its own candidate daemon/state"
  fi
  if grep -qx 'systemctl stop app-orca-candidate.scope' "$log"; then
    ok "orca: reaper stops the exact measured candidate scope"
  else
    bad "orca: reaper did not stop the exact candidate scope (events: $(tr '\n' ';' <"$log"))"
  fi
  if [ -f "$daemon_dir/daemon-vlegacy.pid" ] \
     && grep -qx "{\"pid\": $legacy_pid}" "$daemon_dir/daemon-vlegacy.pid" \
     && kill -0 "$legacy_pid" 2>/dev/null; then
    ok "orca: legacy daemon pidfile and process survive 13 candidate reaps"
  else
    bad "orca: legacy daemon pidfile or process was damaged by candidate reap"
  fi
  if ! grep -q 'app-orca-legacy\.scope\|app-orca-\*\.scope' "$log"; then
    ok "orca: candidate reaper never stops a legacy or guessed scope"
  else
    bad "orca: candidate reaper stopped legacy/guessed scope (events: $(tr '\n' ';' <"$log"))"
  fi

  kill "$legacy_pid" "$candidate_pid" 2>/dev/null || true
  wait "$legacy_pid" 2>/dev/null || true
  wait "$candidate_pid" 2>/dev/null || true
}

start_paseo_holder() {
  local paseo_home="$1" ready="$2" binary="$3"
  env PASEO_HOME="$paseo_home" python3 - "$ready" "$binary" <<'PY' &
import os
import pathlib
import subprocess
import sys
import time

ready, binary = sys.argv[1:]
child = subprocess.Popen([binary, "1000"], env=os.environ.copy())
pathlib.Path(ready).write_text(str(child.pid), encoding="ascii")
while child.poll() is None:
    time.sleep(0.1)
PY
  PASEO_MAIN_PID=$!
  HOLDERS="$HOLDERS $PASEO_MAIN_PID"
  wait_ready "$ready" "$PASEO_MAIN_PID" || return 1
  PASEO_HOLDER_PID="$(cat "$ready")"
  HOLDERS="$HOLDERS $PASEO_HOLDER_PID"
  wait_ready "$ready" "$PASEO_HOLDER_PID"
}

write_paseo_pidfile() {
  local path="$1" pid="$2" started_at="$3"
  mkdir -p "$(dirname "$path")"
  printf '{"pid": %s, "uid": %s, "hostname": "%s", "startedAt": "%s"}\n' \
    "$pid" "$(id -u)" "$(hostname)" "$started_at" >"$path"
}

write_paseo_systemctl() {
  local path="$1"
  cat >"$path" <<'STUB'
#!/usr/bin/env bash
set -u
log="${AIRLOCK_TEST_EVENT_LOG:?}"
holder="${AIRLOCK_TEST_PASEO_PID:?}"
main_pid="${AIRLOCK_TEST_PASEO_MAIN_PID:?}"
declared_home="${AIRLOCK_TEST_SERVICE_HOME:?}"
service_exec="${AIRLOCK_TEST_SERVICE_EXEC:?}"
[ "${1:-}" = --user ] && shift
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  whoami)
    [ "${1:-}" = "$holder" ] || exit 1
    echo holder-7.service
    ;;
  show)
    unit="${1:-}"; shift || true
    [ "$unit" = holder-7.service ] || exit 1
    case " $* " in
      *" --property=MainPID "*) echo "$main_pid" ;;
      *" --property=Environment "*) echo "PASEO_HOME=$declared_home" ;;
      *" --property=ExecStart "*) echo "{ path=/declared/paseo ; argv[]=$service_exec ; ignore_errors=no ; }" ;;
      *) exit 1 ;;
    esac
    ;;
  stop)
    printf 'systemctl stop %s\n' "$*" >>"$log"
    [ "${1:-}" = holder-7.service ] || exit 1
    kill "$holder" 2>/dev/null || true
    kill "$main_pid" 2>/dev/null || true
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$path"
}

run_paseo_case() {
  local d="$TMP/paseo" home="$TMP/paseo/home" paseo_home="$TMP/paseo/home/.paseo"
  local pidfile="$TMP/paseo/home/.paseo/paseo.pid" shim="$TMP/paseo/shim"
  local log="$TMP/paseo/systemctl.log" ready="$TMP/paseo/holder.ready"
  local wrong_ready="$TMP/paseo/wrong.ready" retry_ready="$TMP/paseo/retry.ready"
  local unit="$TMP/paseo/paseo.service" holder main_pid wrong_holder wrong_main retry_holder rc=0 guard_rc=0
  local paseo_supervisor="$TMP/paseo/paseo-supervisor"
  local before_hash before_inode after_hash after_inode attempt line prestarts
  local handover_line mutation_line restart_line
  mkdir -p "$home" "$shim"
  cp /usr/bin/sleep "$paseo_supervisor"
  : >"$log"
  write_paseo_systemctl "$shim/systemctl"

  start_paseo_holder "$paseo_home" "$ready" "$paseo_supervisor" \
    || { bad "paseo: shared-home holder did not become ready"; return; }
  holder="$PASEO_HOLDER_PID"
  write_paseo_pidfile "$pidfile" "$holder" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  before_hash="$(sha256sum "$pidfile" | awk '{print $1}')"
  before_inode="$(stat -c '%d:%i' "$pidfile")"

  main_pid="$PASEO_MAIN_PID"
  if grep -qx "$holder" < <(python3 "$SUBJECT_ROOT/install/resource-holder-pids.py" \
      pidfile "$pidfile" "PASEO_HOME=$paseo_home" 2>/dev/null || true); then
    ok "paseo: matching record and exact PASEO_HOME discover the holder"
  else
    bad "paseo: shared-home pidfile holder was not discovered"
  fi

  (
    # Fixture environment is intentionally subshell-local.
    # shellcheck disable=SC2030,SC2031
    export PATH="$shim:/usr/bin:/bin" AIRLOCK_TEST_EVENT_LOG="$log" \
      AIRLOCK_TEST_PASEO_PID="$holder" AIRLOCK_TEST_PASEO_MAIN_PID="$main_pid" \
      AIRLOCK_TEST_SERVICE_HOME="$paseo_home" \
      AIRLOCK_TEST_SERVICE_EXEC="$paseo_supervisor daemon start --foreground --no-relay --web-ui --listen 6767"
    # shellcheck source=/dev/null
    . "$SUBJECT_ROOT/install/lib.sh"
    airlock_handover_user_resource pidfile "$pidfile" "test Paseo singleton" \
      --service-environment "PASEO_HOME=$paseo_home" \
      --service-exec-prefix "$paseo_supervisor daemon start --foreground --no-relay --web-ui --listen"
  ) || rc=$?
  if ! kill -0 "$holder" 2>/dev/null; then
    wait "$holder" 2>/dev/null || true
  fi
  if ! kill -0 "$main_pid" 2>/dev/null; then
    wait "$main_pid" 2>/dev/null || true
  fi

  if [ "$rc" -eq 0 ]; then
    ok "paseo: child PID hands over only with matching process and service PASEO_HOME"
  else
    bad "paseo: measured shared-home handover failed rc=$rc"
  fi
  if grep -qx 'systemctl stop holder-7.service' "$log"; then
    ok "paseo: stop target comes from systemd whoami, not a legacy name list"
  else
    bad "paseo: measured containing service was not stopped"
  fi
  if ! kill -0 "$holder" 2>/dev/null; then
    ok "paseo: measured pidfile process is gone before candidate start"
  else
    bad "paseo: measured pidfile process survived handover"
  fi
  after_hash="$(sha256sum "$pidfile" | awk '{print $1}')"
  after_inode="$(stat -c '%d:%i' "$pidfile")"
  if [ "$before_hash" = "$after_hash" ] && [ "$before_inode" = "$after_inode" ]; then
    ok "paseo: handover itself preserves shared pidfile bytes and inode"
  else
    bad "paseo: handover mutated the shared pidfile before release verification"
  fi
  if python3 "$SUBJECT_ROOT/apps/paseo/paseo-clear-stale-pid.py" \
       --after-handover "$pidfile" >/dev/null 2>&1 && [ ! -e "$pidfile" ]; then
    ok "paseo: installer-authorized guard clears the released dead record once"
  else
    bad "paseo: released pidfile was not cleared after authorized handover"
  fi

  # Isolate this special-file probe even when a mutation leaves the previous
  # dead record behind instead of clearing it.
  rm -f "$pidfile"
  mkfifo "$pidfile"
  guard_rc=0
  timeout 2 python3 "$SUBJECT_ROOT/apps/paseo/paseo-clear-stale-pid.py" \
    --after-handover "$pidfile" >/dev/null 2>&1 || guard_rc=$?
  if [ "$guard_rc" -ne 0 ] && [ "$guard_rc" -ne 124 ] && [ -p "$pidfile" ]; then
    ok "paseo: stale guard rejects a FIFO without blocking or mutation"
  else
    bad "paseo: stale guard blocked on or mutated a FIFO (rc=$guard_rc)"
  fi
  rm -f "$pidfile"

  # Matching process and service environments alone cannot authorize stopping
  # a broad service. The pidfile PID must also identify the declared app.
  : >"$log"
  start_paseo_holder "$paseo_home" "$wrong_ready" /usr/bin/sleep \
    || { bad "paseo: negative-case holder did not become ready"; return; }
  wrong_holder="$PASEO_HOLDER_PID"
  wrong_main="$PASEO_MAIN_PID"
  write_paseo_pidfile "$pidfile" "$wrong_holder" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  before_hash="$(sha256sum "$pidfile" | awk '{print $1}')"
  rc=0
  (
    # Fixture environment is intentionally subshell-local.
    # shellcheck disable=SC2030,SC2031
    export PATH="$shim:/usr/bin:/bin" AIRLOCK_TEST_EVENT_LOG="$log" \
      AIRLOCK_TEST_PASEO_PID="$wrong_holder" AIRLOCK_TEST_PASEO_MAIN_PID="$wrong_main" \
      AIRLOCK_TEST_SERVICE_HOME="$paseo_home" AIRLOCK_TEST_SERVICE_EXEC="/usr/bin/sleep 1000"
    # shellcheck source=/dev/null
    . "$SUBJECT_ROOT/install/lib.sh"
    airlock_handover_user_resource pidfile "$pidfile" "test Paseo singleton" \
      --service-environment "PASEO_HOME=$paseo_home" \
      --service-exec-prefix "$paseo_supervisor daemon start --foreground --no-relay --web-ui --listen"
  ) >/dev/null 2>&1 || rc=$?
  python3 "$SUBJECT_ROOT/apps/paseo/paseo-clear-stale-pid.py" \
    --after-handover "$pidfile" >/dev/null 2>&1 || guard_rc=$?
  if [ "$rc" -ne 0 ] && kill -0 "$wrong_holder" 2>/dev/null \
     && [ "$guard_rc" -ne 0 ] && [ ! -s "$log" ] \
     && [ "$before_hash" = "$(sha256sum "$pidfile" | awk '{print $1}')" ]; then
    ok "paseo: unrelated child with matching environments fails closed without stop or mutation"
  else
    bad "paseo: unrelated broad-service child was stopped or pidfile changed"
  fi
  kill "$wrong_holder" 2>/dev/null || true
  kill "$wrong_main" 2>/dev/null || true
  wait "$wrong_holder" 2>/dev/null || true
  wait "$wrong_main" 2>/dev/null || true

  # Exercise the subject renderer. On the mutation tree this is the former
  # destructive ExecStartPre plus Restart=always; on the fixed tree there is no
  # candidate-side cleanup. Fifty-three attempts reproduce the measured loop.
  start_paseo_holder "$paseo_home" "$retry_ready" "$paseo_supervisor" \
    || { bad "paseo: retry-loop holder did not become ready"; return; }
  retry_holder="$PASEO_HOLDER_PID"
  write_paseo_pidfile "$pidfile" "$retry_holder" '1970-01-01T00:00:00.000Z'
  before_hash="$(sha256sum "$pidfile" | awk '{print $1}')"
  before_inode="$(stat -c '%d:%i' "$pidfile")"
  # shellcheck source=/dev/null
  . "$SUBJECT_ROOT/apps/paseo/render.sh"
  render_paseo_unit /usr/bin "$home" paseo.test 443 /bin/false 6767 \
    /usr/bin/python3 "$SUBJECT_ROOT/apps/paseo/paseo-clear-stale-pid.py" \
    1G 900M 1024 NoNewPrivileges=yes >"$unit"
  mapfile -t paseo_lines < <(grep '^ExecStartPre=' "$unit" || true)
  prestarts="${#paseo_lines[@]}"
  for attempt in $(seq 1 53); do
    for line in "${paseo_lines[@]}"; do run_rendered_prestart "$line" >/dev/null 2>&1 || true; done
  done
  after_hash="$(sha256sum "$pidfile" 2>/dev/null | awk '{print $1}')"
  after_inode="$(stat -c '%d:%i' "$pidfile" 2>/dev/null || true)"
  if [ "$prestarts" -eq 0 ]; then
    ok "paseo: rendered candidate has no pidfile-mutating ExecStartPre"
  else
    bad "paseo: rendered candidate still has $prestarts pre-start cleanup command(s)"
  fi
  if [ -f "$pidfile" ] && [ "$before_hash" = "$after_hash" ] \
     && [ "$before_inode" = "$after_inode" ] && kill -0 "$retry_holder" 2>/dev/null; then
    ok "paseo: live legacy pidfile and process survive all 53 candidate failures"
  else
    bad "paseo: candidate failures deleted or changed live legacy singleton state"
  fi
  if grep -qx 'Restart=on-success' "$unit" && ! grep -qx 'Restart=always' "$unit"; then
    ok "paseo: nonzero candidate failure is not retried while clean UI restart remains supported"
  else
    bad "paseo: rendered restart policy still loops on candidate failure"
  fi
  if grep -qx 'StartLimitIntervalSec=30' "$unit" && grep -qx 'StartLimitBurst=3' "$unit"; then
    ok "paseo: even clean-exit restart behavior is rate limited"
  else
    bad "paseo: rendered unit lacks a bounded restart rate"
  fi
  # Matching literal installer source text.
  # shellcheck disable=SC2016
  handover_line="$(grep -n -m1 'airlock_handover_user_resource pidfile' \
    "$SUBJECT_ROOT/apps/paseo/install.sh" | cut -d: -f1 || true)"
  mutation_line="$(grep -n -m1 'npm_config_prefix=.*npm i -g' \
    "$SUBJECT_ROOT/apps/paseo/install.sh" | cut -d: -f1 || true)"
  restart_line="$(grep -n -m1 'airlock_run systemctl --user restart airlock-paseo.service' \
    "$SUBJECT_ROOT/apps/paseo/install.sh" | cut -d: -f1 || true)"
  # shellcheck disable=SC2016
  if grep -Fq 'airlock_handover_user_resource pidfile "$PASEO_PIDFILE"' \
       "$SUBJECT_ROOT/apps/paseo/install.sh" \
     && grep -Fq -- '--service-environment "PASEO_HOME=$PASEO_HOME_DIR"' \
       "$SUBJECT_ROOT/apps/paseo/install.sh" \
     && grep -Fq -- '--service-exec-prefix "$PASEO_BIN daemon start --foreground --no-relay --web-ui --listen"' \
       "$SUBJECT_ROOT/apps/paseo/install.sh" \
     && [ -n "$handover_line" ] && [ -n "$mutation_line" ] && [ -n "$restart_line" ] \
     && [ "$handover_line" -lt "$mutation_line" ] && [ "$mutation_line" -lt "$restart_line" ]; then
    ok "paseo: real installer orders measured handover before shared-prefix mutation and restart"
  else
    bad "paseo: real installer lacks resource-derived handover wiring"
  fi
  kill "$retry_holder" 2>/dev/null || true
  wait "$retry_holder" 2>/dev/null || true
  rm -f "$pidfile"
}

if [ ! -f "$SUBJECT_ROOT/apps/fileview/install.sh" ] \
   || [ ! -f "$SUBJECT_ROOT/apps/orca/render.sh" ] \
   || [ ! -f "$SUBJECT_ROOT/apps/paseo/render.sh" ]; then
  echo "FAIL legacy-singleton: invalid AIRLOCK_TEST_SUBJECT_ROOT=$SUBJECT_ROOT" >&2
  exit 1
fi

run_fileview_case service
run_fileview_case scope
run_fileview_case child
run_orca_handover_case
run_orca_case
run_orca_reaper_case
run_paseo_case

echo
echo "legacy-singleton-handover: $pass ok, $fail failed"
[ "$fail" -eq 0 ]
