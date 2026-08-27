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
  AIRLOCK_CUTOVER_ROSTER_PATH="$TMP/roster.json" \
  AIRLOCK_CUTOVER_COMPAT_ENV_PATH="$1" \
  python3 "$ROOT/live/dev-monitor-cutover-config.py"
}

render_cutover_config "$TMP/home/.config/dev-monitor.env" >"$CFG"
mkdir -p "$TMP/code" "$TMP/home"

AIRLOCK_CONFIG="$CFG" python3 "$ROOT/bin/airlock-config" validate
resolved="$(AIRLOCK_CONFIG="$CFG" python3 "$ROOT/bin/airlock-config" env dev-monitor)"
for line in \
  'AIRLOCK_DEV_MONITOR_MESSAGES=true' \
  'AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS=true' \
  'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT_ENV=DEV_MONITOR_SLACK_WEBHOOK' \
  'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE_ENV=DEV_MONITOR_SLACK_WEBHOOK' \
  "AIRLOCK_DEV_MONITOR_COMPAT_ENV_PATH=$TMP/home/.config/dev-monitor.env"
do
  grep -qxF "$line" <<<"$resolved"
done

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
compat_env="$RENDER/files/dev-monitor-compat.env"
nft_file="$RENDER/etc-airlock/dev-monitor-spool.nft"
firewall_unit="$RENDER/etc-systemd-system/airlock-dev-monitor-spool-firewall.service"
firewall_guard="$RENDER/opt-airlock-libexec/airlock-dev-monitor-spool-firewall"
grep -qxF 'Environment=AIRLOCK_DEV_MONITOR_MESSAGES=true' "$unit"
grep -qxF 'Environment=AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS=true' "$unit"
grep -qxF 'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT=https://hooks.example.test/existing' "$env_file"
grep -qxF 'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE=https://hooks.example.test/existing' "$env_file"
grep -qxF 'DEV_MONITOR_SMTP_HOST=' "$env_file"
grep -qxF "DEV_MONITOR_SPOOL=$TMP/home/.local/state/airlock/dev-monitor/spool" "$compat_env"
grep -qxF "DEV_MONITOR_DB=$TMP/home/.local/state/airlock/dev-monitor/messages.db" "$compat_env"
grep -qxF 'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT=https://hooks.example.test/existing' "$compat_env"
grep -qxF 'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE=https://hooks.example.test/existing' "$compat_env"
if grep -Ev '^#' "$compat_env" | grep -Eq 'OWNER|PROXY|SMTP|EXEC|PASSWORD'; then
  echo 'compatibility env contains a forbidden backend-only key' >&2
  exit 1
fi
[ "$(stat -c %a "$compat_env")" = 600 ]
[ "$(stat -c %F "$compat_env")" = 'regular file' ]
[ "$(grep -Evc '^(#|$)' "$compat_env")" = 4 ]
grep -qxF 'ExecStartPre=/usr/bin/systemctl is-active --quiet airlock-dev-monitor-spool-firewall.service' "$unit"
grep -qF 'meta skuid "airlock-dev-monitor-writer"' "$nft_file"
grep -qxF 'Type=notify' "$firewall_unit"
grep -qxF "WRITER_UID=\"\$(/usr/bin/id -u airlock-dev-monitor-writer)\"" "$firewall_guard"

ln -s "$TMP/compat-target" "$TMP/compat-link"
render_cutover_config "$TMP/compat-link" >"$TMP/config-symlink.toml"
if output=$(AIRLOCK_CONFIG="$TMP/config-symlink.toml" AIRLOCK_DRY_RUN=1 \
    AIRLOCK_RENDER_DIR="$TMP/render-symlink" \
    AIRLOCK_TS_FQDN=box.example.test \
    DEV_MONITOR_SLACK_WEBHOOK=https://hooks.example.test/existing \
    HOME="$TMP/home" AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/dev-monitor" AIRLOCK_APP_ID=dev-monitor \
  bash "$ROOT/apps/dev-monitor/install.sh" 2>&1); then
  echo 'compatibility env symlink unexpectedly accepted' >&2
  exit 1
fi
grep -qF 'compatibility env path must not be a symbolic link' <<<"$output"

alias_path="$TMP/home/.config/airlock/../airlock/dev-monitor.env"
render_cutover_config "$alias_path" >"$TMP/config-alias.toml"
if output=$(AIRLOCK_CONFIG="$TMP/config-alias.toml" AIRLOCK_DRY_RUN=1 \
    AIRLOCK_RENDER_DIR="$TMP/render-alias" \
    AIRLOCK_TS_FQDN=box.example.test \
    DEV_MONITOR_SLACK_WEBHOOK=https://hooks.example.test/existing \
    HOME="$TMP/home" AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/dev-monitor" AIRLOCK_APP_ID=dev-monitor \
  bash "$ROOT/apps/dev-monitor/install.sh" 2>&1); then
  echo 'canonical env alias unexpectedly accepted as compatibility path' >&2
  exit 1
fi
grep -qF 'compatibility env path must differ from the canonical backend env' <<<"$output"

sed 's/messages = true/messages = false/' "$CFG" >"$TMP/config-off.toml"
mkdir -p "$TMP/render-off/files"
printf 'stale\n' >"$TMP/render-off/files/dev-monitor-compat.env"
AIRLOCK_CONFIG="$TMP/config-off.toml" AIRLOCK_DRY_RUN=1 \
AIRLOCK_RENDER_DIR="$TMP/render-off" \
AIRLOCK_TS_FQDN=box.example.test \
HOME="$TMP/home" AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/dev-monitor" AIRLOCK_APP_ID=dev-monitor \
  bash "$ROOT/apps/dev-monitor/install.sh" >/dev/null 2>&1
[ ! -e "$TMP/render-off/files/dev-monitor-compat.env" ]

echo 'dev-monitor cutover config: ok'
