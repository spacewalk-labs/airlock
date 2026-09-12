#!/usr/bin/env bash
# Shared, app-specific state transitions for legacy DB conversion, compensation, and the
# post-commit activation. Callers own the durable record/transaction decision; this file
# owns the one list of writers/producers and the mechanics that keep them stopped around
# a DB replacement.

DEVMON_MIGRATION_UNITS=(
  airlock-devmon-heartbeat.timer
  airlock-token-freshness.timer
  airlock-devmon-heartbeat.service
  airlock-token-freshness.service
  airlock-token-freshness-failed.service
  airlock-dev-monitor.service
)
DEVMON_MIGRATION_ACTIVE=()
DEVMON_MIGRATION_TMP_MODE=-
DEVMON_MIGRATION_NEW_MODE=-
DEVMON_MIGRATION_TMP_IDENTITY=
DEVMON_MIGRATION_NEW_IDENTITY=

devmon_migration_state_dir() {
  printf '%s\n' "${AIRLOCK_STATE_DIR:-$HOME/.local/state/airlock}"
}

devmon_migration_unit_state() {
  local unit="$1" row key value
  row="$(timeout 30 systemctl --user show "$unit" \
    --property=LoadState --property=ActiveState --property=MainPID)" || return 1
  DEVMON_UNIT_LOAD='' DEVMON_UNIT_ACTIVE='' DEVMON_UNIT_PID=0
  while IFS='=' read -r key value; do
    case "$key" in
      LoadState) DEVMON_UNIT_LOAD="$value" ;;
      ActiveState) DEVMON_UNIT_ACTIVE="$value" ;;
      MainPID) DEVMON_UNIT_PID="${value:-0}" ;;
    esac
  done <<<"$row"
  [ -n "$DEVMON_UNIT_LOAD" ] && [ -n "$DEVMON_UNIT_ACTIVE" ]
}

devmon_migration_snapshot() {
  local state="$1" unit lane metadata mode
  DEVMON_MIGRATION_ACTIVE=()
  DEVMON_MIGRATION_TMP_MODE=-
  DEVMON_MIGRATION_NEW_MODE=-
  DEVMON_MIGRATION_TMP_IDENTITY=''
  DEVMON_MIGRATION_NEW_IDENTITY=''
  for unit in "${DEVMON_MIGRATION_UNITS[@]}"; do
    devmon_migration_unit_state "$unit" || return 1
    case "$DEVMON_UNIT_LOAD:$DEVMON_UNIT_ACTIVE:$DEVMON_UNIT_PID" in
      not-found:*:*|*:inactive:0|*:failed:0) ;;
      *) DEVMON_MIGRATION_ACTIVE+=("$unit") ;;
    esac
  done
  for lane in tmp new; do
    [ -e "$state/spool/$lane" ] || continue
    [ -d "$state/spool/$lane" ] && [ ! -L "$state/spool/$lane" ] || return 1
    metadata="$(stat -c '%u:%a:%d:%i' "$state/spool/$lane")" || return 1
    [ "${metadata%%:*}" = "$(id -u)" ] || return 1
    mode="${metadata#*:}"; mode="${mode%%:*}"
    if [ "$lane" = tmp ]; then
      DEVMON_MIGRATION_TMP_MODE="$mode"
      DEVMON_MIGRATION_TMP_IDENTITY="${metadata#*:*:}"
    else
      DEVMON_MIGRATION_NEW_MODE="$mode"
      DEVMON_MIGRATION_NEW_IDENTITY="${metadata#*:*:}"
    fi
  done
}

devmon_migration_load_active() {
  local csv="$1" candidate known unit
  local -a candidates=()
  DEVMON_MIGRATION_ACTIVE=()
  [ -n "$csv" ] || return 0
  IFS=',' read -r -a candidates <<<"$csv"
  for candidate in "${candidates[@]}"; do
    known=0
    for unit in "${DEVMON_MIGRATION_UNITS[@]}"; do
      [ "$candidate" != "$unit" ] || { known=1; break; }
    done
    [ "$known" = 1 ] || return 1
    DEVMON_MIGRATION_ACTIVE+=("$candidate")
  done
}

devmon_migration_quiesce() {
  local unit
  for unit in "${DEVMON_MIGRATION_UNITS[@]}"; do
    devmon_migration_unit_state "$unit" || return 1
    case "$DEVMON_UNIT_LOAD:$DEVMON_UNIT_ACTIVE:$DEVMON_UNIT_PID" in
      not-found:*:*|*:inactive:0|*:failed:0) continue ;;
    esac
    timeout 30 systemctl --user stop "$unit" >/dev/null || return 1
    devmon_migration_unit_state "$unit" || return 1
    case "$DEVMON_UNIT_ACTIVE:$DEVMON_UNIT_PID" in
      inactive:0|failed:0) ;; *) return 1 ;;
    esac
  done
}

