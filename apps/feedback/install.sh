#!/usr/bin/env bash
# feedback — a suggestion box at the bottom of the hub. The user types free text
# and submits; a loopback backend attaches the gate-verified owner and forwards
# {owner, text} to a configured external intake (which creates a tracking item and
# returns its URL). Served as a same-origin subpath under the hub.
#
#   browser --> hub (tailscale serve) --(identity)--> hub nginx
#     /feedback/api/  -> airlock-feedback backend 127.0.0.1:BACKEND (loopback)
#
# The suggestion box UI ships INSIDE the hub launcher (hub/index.html, between
# </main> and <footer>) — the orchestrator already copies it to the webroot — so
# this installer only writes the backend unit + nginx fragment. External intake is
# enabled only if [apps.feedback].intake_url + a token are configured. Config from
# airlock.toml. Honors AIRLOCK_DRY_RUN=1.
set -euo pipefail

# ABI (D5): prefer the orchestrator-supplied AIRLOCK_ROOT/AIRLOCK_APP_DIR/
# AIRLOCK_APP_ID, falling back to $0-relative computation for a standalone
# invocation (a test harness that runs this script directly).
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:-$(cd "$HERE/../.." && pwd)}"
HERE="${AIRLOCK_APP_DIR:-$HERE}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-feedback}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$HERE/render.sh"

require_cmd python3 systemctl

airlock_load feedback
BACKEND_PORT="${AIRLOCK_FEEDBACK_BACKEND_PORT:?}"
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
IDENTITY_HEADER="${AIRLOCK_IDENTITY_HEADER:?}"
UNIT_DIR="$HOME/.config/systemd/user"
# AIRLOCK_RENDER_DIR: harness-only destination-root override (highest
# priority). Redirects only where render output lands — install/lib.sh
# fail-closes if this is set without AIRLOCK_DRY_RUN=1, since real system
# mutations (systemctl, sudo tailscale serve) are gated on dry-run alone,
# not on this variable.
if [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  CONFD="$AIRLOCK_RENDER_DIR/confd"
  UNIT_DIR="$AIRLOCK_RENDER_DIR/units"
fi

# Pluggable delivery targets — intake and/or mail. None configured = the box
# degrades to "not configured" (stays hidden).
INTAKE_URL="$(airlock_config get apps.feedback.intake_url 2>/dev/null || true)"
TOKEN_ENV="$(airlock_config get apps.feedback.token_env 2>/dev/null || true)"
[ -n "$TOKEN_ENV" ] || TOKEN_ENV=AIRLOCK_FEEDBACK_TOKEN

# Mail target. The recipient is deployment config (never a default in this repo);
# the API key lives in the env var named by mail_key_env, via the EnvironmentFile.
MAIL_TO="$(airlock_config get apps.feedback.mail_to 2>/dev/null || true)"
MAIL_FROM="$(airlock_config get apps.feedback.mail_from 2>/dev/null || true)"
MAIL_API="$(airlock_config get apps.feedback.mail_api 2>/dev/null || true)"
MAIL_KEY_ENV="$(airlock_config get apps.feedback.mail_key_env 2>/dev/null || true)"
[ -n "$MAIL_KEY_ENV" ] || MAIL_KEY_ENV=RESEND_API_KEY

# --- 1. systemd user unit (loopback backend) ---
# AIRLOCK_RENDER_DIR forces the write branch even under AIRLOCK_DRY_RUN=1 (a
# real dry run with no render dir still just logs) — see install/lib.sh's
# fail-closed guard: RENDER_DIR without DRY_RUN=1 never reaches this line at
# all, and RENDER_DIR never enables sudo/systemctl, only text emission.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] write $UNIT_DIR/airlock-feedback.service (127.0.0.1:$BACKEND_PORT, intake=${INTAKE_URL:-<none>}, mail=${MAIL_TO:+configured})"
else
  install -d "$UNIT_DIR"
  render_feedback_unit "$BACKEND_PORT" "$IDENTITY_HEADER" "$INTAKE_URL" "$TOKEN_ENV" \
    "$MAIL_TO" "$MAIL_FROM" "$MAIL_API" "$MAIL_KEY_ENV" >"$UNIT_DIR/airlock-feedback.service"
fi
airlock_run systemctl --user daemon-reload
airlock_run systemctl --user enable airlock-feedback.service
airlock_run systemctl --user restart airlock-feedback.service

# --- 2. nginx subpath fragment (included inside the hub server = server-level gate) ---
# Config, not a system mutation — written unconditionally. The backend strips the
# /feedback/ prefix itself. No per-location guard: the hub server-level gate
# ($hub_ok) covers it. nginx runtime vars are escaped as \$ so the shell never
# expands them; the only shell substitution is the backend port.
frag="$CONFD/hub-locations.d/feedback.conf"
install -d "$CONFD/hub-locations.d"
render_feedback_nginx "$BACKEND_PORT" > "$frag"
log "wrote nginx fragment: $frag"

# NOTE: smoke runs from the orchestrator AFTER nginx reload (gate not live before).
log "feedback installed (owner: ${AIRLOCK_OWNER}; intake: ${INTAKE_URL:-<none>}; mail: ${MAIL_TO:+configured}${MAIL_TO:-<none>})"
