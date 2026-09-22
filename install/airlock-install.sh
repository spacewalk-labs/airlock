#!/usr/bin/env bash
# Airlock orchestrator: validate config -> install enabled apps -> render nginx
# -> reload. Idempotent; re-run after editing airlock.toml. Set AIRLOCK_DRY_RUN=1
# to print the steps without touching the system.
#
#   bash install/airlock-install.sh
#
# May require sudo for nginx/tailscale steps depending on your box.
set -euo pipefail

_airlock_install_usage() {
  cat <<'EOF'
airlock-install — validate and install the configured Airlock box.
  bash install/airlock-install.sh
  bash install/airlock-install.sh --select-app=<package-id> [...]
  bash install/airlock-install.sh --dangerously-admit-unverified=<package-id>
  bash install/airlock-install.sh --update-channel-handoff=<path> \
    --update-channel-handoff-sha256=<sha256> --select-app=<package-id> [...]
  AIRLOCK_DRY_RUN=1 bash install/airlock-install.sh
  bash install/airlock-install.sh --transfer-owner-from=<current-owner-login>
  bash install/airlock-install.sh --recover-transaction=<transaction-id>
  bash install/airlock-install.sh --help
EOF
}

_airlock_arg_die() {
  printf '[airlock] FATAL: %s\n' "$*" >&2
  exit 1
}

# Classify the complete argv before sourcing helpers or looking at live state.  A
# question or an invalid invocation must not enter self-kill escape, recovery,
# config, render, or lock code merely to learn that it should have exited.
_airlock_lifecycle_args=()
_airlock_selected_apps=()
_airlock_update_channel_handoff=""
_airlock_update_channel_handoff_sha256=""
_airlock_recover_transaction=""
_airlock_transfer_owner_from=""
_airlock_help=0
for _airlock_install_arg in "$@"; do
  case "$_airlock_install_arg" in
    -h|--help)
      _airlock_help=$((_airlock_help + 1))
      ;;
    --dangerously-admit-unverified=*)
      [ "${#_airlock_lifecycle_args[@]}" -eq 0 ] \
        || _airlock_arg_die "--dangerously-admit-unverified is accepted only once"
      _airlock_lifecycle_args+=("$_airlock_install_arg")
      ;;
    --dangerously-admit-unverified)
      _airlock_arg_die "--dangerously-admit-unverified requires =<package-id>"
      ;;
    --select-app=*)
      _airlock_selected_app="${_airlock_install_arg#*=}"
      [[ "$_airlock_selected_app" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] \
        || _airlock_arg_die "--select-app requires one valid package id"
      _airlock_selected_apps+=("$_airlock_selected_app")
      ;;
    --select-app)
      _airlock_arg_die "--select-app requires =<package-id>"
      ;;
    --update-channel-handoff=*)
      [ -z "$_airlock_update_channel_handoff" ] \
        || _airlock_arg_die "--update-channel-handoff is accepted only once"
      _airlock_update_channel_handoff="${_airlock_install_arg#*=}"
      [ -n "$_airlock_update_channel_handoff" ] \
        || _airlock_arg_die "--update-channel-handoff requires =<absolute-private-path>"
      ;;
    --update-channel-handoff-sha256=*)
      [ -z "$_airlock_update_channel_handoff_sha256" ] \
        || _airlock_arg_die "--update-channel-handoff-sha256 is accepted only once"
      _airlock_update_channel_handoff_sha256="${_airlock_install_arg#*=}"
      ;;
    --update-channel-handoff|--update-channel-handoff-sha256)
      _airlock_arg_die "$_airlock_install_arg requires =<value>"
      ;;
    --recover-transaction=*)
      [ -z "$_airlock_recover_transaction" ] \
        || _airlock_arg_die "--recover-transaction is accepted only once"
      _airlock_recover_transaction="${_airlock_install_arg#*=}"
      [[ "$_airlock_recover_transaction" =~ ^[0-9a-f]{32}$ ]] \
        || _airlock_arg_die "--recover-transaction requires one full 32-hex transaction id"
      ;;
    --recover-transaction)
      _airlock_arg_die "--recover-transaction requires =<transaction-id>"
      ;;
    --transfer-owner-from=*)
      [ -z "$_airlock_transfer_owner_from" ] \
        || _airlock_arg_die "--transfer-owner-from is accepted only once"
      _airlock_transfer_owner_from="${_airlock_install_arg#*=}"
      [ -n "$_airlock_transfer_owner_from" ] \
        || _airlock_arg_die "--transfer-owner-from requires =<current-owner-login>"
      [[ "$_airlock_transfer_owner_from" =~ ^[^[:cntrl:]\"\\]+@[^[:cntrl:]\"\\]+$ ]] \
        || _airlock_arg_die "--transfer-owner-from must be one safe email-like login"
      ;;
    --transfer-owner-from)
      _airlock_arg_die "--transfer-owner-from requires =<current-owner-login>"
      ;;
    *)
      _airlock_arg_die "unknown installer argument: $_airlock_install_arg"
      ;;
  esac
done
if [ "$_airlock_help" -gt 0 ]; then
  [ "$#" -eq 1 ] && [ "$_airlock_help" -eq 1 ] \
    || _airlock_arg_die "--help cannot be combined with installer arguments"
  _airlock_install_usage
  exit 0
fi
if [ -n "$_airlock_update_channel_handoff" ] \
    || [ -n "$_airlock_update_channel_handoff_sha256" ]; then
  [ -n "$_airlock_update_channel_handoff" ] \
    && [ -n "$_airlock_update_channel_handoff_sha256" ] \
    || _airlock_arg_die "managed update requires the handoff path and SHA-256 together"
  [ "${#_airlock_selected_apps[@]}" -gt 0 ] \
    || _airlock_arg_die "managed update requires one or more --select-app arguments"
  [ "${#_airlock_lifecycle_args[@]}" -eq 0 ] \
    || _airlock_arg_die "managed update cannot use the unverified package escape hatch"
fi
if [ -n "$_airlock_recover_transaction" ]; then
  [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] \
    || _airlock_arg_die "--recover-transaction cannot be combined with AIRLOCK_DRY_RUN=1"
  [ "${#_airlock_lifecycle_args[@]}" -eq 0 ] \
    && [ "${#_airlock_selected_apps[@]}" -eq 0 ] \
    && [ -z "$_airlock_update_channel_handoff" ] \
    && [ -z "$_airlock_update_channel_handoff_sha256" ] \
    || _airlock_arg_die "--recover-transaction cannot be combined with install arguments"
fi
if [ -n "$_airlock_transfer_owner_from" ]; then
  [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] \
    || _airlock_arg_die "--transfer-owner-from is an explicit live transition, not a dry-run option"
  [ "${#_airlock_lifecycle_args[@]}" -eq 0 ] \
    && [ "${#_airlock_selected_apps[@]}" -eq 0 ] \
    && [ -z "$_airlock_update_channel_handoff" ] \
    && [ -z "$_airlock_update_channel_handoff_sha256" ] \
    && [ -z "$_airlock_recover_transaction" ] \
    || _airlock_arg_die "--transfer-owner-from is accepted only by a full ordinary install"
fi

# A selected install must not acquire mutation authority over unrelated local
# packages.  airlock-config still parses the complete candidate for dependency
# planning, but confirms package-lock bytes only for the explicitly selected
# lifecycle targets.  The argument-free/full installer keeps its global gate.
_airlock_package_info_args=()
if [ "${#_airlock_selected_apps[@]}" -gt 0 ]; then
  _airlock_selected_csv="$(IFS=,; printf '%s' "${_airlock_selected_apps[*]}")"
  _airlock_package_info_args+=("--lifecycle-targets=$_airlock_selected_csv")
fi

# AIRLOCK_FIXTURE_* is executable test authority, not a harmless destination
# hint. Before sourcing helpers or reading live state, bind it to one marked,
# owner-private root and prove every path a fixture run may write stays below
# that root. A normal mutating fixture also has to replace the commands that can
# cross into systemd, nginx, Tailscale, or root-owned paths. This is deliberately
# fail-closed: an incomplete fixture is never allowed to become a live install.
_airlock_fixture_boundary() { # <dry|recover|mutate>
  local _mode="$1" _fixture_signal=0 _name _resolved _tool_paths=()
  while IFS= read -r _name; do
    case "$_name" in AIRLOCK_FIXTURE_*) _fixture_signal=1; break ;; esac
  done < <(compgen -A variable)
  [ "$_fixture_signal" = 1 ] || return 0
  if [ "$_mode" != dry ]; then
    for _name in sudo systemctl systemd-run tailscale; do
      _resolved="$(command -v "$_name" 2>/dev/null || true)"
      _tool_paths+=("$_resolved")
    done
  fi
  python3 - "$_mode" "${AIRLOCK_FIXTURE_LIVE_BOX_LEASE_DIR:-}" \
    "${HOME:-}" "${AIRLOCK_STATE_DIR:-}" "${AIRLOCK_WEBROOT:-}" \
    "${AIRLOCK_CONFD:-}" "${AIRLOCK_NGINX_SITE:-}" \
    "${AIRLOCK_UNIT_DIR_USER:-}" "${AIRLOCK_UNIT_DIR_SYSTEM:-}" \
    "${AIRLOCK_RENDER_DIR:-}" "${_tool_paths[@]}" <<'PY'
import os
import pathlib
import stat
import sys

mode, lease_raw, home, state, webroot, confd, nginx_site, unit_user, unit_system, render, *tools = sys.argv[1:]
lease = pathlib.Path(lease_raw)
if not lease.is_absolute() or lease.name != "airlock-live-box":
    raise SystemExit("fixture boundary: lease path must be absolute and end in /airlock-live-box")
try:
    root = lease.parent.resolve(strict=True)
    root_info = root.lstat()
    marker = root / ".airlock-live-box-fixture-v1"
    marker_info = marker.lstat()
    marker_value = marker.read_text(encoding="ascii")
except (OSError, UnicodeError) as exc:
    raise SystemExit(f"fixture boundary: missing fixture root or marker: {exc}")
if (lease.parent != root or root.is_symlink() or not root.is_dir()
        or root_info.st_uid != os.getuid() or stat.S_IMODE(root_info.st_mode) != 0o700
        or marker.is_symlink() or not marker.is_file()
        or marker_info.st_uid != os.getuid() or stat.S_IMODE(marker_info.st_mode) != 0o600
        or marker_value != "airlock.live-box-fixture/v1\n"):
    raise SystemExit("fixture boundary: root must be canonical, owner-private, and explicitly marked")

def below(label, raw, required):
    if not raw:
        if required:
            raise SystemExit(f"fixture boundary: {label} must be explicit")
        return
    path = pathlib.Path(raw)
    if not path.is_absolute():
        raise SystemExit(f"fixture boundary: {label} must be absolute")
    resolved = path.resolve(strict=False)
    if resolved != root and root not in resolved.parents:
        raise SystemExit(f"fixture boundary: {label} escapes fixture root: {resolved}")

below("HOME", home, True)
state = state or os.fspath(pathlib.Path(home) / ".local" / "state" / "airlock")
unit_user = unit_user or os.fspath(pathlib.Path(home) / ".config" / "systemd" / "user")
below("AIRLOCK_STATE_DIR", state, True)
for label, raw in (
    ("AIRLOCK_WEBROOT", webroot),
    ("AIRLOCK_CONFD", confd),
    ("AIRLOCK_NGINX_SITE", nginx_site),
    ("AIRLOCK_UNIT_DIR_USER", unit_user),
    ("AIRLOCK_UNIT_DIR_SYSTEM", unit_system),
    ("AIRLOCK_RENDER_DIR", render),
):
    below(label, raw, mode == "mutate" and label != "AIRLOCK_RENDER_DIR")
if mode != "dry":
    if len(tools) != 4 or any(not raw for raw in tools):
        raise SystemExit("fixture boundary: mutation command shims are incomplete")
    for raw in tools:
        below("mutation command", raw, True)
PY
}

_airlock_fixture_mode=mutate
[ "${AIRLOCK_DRY_RUN:-0}" != 1 ] || _airlock_fixture_mode=dry
[ -z "$_airlock_recover_transaction" ] || _airlock_fixture_mode=recover
# AIRLOCK_FIXTURE_BOUNDARY_CALL — the regression fixture mutates this exact call.
_airlock_fixture_boundary "$_airlock_fixture_mode" \
  || _airlock_arg_die "unsafe fixture execution refused before live effects"
if [ -n "${AIRLOCK_FIXTURE_LIVE_BOX_LEASE_DIR:-}" ]; then
  printf '[airlock] verified fixture targets before effects: WEBROOT=%s CONFD=%s NGINX_SITE=%s\n' \
    "${AIRLOCK_WEBROOT:-<private-dry-preview>}" \
    "${AIRLOCK_CONFD:-<private-dry-preview>}" \
    "${AIRLOCK_NGINX_SITE:-<no-site-write>}" >&2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# Never inherit a config reader from the caller. The private wrapper is set
# only on individual lifecycle child invocations below; accepting an ambient
# value here would recreate the rejected persistent escape switch under a
# different name.
AIRLOCK_CONFIG_BIN="$ROOT/bin/airlock-config"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/apps/dev-monitor/migration-lifecycle.sh"

# Never trust caller markers as proof of lock, snapshot, or transaction
# ownership. This must precede self-kill escape so the re-exec cannot forward
# stale authority into the recovered process.
unset AIRLOCK_LEDGER_LOCK_HELD AIRLOCK_CONFIG_SNAPSHOT \
  AIRLOCK_CONFIG_SNAPSHOT_SHA256 AIRLOCK_INSTALL_PKG_INFO_SHA256 \
  AIRLOCK_APP_SCOPED_PLAN_SHA256 AIRLOCK_LEDGER_DEPENDENCIES_SHA256 \
  AIRLOCK_PREREQ_RECEIPT AIRLOCK_PREREQ_CONTEXT \
  AIRLOCK_INSTALL_TRANSACTION_ID AIRLOCK_DEVMON_MIGRATION_RECEIPT \
  AIRLOCK_PKG_INFO
while IFS= read -r _airlock_ambient_name; do
  case "$_airlock_ambient_name" in
    AIRLOCK_MANAGED_*|AIRLOCK_UPDATE_CHANNEL_*) unset "$_airlock_ambient_name" ;;
  esac
done < <(compgen -A variable)
unset _airlock_ambient_name

# One bounded root operation serves staging, recovery and forward completion of
# the installed trusted measurer. Candidate code is only copied as inert data;
# it is never executed here. Paths are fixed or transaction-id-derived.
_airlock_trusted_measurer_root() {
  local operation="$1" transaction_id="$2" old_sha="$3" new_sha="$4" source="${5:-}"
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ ]] || return 2
  [[ "$old_sha" =~ ^[0-9a-f]{64}$ ]] || return 2
  [[ "$new_sha" =~ ^[0-9a-f]{64}$ ]] || return 2
  airlock_run sudo python3 - "$operation" "$transaction_id" "$old_sha" "$new_sha" \
      "$source" "$(id -u)" "$(id -g)" <<'PY'
import fcntl
import hashlib
import os
import pathlib
import shutil
import stat
import sys

operation, txid, old_sha, new_sha, source_raw, caller_uid, caller_gid = sys.argv[1:]
caller_uid, caller_gid = int(caller_uid), int(caller_gid)
directory = pathlib.Path("/opt/airlock/libexec")
target = directory / "airlock-managed-release"
old_path = directory / f".airlock-managed-release.{txid}.old"
new_path = directory / f".airlock-managed-release.{txid}.new"
lock_path = directory / ".airlock-managed-release.activation.lock"

def fail(message):
    print(f"trusted measurer activation: {message}", file=sys.stderr)
    raise SystemExit(2)

def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()

def root_file(path, expected_sha, mode):
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or path.is_symlink()
            or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (0, 0, mode)
            or digest(path) != expected_sha):
        fail(f"unsafe or mismatched root file: {path}")

def fsync_file(path):
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def fsync_directory():
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

