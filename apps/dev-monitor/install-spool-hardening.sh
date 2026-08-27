#!/usr/bin/env bash
# Install the dev-monitor spool writer identity, directory boundary and UID egress rule.
# This entry point is intentionally standalone: cutover can establish the prerequisite
# without starting or replacing either console.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$HERE/render.sh"

STATE_OVERRIDE=""
MESSAGES_OVERRIDE=""
WRITER_USER_OVERRIDE=""
WRITER_GROUP_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --state) STATE_OVERRIDE="${2:?}"; shift 2 ;;
    --messages) MESSAGES_OVERRIDE="${2:?}"; shift 2 ;;
    --writer-user) WRITER_USER_OVERRIDE="${2:?}"; shift 2 ;;
    --writer-group) WRITER_GROUP_OVERRIDE="${2:?}"; shift 2 ;;
    *) die "usage: install-spool-hardening.sh [--state DIR] [--messages BOOL] [--writer-user NAME] [--writer-group NAME]" ;;
  esac
done

if [ -z "$MESSAGES_OVERRIDE$WRITER_USER_OVERRIDE$WRITER_GROUP_OVERRIDE" ]; then
  airlock_load dev-monitor
fi
MESSAGES="${MESSAGES_OVERRIDE:-${AIRLOCK_DEV_MONITOR_MESSAGES:-false}}"
WRITER_USER="${WRITER_USER_OVERRIDE:-${AIRLOCK_DEV_MONITOR_SPOOL_WRITER_USER:-airlock-dev-monitor-writer}}"
WRITER_GROUP="${WRITER_GROUP_OVERRIDE:-${AIRLOCK_DEV_MONITOR_SPOOL_WRITER_GROUP:-airlock-dev-monitor-writers}}"
DEVMON_STATE="${STATE_OVERRIDE:-$HOME/.local/state/airlock/dev-monitor}"
NFT_FILE="/etc/airlock/dev-monitor-spool.nft"
NFT_UNIT="/etc/systemd/system/airlock-dev-monitor-spool-firewall.service"
GUARD_FILE="/opt/airlock/libexec/airlock-dev-monitor-spool-firewall"
NFT=/usr/sbin/nft
USERADD=/usr/sbin/useradd
GROUPADD=/usr/sbin/groupadd
SETPRIV=/usr/bin/setpriv

if [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  NFT_FILE="$AIRLOCK_RENDER_DIR/etc-airlock/dev-monitor-spool.nft"
  NFT_UNIT="$AIRLOCK_RENDER_DIR/etc-systemd-system/airlock-dev-monitor-spool-firewall.service"
  GUARD_FILE="$AIRLOCK_RENDER_DIR/opt-airlock-libexec/airlock-dev-monitor-spool-firewall"
fi

case "$MESSAGES" in true|false) ;; *) die "--messages must be true or false" ;; esac

valid_account_name() {
  local value="$1"
  [ "${#value}" -le 32 ] || return 1
  case "$value" in
    [a-z_]* ) ;;
    * ) return 1 ;;
  esac
  case "$value" in *[!a-z0-9_-]* ) return 1 ;; esac
}
valid_account_name "$WRITER_USER" \
  || die "apps.dev-monitor.spool_writer_user must be a lowercase system account name"
valid_account_name "$WRITER_GROUP" \
  || die "apps.dev-monitor.spool_writer_group must be a lowercase system group name"
[ "$WRITER_USER" != root ] || die "spool writer must not be root"