devmon_migration_fence() {
  local state="$1" writer="$2" verify_identity="${3:-false}"
  local lane metadata expected
  for lane in tmp new; do
    [ -e "$state/spool/$lane" ] || continue
    [ -d "$state/spool/$lane" ] && [ ! -L "$state/spool/$lane" ] || return 1
    metadata="$(stat -c '%u:%d:%i' "$state/spool/$lane")" || return 1
    [ "${metadata%%:*}" = "$(id -u)" ] || return 1
    if [ "$verify_identity" = true ]; then
      expected="$DEVMON_MIGRATION_TMP_IDENTITY"
      [ "$lane" != new ] || expected="$DEVMON_MIGRATION_NEW_IDENTITY"
      [ "$metadata" = "$(id -u):$expected" ] || return 1
    fi
    chmod g-w "$state/spool/$lane" || return 1
    if id "$writer" >/dev/null 2>&1; then
      sudo -u "$writer" test ! -w "$state/spool/$lane" || return 1
    fi
  done
}

devmon_migration_restore_db() {
  local policy="$1" database="$2" tool="$3" output rc=0
  if [ "$policy" = marker-safe ]; then
    output="$(python3 "$tool" --compensate-endstate "$database" --offline 2>&1)" || rc=$?
  else
    output="$(python3 "$tool" --restore-backup "${database}.pre-endstate" \
      --restore-to "$database" --offline 2>&1)" || rc=$?
  fi
  [ -z "$output" ] || printf '%s\n' "$output" >&2
  return "$rc"
}

