#!/usr/bin/env bash
# Shared, app-specific state transitions for legacy DB conversion and compensation.
# Callers own the durable receipt/transaction decision; this file owns the one list of
# writers/producers and the mechanics that keep them stopped around a DB replacement.

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
  local state="$1" lane mode
  for lane in tmp new; do
    mode="$DEVMON_MIGRATION_TMP_MODE"
    [ "$lane" != new ] || mode="$DEVMON_MIGRATION_NEW_MODE"
    [ -e "$state/spool/$lane" ] || continue
    [ "$mode" != - ] || mode=3770
    chmod "$mode" "$state/spool/$lane" || return 1
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