info = directory.lstat()
if (not stat.S_ISDIR(info.st_mode) or directory.is_symlink()
        or info.st_uid != 0 or info.st_gid != 0 or stat.S_IMODE(info.st_mode) & 0o022):
    fail("/opt/airlock/libexec is not a protected root directory")
flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0)
lock_fd = os.open(lock_path, flags, 0o600)
try:
    os.fchmod(lock_fd, 0o600)
    os.fchown(lock_fd, 0, 0)
    info = os.fstat(lock_fd)
    if not stat.S_ISREG(info.st_mode):
        fail("activation lock is not a regular file")
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    target_hash = digest(target) if target.exists() and not target.is_symlink() else None
    if operation == "stage":
        if target_hash != old_sha:
            fail("active trusted measurer differs from frozen installed bytes")
        source = pathlib.Path(source_raw)
        source_fd = os.open(
            source, os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
        )
        source_handle = os.fdopen(source_fd, "rb")
        source_info = os.fstat(source_handle.fileno())
        source_digest = hashlib.sha256()
        for block in iter(lambda: source_handle.read(1024 * 1024), b""):
            source_digest.update(block)
        source_handle.seek(0)
        if (not stat.S_ISREG(source_info.st_mode)
                or (source_info.st_uid, source_info.st_gid,
                    stat.S_IMODE(source_info.st_mode)) != (caller_uid, caller_gid, 0o600)
                or source_digest.hexdigest() != new_sha):
            source_handle.close()
            fail("next trusted measurer runfile is not the frozen private input")
        if old_path.exists() or old_path.is_symlink() or new_path.exists() or new_path.is_symlink():
            source_handle.close()
            fail("trusted measurer staging siblings already exist")
        for incoming, destination in ((target.open("rb"), old_path), (source_handle, new_path)):
            with incoming, destination.open("xb") as outgoing:
                shutil.copyfileobj(incoming, outgoing)
                outgoing.flush()
                os.fsync(outgoing.fileno())
            os.chown(destination, 0, 0)
            os.chmod(destination, 0o555)
            fsync_file(destination)
        root_file(old_path, old_sha, 0o555)
        root_file(new_path, new_sha, 0o555)
        root_file(target, old_sha, 0o555)
        fsync_directory()
    elif operation == "forward":
        root_file(old_path, old_sha, 0o555)
        if target_hash == old_sha:
            root_file(new_path, new_sha, 0o555)
            os.replace(new_path, target)
        elif target_hash != new_sha:
            fail("active trusted measurer matches neither old nor new bytes")
        root_file(target, new_sha, 0o555)
        fsync_file(target)
        fsync_directory()
        root_file(target, new_sha, 0o555)
    elif operation == "rollback":
        if target_hash == new_sha:
            root_file(old_path, old_sha, 0o555)
            os.replace(old_path, target)
        elif target_hash != old_sha:
            fail("cannot restore trusted measurer from ambiguous active bytes")
        root_file(target, old_sha, 0o555)
        fsync_file(target)
        fsync_directory()
        root_file(target, old_sha, 0o555)
    elif operation == "cleanup":
        root_file(target, new_sha, 0o555)
        for path, expected in ((old_path, old_sha), (new_path, new_sha)):
            if path.exists() or path.is_symlink():
                root_file(path, expected, 0o555)
                path.unlink()
        fsync_directory()
    elif operation == "cleanup-old":
        root_file(target, old_sha, 0o555)
        for path, expected in ((old_path, old_sha), (new_path, new_sha)):
            if path.exists() or path.is_symlink():
                root_file(path, expected, 0o555)
                path.unlink()
        fsync_directory()
    else:
        fail("unknown activation operation")
finally:
    os.close(lock_fd)
PY
}

# dev-monitor's messages DB is retained operator data and therefore sits outside the
# package checkpoint.  Inside a transaction it is never converted (see
# apps/dev-monitor/activation-record.py); failure and crash recovery take back the
# deferral record before the old package is allowed to run.
_airlock_devmon_compensate() {
  local state_dir="$1" transaction_id="$2" receipt expected_db metadata
  local database writer tmp_mode new_mode active_csv devmon_state
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ ]] || {
    log "WARN: invalid install transaction id for database compensation"
    return 1
  }
  # A deferred activation touched no data: taking its record back is the whole
  # compensation, and it must happen before any restore makes the old package live.
  devmon_activation_compensate "$state_dir" "$transaction_id" || {
    log "WARN: cannot take back the deferred dev-monitor activation record"
    return 1
  }
  # Receipts below are written only by installers from before activation was
  # deferred; a box that stopped mid-transaction on one still needs them honoured.
  receipt="$state_dir/install-checkpoints/$transaction_id/dev-monitor-migration.json"
  [ -e "$receipt" ] || [ -L "$receipt" ] || return 0
  if [ ! -f "$receipt" ] || [ -L "$receipt" ]; then
    log "WARN: dev-monitor migration receipt is not a regular non-symlink file"
    return 1
  fi
  metadata="$(stat -c '%u:%a' "$receipt")" || return 1
  if [ "$metadata" != "$(id -u):600" ]; then
    log "WARN: dev-monitor migration receipt has unsafe ownership or mode"
    return 1
  fi
  expected_db="$HOME/.local/state/airlock/dev-monitor/messages.db"
  metadata="$(python3 - "$receipt" "$transaction_id" "$expected_db" <<'PY'
import json
import re
import sys

path, transaction_id, expected_db = sys.argv[1:]
with open(path, encoding='utf-8') as handle:
    receipt = json.load(handle)
if set(receipt) != {'version', 'transaction_id', 'database', 'writer_user',
                    'spool_modes', 'active_units'} or receipt['version'] != 1:
    raise SystemExit('invalid dev-monitor migration receipt shape')
if receipt['transaction_id'] != transaction_id or receipt['database'] != expected_db:
    raise SystemExit('dev-monitor migration receipt does not match this transaction')
writer = receipt['writer_user']
if not isinstance(writer, str) or not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', writer):
    raise SystemExit('invalid dev-monitor migration writer')
modes = receipt['spool_modes']
if not isinstance(modes, dict) or set(modes) != {'tmp', 'new'}:
    raise SystemExit('invalid dev-monitor migration spool modes')
for mode in modes.values():
    if mode is not None and (not isinstance(mode, str)
                             or not re.fullmatch(r'[0-7]{3,4}', mode)):
        raise SystemExit('invalid dev-monitor migration spool mode')
units = receipt['active_units']
if (not isinstance(units, list) or len(units) != len(set(units))
        or any(not isinstance(unit, str) or ',' in unit or '\t' in unit for unit in units)):
    raise SystemExit('invalid dev-monitor migration unit list')
print('\t'.join((expected_db, writer, modes['tmp'] or '-', modes['new'] or '-',
                 ','.join(units))))
PY
)" || {
    log "WARN: cannot validate dev-monitor migration receipt"
    return 1
  }
  IFS=$'\t' read -r database writer tmp_mode new_mode active_csv <<<"$metadata"
  devmon_state="${database%/messages.db}"
  DEVMON_MIGRATION_TMP_MODE="$tmp_mode"
  DEVMON_MIGRATION_NEW_MODE="$new_mode"
  devmon_migration_load_active "$active_csv" || return 1
  devmon_migration_quiesce || return 1
  devmon_migration_fence "$devmon_state" "$writer" || return 1
  _airlock_devmon_receipt_database="$database"
  _airlock_devmon_receipt_writer="$writer"
  # Restore only an unchanged conversion. A candidate that already ran on the
  # converted database is kept instead -- under every condition forward_check
  # names (backup, marker and current DB all sound, exact canonical schema) plus a
  # candidate tree that still matches its journaled intent. Anything less stays
  # refused: a mismatched hash alone is what corruption looks like too.
  local verdict backup_sha target_sha kept_forward=0 db_lock_fd
  # The classification and the decision made on it happen under the one lock every
  # activation of this database takes, so no other run can change the bytes between
  # the two. The lock is held until the receipt is gone.
  exec {db_lock_fd}>>"$database.activation.lock" || return 1
  flock -w 60 "$db_lock_fd" || {
    log "WARN: another run holds the messages database"
    exec {db_lock_fd}>&-
    return 1
  }
  _airlock_devmon_compensate_locked "$@"
  local rc=$?
  exec {db_lock_fd}>&-
  return "$rc"
}

_airlock_devmon_compensate_locked() {
  local state_dir="$1" transaction_id="$2" receipt database writer devmon_state
  local verdict backup_sha target_sha kept_forward=0 candidate_state=inactive
  receipt="$state_dir/install-checkpoints/$transaction_id/dev-monitor-migration.json"
  database="$_airlock_devmon_receipt_database"; writer="$_airlock_devmon_receipt_writer"
  devmon_state="${database%/messages.db}"
  verdict="$(python3 "$ROOT/apps/dev-monitor/migrate-legacy-state.py" \
    --forward-check "$database" --offline 2>&1)" || {
    log "WARN: cannot classify the dev-monitor database for compensation: $verdict"
    return 1
  }
  case "$verdict" in
    restorable=1)
      devmon_migration_restore_db marker-safe "$database" \
        "$ROOT/apps/dev-monitor/migrate-legacy-state.py" || return 1
      ;;
    "forward=1 backup_sha256="*)
      backup_sha="${verdict#forward=1 backup_sha256=}"; backup_sha="${backup_sha%% *}"
      target_sha="${verdict##* target_sha256=}"
      # The decision is durable, in the transaction body, before the receipt goes: a
      # crash between the two re-enters here and finds the same answer, not half of it.
      "$ROOT/bin/airlock-ledger" transaction-keep-forward dev-monitor "$database" "$backup_sha" "$target_sha" \
        || return 1
      kept_forward=1
      log "dev-monitor's candidate already wrote to the converted database; keeping it (backup ${backup_sha:0:12}) rather than discarding those writes"
      ;;
    *)
      log "WARN: unexpected dev-monitor compensation verdict: $verdict"
      return 1 ;;
  esac
  devmon_migration_restore_spool "$devmon_state" || return 1
  if [ "$kept_forward" = 1 ]; then
    # Best effort: the kept candidate is an uncommitted intent either way, and the
    # next run finishes it. A start failure must not turn a decided keep into degraded,
    # but it is recorded so airlock-status can say the candidate is down.
    if timeout 30 systemctl --user start airlock-dev-monitor.service; then
      candidate_state=active
      [ ! -f "$HOME/.config/systemd/user/airlock-devmon-heartbeat.timer" ] \
        || timeout 30 systemctl --user start airlock-devmon-heartbeat.timer \
        || log "WARN: kept dev-monitor heartbeat timer did not start"
    else
      log "WARN: kept dev-monitor candidate did not start; re-run the installer"
    fi
    "$ROOT/bin/airlock-ledger" transaction-keep-forward-candidate "$candidate_state" \
      || log "WARN: could not record the kept candidate's state"
  fi
  devmon_migration_start_saved unmanaged || return 1
  rm -f -- "$receipt" || return 1
  python3 - "$(dirname "$receipt")" <<'PY' || return 1
import os
import sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

# Forward-only: runs only for a committed transaction's deferral. The record is the
# app's durable smoke debt as well as its conversion debt, so it is cleared only after
# the smoke the pre-commit pass skipped has passed. A failure keeps it for the next run.
_airlock_devmon_activate_owed() {
  local mode="$1" state due rc=0 tx database writer port app pkg_dir
  state="$(devmon_migration_state_dir)"
  due="$(devmon_activation_due "$state")" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) log "dev-monitor activation record is unusable; it was preserved for inspection"; return 1 ;;
  esac
  IFS=$'\t' read -r tx database writer port app <<<"$due"
  if ! python3 -c '
import json, sys
try:
    store = json.load(open(sys.argv[1], encoding="utf-8"))
except OSError:
    raise SystemExit(1)
raise SystemExit(0 if (store.get("entries", {}).get(sys.argv[2]) or {}).get("committed") else 1)
' "$state/app-ledger.json" "$app"; then
    log "dropping the dev-monitor activation of transaction ${tx:0:12}: '$app' is no longer installed"
    devmon_activation_clear "$state" "$tx"
    return
  fi
  log "activating $app for committed transaction ${tx:0:12}: converting the messages database, then starting it"
  devmon_activation_run "$database" "$writer" "$port" || return 1
  pkg_dir="$(airlock_pkg_dir "$app")"
  log "smoke: $app (after activation, $mode)"
  (cd "$pkg_dir" && AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$pkg_dir" AIRLOCK_APP_ID="$app" \
    AIRLOCK_CONFIG_BIN="$_airlock_lifecycle_config_bin" \
    bash "$pkg_dir/smoke.sh" </dev/null) 9>&- \
    || { log "smoke FAILED: $app"; return 1; }
  devmon_activation_clear "$state" "$tx" || return 1
  log "$app activated"
}

# Restoring package bytes is not enough after a removed nginx fragment was loaded into
# the live process. The ledger keeps that publication debt non-terminal across crashes;
# only a successful config test + reload may close it as rolled_back.
_airlock_restore_transaction() {
  local restore_output="" restore_rc=0 nginx_owed=0
  restore_output="$("$ROOT/bin/airlock-ledger" transaction-restore 2>&1)" \
    || restore_rc=$?
  [ -z "$restore_output" ] || printf '%s\n' "$restore_output" >&2
  [ "$restore_rc" = 0 ] || return "$restore_rc"
  nginx_owed="$("$ROOT/bin/airlock-ledger" transaction-show \
    | python3 -c 'import json,sys; print(1 if json.load(sys.stdin).get("nginx_restore_owed") else 0)')" \
    || return 1
  if [ "$nginx_owed" = 1 ]; then
    log "republishing restored nginx fragments before declaring rollback complete"
    airlock_run sudo nginx -t || return 1
    airlock_run sudo systemctl reload nginx || return 1
    "$ROOT/bin/airlock-ledger" transaction-nginx-restore-published || return 1
  fi
}

_airlock_mark_nginx_restore_owed() {
  [ "${_airlock_transaction_active:-0}" = 1 ] || return 0
  "$ROOT/bin/airlock-ledger" transaction-nginx-restore-owed
}

# Transaction inspection is config-independent but recovery is never implicit.  A
# question may read the record; only one exact-id recovery invocation may mutate it.
# In particular, refuse an ordinary install before self-kill escape can create a
# transient unit on behalf of unrelated recovery debt.
_airlock_recovery_lock=0
_airlock_early_state_dir="$(devmon_migration_state_dir)"
if [ -e "$_airlock_early_state_dir/install-transaction.json" ] \
    || [ -L "$_airlock_early_state_dir/install-transaction.json" ]; then
  airlock_pin_state_dir
  _airlock_early_state_dir="${AIRLOCK_STATE_DIR:-$_airlock_early_state_dir}"
  _airlock_recovery_record="$("$ROOT/bin/airlock-ledger" transaction-show \
    | python3 -c '
import json, sys
d = json.load(sys.stdin)
a = d.get("trusted_measurer_activation")
authorities = d.get("managed_authorities") or {}
if a is not None:
    values = (a["state"], a["old_sha256"], a["new_sha256"])
elif authorities:
    old = {item["installed_measurer_sha256"] for item in authorities.values()}
    new = {item["next_measurer_sha256"] for item in authorities.values()}
    if len(old) != 1 or len(new) != 1:
        raise SystemExit("managed transaction has inconsistent measurer hashes")
    values = ("pending", next(iter(old)), next(iter(new)))
else:
    values = ("none", "-", "-")