devmon_migration_restore_spool() {
  local state="$1" lane mode path metadata actual gid
  for lane in tmp new; do
    mode="$DEVMON_MIGRATION_TMP_MODE"
    [ "$lane" != new ] || mode="$DEVMON_MIGRATION_NEW_MODE"
    path="$state/spool/$lane"
    [ -e "$path" ] || continue
    [ "$mode" != - ] || mode=3770
    case "$mode" in
      [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
      *) return 1 ;;
    esac
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    metadata="$(stat -c '%u:%g:%a' "$path")" || return 1
    [ "${metadata%%:*}" = "$(id -u)" ] || return 1
    gid="${metadata#*:}"; gid="${gid%%:*}"

    chmod "$mode" "$path" || return 1
    actual="$(stat -c %a "$path")" || return 1
    [ "$actual" = "$mode" ] && continue

    # Linux may clear setgid after a successful chmod when the operator does not
    # belong to the lane's group. Use the same non-root UID + writer GID boundary as
    # install-spool-hardening.sh, then prove the requested mode actually stuck.
    (( (8#$mode & 8#2000) != 0 )) || return 1
    sudo -u root -g root /usr/bin/setpriv --reuid "$(id -u)" \
      --regid "$gid" --clear-groups -- /usr/bin/chmod "$mode" -- "$path" \
      || return 1
    [ "$(stat -c %a "$path")" = "$mode" ] || return 1
  done
}

devmon_migration_start_saved() {
  local scope="$1" unit
  for unit in "${DEVMON_MIGRATION_ACTIVE[@]}"; do
    if [ "$scope" = unmanaged ]; then
      case "$unit" in airlock-token-freshness*) ;; *) continue ;; esac
    fi
    timeout 30 systemctl --user start "$unit" >/dev/null || return 1
  done
}

# --- Deferred activation -----------------------------------------------------------
#
# Inside an install transaction the legacy DB is left untouched and the candidate is
# installed stopped (apps/dev-monitor/activation-record.py says why). Once the
# transaction is committed there is nothing left to roll back to, so this step is
# forward-only: quiesce, fence, convert, then backend -> health -> heartbeat. A failure
# leaves the record in place for the next run; it never restores the legacy DB.

devmon_activation_tool() {
  printf '%s/activation-record.py\n' "$(dirname "${BASH_SOURCE[0]}")"
}

# devmon_activation_due STATE — prints "tx db writer port app" when an activation is
# owed; rc 1 = none, 2 = refused (unsafe or inconsistent record).
devmon_activation_due() {
  python3 "$(devmon_activation_tool)" due "$1"
}

# devmon_activation_app STATE — prints the app id of any record; rc 1 = none.
devmon_activation_app() {
  python3 "$(devmon_activation_tool)" app "$1"
}

# devmon_activation_compensate STATE TX — a failed TX takes its own record back.
devmon_activation_compensate() {
  python3 "$(devmon_activation_tool)" compensate "$1" "$2"
}

devmon_activation_clear() {
  python3 "$(devmon_activation_tool)" clear "$1" "$2"
}

devmon_activation_backend_healthy() {
  local port="$1" code="" _
  for _ in $(seq 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
      "http://127.0.0.1:${port}/api/overview" 2>/dev/null || true)"
    [ "$code" != 200 ] || return 0
    sleep 1
  done
  log "dev-monitor backend did not answer /api/overview with 200 (last: ${code:-none})"
  return 1
}

# A fence is a chmod g-w on the spool lanes, so a run killed between fencing and
# restoring leaves the cross-UID producer locked out. The next activation would then
# snapshot that locked-out mode as the one to preserve and make it permanent -- the
# 2026-09-11 box was found with exactly that. A lane the writer group cannot write is
# therefore never a mode to keep: "-" makes devmon_migration_restore_spool use the
# canonical one the spool hardening establishes.
devmon_activation_forget_fenced_modes() {
  local lane mode
  for lane in tmp new; do
    mode="$DEVMON_MIGRATION_TMP_MODE"
    [ "$lane" != new ] || mode="$DEVMON_MIGRATION_NEW_MODE"
    [ "$mode" != - ] || continue
    if (( (8#${mode: -2:1} & 2) == 0 )); then
      log "spool $lane lane is closed to the writer group (mode $mode) — restoring the canonical mode instead"
      if [ "$lane" = tmp ]; then DEVMON_MIGRATION_TMP_MODE=-; else DEVMON_MIGRATION_NEW_MODE=-; fi
    fi
  done
}

# devmon_activation_run DB WRITER PORT — convert and start. rc 0 = active and healthy.
# One database, one activation: the ledger lock covers a state directory, and two
# installers with different state directories still name this one database.
devmon_activation_run() {
  local database="$1" writer="$2" port="$3" state output fenced=0 rc=0
  state="${database%/messages.db}"
  exec {_devmon_activation_lock}>>"$database.activation.lock" \
    || { log "cannot open the messages database activation lock"; return 1; }
  flock -w 60 "$_devmon_activation_lock" || {
    log "another run is activating the messages database"
    exec {_devmon_activation_lock}>&-
    return 1
  }
  _devmon_activation_locked_run "$@"
  rc=$?
  exec {_devmon_activation_lock}>&-
  return "$rc"
}

_devmon_activation_locked_run() {
  local database="$1" writer="$2" port="$3" state output fenced=0 rc=0
  state="${database%/messages.db}"
  devmon_migration_snapshot "$state" || { log "cannot inspect DB writers or spool lanes"; return 1; }
  devmon_activation_forget_fenced_modes
  devmon_migration_quiesce || { log "cannot stop and verify DB writers"; return 1; }
  if devmon_migration_fence "$state" "$writer" true; then
    fenced=1
    output="$(python3 "$(dirname "${BASH_SOURCE[0]}")/migrate-legacy-state.py" \
      --endstate "$database" --offline)" || rc=$?
    case "$rc:$output" in
      '0:converted=1 backup_retained=1'|'0:converted=0 backup_retained=1') ;;
      *) log "messages database conversion did not complete (rc=$rc${output:+: $output}); legacy DB and backup retained"
         rc=1 ;;
    esac
  else
    log "cannot fence cross-UID spool publishing"
    rc=1
  fi
  # The spool is reopened on every path: a fenced lane silently drops producers.
  if [ "$fenced" = 1 ] || [ "$rc" != 0 ]; then
    devmon_migration_restore_spool "$state" || { log "cannot restore spool lane modes"; rc=1; }
  fi
  [ "$rc" = 0 ] || return 1
  timeout 30 systemctl --user start airlock-dev-monitor.service \
    || { log "cannot start airlock-dev-monitor.service"; return 1; }
  devmon_activation_backend_healthy "$port" || return 1
  if [ -f "$HOME/.config/systemd/user/airlock-devmon-heartbeat.timer" ]; then
    timeout 30 systemctl --user start airlock-devmon-heartbeat.timer \
      || { log "cannot start airlock-devmon-heartbeat.timer"; return 1; }
  fi
  devmon_migration_start_saved unmanaged \
    || { log "cannot restart previously-active token freshness units"; return 1; }
}