# With messages off there is no writer surface to defend. Remove a prior conditional
# artifact, but do not introduce a sudo/nft dependency on the observability-only install.
if [ "$MESSAGES" != true ]; then
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
    log "[dry] disable airlock-dev-monitor-spool-firewall.service (messages off)"
  elif [ -z "${AIRLOCK_RENDER_DIR:-}" ] \
       && { [ -e "$NFT_FILE" ] || [ -e "$NFT_UNIT" ] || [ -e "$GUARD_FILE" ]; }; then
    require_cmd sudo systemctl
    [ -x "$NFT" ] || die "nft executable is missing"
    if sudo systemctl is-enabled --quiet airlock-dev-monitor-spool-firewall.service 2>/dev/null \
       || sudo systemctl is-active --quiet airlock-dev-monitor-spool-firewall.service 2>/dev/null; then
      sudo systemctl disable --now airlock-dev-monitor-spool-firewall.service
    fi
    if sudo "$NFT" list table inet airlock_dev_monitor_spool >/dev/null 2>&1; then
      sudo "$NFT" destroy table inet airlock_dev_monitor_spool
    fi
    sudo rm -f "$NFT_FILE" "$NFT_UNIT" "$GUARD_FILE"
    sudo systemctl daemon-reload
  fi
  exit 0
fi

if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] create/verify system writer $WRITER_USER:$WRITER_GROUP"
  log "[dry] harden $DEVMON_STATE/spool and enable UID egress firewall"
  exit 0
fi

# Render mode exercises the exact rooted artifacts without consulting or changing the
# host account database. nft resolves the configured name to the box-assigned UID only
# when the real system unit loads the ruleset.
if [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  install -d "$(dirname "$NFT_FILE")" "$(dirname "$NFT_UNIT")" "$(dirname "$GUARD_FILE")"
  render_dev_monitor_spool_nft "$WRITER_USER" >"$NFT_FILE"
  render_dev_monitor_spool_firewall_guard "$WRITER_USER" \
    /etc/airlock/dev-monitor-spool.nft >"$GUARD_FILE"
  chmod 755 "$GUARD_FILE"
  render_dev_monitor_spool_firewall_unit >"$NFT_UNIT"
  exit 0
fi

require_cmd getent id sudo systemctl stat grep cut awk install mktemp mv setpriv
[ -x "$NFT" ] || die "nft executable is missing"
[ -x "$USERADD" ] || die "useradd executable is missing"
[ -x "$GROUPADD" ] || die "groupadd executable is missing"

if ! getent group "$WRITER_GROUP" >/dev/null; then
  sudo "$GROUPADD" --system "$WRITER_GROUP"
fi
expected_gid="$(getent group "$WRITER_GROUP" | cut -d: -f3)"
[ -n "$expected_gid" ] || die "cannot resolve spool writer group"

if ! getent passwd "$WRITER_USER" >/dev/null; then
  sudo "$USERADD" --system --gid "$WRITER_GROUP" --no-create-home \
    --home-dir /nonexistent --shell /usr/sbin/nologin "$WRITER_USER"
fi
writer_uid="$(id -u "$WRITER_USER")"
writer_gid="$(id -g "$WRITER_USER")"
writer_shell="$(getent passwd "$WRITER_USER" | cut -d: -f7)"
writer_home="$(getent passwd "$WRITER_USER" | cut -d: -f6)"
writer_groups="$(id -G "$WRITER_USER")"
group_members="$(getent group "$WRITER_GROUP" | cut -d: -f4)"
uid_min="$(awk '$1 == "UID_MIN" { print $2; exit }' /etc/login.defs)"
gid_min="$(awk '$1 == "GID_MIN" { print $2; exit }' /etc/login.defs)"
other_primary="$(getent passwd | awk -F: -v gid="$expected_gid" -v user="$WRITER_USER" \
  '$4 == gid && $1 != user { print $1; exit }')"
case "$writer_uid:$writer_gid" in *[!0-9:]*|:*|*:) die "cannot resolve numeric spool writer identity" ;; esac
case "$uid_min:$gid_min" in *[!0-9:]*|:*|*:) die "cannot resolve system account ranges" ;; esac
[ "$writer_uid" != 0 ] || die "spool writer unexpectedly resolves to uid 0"
[ "$writer_uid" -lt "$uid_min" ] || die "spool writer must be a system UID"
[ "$expected_gid" -lt "$gid_min" ] || die "spool writer group must be a system GID"
[ "$writer_home" = /nonexistent ] \
  || die "spool writer must use the dedicated /nonexistent home"
