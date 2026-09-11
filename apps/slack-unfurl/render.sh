# shellcheck shell=bash
# Sourceable render library: functions only, with no top-level execution.

# render_slack_unfurl_unit DOMAIN DEDICATED_PORTS BOT_TOKEN_NAME APP_TOKEN_NAME BACKEND_DIR
render_slack_unfurl_unit() {
  local DOMAIN="$1" DEDICATED_PORTS="$2" BOT_TOKEN_NAME="$3" APP_TOKEN_NAME="$4" BACKEND_DIR="$5"
  cat <<UNIT
[Unit]
Description=airlock Slack published-document unfurl worker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Optional at render time so operators can create it as mode 0600 before the
# first live start. The worker itself fails closed when either named token is absent.
EnvironmentFile=-%h/.config/airlock-slack-unfurl.env
Environment=AIRLOCK_SLACK_UNFURL_DOMAIN=${DOMAIN}
Environment=AIRLOCK_SLACK_UNFURL_ALLOWED_PORTS=${DEDICATED_PORTS}
Environment=AIRLOCK_SLACK_UNFURL_BOT_TOKEN_NAME=${BOT_TOKEN_NAME}
Environment=AIRLOCK_SLACK_UNFURL_APP_TOKEN_NAME=${APP_TOKEN_NAME}
ExecStart=/usr/bin/python3 ${BACKEND_DIR}/slack_unfurl.py
# At most four acknowledged events wait behind one active event. The worker
# drains that bounded queue on SIGTERM; 15 minutes covers their worst-case
# sequential metadata and Slack API timeouts instead of systemd killing them.
TimeoutStopSec=15min
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
}
