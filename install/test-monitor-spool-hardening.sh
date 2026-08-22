#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/airlock-devmon-hardening.XXXXXX)"
HOST_PROBE=0
cleanup() {
  if [ "$HOST_PROBE" = 1 ]; then
    sudo -n rm -rf "$TMP" 2>/dev/null || true
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT
CFG="$TMP/airlock.toml"
RENDER="$TMP/render"

cat >"$CFG" <<'TOML'
[airlock]
config_version = 2
[site]
name = "test"
[auth]
provider = "tailscale"
owner = "owner@example.test"
[apps.dev-monitor]
messages = true
spool_writer_user = "fixture-writer"
spool_writer_group = "fixture-writers"
TOML

AIRLOCK_CONFIG="$CFG" AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$RENDER" \
  bash "$ROOT/apps/dev-monitor/install-spool-hardening.sh"
nft_file="$RENDER/etc-airlock/dev-monitor-spool.nft"
unit_file="$RENDER/etc-systemd-system/airlock-dev-monitor-spool-firewall.service"
guard_file="$RENDER/opt-airlock-libexec/airlock-dev-monitor-spool-firewall"
grep -qxF '    meta skuid "fixture-writer" oifname "lo" accept' "$nft_file"
grep -qxF '    meta skuid "fixture-writer" reject with icmpx type admin-prohibited' "$nft_file"
grep -qxF 'destroy table inet airlock_dev_monitor_spool' "$nft_file"
grep -qxF 'Type=notify' "$unit_file"
grep -qxF 'Before=network-pre.target' "$unit_file"
grep -qxF 'ExecStart=/opt/airlock/libexec/airlock-dev-monitor-spool-firewall' "$unit_file"
grep -qxF 'ExecReload=/usr/sbin/nft -f /etc/airlock/dev-monitor-spool.nft' "$unit_file"
grep -qxF "WRITER_UID=\"\$(/usr/bin/id -u fixture-writer)\"" "$guard_file"
grep -qxF '/usr/bin/systemd-notify --ready' "$guard_file"
grep -qxF 'while /bin/sleep 1; do' "$guard_file"

# The user service must refuse to start when the system firewall unit is not active, while
# messages=false remains an observability-only unit with no system-scope dependency.
# shellcheck source=/dev/null
. "$ROOT/apps/dev-monitor/render.sh"
guarded="$(render_dev_monitor_unit 18804 true Tailscale-User-Login box.example.test,box /tmp/devmon.env false 24 24 true)"
plain="$(render_dev_monitor_unit 18804 false Tailscale-User-Login box.example.test,box /tmp/devmon.env false 24 24 false)"
grep -qxF 'ExecStartPre=/usr/bin/systemctl is-active --quiet airlock-dev-monitor-spool-firewall.service' <<<"$guarded"
if grep -qF 'airlock-dev-monitor-spool-firewall.service' <<<"$plain"; then
  echo 'messages-off unit unexpectedly requires spool firewall' >&2
  exit 1
fi

# The repository CI intentionally has no nft/daemon dependency. Keep the exact render and
# fail-closed assertions mandatory everywhere, then add the kernel/cross-UID probe wherever
# the host explicitly offers nft and passwordless sudo. Live phase verification always does.
if [ -x /usr/sbin/nft ] && id nobody >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  HOST_PROBE=1
  sed 's/"fixture-writer"/"nobody"/g' "$nft_file" >"$TMP/nft-parse.nft"
  sudo -n /usr/sbin/nft -c -f "$TMP/nft-parse.nft"

  # Exercise the permission model with a real second UID, entirely under a disposable path.
  writer_user=nobody
  writer_group="$(id -gn "$writer_user")"
  writer_gid="$(id -g "$writer_user")"
  operator="$(id -un)"
  operator_uid="$(id -u)"
  operator_group="$(id -gn)"
  state="$TMP/state"
  chmod 711 "$TMP"
  sudo -n install -d -m 710 -o "$operator" -g "$writer_group" "$state"
  sudo -n install -d -m 710 -o "$operator" -g "$writer_group" "$state/spool"
  sudo -n install -d -m 3770 -o "$operator" -g "$writer_group" \
    "$state/spool/tmp" "$state/spool/new"
  sudo -n install -d -m 700 -o "$operator" -g "$operator_group" \
    "$state/spool/processing" "$state/spool/bad"

# Simulate the real backend startup first. Both init_db() and ensure_dirs() must preserve
# the installer boundary, then the second UID publishes and the collector ingests it.
AIRLOCK_DEV_MONITOR_MESSAGES=true \
PYTHONPATH="$ROOT/apps/dev-monitor/backend" python3 - "$state" <<'PY'
import os, sys
import devmon_messages as messages
import devmon_spool as spool
state = sys.argv[1]
messages.init_db(os.path.join(state, 'messages.db'))
spool.ensure_dirs(os.path.join(state, 'spool'))
PY
install -m 755 "$ROOT/apps/dev-monitor/examples/emit_message.py" "$TMP/emit_message.py"
  sudo -n -u "$writer_user" python3 "$TMP/emit_message.py" \
  --spool "$state/spool" --source phase3 --group-key phase3:cross-uid \
  --kind info --title 'cross uid probe' --event-id phase3-cross-uid >/dev/null
AIRLOCK_DEV_MONITOR_MESSAGES=true \
PYTHONPATH="$ROOT/apps/dev-monitor/backend" python3 - "$state" <<'PY'
import os, sys
import devmon_messages as messages
import devmon_spool as spool
state = sys.argv[1]
messages.init_db(os.path.join(state, 'messages.db'))
spool.ensure_dirs(os.path.join(state, 'spool'))
result = spool.scan_once(os.path.join(state, 'spool'))
assert result['inserted'] == 1, result
assert messages._conn().execute(
    'SELECT COUNT(*) FROM occurrences WHERE event_id=?',
    ('phase3-cross-uid',)).fetchone()[0] == 1
PY
  if sudo -n -u "$writer_user" sh -c \
       "test -r '$state/spool/processing' || touch '$state/spool/processing/escape'" \
       2>/dev/null; then
    echo 'writer reached collector-only processing lane' >&2
    exit 1
  fi

# Regression for the privilege boundary: even if a user-owned spool leaf is swapped to a
# symlink, the directory command used by the real installer runs with the operator UID and
# cannot chmod/chgrp a root-owned target through it.
root_target="$TMP/root-target"
  sudo -n install -d -m 755 -o root -g root "$root_target"
  ln -s "$root_target" "$TMP/hostile-leaf"
  if sudo -n -u root -g root /usr/bin/setpriv --reuid "$operator_uid" \
       --regid "$writer_gid" --clear-groups -- /usr/bin/install -d -m 710 \
       -o "$operator" -g "$writer_group" -- "$TMP/hostile-leaf" 2>/dev/null; then
    echo 'non-root directory install unexpectedly followed and changed a root target' >&2
    exit 1
  fi
  test "$(stat -c '%a:%U:%G' "$root_target")" = 755:root:root
else
  echo 'skip: host nft/cross-UID probe unavailable (offline assertions still passed)'
fi

# Pin the installer's verification and fail-closed actions so a future simplification
# cannot retain only the rendered comments while dropping the enforcement.
grep -qF 'systemctl reload airlock-dev-monitor-spool-firewall.service' \
  "$ROOT/apps/dev-monitor/install-spool-hardening.sh"
grep -qF "\"\$NFT\" -n list table inet airlock_dev_monitor_spool" \
  "$ROOT/apps/dev-monitor/install-spool-hardening.sh"
grep -qF 'install -d -m 3770' \
  "$ROOT/apps/dev-monitor/install-spool-hardening.sh"
grep -qF 'spool writer must not belong to supplementary groups' \
  "$ROOT/apps/dev-monitor/install-spool-hardening.sh"
grep -qF 'spool writer group has another explicit member' \
  "$ROOT/apps/dev-monitor/install-spool-hardening.sh"
grep -qF 'spool writer can enter a collector-only lane' \
  "$ROOT/apps/dev-monitor/install-spool-hardening.sh"
# The cross-UID probes must SAY something when they refuse. They used to be four bare
# `test` commands under `set -e`, so the check written to catch a silent failure was
# itself silent: exit 1, no output, on a real box. Pinning the messages is a text check
# and cannot prove the script is not silent — what it does catch is the regression that
# actually happened, someone dropping the `|| die` back off. A behavioural check would
# have to run the hardening script against a 0700 ancestor, and that path installs a
# system firewall unit, so it belongs in live phase verification rather than here.
for _msg in 'cannot reach' 'cannot enter' 'cannot write'; do
  grep -qF "$_msg" "$ROOT/apps/dev-monitor/install-spool-hardening.sh" || {
    echo "cross-UID probe lost its message (\"$_msg\") — a failure here would be silent again" >&2
    exit 1
  }
done
grep -qF 'first_blocking_ancestor' "$ROOT/apps/dev-monitor/install-spool-hardening.sh" || {
  echo 'the blocked-ancestor message no longer names which directory blocked' >&2
  exit 1
}
grep -qF "sudo -u root -g root \"\$SETPRIV\" --reuid \"\$operator_uid\"" \
  "$ROOT/apps/dev-monitor/install-spool-hardening.sh"
if grep -qF 'sudo install -d -m 710' "$ROOT/apps/dev-monitor/install-spool-hardening.sh"; then
  echo 'root install unexpectedly touches the user-owned state path' >&2
  exit 1
fi

echo 'dev-monitor spool hardening: ok'