print("\t".join((d["id"], d["phase"], *values)))
')" || die "cannot read existing install transaction"
  IFS=$'\t' read -r _airlock_recovery_id _airlock_recovery_phase \
    _airlock_recovery_activation _airlock_recovery_old_sha _airlock_recovery_new_sha \
    <<<"$_airlock_recovery_record"
  _airlock_recovery_required=0
  case "$_airlock_recovery_phase:$_airlock_recovery_activation" in
    prepared:*|installing:*|rolling_back:*|degraded:*|committed:owed)
      _airlock_recovery_required=1
      ;;
  esac
  if [ -z "$_airlock_recover_transaction" ] && [ "$_airlock_recovery_required" = 1 ] \
      && [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
    die "unfinished transaction blocks a new candidate
  transaction: $_airlock_recovery_id
  phase: $_airlock_recovery_phase${_airlock_recovery_activation:+/$_airlock_recovery_activation}
  checkpoint: $_airlock_early_state_dir/install-checkpoints/$_airlock_recovery_id
  recover: bash install/airlock-install.sh --recover-transaction=$_airlock_recovery_id"
  fi
  if [ -n "$_airlock_recover_transaction" ]; then
    [ "$_airlock_recover_transaction" = "$_airlock_recovery_id" ] \
      || die "requested recovery transaction $_airlock_recover_transaction does not match current transaction $_airlock_recovery_id"
    if [ "$_airlock_recovery_required" != 1 ]; then
      log "transaction $_airlock_recovery_id is already terminal ($_airlock_recovery_phase)"
      exit 0
    fi
    # Recovery may stop this session's host service. Escape only after argv and the
    # exact durable transaction id have been validated, then acquire the live-box
    # lease inside that detached unit so its keeper survives the host restart.
    airlock_escape_selfkill_cgroup "$0" "$@"
    airlock_enter_live_box_lease "recover:$_airlock_recovery_id" "$0" "$@"
    airlock_preflight_bootstrap
    require_cmd flock
  else
    # A dry run may inspect a candidate beside recovery debt, but never repairs it.
    [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] || log "dry run leaves unfinished transaction $_airlock_recovery_id ($_airlock_recovery_phase) unchanged"
  fi
fi

if [ -n "$_airlock_recover_transaction" ]; then
  [ -e "$_airlock_early_state_dir/install-transaction.json" ] \
    || die "requested recovery transaction $_airlock_recover_transaction does not exist"
  if [ -n "${AIRLOCK_LEDGER_LOCK_FD:-}" ]; then
    case "$AIRLOCK_LEDGER_LOCK_FD" in *[!0-9]*) die "inherited ledger lock fd must be numeric" ;; esac
    [ "$AIRLOCK_LEDGER_LOCK_FD" -ge 3 ] 2>/dev/null \
      && [ -f "/proc/self/fd/$AIRLOCK_LEDGER_LOCK_FD" ] \
      && [ "/proc/self/fd/$AIRLOCK_LEDGER_LOCK_FD" -ef "$_airlock_early_state_dir/app-ledger.lock" ] \
      || die "inherited ledger lock fd does not name $_airlock_early_state_dir/app-ledger.lock"
    flock -n "$AIRLOCK_LEDGER_LOCK_FD" || die "inherited ledger lock fd is unavailable"
    if [ "$AIRLOCK_LEDGER_LOCK_FD" != 9 ]; then
      eval "exec 9<&$AIRLOCK_LEDGER_LOCK_FD"
      eval "exec $AIRLOCK_LEDGER_LOCK_FD>&-"
    fi
  else
    exec 9>>"$_airlock_early_state_dir/app-ledger.lock"
    flock -n 9 || die "another airlock run holds the ledger lock ($_airlock_early_state_dir/app-ledger.lock) — recovery will not race it"
  fi
  AIRLOCK_LEDGER_LOCK_HELD=1
  export AIRLOCK_LEDGER_LOCK_HELD
  case "$_airlock_recovery_phase" in
    prepared|installing|rolling_back|degraded)
      log "explicitly recovering install transaction $_airlock_recovery_id"
      case "$_airlock_recovery_activation" in
        owed)
          _airlock_trusted_measurer_root rollback "$_airlock_recovery_id" \
            "$_airlock_recovery_old_sha" "$_airlock_recovery_new_sha" \
            || die "trusted measurer rollback remains degraded; no app restore was attempted"
          "$ROOT/bin/airlock-ledger" transaction-trusted-measurer-clear \
            || die "cannot clear restored trusted measurer activation"
          _airlock_trusted_measurer_root cleanup-old "$_airlock_recovery_id" \
            "$_airlock_recovery_old_sha" "$_airlock_recovery_new_sha" \
            || die "cannot remove verified trusted measurer staging evidence"
          ;;
        pending)
          _airlock_trusted_measurer_root cleanup-old "$_airlock_recovery_id" \
            "$_airlock_recovery_old_sha" "$_airlock_recovery_new_sha" \
            || die "cannot clean interrupted trusted measurer staging evidence"
          ;;
      esac
      if ! _airlock_devmon_compensate \
          "$_airlock_early_state_dir" "$_airlock_recovery_id"; then
        AIRLOCK_TRANSACTION_ERROR="dev-monitor database compensation failed during recovery" \
          "$ROOT/bin/airlock-ledger" transaction-fail recovery dev-monitor >/dev/null 2>&1 \
          || true
        die "database compensation remains degraded; incompatible old writers were not restarted"
      fi
      _airlock_restore_transaction \
        || die "transaction recovery remains degraded; inspect bin/airlock-status before retrying"
      ;;
    committed)
      case "$_airlock_recovery_activation" in
        owed)
          log "finishing committed trusted measurer activation before a new candidate"
          _airlock_trusted_measurer_root forward "$_airlock_recovery_id" \
            "$_airlock_recovery_old_sha" "$_airlock_recovery_new_sha" \
            || die "apps are committed but trusted measurer activation durability is unverified"
          "$ROOT/bin/airlock-ledger" transaction-trusted-measurer-durable \
            || die "cannot record durable trusted measurer activation"
          _airlock_trusted_measurer_root cleanup "$_airlock_recovery_id" \
            "$_airlock_recovery_old_sha" "$_airlock_recovery_new_sha" \
            || die "cannot clean durable trusted measurer activation evidence"
          ;;
        durable)
          _airlock_trusted_measurer_root cleanup "$_airlock_recovery_id" \
            "$_airlock_recovery_old_sha" "$_airlock_recovery_new_sha" \
            || die "cannot clean durable trusted measurer activation evidence"
          ;;
      esac
      ;;
  esac
  log "explicit recovery finished for transaction $_airlock_recovery_id"
  exit 0
fi

# Before a normal mutating install can stop anything: if this run is hosted by one
# of the units it may restart, move it out of that cgroup so it survives teardown.
# Help, invalid argv, dry-run, and recovery-debt refusal have already returned.
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  # The transient unit is admission transport, not the mutator. Acquire the lease
  # after detaching so its keeper and fd survive any app service restarted below.
  airlock_escape_selfkill_cgroup "$0" "$@"
  airlock_enter_live_box_lease "install" "$0" "$@"
fi

# The exceptional path is one exact, package-scoped argv value.  Do not add an
# environment alias: an exported value would silently remain active for later
# runs. Lifecycle argv remains empty; a private temporary config wrapper gives
# only this process tree the same package-scoped decision.
_airlock_lifecycle_config_bin="$AIRLOCK_CONFIG_BIN"
_airlock_config_wrapper=""
_airlock_config_snapshot=""
_airlock_prereq_receipt=""
_airlock_ledger_plan_file=""
_airlock_ledger_dependencies_file=""
_airlock_scoped_plan_file=""
_airlock_candidate_webjson_file=""
_airlock_managed_context_file=""
_airlock_managed_authority_file=""
_airlock_managed_authority_sha256=""
_airlock_managed_next_measurer=""
_airlock_managed_installed_measurer_sha256=""
_airlock_managed_next_measurer_sha256=""
_airlock_dry_preview_root=""
_airlock_managed_mode=0
_airlock_transaction_active=0
_airlock_transaction_id=""
_airlock_failure_phase="pre-mutation"
_airlock_failure_app="-"
_airlock_removed_after_first_reload=0
if [ -n "$_airlock_update_channel_handoff" ] \
    || [ -n "$_airlock_update_channel_handoff_sha256" ]; then
  _airlock_managed_mode=1
fi

_airlock_cleanup_config_wrapper() {
  local _exit_rc=$? _db_restore_rc=0 _trusted_restore_rc=0 _fail_rc=0 _restore_rc=0
  local _result="degraded" _trusted_state="none"
  trap - EXIT INT TERM HUP
  if [ "${_airlock_transaction_active:-0}" = 1 ]; then
    [ "$_exit_rc" != 0 ] || _exit_rc=1
    if [ "${_airlock_managed_mode:-0}" = 1 ]; then
      _trusted_state="$("$ROOT/bin/airlock-ledger" transaction-show \
        | python3 -c 'import json,sys; print((json.load(sys.stdin).get("trusted_measurer_activation") or {}).get("state", "pending"))')" \
        || _trusted_restore_rc=$?
      if [ "$_trusted_restore_rc" = 0 ]; then
        case "$_trusted_state" in
          owed)
            _airlock_trusted_measurer_root rollback "$_airlock_transaction_id" \
              "$_airlock_managed_installed_measurer_sha256" \
              "$_airlock_managed_next_measurer_sha256" \
              && "$ROOT/bin/airlock-ledger" transaction-trusted-measurer-clear \
              && _airlock_trusted_measurer_root cleanup-old "$_airlock_transaction_id" \
                "$_airlock_managed_installed_measurer_sha256" \
                "$_airlock_managed_next_measurer_sha256" \
              || _trusted_restore_rc=$?
            ;;
          pending)
            _airlock_trusted_measurer_root cleanup-old "$_airlock_transaction_id" \
              "$_airlock_managed_installed_measurer_sha256" \
              "$_airlock_managed_next_measurer_sha256" \
              || _trusted_restore_rc=$?
            ;;
          *) _trusted_restore_rc=1 ;;
        esac
      fi
    fi
    _airlock_devmon_compensate \
      "$(devmon_migration_state_dir)" \
      "${_airlock_transaction_id:-}" || _db_restore_rc=$?
    AIRLOCK_TRANSACTION_ERROR="installer exited rc=$_exit_rc" \
      "$ROOT/bin/airlock-ledger" transaction-fail \
        "${_airlock_failure_phase:-unknown}" "${_airlock_failure_app:--}" \
        >/dev/null 2>&1 || _fail_rc=$?
    if [ "$_db_restore_rc" = 0 ] && [ "$_trusted_restore_rc" = 0 ] \
        && [ "$_fail_rc" = 0 ]; then
      _airlock_restore_transaction || _restore_rc=$?
      [ "$_restore_rc" != 0 ] || _result="rolled_back"
    elif [ "$_fail_rc" != 0 ]; then
      log "WARN: failed to persist the install transaction failure"
    fi
    log "FATAL: transaction=${_airlock_transaction_id:-unknown} phase=${_airlock_failure_phase:-unknown} app=${_airlock_failure_app:--} result=$_result; inspect: bin/airlock-status"
  fi
  [ -z "$_airlock_config_wrapper" ] || rm -f -- "$_airlock_config_wrapper"
  [ -z "$_airlock_config_snapshot" ] || rm -f -- "$_airlock_config_snapshot"
  [ -z "$_airlock_prereq_receipt" ] || rm -f -- "$_airlock_prereq_receipt"
  [ -z "$_airlock_ledger_plan_file" ] || rm -f -- "$_airlock_ledger_plan_file"
  [ -z "$_airlock_ledger_dependencies_file" ] || rm -f -- "$_airlock_ledger_dependencies_file"
  [ -z "$_airlock_scoped_plan_file" ] || rm -f -- "$_airlock_scoped_plan_file"
  [ -z "$_airlock_candidate_webjson_file" ] || rm -f -- "$_airlock_candidate_webjson_file"
  [ -z "$_airlock_managed_context_file" ] || rm -f -- "$_airlock_managed_context_file"
  [ -z "$_airlock_managed_authority_file" ] || rm -f -- "$_airlock_managed_authority_file"
  [ -z "$_airlock_dry_preview_root" ] || rm -rf -- "$_airlock_dry_preview_root"
  exit "$_exit_rc"
}
trap _airlock_cleanup_config_wrapper EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [ "${#_airlock_lifecycle_args[@]}" -eq 1 ]; then
  _airlock_config_wrapper="$(mktemp)" || die "cannot create break-glass config wrapper"
  python3 - "$_airlock_config_wrapper" "$AIRLOCK_CONFIG_BIN" \
    "${_airlock_lifecycle_args[0]}" <<'PY' \
    || die "cannot write break-glass config wrapper"
from pathlib import Path
import sys

path, config_bin, argument = sys.argv[1:]
source = """import os
import sys
os.execv(sys.executable, [sys.executable, %r, %r, *sys.argv[1:]])
""" % (config_bin, argument)
Path(path).write_text(source, encoding="utf-8")
PY
  chmod 0600 "$_airlock_config_wrapper" || die "cannot protect break-glass config wrapper"
  _airlock_lifecycle_config_bin="$_airlock_config_wrapper"
  # From this point every orchestrator config read, not only lifecycle reads,
  # goes through the one-run wrapper. install/lib.sh itself does not interpret
  # lifecycle argv, so running a package script with the public flag cannot
  # create an unaudited admission path.
  AIRLOCK_CONFIG_BIN="$_airlock_config_wrapper"
fi
airlock_preflight_bootstrap

# Freeze the operator file before choosing the ledger-lock predicate. A managed
# producer has already frozen it while holding the state lease, so the paired
# handoff authenticates those exact bytes instead of opening mutable config a
# second time. The ordinary path retains the existing install-snapshot ABI.
if [ "$_airlock_managed_mode" = 1 ]; then
  _airlock_managed_context_file="$(mktemp)" \
    || die "cannot create managed installer context"
  chmod 0600 "$_airlock_managed_context_file" \
    || die "cannot protect managed installer context"
  python3 - "$_airlock_update_channel_handoff" \
      "$_airlock_update_channel_handoff_sha256" \
      "${_airlock_selected_apps[@]}" >"$_airlock_managed_context_file" <<'PY' \
    || die "managed update handoff authentication failed before candidate validation"
import hashlib
import json
import os
import pathlib
import re
import stat
import sys

handoff_raw_path, handoff_sha, *selected = sys.argv[1:]
sha = re.compile(r"[0-9a-f]{64}\Z")
sha40 = re.compile(r"[0-9a-f]{40}\Z")
digest = re.compile(r"sha256:[0-9a-f]{64}\Z")
appid = re.compile(r"[a-z0-9][a-z0-9-]{0,31}\Z")

def fail(message):
    print(f"managed installer handoff: {message}", file=sys.stderr)
    raise SystemExit(2)

def pairs(rows):
    value = {}
    for key, item in rows:
        if key in value:
            fail(f"duplicate JSON key {key!r}")
        value[key] = item
    return value

def canonical(value):
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n").encode()

def load_json(path, label):
    try:
        raw = path.read_bytes()
        value = json.loads(raw, object_pairs_hook=pairs)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"cannot read {label}: {exc}")
    if canonical(value) != raw:
        fail(f"{label} is not canonical JSON")
    return value, raw