[ "$writer_gid" = "$expected_gid" ] \
  || die "existing spool writer does not use the configured primary group"
case "$writer_shell" in
  */nologin|*/false) ;;
  *) die "existing spool writer is a login account; refusing to apply an egress block" ;;
esac
[ "$writer_groups" = "$expected_gid" ] \
  || die "spool writer must not belong to supplementary groups"
case "$group_members" in
  ""|"$WRITER_USER") ;;
  *) die "spool writer group has another explicit member" ;;
esac
[ -z "$other_primary" ] || die "spool writer group is another account's primary group"

operator="$(id -un)"
operator_group="$(id -gn)"
operator_uid="$(id -u)"
[ "$WRITER_USER" != "$operator" ] || die "spool writer must be separate from the operator"
[ "$WRITER_GROUP" != "$operator_group" ] \
  || die "spool writer group must be separate from the operator primary group"

stage="$(mktemp -d "${TMPDIR:-/tmp}/airlock-devmon-firewall.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
render_dev_monitor_spool_nft "$WRITER_USER" >"$stage/rules.nft"
render_dev_monitor_spool_firewall_guard "$WRITER_USER" "$NFT_FILE" >"$stage/guard"
render_dev_monitor_spool_firewall_unit >"$stage/unit"
chmod 600 "$stage/rules.nft" "$stage/unit"
chmod 700 "$stage/guard"
sudo "$NFT" -c -f "$stage/rules.nft"
sudo install -d -m 755 /etc/airlock /opt/airlock/libexec
sudo install -m 600 -o root -g root "$stage/rules.nft" "${NFT_FILE}.new"
sudo install -m 755 -o root -g root "$stage/guard" "${GUARD_FILE}.new"
sudo install -m 644 -o root -g root "$stage/unit" "${NFT_UNIT}.new"
sudo mv -f "${NFT_FILE}.new" "$NFT_FILE"
sudo mv -f "${GUARD_FILE}.new" "$GUARD_FILE"
sudo mv -f "${NFT_UNIT}.new" "$NFT_UNIT"
sudo systemctl daemon-reload
sudo systemctl enable airlock-dev-monitor-spool-firewall.service
if sudo systemctl is-active --quiet airlock-dev-monitor-spool-firewall.service; then
  sudo systemctl reload airlock-dev-monitor-spool-firewall.service
else
  sudo systemctl start airlock-dev-monitor-spool-firewall.service
fi
sudo systemctl is-active --quiet airlock-dev-monitor-spool-firewall.service
sudo "$NFT" -n list table inet airlock_dev_monitor_spool \
  | grep -Eq "skuid[[:space:]]+${writer_uid}([^0-9]|$)" \
  || die "spool writer UID egress rule is not active"

# The firewall is active before the writer gains spool access. Run directory operations
# with the operator UID (and only the writer group as EGID), never root: a symlink planted
# anywhere below the user-owned state path therefore cannot turn install(1) into a root
# chown/chmod primitive.
safe_user_dir() {
  local path="$1"
  [ ! -L "$path" ] || die "refusing symlink in spool state: $path"
  { [ ! -e "$path" ] || [ -d "$path" ]; } || die "spool state path is not a directory: $path"
}
for path in "$DEVMON_STATE" "$DEVMON_STATE/spool" \
  "$DEVMON_STATE/spool/tmp" "$DEVMON_STATE/spool/new" \
  "$DEVMON_STATE/spool/processing" "$DEVMON_STATE/spool/bad"; do
  safe_user_dir "$path"
done
as_operator_writer() {
  # Some sudoers policies grant passwordless runas-user but not runas-group. Enter through
  # the explicit root:root rule, then drop both IDs before touching the user-owned tree.
  # The directory operation therefore retains the original non-root symlink boundary.
  sudo -u root -g root "$SETPRIV" --reuid "$operator_uid" \
    --regid "$expected_gid" --clear-groups -- "$@"
}
as_operator_writer /usr/bin/install -d -m 710 \
  -o "$operator" -g "$WRITER_GROUP" -- "$DEVMON_STATE" "$DEVMON_STATE/spool"
