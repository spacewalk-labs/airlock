#!/usr/bin/env bash
# Mode 644: the orchestrator invokes lifecycle scripts with bash.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run through the Airlock installer, or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID explicitly}"
HERE="${AIRLOCK_APP_DIR:-$HERE}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-slack-unfurl}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$HERE/render.sh"

require_cmd python3 systemctl
airlock_load slack-unfurl

DOMAIN="${AIRLOCK_SLACK_UNFURL_DOMAIN_SUFFIX:?}"
DEDICATED_PORTS="${AIRLOCK_SLACK_UNFURL_DEDICATED_PORTS:?}"
BOT_TOKEN_NAME="${AIRLOCK_SLACK_UNFURL_BOT_TOKEN_ENV:?}"
APP_TOKEN_NAME="${AIRLOCK_SLACK_UNFURL_APP_TOKEN_ENV:?}"

# Validate public configuration before writing or restarting anything. Token
# values are intentionally neither needed nor read during installation.
python3 "$HERE/backend/slack_unfurl.py" --check-config \
  "$DOMAIN" "$DEDICATED_PORTS" "$BOT_TOKEN_NAME" "$APP_TOKEN_NAME"

APP_DIR_LOCAL="$HOME/.local/share/airlock-slack-unfurl"
UNIT_DIR="$HOME/.config/systemd/user"
SECRET_ENV_FILE="$HOME/.config/airlock-slack-unfurl.env"

# The unit deliberately delegates token creation to the operator, but once the
# file exists the installer owns keeping its local boundary narrow. Never
# follow a symlink here: chmodding its target could widen or mutate an unrelated
# file selected outside this package.
if [ -L "$SECRET_ENV_FILE" ]; then
  die "slack-unfurl token EnvironmentFile must not be a symlink: $SECRET_ENV_FILE"
elif [ -e "$SECRET_ENV_FILE" ]; then
  [ -f "$SECRET_ENV_FILE" ] || die "slack-unfurl token EnvironmentFile must be a regular file: $SECRET_ENV_FILE"
  [ -O "$SECRET_ENV_FILE" ] || die "slack-unfurl token EnvironmentFile must be owned by the installing user: $SECRET_ENV_FILE"
  if [ "$(stat -c '%a' -- "$SECRET_ENV_FILE")" != 600 ]; then
    if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
      log "[dry] chmod 0600 $SECRET_ENV_FILE"
    else
      chmod 600 -- "$SECRET_ENV_FILE"
      log "tightened slack-unfurl token EnvironmentFile to mode 0600"
    fi
  fi
fi

[ -n "${AIRLOCK_RENDER_DIR:-}" ] && UNIT_DIR="$AIRLOCK_RENDER_DIR/units"

if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] install Slack unfurl worker -> $APP_DIR_LOCAL/backend"
else
  install -d "$APP_DIR_LOCAL/backend"
  install -m644 "$HERE/backend/slack_unfurl.py" "$APP_DIR_LOCAL/backend/slack_unfurl.py"
  install -m644 "$HERE/backend/socket_mode.py" "$APP_DIR_LOCAL/backend/socket_mode.py"
fi

if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] write $UNIT_DIR/airlock-slack-unfurl.service"
else
  install -d "$UNIT_DIR"
  render_slack_unfurl_unit "$DOMAIN" "$DEDICATED_PORTS" "$BOT_TOKEN_NAME" "$APP_TOKEN_NAME" \
    "$APP_DIR_LOCAL/backend" > "$UNIT_DIR/airlock-slack-unfurl.service"
fi

airlock_run systemctl --user daemon-reload
airlock_run systemctl --user enable airlock-slack-unfurl.service
airlock_run systemctl --user restart airlock-slack-unfurl.service

log "slack-unfurl installed (outbound Socket Mode; domain suffix configured)"