def raw_hash(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()

if not sha.fullmatch(handoff_sha):
    fail("handoff SHA-256 is not lowercase 64-hex")
handoff_path = pathlib.Path(handoff_raw_path)
if not handoff_path.is_absolute() or os.path.normpath(handoff_raw_path) != handoff_raw_path:
    fail("handoff path must be normalized and absolute")
handoff, handoff_raw = load_json(handoff_path, "handoff")
if hashlib.sha256(handoff_raw).hexdigest() != handoff_sha:
    fail("handoff bytes differ from the supplied SHA-256")
handoff_keys = {
    "actor", "anchor_path", "anchor_sha256", "config_path", "config_sha256",
    "core_measurement_path", "core_measurement_sha256", "current_release_path",
    "current_release_sha256", "fetched_public_revision", "installed_measurer_sha256",
    "next_measurer_path", "next_measurer_sha256", "receipt_path", "receipt_sha256",
    "schema", "selected_apps",
}
if (set(handoff) != handoff_keys
        or handoff.get("schema") != "airlock.update-channel.install-handoff/v1"
        or handoff.get("actor") != "update-channel"):
    fail("handoff has an unsupported closed shape")
for key in ("anchor_sha256", "config_sha256", "core_measurement_sha256",
            "current_release_sha256", "installed_measurer_sha256",
            "next_measurer_sha256", "receipt_sha256"):
    if not isinstance(handoff.get(key), str) or not sha.fullmatch(handoff[key]):
        fail(f"handoff {key} is not lowercase 64-hex")
if not isinstance(handoff.get("fetched_public_revision"), str) \
        or not sha40.fullmatch(handoff["fetched_public_revision"]):
    fail("handoff fetched public revision is not a full lowercase SHA")
if (len(selected) != len(set(selected)) or any(not appid.fullmatch(item) for item in selected)
        or handoff.get("selected_apps") != sorted(selected)):
    fail("handoff selected apps differ from the unique installer selection")

scratch = handoff_path.parent
scratch_info = scratch.lstat()
if (not stat.S_ISDIR(scratch_info.st_mode) or scratch.is_symlink()
        or scratch.resolve(strict=True) != scratch
        or (scratch_info.st_uid, scratch_info.st_gid, stat.S_IMODE(scratch_info.st_mode))
            != (os.geteuid(), os.getegid(), 0o700)):
    fail("handoff parent is not the invoking user's private real directory")
payloads = {
    "config": pathlib.Path(handoff["config_path"]),
    "measurement": pathlib.Path(handoff["core_measurement_path"]),
    "current": pathlib.Path(handoff["current_release_path"]),
    "next": pathlib.Path(handoff["next_measurer_path"]),
    "receipt": pathlib.Path(handoff["receipt_path"]),
    "handoff": handoff_path,
}
for label, path in payloads.items():
    if (not path.is_absolute() or os.path.normpath(os.fspath(path)) != os.fspath(path)
            or any(char in os.fspath(path) for char in "\n\r\t") or path.parent != scratch):
        fail(f"{label} escaped the one private handoff directory")
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or path.is_symlink()
            or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode))
                != (os.geteuid(), os.getegid(), 0o600)):
        fail(f"{label} is not a private invoking-user regular file")

anchor_path = pathlib.Path(handoff["anchor_path"])
if anchor_path != pathlib.Path("/etc/airlock/managed-channel.json"):
    fail("handoff cannot choose an enrollment anchor")
for parent in (pathlib.Path("/"), pathlib.Path("/etc"), pathlib.Path("/etc/airlock")):
    info = parent.lstat()
    if (not stat.S_ISDIR(info.st_mode) or parent.is_symlink()
            or info.st_uid != 0 or info.st_gid != 0 or stat.S_IMODE(info.st_mode) & 0o022):
        fail(f"root anchor parent is not protected: {parent}")
fd = os.open(anchor_path, os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0))
with os.fdopen(fd, "rb") as handle:
    info = os.fstat(handle.fileno())
    anchor_raw = handle.read()
if (not stat.S_ISREG(info.st_mode)
        or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (0, 0, 0o644)
        or hashlib.sha256(anchor_raw).hexdigest() != handoff["anchor_sha256"]):
    fail("root anchor owner, mode, type or digest changed")
try:
    anchor = json.loads(anchor_raw, object_pairs_hook=pairs)
except (UnicodeError, json.JSONDecodeError) as exc:
    fail(f"root anchor is invalid JSON: {exc}")
if canonical(anchor) != anchor_raw:
    fail("root anchor is not canonical JSON")
anchor_keys = {"authority_path", "channel_id", "enrollment_digest", "organization_id",
               "root_key_id", "schema", "state_path", "store_path", "writer_gid", "writer_uid"}
if (set(anchor) != anchor_keys or anchor.get("schema") != "airlock.managed.install-anchor/v1"
        or (anchor.get("writer_uid"), anchor.get("writer_gid")) != (os.geteuid(), os.getegid())):
    fail("root anchor has an unsupported identity or closed shape")
managed_root = pathlib.Path(f"/var/lib/airlock/managed/{os.geteuid()}")
expected_anchor_paths = {
    "authority_path": os.fspath(managed_root / "authority"),
    "state_path": os.fspath(managed_root / "managed-state.json"),
    "store_path": os.fspath(managed_root / "store"),
}
if any(anchor.get(key) != value for key, value in expected_anchor_paths.items()):
    fail("root anchor paths are not the fixed writer namespace")
if (not isinstance(anchor.get("enrollment_digest"), str) or not digest.fullmatch(anchor["enrollment_digest"])
        or not isinstance(anchor.get("root_key_id"), str) or not digest.fullmatch(anchor["root_key_id"])):
    fail("root anchor digests are invalid")

measurement, measurement_raw = load_json(payloads["measurement"], "core measurement")
current, current_raw = load_json(payloads["current"], "current release")
receipt, receipt_raw = load_json(payloads["receipt"], "config receipt")
if raw_hash(payloads["config"]) != handoff["config_sha256"]:
    fail("frozen config differs from the handoff")
if hashlib.sha256(measurement_raw).hexdigest() != handoff["core_measurement_sha256"]:
    fail("core measurement differs from the handoff")
if hashlib.sha256(current_raw).hexdigest() != handoff["current_release_sha256"]:
    fail("current release differs from the handoff")
if hashlib.sha256(receipt_raw).hexdigest() != handoff["receipt_sha256"]:
    fail("config receipt differs from the handoff")
if raw_hash(payloads["next"]) != handoff["next_measurer_sha256"]:
    fail("next trusted measurer differs from the handoff")
target = pathlib.Path("/opt/airlock/libexec/airlock-managed-release")
target_info = target.lstat()
if (not stat.S_ISREG(target_info.st_mode) or target.is_symlink()
        or (target_info.st_uid, target_info.st_gid, stat.S_IMODE(target_info.st_mode)) != (0, 0, 0o555)
        or raw_hash(target) != handoff["installed_measurer_sha256"]):
    fail("installed trusted measurer differs from the frozen root anchor input")

measurement_keys = {"digest", "public_revision", "public_tree", "schema", "source_revision"}
current_keys = {"authority_membership_digest", "authority_sequence", "bundle_digest",
                "catalog_digest", "channel_id", "core_digest", "core_revision", "epoch",
                "lock_digest", "organization_id", "promotion_membership_digest",
                "promotion_receipt_digest", "promotion_receipt_path", "publisher_id",
                "publisher_key_id", "receipt_id", "release_path", "requested_capabilities",
                "root_key_id", "schema", "sequence", "snapshot_digest", "target_profile",
                "verified_at"}
receipt_keys = {"authority_membership_digest", "authority_path", "authority_sequence",
                "catalog_digest", "channel_id", "config_digest", "config_origin", "config_path",
                "config_sha256", "epoch", "local_config_digest", "lock_digest",
                "managed_packages", "organization_id", "projection_digest", "release_mode",
                "release_path", "root_key_id", "schema", "selection_digest",
                "selection_sequence", "sequence", "snapshot_digest", "state_digest",
                "state_path", "target_profile", "verified_at", "verified_state"}
if set(measurement) != measurement_keys or measurement.get("schema") != "airlock.core-public-measurement/v1":
    fail("core measurement has an unsupported closed shape")
if set(current) != current_keys or current.get("schema") != "airlock.managed.current-release/v1":
    fail("current release has an unsupported closed shape")
if set(receipt) != receipt_keys or receipt.get("schema") != "airlock.managed.config-receipt/v1":
    fail("config receipt has an unsupported closed shape")
if (measurement.get("source_revision") != current.get("core_revision")
        or measurement.get("public_revision") != handoff["fetched_public_revision"]
        or measurement.get("digest") != current.get("core_digest")):
    fail("private revision, public revision and core digest bindings disagree")
for key in ("authority_membership_digest", "authority_sequence", "catalog_digest", "channel_id",
            "epoch", "lock_digest", "organization_id", "release_path", "root_key_id", "sequence",
            "snapshot_digest", "target_profile", "verified_at"):
    if receipt.get(key) != current.get(key):
        fail(f"config receipt differs from current release at {key}")
if (receipt.get("authority_path") != anchor["authority_path"]
        or receipt.get("state_path") != anchor["state_path"]
        or receipt.get("config_path") != handoff["config_path"]
        or receipt.get("config_sha256") != handoff["config_sha256"]
        or receipt.get("config_digest") != "sha256:" + handoff["config_sha256"]
        or receipt.get("release_mode") != "promoted-current"):
    fail("config receipt paths or effective config binding disagree")
if (not isinstance(receipt.get("release_path"), str)
        or not os.path.isabs(receipt["release_path"])
        or any(char in receipt["release_path"] for char in "\n\r\t")):
    fail("config receipt release path is not a safe absolute path")
verified = receipt.get("verified_state")
if (not isinstance(verified, dict)
        or verified.get("organization_id") != anchor.get("organization_id")
        or verified.get("root_key_id") != anchor.get("root_key_id")
        or verified.get("enrollment_digest") != anchor.get("enrollment_digest")):
    fail("config receipt state is not enrolled by the fixed root anchor")
if (current.get("organization_id") != anchor.get("organization_id")
        or current.get("channel_id") != anchor.get("channel_id")
        or current.get("root_key_id") != anchor.get("root_key_id")):
    fail("current release identity differs from the fixed root anchor")
rows = receipt.get("managed_packages")
if not isinstance(rows, list) or not rows:
    fail("config receipt contains no managed packages")
by_id = {}
for row in rows:
    if (not isinstance(row, dict) or set(row) != {"capabilities", "id", "package_digest",
            "path", "policy", "source_class"} or row.get("source_class") != "managed"
            or not isinstance(row.get("id"), str) or not appid.fullmatch(row["id"])
            or not isinstance(row.get("package_digest"), str) or not digest.fullmatch(row["package_digest"])):
        fail("config receipt managed package row is invalid")
    by_id[row["id"]] = row
if list(by_id) != sorted(by_id) or list(by_id) != handoff["selected_apps"]:
    fail("config receipt managed packages differ from selected apps")
config_origin = receipt.get("config_origin")
if (not isinstance(config_origin, str) or not os.path.isabs(config_origin)
        or "\n" in config_origin or "\r" in config_origin or "\t" in config_origin):
    fail("config receipt origin is not a safe absolute path")
base = {
    "anchor_sha256": handoff["anchor_sha256"],
    "authority_membership_digest": current["authority_membership_digest"],
    "authority_sequence": current["authority_sequence"],
    "channel_id": current["channel_id"],
    "config_sha256": handoff["config_sha256"],
    "core_digest": current["core_digest"],
    "core_revision": current["core_revision"],
    "enrollment_digest": anchor["enrollment_digest"],
    "epoch": current["epoch"],
    "fetched_public_revision": handoff["fetched_public_revision"],
    "installed_measurer_sha256": handoff["installed_measurer_sha256"],
    "lock_digest": current["lock_digest"],
    "next_measurer_sha256": handoff["next_measurer_sha256"],
    "organization_id": current["organization_id"],
    "promotion_receipt_digest": current["promotion_receipt_digest"],
    "public_tree": measurement["public_tree"],
    "publisher_key_id": current["publisher_key_id"],
    "receipt_sha256": handoff["receipt_sha256"],
    "root_key_id": current["root_key_id"],
    "schema": "airlock.managed.intent-authority/v1",
    "selection_digest": receipt["selection_digest"],
    "selection_sequence": receipt["selection_sequence"],
    "sequence": current["sequence"],
    "snapshot_digest": current["snapshot_digest"],
    "state_digest": receipt["state_digest"],
    "target_profile": current["target_profile"],
}
consumer = {
    "authority_path": anchor["authority_path"],
    "config_origin": config_origin,
    "config_path": handoff["config_path"],
    "config_sha256": handoff["config_sha256"],
    "installed_measurer_sha256": handoff["installed_measurer_sha256"],
    "next_measurer_path": handoff["next_measurer_path"],
    "next_measurer_sha256": handoff["next_measurer_sha256"],
    "receipt_path": handoff["receipt_path"],
    "receipt_sha256": handoff["receipt_sha256"],
    "release_path": receipt["release_path"],
    "state_path": anchor["state_path"],
}
context = {"authority_base": base, "consumer": consumer, "managed_packages": by_id,
           "schema": "airlock.managed.installer-context/v1", "scratch": os.fspath(scratch)}
sys.stdout.buffer.write(canonical(context))
PY
  mapfile -t _airlock_managed_values < <(python3 - \
      "$_airlock_managed_context_file" <<'PY'
import json, sys
context = json.load(open(sys.argv[1], encoding="utf-8"))
consumer = context["consumer"]
for value in (consumer["config_path"], consumer["config_sha256"], consumer["config_origin"],
              consumer["receipt_path"], consumer["receipt_sha256"], consumer["state_path"],
              consumer["release_path"], consumer["authority_path"], consumer["next_measurer_path"],
              consumer["installed_measurer_sha256"], consumer["next_measurer_sha256"],
              context["scratch"]):
    print(value)
PY
  ) || die "cannot read authenticated managed installer context"
  [ "${#_airlock_managed_values[@]}" = 12 ] \
    || die "authenticated managed installer context is incomplete"
  _airlock_config_snapshot="${_airlock_managed_values[0]}"
  _snapshot_digest="${_airlock_managed_values[1]}"
  AIRLOCK_CONFIG="${_airlock_managed_values[2]}"
  AIRLOCK_MANAGED_CONFIG_RECEIPT="${_airlock_managed_values[3]}"
  AIRLOCK_MANAGED_CONFIG_RECEIPT_SHA256="${_airlock_managed_values[4]}"
  AIRLOCK_MANAGED_STATE="${_airlock_managed_values[5]}"
  AIRLOCK_MANAGED_RELEASE="${_airlock_managed_values[6]}"
  AIRLOCK_MANAGED_AUTHORITY="${_airlock_managed_values[7]}"
  _airlock_managed_next_measurer="${_airlock_managed_values[8]}"
  _airlock_managed_installed_measurer_sha256="${_airlock_managed_values[9]}"
  _airlock_managed_next_measurer_sha256="${_airlock_managed_values[10]}"
  _airlock_managed_scratch="${_airlock_managed_values[11]}"
  AIRLOCK_CONFIG_SNAPSHOT="$_airlock_config_snapshot"
  AIRLOCK_CONFIG_SNAPSHOT_SHA256="$_snapshot_digest"
  export AIRLOCK_CONFIG AIRLOCK_CONFIG_SNAPSHOT AIRLOCK_CONFIG_SNAPSHOT_SHA256 \
    AIRLOCK_MANAGED_CONFIG_RECEIPT AIRLOCK_MANAGED_CONFIG_RECEIPT_SHA256 \
    AIRLOCK_MANAGED_STATE AIRLOCK_MANAGED_RELEASE AIRLOCK_MANAGED_AUTHORITY
else
  _airlock_config_snapshot="$(mktemp)" || die "cannot create install config snapshot"
  _snapshot_receipt="$(airlock_config install-snapshot "$_airlock_config_snapshot")" || exit 2
  _snapshot_digest="$(printf '%s' "$_snapshot_receipt" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')" \
    || die "cannot read install config snapshot digest"
  AIRLOCK_CONFIG="$(printf '%s' "$_snapshot_receipt" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["config_path"])')" \
    || die "cannot read install config snapshot origin"
  [[ "$_snapshot_digest" =~ ^[0-9a-f]{64}$ ]] \
    || die "install config snapshot returned an invalid digest"
  AIRLOCK_CONFIG_SNAPSHOT="$_airlock_config_snapshot"
  AIRLOCK_CONFIG_SNAPSHOT_SHA256="$_snapshot_digest"
  export AIRLOCK_CONFIG AIRLOCK_CONFIG_SNAPSHOT AIRLOCK_CONFIG_SNAPSHOT_SHA256
fi