as_operator_writer /usr/bin/install -d -m 3770 \
  -o "$operator" -g "$WRITER_GROUP" -- \
  "$DEVMON_STATE/spool/tmp" "$DEVMON_STATE/spool/new"
install -d -m 700 -o "$operator" -g "$operator_group" -- \
  "$DEVMON_STATE/spool/processing" "$DEVMON_STATE/spool/bad"

expect_dir() {
  local path="$1" mode="$2" owner="$3" group="$4" actual
  actual="$(stat -c '%a:%U:%G' "$path")"
  [ "$actual" = "$mode:$owner:$group" ] \
    || die "spool hardening verification failed for $path"
}
expect_dir "$DEVMON_STATE/spool" 710 "$operator" "$WRITER_GROUP"
expect_dir "$DEVMON_STATE" 710 "$operator" "$WRITER_GROUP"
expect_dir "$DEVMON_STATE/spool/tmp" 3770 "$operator" "$WRITER_GROUP"
expect_dir "$DEVMON_STATE/spool/new" 3770 "$operator" "$WRITER_GROUP"
# Walk up until the writer can traverse, and name the first one it cannot. Without this
# the operator is told about a leaf whose own mode is correct — the block is upstream.
first_blocking_ancestor() {
  local path="$1" blocking="$1"
  while [ "$path" != / ] && [ -n "$path" ]; do
    sudo -u "$WRITER_USER" test -x "$path" || blocking="$path"
    path="$(dirname "$path")"
  done
  printf '%s' "$blocking"
}

expect_dir "$DEVMON_STATE/spool/processing" 700 "$operator" "$operator_group"
expect_dir "$DEVMON_STATE/spool/bad" 700 "$operator" "$operator_group"

# Check the effective cross-UID boundary as well as leaf metadata. This catches a 0700
# ancestor that would silently make the configured writer unusable on another box.
#
# Each carries its own message because THIS GUARD WAS ITSELF SILENT. Under `set -e` a
# bare failing `test` ended the script with status 1 and no output at all — so the check
# written to stop a silent failure produced one. Measured 2026-08-22 on a box updating
# to this revision: the install died here four times and the only way to find out why
# was `bash -x` on three nested scripts.
#
# The first line is the one that fires, and `first_blocking_ancestor` says WHICH
# directory did it: the writer is a different uid, so any 0700 on the path defeats it,
# and naming the leaf sends the reader to the wrong place.
sudo -u "$WRITER_USER" test -x "$DEVMON_STATE" \
  || die "spool writer $WRITER_USER cannot reach $DEVMON_STATE — blocked at $(first_blocking_ancestor "$DEVMON_STATE")
       That directory needs to be traversable by the writer (mode 710 with group
       $WRITER_GROUP, or 711). Note install/airlock-install.sh creates the state
       directory 0700 on every run, so widening it by hand does not survive."
sudo -u "$WRITER_USER" test -x "$DEVMON_STATE/spool" \
  || die "spool writer $WRITER_USER cannot enter $DEVMON_STATE/spool (needs mode 710, group $WRITER_GROUP)"
sudo -u "$WRITER_USER" test -w "$DEVMON_STATE/spool/tmp" \
  || die "spool writer $WRITER_USER cannot write $DEVMON_STATE/spool/tmp (needs mode 3770, group $WRITER_GROUP)"
sudo -u "$WRITER_USER" test -w "$DEVMON_STATE/spool/new" \
  || die "spool writer $WRITER_USER cannot write $DEVMON_STATE/spool/new (needs mode 3770, group $WRITER_GROUP)"
if sudo -u "$WRITER_USER" test -x "$DEVMON_STATE/spool/processing" \
   || sudo -u "$WRITER_USER" test -x "$DEVMON_STATE/spool/bad"; then
  die "spool writer can enter a collector-only lane"
fi

log "dev-monitor spool hardening active (writer uid=$writer_uid, external egress blocked)"
