#!/usr/bin/env bash
# The P6 cutover input must switch on the canonical names before the old service stops.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AIRLOCK_PASEO_MEM_CAP_BYTES=8589934592
CFG="$TMP/airlock.toml"
RENDER="$TMP/render"

render_cutover_config() {
  AIRLOCK_CUTOVER_OWNER=owner@example.test \
  AIRLOCK_CUTOVER_SITE_NAME='Test Airlock' \
  AIRLOCK_CUTOVER_CODE_ROOT="$TMP/code" \
  python3 "$ROOT/live/dev-monitor-cutover-config.py"
}

render_cutover_config >"$CFG"
mkdir -p "$TMP/code" "$TMP/home"

AIRLOCK_CONFIG="$CFG" python3 "$ROOT/bin/airlock-config" validate
resolved="$(AIRLOCK_CONFIG="$CFG" python3 "$ROOT/bin/airlock-config" env dev-monitor)"
for line in \
  'AIRLOCK_DEV_MONITOR_MESSAGES=true' \
  'AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS=true' \
  'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT_ENV=DEV_MONITOR_SLACK_WEBHOOK'
do
  grep -qxF "$line" <<<"$resolved"
done

mkdir -p "$TMP/home/.config/airlock"
printf 'DEV_MONITOR_SLACK_WEBHOOK=https://hooks.example.test/existing\n' \
  > "$TMP/home/.config/airlock/dev-monitor-secrets.env"
chmod 600 "$TMP/home/.config/airlock/dev-monitor-secrets.env"

AIRLOCK_CONFIG="$CFG" \
AIRLOCK_DRY_RUN=1 \
AIRLOCK_RENDER_DIR="$RENDER" \
AIRLOCK_TS_FQDN=box.example.test \
DEV_MONITOR_SLACK_WEBHOOK=https://hooks.example.test/existing \
HOME="$TMP/home" \
AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/dev-monitor" AIRLOCK_APP_ID=dev-monitor \
  bash "$ROOT/apps/dev-monitor/install.sh" >/dev/null 2>&1

unit="$RENDER/units/airlock-dev-monitor.service"
env_file="$RENDER/files/dev-monitor.env"
nft_file="$RENDER/etc-airlock/dev-monitor-spool.nft"
firewall_unit="$RENDER/etc-systemd-system/airlock-dev-monitor-spool-firewall.service"
firewall_guard="$RENDER/opt-airlock-libexec/airlock-dev-monitor-spool-firewall"
grep -qxF 'Environment=AIRLOCK_DEV_MONITOR_MESSAGES=true' "$unit"
grep -qxF 'Environment=AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS=true' "$unit"
grep -qxF 'DEVMON_SLACK_WEBHOOK_NAME=DEV_MONITOR_SLACK_WEBHOOK' "$env_file"
grep -qxF 'EnvironmentFile=-%h/.config/airlock/dev-monitor-secrets.env' "$unit"
if grep -qrF 'https://hooks.example.test/existing' "$RENDER"; then
  echo 'credential value was copied into render output' >&2
  exit 1
fi
[ "$(stat -c %a "$env_file")" = 600 ]
[ ! -e "$RENDER/files/dev-monitor-compat.env" ]
if grep -Eq 'slack_webhook_routine_env|roster_path|compat_env_path|smtp_' "$CFG"; then
  echo 'removed app key emitted by cutover generator' >&2
  exit 1
fi
grep -qxF 'ExecStartPre=/usr/bin/systemctl is-active --quiet airlock-dev-monitor-spool-firewall.service' "$unit"
grep -qF 'meta skuid "airlock-dev-monitor-writer"' "$nft_file"
grep -qxF 'Type=notify' "$firewall_unit"
grep -qxF "WRITER_UID=\"\$(/usr/bin/id -u airlock-dev-monitor-writer)\"" "$firewall_guard"

sed 's/messages = true/messages = false/' "$CFG" >"$TMP/config-off.toml"
mkdir -p "$TMP/render-off/files"
AIRLOCK_CONFIG="$TMP/config-off.toml" AIRLOCK_DRY_RUN=1 \
AIRLOCK_RENDER_DIR="$TMP/render-off" \
AIRLOCK_TS_FQDN=box.example.test \
HOME="$TMP/home" AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/dev-monitor" AIRLOCK_APP_ID=dev-monitor \
  bash "$ROOT/apps/dev-monitor/install.sh" >/dev/null 2>&1
[ ! -e "$TMP/render-off/files/dev-monitor-compat.env" ]
grep -qxF 'DEV_MONITOR_OWNER=owner@example.test' "$TMP/render-off/files/dev-monitor.env"
if grep -q '^DEV_MONITOR_SPOOL=' "$TMP/render-off/files/dev-monitor.env"; then
  echo 'messages=false retained message spool config' >&2
  exit 1
fi

echo 'dev-monitor cutover config: ok'