# Packaged apps (docs/design/app-package-contract.md). One read-only probe up
# front answers three things: the resolved config path (exported so app scripts
# resolve the SAME config from any cwd — a packaged app's cwd is its package
# dir, from which the upward search would find nothing), the packaged-app set,
# and whether this run touches the installed-state ledger at all.
AIRLOCK_PKG_INFO="$(airlock_config package-info "${_airlock_package_info_args[@]}")" || exit 2
export AIRLOCK_PKG_INFO
_pkg_info_digest="$(printf '%s' "$AIRLOCK_PKG_INFO" \
  | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" \
  || die "cannot hash package-info for prerequisite receipt"
if [ "$_airlock_managed_mode" = 1 ]; then
  _airlock_managed_authority_file="$(mktemp "$_airlock_managed_scratch/managed-authorities.XXXXXX")" \
    || die "cannot create managed transaction authority sidecar"
  chmod 0600 "$_airlock_managed_authority_file" \
    || die "cannot protect managed transaction authority sidecar"
  python3 - "$_airlock_managed_context_file" \
      "$_airlock_managed_authority_file" <<'PY' \
    || die "managed package-info differs from its authenticated producer tuple"
import copy
import json
import os
import pathlib
import stat
import sys

context_path, output_raw = sys.argv[1:]
context = json.load(open(context_path, encoding="utf-8"))
package_info = json.loads(os.environ["AIRLOCK_PKG_INFO"])
rows = context["managed_packages"]
packages = package_info.get("packages")
managed_ids = ({app_id for app_id, package in packages.items()
                if isinstance(package, dict) and package.get("source_class") == "managed"}
               if isinstance(packages, dict) else set())
if not isinstance(packages, dict) or managed_ids != set(rows):
    raise SystemExit("managed package-info ids differ from the closed receipt selection")
authorities = {}
for app_id in sorted(rows):
    package = packages[app_id]
    row = rows[app_id]
    capabilities = package.get("capabilities")
    if (package.get("source_class") != "managed"
            or package.get("signed_package_digest") != row.get("package_digest")
            or not isinstance(capabilities, list)
            or capabilities != sorted(set(capabilities))
            or not set(capabilities).issubset({"rooted-artifact", "system-unit"})
            or not set(capabilities).issubset(set(row.get("capabilities") or []))
            or os.path.realpath(package.get("dir", "")) != os.path.realpath(row.get("path", ""))):
        raise SystemExit(f"managed package {app_id} lost its signed path/digest/capability binding")
    authority = copy.deepcopy(context["authority_base"])
    authority["capabilities"] = capabilities
    authority["package_digest"] = row["package_digest"]
    authorities[app_id] = authority
value = {"authorities": authorities, "schema": "airlock.managed.run-authorities/v1"}
raw = (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode()
output = pathlib.Path(output_raw)
info = output.lstat()
parent = output.parent.lstat()
if (not stat.S_ISREG(info.st_mode) or output.is_symlink()
        or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode))
            != (os.geteuid(), os.getegid(), 0o600)
        or not stat.S_ISDIR(parent.st_mode) or output.parent.is_symlink()
        or (parent.st_uid, parent.st_gid, stat.S_IMODE(parent.st_mode))
            != (os.geteuid(), os.getegid(), 0o700)):
    raise SystemExit("managed authority sidecar is outside the private run directory")
with output.open("wb") as handle:
    handle.write(raw)
    handle.flush()
    os.fsync(handle.fileno())
PY
  _airlock_managed_authority_sha256="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$_airlock_managed_authority_file")" \
    || die "cannot hash managed transaction authority sidecar"
fi
AIRLOCK_PREREQ_CONTEXT="config=${AIRLOCK_CONFIG_SNAPSHOT_SHA256} package=${_pkg_info_digest}"
_airlock_prereq_receipt="$(mktemp)" || die "cannot create prerequisite receipt"
AIRLOCK_PREREQ_RECEIPT="$_airlock_prereq_receipt"
export AIRLOCK_PREREQ_CONTEXT AIRLOCK_PREREQ_RECEIPT
AIRLOCK_CONFIG="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin)["config_path"])')"
export AIRLOCK_CONFIG AIRLOCK_ROOT
_pkg_ids="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c 'import sys,json; print("\n".join(sorted(json.load(sys.stdin)["packages"])))')"
_app_ids="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c 'import sys,json; print("\n".join(json.load(sys.stdin)["order"]))')"
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ "${#_airlock_lifecycle_args[@]}" -eq 1 ]; then
  log "[dry] DANGEROUS: would admit unverified package lock mismatch: ${_airlock_lifecycle_args[0]} (no audit or lock state will be written)"
fi
_state_dir="${AIRLOCK_STATE_DIR:-$HOME/.local/state/airlock}"
LEDGER_FILE="$_state_dir/app-ledger.json"
RETIREMENT_FILE="$_state_dir/plaintext-retirement.json"
TRANSACTION_FILE="$_state_dir/install-transaction.json"
# F15 amendment (child 4/P4): the gate must also open for a box that has NO
# configured packages and NO ledger file yet, but DOES have a known builtin
# on disk (apps/<id>/airlock-app.toml, hub/core and shadowed ids excluded) —
# the box that used to escape the gate entirely (hub-only, install/airlock-
# install.sh's old predicate) is exactly the one the F15 adoption sweep
# exists to reach. `known-builtins` itself needs no lock (read-only).
_known_builtins="$(airlock_config known-builtins)" || exit 2

# One writer (D6/F9c): the exclusive span covers validate -> mutate -> commit —
# a lock taken after validate would let a concurrent run's journal write
# invalidate a finished disjointness check. Only runs that can touch the ledger
# or plaintext-retirement record lock. A box with none of those records, no
# packages, and no known builtin never creates the state dir; a dry run locks
# nothing because it mutates nothing.
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] \
  && { [ -n "$_pkg_ids" ] || [ -e "$LEDGER_FILE" ] || [ -L "$LEDGER_FILE" ] \
    || [ -e "$RETIREMENT_FILE" ] || [ -L "$RETIREMENT_FILE" ] \
    || [ -e "$TRANSACTION_FILE" ] || [ -L "$TRANSACTION_FILE" ] \
    || [ -n "$_known_builtins" ]; }; then
  require_cmd flock
  # `install -d -m` sets the mode on an EXISTING directory too, and that turned a
  # default into an enforcement nobody declared. dev-monitor's spool is written by a
  # second uid, so that uid has to TRAVERSE this directory
  # (apps/dev-monitor/install-spool-hardening.sh checks exactly that) — and 0700 forbids
  # it. Re-asserting the mode here meant the check could never pass: widen it and the
  # next run closes it again.
  #
  # Measured 2026-08-22 on a box updating to this revision: the install died at
  # dev-monitor four times, and setting the directory to 710 by hand did not survive a
  # single re-run.
  #
  # 0700 is still what a directory created HERE gets. What changed is that it is a
  # default rather than a reassertion — an existing directory keeps the mode its owner,
  # or an app that declared why, gave it.
  [ -d "$_state_dir" ] || install -d -m 0700 "$_state_dir"
  airlock_pin_state_dir
  _state_dir="${AIRLOCK_STATE_DIR:-$_state_dir}"
  LEDGER_FILE="$_state_dir/app-ledger.json"
  RETIREMENT_FILE="$_state_dir/plaintext-retirement.json"
  TRANSACTION_FILE="$_state_dir/install-transaction.json"
  if [ "$_airlock_recovery_lock" = 1 ]; then
    AIRLOCK_LEDGER_LOCK_FD=9
  fi
  if [ -n "${AIRLOCK_LEDGER_LOCK_FD:-}" ]; then
    case "$AIRLOCK_LEDGER_LOCK_FD" in
      *[!0-9]*) die "inherited ledger lock fd must be an open descriptor >= 3" ;;
    esac
    [ "$AIRLOCK_LEDGER_LOCK_FD" -ge 3 ] 2>/dev/null \
      || die "inherited ledger lock fd must be an open descriptor >= 3"
    [ -f "/proc/self/fd/$AIRLOCK_LEDGER_LOCK_FD" ] \
      && [ "/proc/self/fd/$AIRLOCK_LEDGER_LOCK_FD" -ef "$_state_dir/app-ledger.lock" ] \
      || die "inherited ledger lock fd does not name $_state_dir/app-ledger.lock"
    flock -n "$AIRLOCK_LEDGER_LOCK_FD" \
      || die "inherited ledger lock fd is not available ($_state_dir/app-ledger.lock)"
    if [ "$AIRLOCK_LEDGER_LOCK_FD" != 9 ]; then
      eval "exec 9<&$AIRLOCK_LEDGER_LOCK_FD"
      eval "exec $AIRLOCK_LEDGER_LOCK_FD>&-"
    fi
  else
    exec 9>>"$_state_dir/app-ledger.lock"
    flock -n 9 || die "another airlock run holds the ledger lock ($_state_dir/app-ledger.lock) — one writer at a time; re-run when it finishes"
  fi
  unset AIRLOCK_LEDGER_LOCK_FD
  # Sidecar mutation commands are also directly dispatchable. Tell them this
  # process already owns the shared writer lock so they neither deadlock nor
  # admit a concurrent manual recovery mutation into this run.
  AIRLOCK_LEDGER_LOCK_HELD=1
  export AIRLOCK_LEDGER_LOCK_HELD
  # Re-read the immutable snapshot under the lock. This is intentionally the
  # same candidate as the gate probe, not a second read of a mutable operator
  # file: gate, plan/remove and app install must never observe A/B configs.
  AIRLOCK_PKG_INFO="$(airlock_config package-info "${_airlock_package_info_args[@]}")" || exit 2
  export AIRLOCK_PKG_INFO
  _pkg_ids="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c 'import sys,json; print("\n".join(sorted(json.load(sys.stdin)["packages"])))')"
  _app_ids="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c 'import sys,json; print("\n".join(json.load(sys.stdin)["order"]))')"
  if [ "${#_airlock_lifecycle_args[@]}" -eq 1 ]; then
    _breakglass_id="${_airlock_lifecycle_args[0]#*=}"
    _breakglass_receipt="$(printf '%s' "$AIRLOCK_PKG_INFO" \
      | "$ROOT/bin/airlock-ledger" audit-lock-override "$_breakglass_id")" \
      || die "failed to record break-glass admission before package mutation"
    [[ "$_breakglass_receipt" =~ ^[0-9a-f]{64}$ ]] \
      || die "break-glass audit returned an invalid current-run receipt"
  fi
  _ledger_gate=1
else
  # Decided ONCE, with the lock: a run that chose not to lock must never
  # touch the ledger later, even if a concurrent run creates the file
  # between this decision and reconcile (one writer, D6/F9c).
  _ledger_gate=0
fi

log "validating airlock.toml"
airlock_config validate || exit 2
airlock_preflight

# Fail-closed: Airlock v1 requires Tailscale up as the ingress (see SECURITY.md).
# (The app installers configure `tailscale serve`; this only requires Tailscale is
# authenticated.) Only a dry run may skip the live check.
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  ts_require_tailscale
  ts_require_https
fi

airlock_load hub    # AIRLOCK_HUB_NGINX_PORT / _HTTPS_PORT / _HTTP_PORT / _REDIRECT_PORT
_airlock_snapshot_owner="$AIRLOCK_OWNER"
# The platform account/secret surface's port, validated once here. devterm proxies the
# platform secret routes to it (airlock_accounts_port); exporting it keeps that a read of
# this validation rather than a second one.
export AIRLOCK_HUB_ACCOUNTS_PORT

WEBROOT="${AIRLOCK_WEBROOT:-/opt/airlock/hub}"
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
NGINX_SITE="${AIRLOCK_NGINX_SITE:-/etc/nginx/conf.d/airlock.conf}"
_airlock_installed_webjson="$WEBROOT/__airlock.json"

# Measure the deployment FQDN ONCE and hand it to everything downstream (the
# renderers' redirect target, the launcher's cross-port links). Every one of those
# must name the FQDN: the Tailscale cert covers it and nothing else, so a short
# hostname produces links the browser refuses. An operator override wins, which is
# also what lets CI render offline.
if [ -z "${AIRLOCK_TS_FQDN:-}" ]; then
  if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
    AIRLOCK_TS_FQDN="$(ts_fqdn)"
  elif [ -f "$_airlock_installed_webjson" ] \
      && [ ! -L "$_airlock_installed_webjson" ]; then
    AIRLOCK_TS_FQDN="$(python3 - "$_airlock_installed_webjson" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8")).get("fqdn")
if isinstance(value, str) and value:
    print(value)
PY
)" || die "cannot read the installed FQDN for dry-run discovery comparison"
  fi
fi
export AIRLOCK_TS_FQDN

# A normal dry run always renders into a private scratch tree.  Trying the requested
# live roots first is itself a write when their parent is writable, and app installers
# write nginx fragments unconditionally because the renderer consumes them.  The old
# fallback therefore made preview safety depend on permissions: root-owned /etc was
# safe while a user-owned installed root was changed.
#
# Hermetic render suites may request a pre-existing output directory explicitly.  It
# is an output contract, not a live-root override: the orchestrator derives both
# writable roots below it and never treats AIRLOCK_WEBROOT/AIRLOCK_CONFD as preview
# destinations on their own.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  if [ -n "${AIRLOCK_DRY_RUN_OUTPUT_DIR:-}" ]; then
    case "$AIRLOCK_DRY_RUN_OUTPUT_DIR" in
      /*) ;;
      *) die "AIRLOCK_DRY_RUN_OUTPUT_DIR must be an absolute pre-existing directory" ;;
    esac
    [ -d "$AIRLOCK_DRY_RUN_OUTPUT_DIR" ] && [ ! -L "$AIRLOCK_DRY_RUN_OUTPUT_DIR" ] \
      && [ "$(stat -c %u "$AIRLOCK_DRY_RUN_OUTPUT_DIR")" = "$(id -u)" ] \
      || die "AIRLOCK_DRY_RUN_OUTPUT_DIR must be a real directory owned by this user"
    _scratch="$AIRLOCK_DRY_RUN_OUTPUT_DIR"
  else
    _airlock_dry_preview_root="$(mktemp -d)" || die "cannot create private dry-run render root"
    chmod 0700 "$_airlock_dry_preview_root" || die "cannot protect dry-run render root"
    _scratch="$_airlock_dry_preview_root"
    log "[dry] previewing into private scratch $_scratch; live render roots stay untouched"
  fi
  WEBROOT="$_scratch/web"; CONFD="$_scratch/confd"; NGINX_SITE="$_scratch/airlock.conf"
  AIRLOCK_WEBROOT="$WEBROOT"; AIRLOCK_CONFD="$CONFD"; AIRLOCK_NGINX_SITE="$NGINX_SITE"
fi

_airlock_canonical_nginx_site() { # <path>; resolve parent aliases, preserve final symlink
  python3 - "$1" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.is_absolute():
    path = pathlib.Path.cwd() / path
print(path.parent.resolve(strict=False) / path.name)
PY
}
NGINX_SITE="$(_airlock_canonical_nginx_site "$NGINX_SITE")" \
  || die "cannot canonicalize nginx output path"
AIRLOCK_NGINX_SITE="$NGINX_SITE"
export AIRLOCK_WEBROOT AIRLOCK_CONFD AIRLOCK_NGINX_SITE

_airlock_snapshot_nginx_site() { # <source> <private-copy>; prints 0 or 1
  local _source="$1" _copy="$2"
  : > "$_copy" || return 1
  if [ -L "$_source" ]; then
    printf '%s\n' "nginx owner continuity: current site must not be a symlink: $_source" >&2
    return 1
  fi
  if [ ! -e "$_source" ]; then
    printf '0\n'
    return 0
  fi
  if [ ! -f "$_source" ]; then
    printf '%s\n' "nginx owner continuity: current site must be a regular file: $_source" >&2
    return 1
  fi
  if [ -r "$_source" ]; then
    cat -- "$_source" > "$_copy" || return 1
  else
    # shellcheck disable=SC2024 # privilege is needed only to read source; copy is caller-owned
    sudo cat -- "$_source" > "$_copy" || return 1
  fi
  printf '1\n'
}

# AIRLOCK_OWNER_CONTINUITY_PREWRITE — must stay before the first WEBROOT/CONFD write.
_airlock_owner_site_snapshot="$(mktemp)" || die "cannot allocate owner continuity snapshot"
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  : > "$_airlock_owner_site_snapshot"
  _airlock_owner_site_present=0
else
  _airlock_owner_site_present="$(_airlock_snapshot_nginx_site \
    "$NGINX_SITE" "$_airlock_owner_site_snapshot")" || {
    rm -f "$_airlock_owner_site_snapshot"
    die "cannot snapshot the current nginx site before output mutation"
  }
fi
if ! airlock_require_nginx_owner_continuity \
    "$_airlock_owner_site_snapshot" "$_airlock_owner_site_present" \
    "$_airlock_snapshot_owner" "$_airlock_transfer_owner_from"; then
  rm -f "$_airlock_owner_site_snapshot"
  die "refusing output mutation without nginx owner continuity"
fi
rm -f "$_airlock_owner_site_snapshot"

if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  install -d "$WEBROOT/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d"
fi

# Resolve every read-only candidate projection now, while all recorded apps are
# still active and after dry-run scratch roots have reached their final values.
# A bad manifest icon, launcher tile, env projection, plaintext mapping, or
# prerequisite must not surface for the first time after reconcile has already
# deactivated a working app.
log "validating the complete install candidate"
_candidate_preflight="$(printf '%s' "$AIRLOCK_PKG_INFO" \
  | airlock_config install-preflight --package-info-stdin)" || exit 2
[[ "$_candidate_preflight" =~ ^[0-9a-f]{64}$ ]] \
  || die "complete install candidate preflight returned an invalid digest"
airlock_verify_prerequisite_receipt \
  || die "prerequisites changed after preflight — no app was deactivated"

# App-scoped managed execution is an explicit invocation mode. Its complete
# ledger evidence and pure plan are produced, independently re-hashed, and
# persisted into the transaction before the first candidate mutation. The
# argument-free public/full path deliberately stays on the legacy flow below.
_active_ports=""
_upgrade_ids=""
_remove_plan=""
_removed_ids=""
_plan=""
_adopt_scan=""
_tx_specs=()
_scoped_destructive_plan=""
_scoped_member_ids=""
if [ "${#_airlock_selected_apps[@]}" -gt 0 ]; then
  [ "$_ledger_gate" = 1 ] || [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] \
    || die "app-scoped selection requires the installed-state ledger lock"
  _candidate_preflight_now="$(printf '%s' "$AIRLOCK_PKG_INFO" \
    | airlock_config install-preflight --package-info-stdin)" || exit 2
  [ "$_candidate_preflight_now" = "$_candidate_preflight" ] \
    || die "install candidate changed before app-scoped planning — nothing was mutated"
  AIRLOCK_INSTALL_PKG_INFO_SHA256="$(printf '%s' "$AIRLOCK_PKG_INFO" \
    | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" \
    || die "cannot hash frozen package plan"
  export AIRLOCK_INSTALL_PKG_INFO_SHA256
  _active_ports="$(airlock_config plaintext | awk '{print $2}' | tr '\n' ' ')"
  _airlock_ledger_plan_file="$(mktemp)" || die "cannot create ledger plan input"
  _airlock_ledger_dependencies_file="$(mktemp)" \
    || die "cannot create ledger dependency snapshot"
  _airlock_scoped_plan_file="$(mktemp)" || die "cannot create app-scoped plan"
  _airlock_candidate_webjson_file="$(mktemp)" \
    || die "cannot create app-scoped discovery projection"
  if printf '%s' "$AIRLOCK_PKG_INFO" \
      | "$ROOT/bin/airlock-ledger" plan \
          --dependency-snapshot "$_airlock_ledger_dependencies_file" \
          >"$_airlock_ledger_plan_file"; then
    :
  else
    _rc=$?
    [ "$_rc" = 3 ] \
      && die "a recorded app without a deactivator blocks this change (see above) — the one exit is the explicit teardown command it names"
    die "installed-state ledger plan with dependency snapshot failed (rc=$_rc)"
  fi
  _plan="$(cat "$_airlock_ledger_plan_file")"
  _adopt_scan="$(airlock_config adopt-scan)" \
    || die "known-builtin adoption sweep failed (rc=$?)"

  _scoped_planner_args=(
    --package-info -
    --ledger-plan "$_airlock_ledger_plan_file"
    --ledger-dependencies "$_airlock_ledger_dependencies_file"
    --candidate-preflight-digest "$_candidate_preflight"
    --mode selected
  )
  for _selected_app in "${_airlock_selected_apps[@]}"; do
    _scoped_planner_args+=(--select "$_selected_app")
  done
  while IFS= read -r _handoff_app; do
    [ -n "$_handoff_app" ] || continue
    [ "$_handoff_app" = hub ] && continue
    _handoff_owners="$(printf '%s' "$AIRLOCK_PKG_INFO" \
      | "$ROOT/bin/airlock-ledger" handoffs "$_handoff_app")" \
      || die "could not bind resource handoffs for '$_handoff_app' — nothing was mutated"
    while IFS= read -r _handoff_owner; do
      [ -n "$_handoff_owner" ] || continue
      _scoped_planner_args+=(--handoff "${_handoff_owner}:${_handoff_app}")
    done <<<"$_handoff_owners"
  done <<<"$_app_ids"
  printf '%s' "$AIRLOCK_PKG_INFO" \
    | python3 "$ROOT/install/app-scoped-plan.py" "${_scoped_planner_args[@]}" \
        >"$_airlock_scoped_plan_file" \
    || die "app-scoped plan refused the locked candidate — nothing was mutated"
  airlock_config webjson >"$_airlock_candidate_webjson_file" \
    || die "cannot render app-scoped discovery precondition — nothing was mutated"

  _scoped_contract="$(python3 - \
      "$_airlock_scoped_plan_file" "$_airlock_ledger_dependencies_file" \
      "$_candidate_preflight" "$_airlock_candidate_webjson_file" \
      "$_airlock_installed_webjson" \
      "${_airlock_selected_apps[@]}" <<'PY'
import hashlib
import json
import sys

plan_path, dependencies_path, candidate, candidate_webjson_path, installed_webjson_path, *selected = sys.argv[1:]

def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()

with open(plan_path, "rb") as handle:
    plan = json.load(handle)
with open(dependencies_path, "rb") as handle:
    dependencies = json.load(handle)
body = dict(plan)
plan_digest = body.pop("plan_digest", None)
if plan_digest != hashlib.sha256(canonical(body)).hexdigest():
    raise SystemExit("app-scoped plan digest mismatch")
dependency_digest = hashlib.sha256(canonical(dependencies)).hexdigest()
if plan.get("inputs", {}).get("ledger_dependencies_digest") != dependency_digest:
    raise SystemExit("app-scoped dependency snapshot digest mismatch")
if plan.get("candidate_preflight_digest") != candidate:
    raise SystemExit("app-scoped candidate preflight digest mismatch")
if plan.get("mode") != "selected" or len(selected) != len(set(selected)) \
        or set(plan.get("requested_apps", [])) != set(selected):
    raise SystemExit("app-scoped selection does not match the installer request")

groups = plan.get("groups")
if not isinstance(groups, list) or not groups:
    raise SystemExit("app-scoped plan contains no selected safety group")
execution = plan.get("execution")
if not isinstance(execution, dict) or set(execution) != {
        "actions", "destructive_order", "install_order", "remove_order"}:
    raise SystemExit("app-scoped plan has no closed execution contract")
actions = execution["actions"]
action_by_id = {row.get("app_id"): row.get("action") for row in actions}
expected_destructive = [row.get("app_id") for row in actions
                        if row.get("action") in {"remove", "teardown-intent", "upgrade-deactivate"}]
expected_removals = [row.get("app_id") for row in actions
                     if row.get("action") in {"remove", "teardown-intent"}]
if (len(action_by_id) != len(actions)
        or any(app_id in set(plan.get("unrelated_apps", [])) for app_id in action_by_id)
        or len(execution["install_order"]) != len(set(execution["install_order"]))
        or any(app_id not in action_by_id for app_id in execution["install_order"])
        or execution["destructive_order"] != expected_destructive
        or execution["remove_order"] != expected_removals):
    raise SystemExit("app-scoped execution contract is inconsistent")

# The installer still owns one global discovery render.  Selected execution may
# change entries in its safety group, but every other byte must already match the
# installed projection; otherwise publishing the full candidate would expose an
# app this transaction did not install or update unrelated global metadata.
try:
    with open(candidate_webjson_path, "rb") as handle:
        candidate_webjson = json.load(handle)
    with open(installed_webjson_path, "rb") as handle:
        installed_webjson = json.load(handle)
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"cannot prove installed discovery state: {exc}") from exc
if not isinstance(candidate_webjson, dict) or not isinstance(installed_webjson, dict):
    raise SystemExit("cannot prove installed discovery state: projection is not an object")
candidate_unselected = json.loads(json.dumps(candidate_webjson))
installed_unselected = json.loads(json.dumps(installed_webjson))
candidate_apps = candidate_unselected.get("apps")
installed_apps = installed_unselected.get("apps")
if not isinstance(candidate_apps, dict) or not isinstance(installed_apps, dict):
    raise SystemExit("cannot prove installed discovery state: apps is not an object")
for app_id in action_by_id:
    candidate_apps.pop(app_id, None)
    installed_apps.pop(app_id, None)
if candidate_unselected != installed_unselected:
    raise SystemExit("unselected discovery projection differs from installed state")

print("BIND\t" + plan_digest + "\t" + dependency_digest)
for row in actions:
    print("ACTION\t" + row["action"] + "\t" + row["app_id"])
for app_id in execution["install_order"]:
    print("INSTALL\t" + app_id)
for app_id in execution["destructive_order"]:
    print("DESTRUCTIVE\t" + action_by_id[app_id] + "\t" + app_id)
PY
)" || die "cannot verify app-scoped plan binding — nothing was mutated"

  _app_ids=""
  while IFS=$'\t' read -r _kind _value _id; do
    case "$_kind" in
      BIND)
        AIRLOCK_APP_SCOPED_PLAN_SHA256="$_value"
        AIRLOCK_LEDGER_DEPENDENCIES_SHA256="$_id"
        export AIRLOCK_APP_SCOPED_PLAN_SHA256 AIRLOCK_LEDGER_DEPENDENCIES_SHA256
        ;;
      ACTION)
        _tx_specs+=("${_value}:${_id}")
        _scoped_member_ids="$_scoped_member_ids $_id"
        case "$_value" in
          remove|teardown-intent)
            _remove_plan="${_remove_plan}${_value}"$'\t'"${_id}"$'\n' ;;
          upgrade-deactivate)
            _upgrade_ids="$_upgrade_ids $_id" ;;
        esac
        ;;
      INSTALL)
        if [ -z "$_app_ids" ]; then
          _app_ids="$_value"
        else
          _app_ids="${_app_ids}"$'\n'"${_value}"
        fi
        ;;
      DESTRUCTIVE)
        _scoped_destructive_plan="${_scoped_destructive_plan}${_value}"$'\t'"${_id}"$'\n'
        ;;
      *)
        die "unknown app-scoped plan binding row: $_kind"
        ;;
    esac
  done <<<"$_scoped_contract"
  if ! [[ "${AIRLOCK_APP_SCOPED_PLAN_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] \
      || ! [[ "${AIRLOCK_LEDGER_DEPENDENCIES_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]; then
    die "app-scoped plan binding returned invalid digests — nothing was mutated"
  fi
  _scoped_owed_app=""
  _scoped_owed_rc=0
  _scoped_owed_app="$(devmon_activation_app "$(devmon_migration_state_dir)")" \
    || _scoped_owed_rc=$?
  case "$_scoped_owed_rc" in
    0)
      if [[ " $_scoped_member_ids " != *" $_scoped_owed_app "* ]]; then
        die "app-scoped selection excludes owed activation for '$_scoped_owed_app' — resolve it before mutation or select its safety group"
      fi
      ;;
    1) ;;
    *) die "cannot classify owed activation before app-scoped mutation" ;;
  esac
  if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] && [ "${#_tx_specs[@]}" -gt 0 ]; then
    _airlock_failure_phase="checkpoint"
    if [ "$_airlock_managed_mode" = 1 ]; then
      _airlock_transaction_id="$(printf '%s' "$AIRLOCK_PKG_INFO" \
        | "$ROOT/bin/airlock-ledger" transaction-begin \
            "--managed-authority-file=$_airlock_managed_authority_file" \
            "--managed-authority-sha256=$_airlock_managed_authority_sha256" \
            "${_tx_specs[@]}")" \
        || die "could not bind managed authority and app-scoped plan to a verified install checkpoint — no app was deactivated"
    else
      _airlock_transaction_id="$(printf '%s' "$AIRLOCK_PKG_INFO" \
        | "$ROOT/bin/airlock-ledger" transaction-begin "${_tx_specs[@]}")" \
        || die "could not bind app-scoped plan to a verified install checkpoint — no app was deactivated"
    fi
    _airlock_transaction_active=1
    AIRLOCK_INSTALL_TRANSACTION_ID="$_airlock_transaction_id"
    export AIRLOCK_INSTALL_TRANSACTION_ID
    log "app-scoped install transaction prepared: $_airlock_transaction_id"
  fi
fi

# A committed install whose dev-monitor activation did not finish is resumed first.
# It is not a gate: the new candidate may be the fix, so a failure only warns.
if [ "$_ledger_gate" = 1 ] && { [ "${#_airlock_selected_apps[@]}" = 0 ] \
  || [[ " $_scoped_member_ids " == *" dev-monitor "* ]]; }; then
  _airlock_devmon_activate_owed resume \
    || log "WARN: dev-monitor activation is still owed; continuing with the new candidate"
fi

# 1) hub static + frontend config
# WEBROOT and CONFD live under system paths nginx can read. Create them with sudo
# and hand ownership to the installing user, so the hub write + each app's fragment
# write need no further sudo (nginx still reads them — dirs are world-readable).
log "installing hub -> $WEBROOT"
airlock_run sudo mkdir -p "$WEBROOT/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d"
airlock_run sudo chown -R "$(id -un):$(id -gn)" "$WEBROOT" "$CONFD"
airlock_run cp "$ROOT/hub/index.html" "$ROOT/hub/wrong-owner.html" "$WEBROOT/"
# hub brand marks (favicon.png + apple-touch-icon.png), app brand icons, and the
# per-app icon set generated from the launcher sprite (assets/app-icons/, see
# bin/gen-app-icons.py) — all served from /assets/, which same-origin subpath apps
# reference directly. A recursive copy, so a new asset directory needs no wiring here.
[ -d "$ROOT/hub/assets" ] && airlock_run cp -r "$ROOT/hub/assets/." "$WEBROOT/assets/"
# [branding] icon_ring: the subpath apps (notepad, publish, fileview, dev-monitor)
# take their favicon from assets/app-icons/, so ringing only each gate's own copy
# left most tabs on a multi-box tailnet identical. Same filenames, ringed content —
# no page is edited. SVG only; see ring_icon_svg's note on the PNG half.
_icon_ring="$(airlock_config get branding.icon_ring 2>/dev/null || true)"
if [ -n "$_icon_ring" ]; then
  # A dry run must not touch the live webroot. This loop rewrites files in place,
  # so unlike the copy above it cannot go through airlock_run — and the copy above
  # is what restores the unringed original, so a dry run that rang anyway would
  # ring the already-ringed icon, nesting the mark smaller on every re-run.
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
    log "[dry] ring app favicons in $WEBROOT/assets/app-icons/ (${_icon_ring})"
  elif [ -d "$WEBROOT/assets/app-icons" ]; then
    for _icon in "$WEBROOT"/assets/app-icons/*.svg; do
      [ -f "$_icon" ] || continue
      if ring_icon_svg "$_icon_ring" "$_icon" > "$_icon.ringed"; then
        mv "$_icon.ringed" "$_icon"
      else
        rm -f "$_icon.ringed"      # never leave a half-written icon in the webroot
        die "icon_ring: could not ring $_icon"
      fi
    done
    log "app favicons ringed (${_icon_ring})"
  fi
fi
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] airlock-config webjson > $WEBROOT/__airlock.json"
else
  airlock_config webjson > "$WEBROOT/__airlock.json"
fi

# 1b) reconcile the installed-state ledger (packaged apps only). Repairs
# crashed runs, removes what config no longer desires — a refusal (recorded
# app without a deactivator) aborts here, before any install touches the box.
# Sits after the roots above because full-mode teardown resolves against
# $CONFD/$WEBROOT. Explicit selected mode already prepared and bound its
# narrower transaction before those roots were mutated.
if [ "$_ledger_gate" = 1 ] || { [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] \
  && { [ -n "$_pkg_ids" ] || [ -f "$LEDGER_FILE" ] || [ -n "$_known_builtins" ]; }; }; then
  if [ "${#_airlock_selected_apps[@]}" = 0 ]; then
    # Close the read-to-reconcile window.  The first pass proved every static
    # projection before any install mutation; this repeat proves it is still the
    # same candidate immediately before the first ledger removal/deactivation.
    _candidate_preflight_now="$(printf '%s' "$AIRLOCK_PKG_INFO" \
      | airlock_config install-preflight --package-info-stdin)" || exit 2
    [ "$_candidate_preflight_now" = "$_candidate_preflight" ] \
      || die "install candidate changed before reconcile — no recorded app was deactivated"
    # The two unfrozen preflights above proved that the live registry still
    # matches the original package plan immediately before teardown. From this
    # boundary onward every config child reuses that exact plan instead of
    # reopening a mutable registry after installed state has been disturbed.
    AIRLOCK_INSTALL_PKG_INFO_SHA256="$(printf '%s' "$AIRLOCK_PKG_INFO" \
      | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" \
      || die "cannot hash frozen package plan"
    export AIRLOCK_INSTALL_PKG_INFO_SHA256
    # Computed only on ledger-touching runs: a built-in-only box must see the
    # exact byte stream it saw before packages existed.
    _active_ports="$(airlock_config plaintext | awk '{print $2}' | tr '\n' ' ')"
    _plan="$(printf '%s' "$AIRLOCK_PKG_INFO" | "$ROOT/bin/airlock-ledger" plan)" || {
      _rc=$?
      [ "$_rc" = 3 ] && die "a recorded app without a deactivator blocks this change (see above) — the one exit is the explicit teardown command it names"
      die "installed-state ledger plan failed (rc=$_rc)"
    }
    # Snapshot the report-only adoption sweep before the first teardown.  Some
    # shipped manifests project mutable operator registries; reopening one after
    # reconcile would introduce a second candidate revision and could abort only
    # after an old package had already been deactivated.
    _adopt_scan="$(airlock_config adopt-scan)" \
      || die "known-builtin adoption sweep failed (rc=$?)"
    # Classify only. No app is deactivated here: upgrades move to their own
    # install turn, and config removals wait until all desired apps smoke+commit.
    # Every planned app is checkpointed first, so an install, smoke, final-render,
    # or removal error can compensate the complete touched prefix.
    while IFS=$'\t' read -r _action _id; do
      [ -n "${_action:-}" ] || continue
      _tx_specs+=("${_action}:${_id}")
      case "$_action" in
        remove|teardown-intent)
          _remove_plan="${_remove_plan}${_action}"$'\t'"${_id}"$'\n' ;;
        upgrade-deactivate)
          _upgrade_ids="$_upgrade_ids $_id" ;;
        fresh|reinstall|upgrade-diff)
          : ;;
        *)
          die "unknown ledger plan action: $_action ($_id)" ;;
      esac
    done <<<"$_plan"
    if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] && [ "${#_tx_specs[@]}" -gt 0 ]; then
      _airlock_failure_phase="checkpoint"
      _airlock_transaction_id="$(printf '%s' "$AIRLOCK_PKG_INFO" \
        | "$ROOT/bin/airlock-ledger" transaction-begin "${_tx_specs[@]}")" \
        || die "could not create a verified install checkpoint — no app was deactivated"
      _airlock_transaction_active=1
      AIRLOCK_INSTALL_TRANSACTION_ID="$_airlock_transaction_id"
      export AIRLOCK_INSTALL_TRANSACTION_ID
      log "install transaction prepared: $_airlock_transaction_id"
    fi
  fi

  # F15 sweep (child 4/P4, amended: runs on EVERY ledger-enabled run, not
  # only the first): known builtins with no config entry and no ledger
  # record are reported here — loudly, never removed on their own. Read-only
  # (adopt-scan mutates nothing); the operator runs the printed `--adopt`
  # line by hand. Captured into a variable with an explicit failure check
  # (not `done < <(...)`): a process-substitution's exit status is invisible
  # to `set -e` — a failing sweep would otherwise vanish silently instead of
  # aborting the run.
  while IFS=$'\t' read -r _kind _kid _detail; do
    [ -n "${_kind:-}" ] || continue
    case "$_kind" in
      ADOPT)
        log "pre-ledger artifact(s) found for known builtin '$_kid': $_detail — reclaim with: bin/airlock-teardown --adopt $_kid"
        ;;
      EXCLUDE)
        log "known builtin '$_kid' has artifacts but its claims overlap live state — resolve by hand ($_detail)"
        ;;
      *)
        die "unknown adopt-scan line: $_kind ($_kid)" ;;
    esac
  done <<<"$_adopt_scan"
fi

# 1c) The first platform-owned user unit. Apps own their own units below, but the secret
# drop's TTL must remain enforced when no consuming app is installed or running. The
# helper owns both render/install and the symmetric explicit teardown path.
log "installing platform secret TTL timer"
AIRLOCK_ROOT="$ROOT" bash "$ROOT/install/airlock-secret-timer.sh" install

# Update discovery is likewise platform-owned: it compares the platform release,
# package ledger and local harness once per day, then dev-monitor only reads its snapshot.
log "installing platform update detector timer"
AIRLOCK_ROOT="$ROOT" bash "$ROOT/install/airlock-update-timer.sh" install

# 1c-2) The platform account surface (ACCT_SURFACE). A service rather than a oneshot:
# the hub proxies /airlock-accounts/ to it behind an owner-only guard. It stays behind
# nginx on loopback and never binds the tailnet itself.
log "installing platform account surface"
AIRLOCK_ROOT="$ROOT" AIRLOCK_HUB_ACCOUNTS_PORT="$AIRLOCK_HUB_ACCOUNTS_PORT" \
  AIRLOCK_HUB_FLEET_STORE="${AIRLOCK_HUB_FLEET_STORE-}" \
  AIRLOCK_HUB_FLEET_STORE_URL="${AIRLOCK_HUB_FLEET_STORE_URL-}" \
  AIRLOCK_HUB_XAI="${AIRLOCK_HUB_XAI-false}" \
  bash "$ROOT/install/airlock-accounts-api.sh" install

# 1d) Retire platform units this tree no longer declares. Runs AFTER the installs above,
# so a failure up there aborts (set -e) before anything is swept — the declared set is
# only trustworthy once it has actually been written. The list below is this installer's
# complete platform unit set; adding a unit above without adding it here deletes it on the
# next run, which is what the test's "declared units survive" control is for.
# live/systemd/* is a different owner and a different installer (live/install-timer.sh) —
# see airlock_sweep_platform_units for why the marker names one.
airlock_sweep_platform_units airlock-install \
  airlock-secret-sweep.service airlock-secret-sweep.timer \
  airlock-update-detect.service airlock-update-detect.timer \
  airlock-accounts-api.service

# 2) enabled app installers (each drops its own nginx fragment into $CONFD/*)
# Child 4/P3: validate already refused any enabled app that is neither hub
# nor a resolvable package (shipped or explicit) — pkg_dir is unconditionally
# non-empty here, so the legacy "apps/$app/install.sh not present yet"
# fallback branch is retired.
# Selected mode consumes the ledger producer's destructive order as one
# pre-install sequence. Upgrade dependents therefore deactivate before their
# dependencies even though the fresh install order runs in the opposite,
# dependency-topological direction. Full mode retains its legacy just-in-time
# upgrade and post-commit config-removal behavior below.
if [ "${#_airlock_selected_apps[@]}" -gt 0 ] && [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  while IFS=$'\t' read -r _action _id; do
    [ -n "${_action:-}" ] || continue
    _airlock_failure_app="$_id"
    _airlock_failure_phase="deactivate"
    "$ROOT/bin/airlock-ledger" transaction-touch "$_id"
    case "$_action" in
      upgrade-deactivate)
        printf '%s' "$AIRLOCK_PKG_INFO" \
          | "$ROOT/bin/airlock-ledger" preflight-remove "$_id" --for-upgrade --active-ports "$_active_ports" >/dev/null
        "$ROOT/bin/airlock-ledger" transaction-deactivated "$_id"
        log "app-scoped reconcile: deactivating '$_id' before selected installs"
        printf '%s' "$AIRLOCK_PKG_INFO" \
          | "$ROOT/bin/airlock-ledger" remove "$_id" --for-upgrade --active-ports "$_active_ports" \
          || die "could not deactivate '$_id'; compensating the selected transaction"
        ;;
      remove|teardown-intent)
        printf '%s' "$AIRLOCK_PKG_INFO" \
          | "$ROOT/bin/airlock-ledger" preflight-remove "$_id" --active-ports "$_active_ports" >/dev/null
        "$ROOT/bin/airlock-ledger" transaction-deactivated "$_id"
        log "app-scoped reconcile: removing '$_id' before selected installs"
        printf '%s' "$AIRLOCK_PKG_INFO" \
          | "$ROOT/bin/airlock-ledger" remove "$_id" --active-ports "$_active_ports" \
          || die "could not remove '$_id'; compensating the selected transaction"
        _removed_ids="$_removed_ids $_id"
        ;;
      *)
        die "unknown app-scoped destructive action: $_action ($_id)"
        ;;
    esac
  done <<<"$_scoped_destructive_plan"
fi

_installed_pkgs=""
while read -r app; do
  [ -n "$app" ] || continue
  [ "$app" = hub ] && continue
  pkg_dir="$(airlock_pkg_dir "$app")"
  inst="$pkg_dir/install.sh"
  if [ ! -f "$inst" ] || [ -L "$inst" ]; then
    # Validate proved this was a regular non-symlink file (F6). Absence is
    # a validate-then-delete race; a symlink is worse — the D6 digest
    # records only a symlink's target string, so following it here would
    # run unverified content behind an unchanged digest.
    die "packaged app '$app': $inst is missing or not a regular non-symlink file (F6)"
  elif [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
    # A dry run never executes an uncertified package's scripts: their
    # AIRLOCK_DRY_RUN discipline is unknown third-party code (D4), and
    # running it without lock or journal would break both contracts. Every
    # canonical bundle app's immutable policy certifies full AIRLOCK_DRY_RUN
    # discipline, so its install.sh DOES run here.  Consume that derived fact;
    # source_class remains provenance and an id/path classification is not an
    # authorization decision. The ledger is never touched on this path (no
    # intent/icon-stage/commit): those stay gated to a real run, below.
    _dry_certified="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c '
import json, sys
pkg = (json.load(sys.stdin).get("packages") or {}).get(sys.argv[1]) or {}
print("1" if "dry-run-exec" in (pkg.get("certifications") or []) else "0")
' "$app")"
    if [ "$_dry_certified" = 1 ]; then
      log "[dry] installing packaged app: $app ($pkg_dir) (shipped app — dry run executes)"
      (cd "$pkg_dir" && AIRLOCK_CONFD="$CONFD" AIRLOCK_ROOT="$ROOT" \
        AIRLOCK_APP_DIR="$pkg_dir" AIRLOCK_APP_ID="$app" \
        AIRLOCK_CONFIG_BIN="$_airlock_lifecycle_config_bin" \
        bash "$inst" </dev/null) 9>&-
      # serve.https platform render (D2 manifest surface; child-4 P2b STEP
      # 0 infra) — byte-identical to the direct `sudo tailscale serve
      # --bg --https=...` call devterm/code-server/orca/paseo used to run
      # inline from their own install.sh (install/test-serve-https-parity.sh).
      # Runs here, not inside the subshell above: it only reads
      # AIRLOCK_PKG_INFO/$app, same as the hub's own https serve call
      # below (step 5), which also runs un-subshelled in this scope.
      airlock_render_serve_https "$app"
    else
      log "[dry] would install packaged app: $app from $pkg_dir (script not run)"
    fi
  else
    _airlock_failure_app="$app"
    _airlock_failure_phase="intent"
    if [ "$_airlock_transaction_active" = 1 ]; then
      "$ROOT/bin/airlock-ledger" transaction-touch "$app"
    fi
    _handoff_ids="$(printf '%s' "$AIRLOCK_PKG_INFO" \
      | "$ROOT/bin/airlock-ledger" handoffs "$app")" \
      || die "could not calculate resource handoff for '$app'"
    while IFS= read -r _handoff_id; do
      [ -n "$_handoff_id" ] || continue
      case " $_removed_ids " in *" $_handoff_id "*) continue ;; esac
      _airlock_failure_phase="resource-handoff"
      _airlock_failure_app="$_handoff_id"
      "$ROOT/bin/airlock-ledger" transaction-touch "$_handoff_id"
      printf '%s' "$AIRLOCK_PKG_INFO" \
        | "$ROOT/bin/airlock-ledger" preflight-remove "$_handoff_id" --active-ports "$_active_ports" >/dev/null
      "$ROOT/bin/airlock-ledger" transaction-deactivated "$_handoff_id"
      log "resource handoff: removing '$_handoff_id' immediately before '$app'"
      printf '%s' "$AIRLOCK_PKG_INFO" \
        | "$ROOT/bin/airlock-ledger" remove "$_handoff_id" --active-ports "$_active_ports" \
        || die "resource handoff from '$_handoff_id' to '$app' failed; compensating"
      _removed_ids="$_removed_ids $_handoff_id"
    done <<<"$_handoff_ids"
    _airlock_failure_app="$app"
    case "${#_airlock_selected_apps[@]}: $_upgrade_ids " in
      0:*" $app "*)
        _airlock_failure_phase="deactivate"
        printf '%s' "$AIRLOCK_PKG_INFO" \
          | "$ROOT/bin/airlock-ledger" preflight-remove "$app" --for-upgrade --active-ports "$_active_ports" >/dev/null
        "$ROOT/bin/airlock-ledger" transaction-deactivated "$app"
        log "reconcile: '$app' changed — deactivating it immediately before its fresh install"
        printf '%s' "$AIRLOCK_PKG_INFO" \
          | "$ROOT/bin/airlock-ledger" remove "$app" --for-upgrade --active-ports "$_active_ports" \
          || die "could not deactivate '$app'; compensating the touched transaction"
        ;;
    esac
    _airlock_failure_phase="install"
    log "installing packaged app: $app ($pkg_dir)"
    printf '%s' "$AIRLOCK_PKG_INFO" | "$ROOT/bin/airlock-ledger" intent "$app" --active-ports "$_active_ports" >/dev/null
    # F4: stage the tile icon ONLY NOW that the intent above names its
    # destination (record before mutate) — a crash after the copy leaves an
    # artifact the ledger already knows how to reclaim. icon-stage is one
    # process: it re-checks containment, proves the tree still matches the
    # journaled intent (digest), refuses symlinks at every destination
    # component, and writes atomically.
    _icon_out="$(airlock_config icon-stage "$app")" \
      || die "packaged app '$app': tile icon staging failed (F4)"
    [ -z "$_icon_out" ] || log "staged tile icon: $app -> $WEBROOT/$_icon_out"
    # 9>&-: lifecycle children must not inherit the lock fd — a background
    # process an installer leaves behind would hold the flock forever.
    if (cd "$pkg_dir" && AIRLOCK_CONFD="$CONFD" AIRLOCK_ROOT="$ROOT" \
        AIRLOCK_APP_DIR="$pkg_dir" AIRLOCK_APP_ID="$app" \
        AIRLOCK_CONFIG_BIN="$_airlock_lifecycle_config_bin" \
        bash "$inst" </dev/null) 9>&-; then
      # serve.https remains the platform-owned ingress apply primitive. A4 will
      # replace this live call with a staged full candidate; A3 only gives the
      # existing call an exact, measured result.
      if ! airlock_render_serve_https "$app"; then
        [ "${#_airlock_selected_apps[@]}" -eq 0 ] \
          || "$ROOT/bin/airlock-ledger" transaction-resource-result \
               apply "$app" failed >/dev/null 2>&1 || true
        die "packaged app '$app': ingress apply failed; compensating the touched transaction"
      fi
    else
      _airlock_lifecycle_rc=$?
      [ "${#_airlock_selected_apps[@]}" -eq 0 ] \
        || "$ROOT/bin/airlock-ledger" transaction-resource-result \
             apply "$app" failed >/dev/null 2>&1 || true
      exit "$_airlock_lifecycle_rc"
    fi
    _installed_pkgs="$_installed_pkgs $app"
  fi
done <<<"$_app_ids"
_airlock_failure_app="-"
_airlock_failure_phase="final-render"

# 3) render the main site (includes the fragments from step 2)
log "rendering nginx site -> $NGINX_SITE"
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] render-nginx.sh > $NGINX_SITE"
else
  tmp="$(mktemp)"
  AIRLOCK_CONFIG_BIN="$_airlock_lifecycle_config_bin" \
    bash "$ROOT/install/render-nginx.sh" > "$tmp"
  if [ "$NGINX_SITE" = /etc/nginx/conf.d/airlock.conf ]; then
    IFS=$'\t' read -r _airlock_publish_enabled _airlock_publish_gate_port \
      _airlock_publish_selector < <(
        if airlock_config apps | grep -qx publish; then
          eval "$(airlock_config env publish)"
          _selector=hub_ok
          [ "${AIRLOCK_PUBLISH_TAILNET_VIEW:-false}" != true ] || _selector=tailnet_ok
          printf '1\t%s\t%s\n' "${AIRLOCK_PUBLISH_GATE_PORT:?publish gate_port missing}" "$_selector"
        else
          printf '0\t-\t-\n'
        fi
      )
  fi
  # Re-snapshot at the last responsible moment: a changed owner_ok map between
  # the pre-write decision and this copy is a TOCTOU refusal, not authority.
  _airlock_owner_site_snapshot="$(mktemp)" || {
    rm -f "$tmp"
    die "cannot allocate final owner continuity snapshot"
  }
  _airlock_owner_site_present="$(_airlock_snapshot_nginx_site \
    "$NGINX_SITE" "$_airlock_owner_site_snapshot")" || {
    rm -f "$tmp" "$_airlock_owner_site_snapshot"
    die "cannot snapshot the current nginx site before replacement"
  }
  if [ "$NGINX_SITE" = /etc/nginx/conf.d/airlock.conf ]; then
    if ! airlock_require_nginx_publish_continuity \
        "$_airlock_owner_site_snapshot" "$tmp" "$_airlock_publish_enabled" \
        "$_airlock_publish_gate_port" "$_airlock_publish_selector"; then
      rm -f "$tmp" "$_airlock_owner_site_snapshot"
      die "refusing to replace the live nginx site without listener and publish-gate continuity"
    fi
  fi
  # AIRLOCK_OWNER_CONTINUITY_PRECOPY — the last decision before the site copy.
  if ! airlock_require_nginx_owner_continuity \
      "$_airlock_owner_site_snapshot" "$_airlock_owner_site_present" \
      "$_airlock_snapshot_owner" "$_airlock_transfer_owner_from" "$tmp"; then
    rm -f "$tmp" "$_airlock_owner_site_snapshot"
    die "refusing nginx replacement without current and rendered owner continuity"
  fi
  airlock_run sudo cp "$tmp" "$NGINX_SITE"
  rm -f "$tmp" "$_airlock_owner_site_snapshot"
fi

# 4) validate + reload
airlock_run sudo nginx -t
_airlock_mark_nginx_restore_owed
airlock_run sudo systemctl reload nginx

# 4b) reboot survival. Each app installer already `systemctl --user enable`s its
# units, but on a headless box --user units only start at boot when the installing
# user has lingering enabled. Also make sure nginx + tailscaled come up on boot.
# Idempotent; safe to re-run. Warnings are loud but non-fatal (don't abort a
# working install just because boot-persistence couldn't be armed).
airlock_enable_linger "$(id -un)"
# The two below keep exit-code warnings on purpose: nothing else in this repo
# enables them, so a failure here is genuinely news, and both messages already say
# "usually already enabled by the package" rather than claiming something is broken.
airlock_run sudo systemctl enable nginx \
  || log "WARN: could not enable nginx on boot (usually already enabled by the package)"
airlock_run sudo systemctl enable tailscaled \
  || log "WARN: could not enable tailscaled on boot (usually already enabled by the Tailscale package)"

# 5) expose the hub entrance over https via tailscale serve
airlock_run sudo tailscale serve --bg --https="${AIRLOCK_HUB_HTTPS_PORT}" "http://127.0.0.1:${AIRLOCK_HUB_NGINX_PORT}"

# 5b) plaintext ports — ONE owner, and only now that nginx is reloaded and actually
# serving the redirect ports. Each plaintext port is pointed at its app's
# redirect_port, whose sole response is a 301 to https: no page and no identity
# header ever crosses a non-TLS connection.
#
# Then RETIRE stale mappings. `tailscale serve --bg` persists until explicitly
# turned off, so a port that config no longer asks for (app removed, port changed)
# would keep proxying its old target — a plaintext hole that survives every
# re-install. Only Airlock's own plaintext ports are considered; mappings an
# operator added by hand are left alone.
want_ports=""
# The sidecar is the retirement authority when config, payload, and ledger are
# all gone. Commit it BEFORE opening a persistent Tailscale mapping. A later
# mapping/smoke failure deliberately leaves the record behind for retry/cleanup.
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  airlock_config plaintext-retirement-record || exit 2
fi
while IFS=$'\t' read -r app listen redirect; do
  [ -n "${listen:-}" ] || continue
  log "plaintext ingress: :$listen -> 301 https (${app})"
  ts_apply_plaintext_mapping "$app" "$listen" "$redirect"
  want_ports="$want_ports $listen"
done < <(airlock_config plaintext)

ts_reconcile_plaintext_ports "$want_ports" \
  || die "cannot reconcile stale plaintext ingress"

# A3 records apply only after both per-app HTTPS and the existing global
# plaintext primitives have run. Final verification is deliberately deferred
# until after a successful smoke and runs immediately before the app's commit:
# readiness may legitimately change live observations while smoke waits. A4
# will move these ingress mutations behind a staged whole-candidate gate; until
# then this remains a result boundary around the existing execution order, not
# a staging claim.
if [ "${#_airlock_selected_apps[@]}" -gt 0 ] && [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  for app in $_installed_pkgs; do
    _airlock_failure_phase="resource-apply"
    _airlock_failure_app="$app"
    "$ROOT/bin/airlock-ledger" transaction-resource-result \
      apply "$app" passed >/dev/null \
      || die "packaged app '$app': resource apply result failed; compensating"
  done
fi

# 6) smoke each enabled app now that the gate is live
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  smoke_fail=0
  _smoke_failed=""
  # Any owed activation, not only this transaction's: an app still awaiting one is
  # stopped, so smoking it here would fail a healthy run and roll back other apps.
  _devmon_deferred_app="$(devmon_activation_app "$(devmon_migration_state_dir)")" \
    || _devmon_deferred_app=""
  while read -r app; do
    [ -n "$app" ] || continue
    [ "$app" = hub ] && continue
    if [ "$app" = "$_devmon_deferred_app" ]; then
      # Stopped on purpose until commit; its smoke runs right after activation.
      log "smoke: $app deferred until its post-commit activation"
      continue
    fi
    _airlock_failure_phase="smoke"
    _airlock_failure_app="$app"
    pkg_dir="$(airlock_pkg_dir "$app")"
    s="$pkg_dir/smoke.sh"
    # Validate proved smoke.sh was a regular non-symlink file (F6); a
    # silent skip would commit an app nothing ever smoked, and a symlink
    # would run content the digest never covered.
    { [ -f "$s" ] && [ ! -L "$s" ]; } \
      || die "packaged app '$app': $s is missing or not a regular non-symlink file (F6)"
    log "smoke: $app"
    (cd "$pkg_dir" && AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$pkg_dir" AIRLOCK_APP_ID="$app" \
      AIRLOCK_CONFIG_BIN="$_airlock_lifecycle_config_bin" \
      bash "$s" </dev/null) 9>&- \
      || { log "smoke FAILED: $app"; smoke_fail=1; _smoke_failed="$_smoke_failed $app"; }
  done <<<"$_app_ids"

  # 6b-ledger) commit packaged installs that met the commit condition:
  # install.sh succeeded AND smoke.sh ran and succeeded (F6 guarantees the
  # script exists, so "or absent" is gone from the condition). Committed
  # BEFORE the any-smoke-failed die below, so app B's clean install is
  # recorded even when app A's smoke fails — the failed app stays an intent
  # the next run repairs. The one app whose activation this transaction deferred
  # commits on its install alone: it cannot run before commit, so its smoke
  # follows the activation, and a failure there stays owed (never rolled back).
  _commit_fail=0
  for app in $_installed_pkgs; do
    case " $_smoke_failed " in *" $app "*) continue ;; esac
    if [ "${#_airlock_selected_apps[@]}" -gt 0 ]; then
      _airlock_failure_phase="resource-verify"
      _airlock_failure_app="$app"
      "$ROOT/bin/airlock-ledger" transaction-resource-result \
        verify "$app" passed >/dev/null \
        || die "packaged app '$app': resource verification failed; compensating"
    fi
    _airlock_failure_phase="commit"
    _airlock_failure_app="$app"
    printf '%s' "$AIRLOCK_PKG_INFO" | "$ROOT/bin/airlock-ledger" commit "$app" \
      --active-ports "$_active_ports" \
      || { log "installed-state ledger commit failed for '$app' (intent kept; the next run repairs it)"; _commit_fail=1; }
  done
  [ "$smoke_fail" = 0 ] || die "one or more app smokes failed"
  [ "$_commit_fail" = 0 ] || die "one or more ledger commits failed (see above)"

  # Config removals are last. They cannot strand an app that has not reached
  # its own install/smoke/commit turn, and they remain compensatable because
  # their committed artifacts were checkpointed with the rest of the plan.
  while IFS=$'\t' read -r _action _id; do
    [ -n "${_action:-}" ] || continue
    case " $_removed_ids " in *" $_id "*) continue ;; esac
    _airlock_failure_phase="remove"
    _airlock_failure_app="$_id"
    "$ROOT/bin/airlock-ledger" transaction-touch "$_id"
    printf '%s' "$AIRLOCK_PKG_INFO" \
      | "$ROOT/bin/airlock-ledger" preflight-remove "$_id" --active-ports "$_active_ports" >/dev/null
    "$ROOT/bin/airlock-ledger" transaction-deactivated "$_id"
    log "reconcile: removing '$_id' after desired apps committed"
    printf '%s' "$AIRLOCK_PKG_INFO" \
      | "$ROOT/bin/airlock-ledger" remove "$_id" --active-ports "$_active_ports" \
      || die "could not remove '$_id'; compensating the touched transaction"
    _airlock_removed_after_first_reload=1
  done <<<"$_remove_plan"

  # The first reload happens while retiring packages still own their fragments: removal
  # is deliberately last so every desired app has committed before old state disappears.
  # Publish that last mutation too. Without this reload nginx keeps the deleted proxy
  # location in memory and answers 502 against its now-stopped upstream until another
  # install happens to reload it.
  if [ "$_airlock_removed_after_first_reload" = 1 ]; then
    _airlock_failure_phase="remove-publish"
    _airlock_failure_app="-"
    log "reloading nginx after retired package fragments were removed"
    airlock_run sudo nginx -t
    _airlock_mark_nginx_restore_owed
    airlock_run sudo systemctl reload nginx
  fi
fi
_airlock_failure_app="-"
_airlock_failure_phase="frontend-check"

# 6b) the layer in front of the loopback smokes: is the serve mapping assembled, is TLS
# terminating, is something alive behind it. Skips itself, loudly, under a dry run.
serve_rc=0; airlock_serve_check || serve_rc=$?
# 2 = the check could not run and said why. Not a pass, and not a reason to abort a
# finished install — the closing lines below already refuse to claim what was not
# established.
[ "$serve_rc" != 1 ] || die "the apps are up but the tailscale serve frontend is not — fix that before handing this box over"

# Trust-on-first-use records are the final write of a successful real run.
# Validation, install, smoke, ledger, and the runnable serve check have all
# crossed their fatal edges above. A dry run never writes machine trust state.
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  if [ "$_airlock_transaction_active" = 1 ] && [ "$_airlock_managed_mode" = 1 ]; then
    _airlock_failure_phase="trusted-measurer-stage"
    _airlock_failure_app="-"
    _airlock_trusted_measurer_root stage "$_airlock_transaction_id" \
      "$_airlock_managed_installed_measurer_sha256" \
      "$_airlock_managed_next_measurer_sha256" \
      "$_airlock_managed_next_measurer" \
      || die "could not stage the frozen trusted measurer; apps will be restored"
    "$ROOT/bin/airlock-ledger" transaction-trusted-measurer-owed \
      || die "could not durably bind trusted measurer activation; apps will be restored"
  fi
  _airlock_failure_phase="lock-finalize"
  _airlock_failure_app="-"
  if [ "${#_airlock_lifecycle_args[@]}" -eq 1 ]; then
    airlock_config lock-finalize "$_breakglass_receipt" || exit 2
  else
    airlock_config lock-finalize || exit 2
  fi
  if [ "$_airlock_transaction_active" = 1 ]; then
    _airlock_failure_phase="transaction-commit"
    "$ROOT/bin/airlock-ledger" transaction-finish committed
    _airlock_transaction_active=0
  fi
  if [ "$_airlock_managed_mode" = 1 ] && [ -n "$_airlock_transaction_id" ]; then
    _airlock_failure_phase="post-commit-trusted-measurer"
    _airlock_trusted_measurer_root forward "$_airlock_transaction_id" \
      "$_airlock_managed_installed_measurer_sha256" \
      "$_airlock_managed_next_measurer_sha256" \
      || die "apps are committed but trusted measurer activation durability is unverified; re-run the installer"
    "$ROOT/bin/airlock-ledger" transaction-trusted-measurer-durable \
      || die "apps are committed but durable trusted measurer activation was not recorded; re-run the installer"
    _airlock_trusted_measurer_root cleanup "$_airlock_transaction_id" \
      "$_airlock_managed_installed_measurer_sha256" \
      "$_airlock_managed_next_measurer_sha256" \
      || die "apps are committed and trusted measurer is durable, but verified staging cleanup remains; re-run the installer"
  fi
  # Past the commit there is nothing to roll back to: activation moves forward or
  # stops and says so, with the legacy DB and its backup intact for the next run.
  if [ "$_ledger_gate" = 1 ]; then
    _airlock_failure_phase="post-commit-activation"
    _airlock_devmon_activate_owed commit \
      || die "the install is committed but dev-monitor activation did not finish; its messages database is intact — re-run the installer to resume (bin/airlock-status)"
  fi
fi

# The closing lines name the URL to open and then name what was not established. The
# second is not a footnote on the first: an install that ends "done" while the box is
# unreachable is the failure this whole check exists for, and only the operator, on
# another device, can rule it out.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "done (dry run — nothing was changed). You would open: https://<your-box>.<tailnet>.ts.net/"
else
  log "done. Open: $(airlock_entrance_url)"
  airlock_ingress_unverified
fi
