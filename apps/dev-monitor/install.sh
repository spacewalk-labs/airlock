#!/usr/bin/env bash
# dev-monitor — per-box system/service/network/storage observability, served as a
# same-origin subpath under the hub (owner + collaborators), plus an OPTIONAL
# owner-only message/action console (messages = true; default off).
#
#   browser --> hub (tailscale serve) --(identity)--> hub nginx
#     /monitor/        -> dashboard UI (static, from the hub webroot)
#     /monitor/api/    -> airlock-dev-monitor backend 127.0.0.1:BACKEND (loopback)
#
# The backend binds loopback and strips the /monitor/ prefix itself. Config from
# airlock.toml ([apps.dev-monitor]). Honors AIRLOCK_DRY_RUN=1.
set -euo pipefail

# ABI (D5): the caller sets AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID and runs
# this script with cwd = AIRLOCK_APP_DIR. AIRLOCK_ROOT is REQUIRED: the platform
# root cannot be derived from $0, because "$0/../.." is only the platform when the
# package happens to sit in the platform's own apps/ tree — the arrangement the
# apps/ cutover ends. $0-relative self-location (this file's own directory) stays
# fine and is what AIRLOCK_APP_DIR falls back to.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
HERE="${AIRLOCK_APP_DIR:-$HERE}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-dev-monitor}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$HERE/render.sh"

require_cmd python3 systemctl journalctl realpath

airlock_load dev-monitor
BACKEND_PORT="${AIRLOCK_DEV_MONITOR_BACKEND_PORT:?}"
MESSAGES="${AIRLOCK_DEV_MONITOR_MESSAGES:-false}"
SLACK_WEBHOOK_URGENT_ENV="${AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT_ENV:-}"
SLACK_WEBHOOK_ROUTINE_ENV="${AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE_ENV:-}"
SLACK_WEBHOOK_ENV="${AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ENV:-}"
EXEC_CWD_ROOT="${AIRLOCK_DEV_MONITOR_EXEC_CWD_ROOT:-}"
EXEC_SESSION="${AIRLOCK_DEV_MONITOR_EXEC_SESSION:-devmon-exec}"
SPOOL_WRITER_USER="${AIRLOCK_DEV_MONITOR_SPOOL_WRITER_USER:-airlock-dev-monitor-writer}"
SPOOL_WRITER_GROUP="${AIRLOCK_DEV_MONITOR_SPOOL_WRITER_GROUP:-airlock-dev-monitor-writers}"
SMTP_HOST="${AIRLOCK_DEV_MONITOR_SMTP_HOST:-}"
SMTP_PORT="${AIRLOCK_DEV_MONITOR_SMTP_PORT:-}"
SMTP_FROM="${AIRLOCK_DEV_MONITOR_SMTP_FROM:-}"
SMTP_TO="${AIRLOCK_DEV_MONITOR_SMTP_TO:-}"
SMTP_USER="${AIRLOCK_DEV_MONITOR_SMTP_USER:-}"
SMTP_PASSWORD_ENV="${AIRLOCK_DEV_MONITOR_SMTP_PASSWORD_ENV:-}"
ROSTER_PATH="${AIRLOCK_DEV_MONITOR_ROSTER_PATH:-}"
TOKEN_FRESHNESS="${AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS:-false}"
TOKEN_WARN_HOURS="${AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS_WARN_HOURS:-24}"
TOKEN_STALE_HOURS="${AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS_STALE_HOURS:-24}"
# D5 hands the platform capability in. Pin its resolved absolute path before a unit
# records it, matching devterm's P2a handoff: an app may validate a capability path but
# must never reconstruct $ROOT/bin/... for itself.
case "$AIRLOCK_ACCOUNTS_STATUS_BIN" in
  /*) ;;
  *) die "AIRLOCK_ACCOUNTS_STATUS_BIN must be an absolute D5 platform path" ;;
esac
[ -f "$AIRLOCK_ACCOUNTS_STATUS_BIN" ] && [ -x "$AIRLOCK_ACCOUNTS_STATUS_BIN" ] \
  || die "AIRLOCK_ACCOUNTS_STATUS_BIN does not name an executable platform file"
ACCOUNTS_STATUS_BIN="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' \
  "$AIRLOCK_ACCOUNTS_STATUS_BIN")"
# The box-wide default agent, and the second D5 capability that resolves it. Same handoff
# rule as above: this app validates the path it is given and never rebuilds $ROOT/bin/... .
#
# The value itself is NOT validated here against a list of names. airlock-config already
# refuses an unknown [agent].provider at validate time, and a second copy of the vocabulary
# in this file would go stale the day a third CLI is added — the failure would be an install
# that refuses a value the platform accepts, which reads as a broken installer.
AGENT_PROVIDER="${AIRLOCK_AGENT_PROVIDER:-}"
# Both values land on `Environment=` lines in a unit file, where a newline is a new
# directive. The orchestrator runs `airlock-config validate` first and that refuses a
# provider outside auto/claude/codex, so this is the second lock and not the first —
# but an app installer run on its own must not be able to write a unit nobody wrote.
# Same guard this file already applies to the resolved Slack and SMTP values below.
#
# Newline only, and that is the whole list on purpose. Measured on systemd 255, 2026-09-01,
# because two reviewers disagreed about the backslash and neither had run it:
#
#   Environment=A=val\        -> systemctl show -p Environment
#   Environment=B=second         Environment=A=val Environment=B=second
#
# The trailing backslash DOES join the two physical lines (systemd.syntax line continuation
# applies to unit directives, not only to EnvironmentFile), but the joined line is still one
# `Environment=` directive — so the worst it does is swallow the next assignment, which now
# surfaces as the loud half-configured case in action_runner.resolve_agent() rather than as a
# silent wrong CLI. A raw newline is different in kind, and that is the one blocked here:
#
#   Environment=A=val
#   ExecStartPre=/bin/echo INJECTED
#                             -> ExecStartPre={ path=/bin/echo ; argv[]=/bin/echo INJECTED ; … }
#
# A space or a `%` stays inside the value the same way it does for the existing
# ACCOUNTS_STATUS_BIN and cors_hosts lines. Only a newline can start a new DIRECTIVE.
for _pair in "agent.provider:$AGENT_PROVIDER" "AIRLOCK_AGENT_BIN:$AIRLOCK_AGENT_BIN"; do
  case "${_pair#*:}" in
    *[$'\n\r']*) die "resolved ${_pair%%:*} must not contain newlines — it is written onto a systemd Environment= line" ;;
  esac
done
case "$AIRLOCK_AGENT_BIN" in
  /*) ;;
  *) die "AIRLOCK_AGENT_BIN must be an absolute D5 platform path" ;;
esac
# Readable, not executable: bin/airlock-agent is mode 100644 by design and every caller
# spawns python3 for it, the same way install/lib.sh spawns bin/airlock-config.
[ -f "$AIRLOCK_AGENT_BIN" ] && [ -r "$AIRLOCK_AGENT_BIN" ] \
  || die "AIRLOCK_AGENT_BIN does not name a readable platform file"
AGENT_BIN="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' \
  "$AIRLOCK_AGENT_BIN")"
# Optional cutover bridge for existing producers/watchdogs. There is deliberately no
# default: a public installer must not guess a box-specific legacy path. The operator names
# the path in deployment config, and the generated file contains only four compatibility
# values. Keeping it in config also makes disable/reinstall update the same owned file.
COMPAT_ENV="${AIRLOCK_DEV_MONITOR_COMPAT_ENV_PATH:-}"
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
WEBROOT="${AIRLOCK_WEBROOT:-/opt/airlock/hub}"
IDENTITY_HEADER="${AIRLOCK_IDENTITY_HEADER:?}"
# This value is interpolated into an nginx variable name below. airlock-config derives it
# from a fixed provider map so it is always well formed, but this script can be run
# standalone with the env var set — and a value carrying whitespace or a brace would either
# break the hub config (reload fails, whole hub down) or inject directives.
case "$IDENTITY_HEADER" in
  *[!A-Za-z0-9-]*|'') die "AIRLOCK_IDENTITY_HEADER must be a bare HTTP header name (letters, digits, '-'): got '$IDENTITY_HEADER'" ;;
esac
# Same reasoning one level down: these values feed a systemd EnvironmentFile,
# where a newline would inject additional environment entries.
for _v in "$EXEC_CWD_ROOT" "$EXEC_SESSION" "$SLACK_WEBHOOK_URGENT_ENV" \
          "$SLACK_WEBHOOK_ROUTINE_ENV" "$SLACK_WEBHOOK_ENV" \
          "$SMTP_HOST" "$SMTP_PORT" "$SMTP_FROM" "$SMTP_TO" "$SMTP_USER" \
          "$SMTP_PASSWORD_ENV" "$ROSTER_PATH" "$COMPAT_ENV"; do
  case "$_v" in *[$'\n\r']*) die "config values must not contain newlines" ;; esac
done
case "$COMPAT_ENV" in
  "") ;;
  /*) ;;
  *) die "AIRLOCK_DEV_MONITOR_COMPAT_ENV_PATH must be an absolute path" ;;
esac
# Precedence treats surrounding whitespace as unset, matching the documented table.
trim_config_value() {
  python3 -c 'import sys; print(sys.argv[1].strip(), end="")' "$1"
}
SLACK_WEBHOOK_URGENT_ENV="$(trim_config_value "$SLACK_WEBHOOK_URGENT_ENV")"
SLACK_WEBHOOK_ROUTINE_ENV="$(trim_config_value "$SLACK_WEBHOOK_ROUTINE_ENV")"
SLACK_WEBHOOK_ENV="$(trim_config_value "$SLACK_WEBHOOK_ENV")"
SMTP_HOST="$(trim_config_value "$SMTP_HOST")"
SMTP_PORT="$(trim_config_value "$SMTP_PORT")"
SMTP_FROM="$(trim_config_value "$SMTP_FROM")"
SMTP_TO="$(trim_config_value "$SMTP_TO")"
SMTP_USER="$(trim_config_value "$SMTP_USER")"
SMTP_PASSWORD_ENV="$(trim_config_value "$SMTP_PASSWORD_ENV")"
ROSTER_PATH="$(trim_config_value "$ROSTER_PATH")"
OWNER="${AIRLOCK_OWNER:?}"
UNIT_DIR="$HOME/.config/systemd/user"
DEVMON_STATE="$HOME/.local/state/airlock/dev-monitor"
DEVMON_ENV="$HOME/.config/airlock/dev-monitor.env"
DEVMON_ENV_OUTPUT="$DEVMON_ENV"
COMPAT_ENV_OUTPUT=""
# AIRLOCK_RENDER_DIR: harness-only destination-root override (highest
# priority). Redirects only where render output lands — install/lib.sh
# fail-closes if this is set without AIRLOCK_DRY_RUN=1, since real system
# mutations (systemctl, sudo tailscale serve, and orca's own sudo nft/
# systemctl calls) are gated on dry-run alone, not on this variable.
if [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  CONFD="$AIRLOCK_RENDER_DIR/confd"
  UNIT_DIR="$AIRLOCK_RENDER_DIR/units"
  # Capture output under the harness root, but keep EnvironmentFile= pointed at
  # the path the real service will read. Confusing these paths makes a golden pass
  # while the rendered unit reads a file that exists only in the test harness.
  DEVMON_ENV_OUTPUT="$AIRLOCK_RENDER_DIR/files/dev-monitor.env"
fi
if [ -n "$COMPAT_ENV" ]; then
  [ ! -L "$COMPAT_ENV" ] \
    || die "compatibility env path must not be a symbolic link"
  COMPAT_ENV="$(realpath -m -- "$COMPAT_ENV")" \
    || die "compatibility env path could not be normalized"
  DEVMON_ENV_NORMALIZED="$(realpath -m -- "$DEVMON_ENV")" \
    || die "canonical backend env path could not be normalized"
  COMPAT_ENV_OUTPUT="${AIRLOCK_RENDER_DIR:+$AIRLOCK_RENDER_DIR/files/dev-monitor-compat.env}"
  COMPAT_ENV_OUTPUT="${COMPAT_ENV_OUTPUT:-$COMPAT_ENV}"
  [ "$COMPAT_ENV" != "$DEVMON_ENV_NORMALIZED" ] \
    || die "compatibility env path must differ from the canonical backend env"
  [ ! -e "$COMPAT_ENV" ] || [ -f "$COMPAT_ENV" ] \
    || die "compatibility env path must be absent or a regular file"
fi

# The spool is written by a SECOND UID, which therefore has to traverse every directory
# above it. The one in the way is Airlock's own state directory: install/airlock-install.sh
# creates it 0700, which is right for a directory holding the ledger and wrong for a
# parent this app needs a foreign uid to walk through. So widen exactly that one bit,
# here, where it is the OPERATOR doing it to their own directory — no sudo, and nothing
# root-owned is involved.
#
# `o+x` and not `o+rx`: traverse, never list. The ledger beside us stays 0600 and the
# directory stays unlistable, so what this grants is the ability to reach a path you
# already know the name of, which is the whole requirement. Group would be narrower
# still, but chgrp to a group the operator does not belong to needs root, and
# install/test-monitor-spool-hardening.sh deliberately forbids root from touching the
# user-owned state path at all.
#
# Measured 2026-08-22: without this the install dies in install-spool-hardening.sh's
# cross-UID check, which is the check written to catch precisely this.
_devmon_state_parent="$(dirname "$DEVMON_STATE")"
if [ -d "$_devmon_state_parent" ]; then
  chmod o+x "$_devmon_state_parent" \
    || die "cannot make $_devmon_state_parent traversable for the spool writer"
fi

# Establish (or remove, when messages=false) the system-scope writer boundary before
# rendering or restarting the user service. The rendered unit independently checks that
# the firewall unit is active, so a missing rule fails closed on every later restart too.
bash "$HERE/install-spool-hardening.sh" --state "$DEVMON_STATE" \
  --messages "$MESSAGES" --writer-user "$SPOOL_WRITER_USER" \
  --writer-group "$SPOOL_WRITER_GROUP"

# The unread badge (hub/assets/airlock-return.js) polls owner/messages/preview
# cross-origin from the separate-port tools (devterm/code-server/orca/paseo — same box,
# different ports). That path matches the OWNER location in the fragment below, not the
# general one, because nginx picks the longest matching prefix. So the echo has to come
# from the backend — which is also the only place that knows this particular route is
# the badge's rather than the owner's data. All we do here is name the hosts that count
# as this box; everything else the backend serves stays same-origin only.
#
# With no measurable FQDN we pass nothing: the backend still recognises its own hostname,
# so a short-name origin keeps working and the badge degrades instead of breaking.
FQDN="${AIRLOCK_TS_FQDN:-}"
# Two statements, not `$(... || true)`: ts_fqdn ends in `die`, and an `exit` inside a
# command substitution kills the substitution before `|| true` can run. Same trap
# install/render-nginx.sh documents.
[ -n "$FQDN" ] || FQDN="$(ts_fqdn 2>/dev/null)" || FQDN=""
cors_hosts=""
if [ -n "$FQDN" ]; then
  cors_hosts="${FQDN},${FQDN%%.*}"
else
  log "WARN: tailnet FQDN unresolved — the unread badge is reachable only from a short-name origin"
fi

# --- 0. owner gate + optional message/action console state ---
# The update API always needs its two-value owner gate; the message feature additionally
# needs spool/DB state. The same 0600 file carries the full set when messages=true and
# only the gate when false, so turning messages off cannot also turn off updates.
#
# The proxy secret is what proves a request came through nginx rather than straight to
# the loopback port. A real install rotates it: nginx and the unit are rewritten in the
# same run, so rotation costs nothing and bounds the lifetime of a value that leaked from
# an old config.
#
# A DRY RUN must not rotate it, so it reuses the deployed secret when it can read one.
# That alone is not enough — an unreadable env file leaves nothing to reuse — which is why
# the fragment write further down also refuses to overwrite an existing file on a dry run.
# Between them, a preview can never hand nginx a secret the running backend has not seen.
#
# The spool is 0700 and owned by the operator. Anything that can write it can create a
# card — including an `action` card — so treat spool write access as equivalent to
# console access. It is not equivalent to execution: an action card still has to be
# approved by the owner in the console, and the approved plan is hash-pinned, before
# anything runs. See SECURITY.md.
DEVMON_SECRET=""
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -r "$DEVMON_ENV" ]; then
  DEVMON_SECRET="$(sed -n 's/^DEV_MONITOR_PROXY_SECRET=//p' "$DEVMON_ENV" | head -1)"
fi
# Nothing to reuse (no env file yet, or it is unreadable): mint one. Safe on a dry run
# only because the fragment write below will not overwrite an existing file.
[ -n "$DEVMON_SECRET" ] || DEVMON_SECRET="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
SLACK_WEBHOOK_URGENT=""
SLACK_WEBHOOK_ROUTINE=""
if [ "$MESSAGES" = true ]; then
  if [ -n "$SLACK_WEBHOOK_URGENT_ENV" ]; then
    SLACK_WEBHOOK_URGENT="$(printenv "$SLACK_WEBHOOK_URGENT_ENV" 2>/dev/null || true)"
    [ -n "$SLACK_WEBHOOK_URGENT" ] || log "WARN: slack_webhook_urgent_env names an unset variable — urgent Slack delivery stays off"
  elif [ -n "$SLACK_WEBHOOK_ENV" ]; then
    SLACK_WEBHOOK_URGENT="$(printenv "$SLACK_WEBHOOK_ENV" 2>/dev/null || true)"
    [ -n "$SLACK_WEBHOOK_URGENT" ] || log "WARN: legacy slack_webhook_env names an unset variable — urgent Slack delivery stays off"
  fi
  if [ -n "$SLACK_WEBHOOK_ROUTINE_ENV" ]; then
    SLACK_WEBHOOK_ROUTINE="$(printenv "$SLACK_WEBHOOK_ROUTINE_ENV" 2>/dev/null || true)"
    [ -n "$SLACK_WEBHOOK_ROUTINE" ] || log "WARN: slack_webhook_routine_env names an unset variable — routine Slack delivery stays off"
  fi
  for _v in "$SLACK_WEBHOOK_URGENT" "$SLACK_WEBHOOK_ROUTINE"; do
    case "$_v" in *[$'\n\r']*) die "resolved Slack webhook values must not contain newlines" ;; esac
  done

  # The email lane. Same indirection as the webhooks: config names the variable, never
  # holds the password. The warnings are per-field because "email is off" is not a
  # diagnosis — the operator has to know which of the five is missing.
  SMTP_PASSWORD=""
  if [ -n "$SMTP_PASSWORD_ENV" ]; then
    SMTP_PASSWORD="$(printenv "$SMTP_PASSWORD_ENV" 2>/dev/null || true)"
    [ -n "$SMTP_PASSWORD" ] || log "WARN: smtp_password_env names an unset variable — the email lane will try to send without a credential"
  fi
  # Newlines and backslashes, on both credential fields. The env file is a systemd
  # EnvironmentFile, which strips a backslash and treats a trailing one as a line
  # continuation — measured: `hunter2\` swallows the next variable, and `CORP\jdoe` arrives
  # as `CORPjdoe`. Either way SMTP auth fails with nothing pointing at the cause. The user
  # field matters as much as the password here: `DOMAIN\user` is the ordinary spelling for
  # SMTP AUTH against a Windows relay, so it is the value most likely to contain one.
  for _pair in "SMTP password:$SMTP_PASSWORD" "SMTP user:$SMTP_USER"; do
    case "${_pair#*:}" in
      *[$'\n\r']*) die "resolved ${_pair%%:*} must not contain newlines" ;;
      *\\*) die "resolved ${_pair%%:*} must not contain a backslash — systemd EnvironmentFile reads it as a line continuation" ;;
    esac
  done
  if [ -n "$SMTP_HOST$SMTP_FROM$SMTP_TO" ]; then
    for _pair in "smtp_host:$SMTP_HOST" "smtp_from:$SMTP_FROM" "smtp_to:$SMTP_TO"; do
      [ -n "${_pair#*:}" ] || log "WARN: ${_pair%%:*} is empty — the email lane stays off (page still reaches Slack and the console)"
    done
  fi

  if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
    install -d -m 700 "$(dirname "$DEVMON_ENV")"
  fi
  # The console link that Slack messages carry. Without a resolvable tailnet FQDN there
  # is no address that works from a phone, so the link is omitted rather than guessed.
  CONSOLE_URL=""
  if [ -n "$FQDN" ]; then
    CONSOLE_URL="https://${FQDN}/monitor/#messages"
  else
    log "WARN: tailnet FQDN unresolved — Slack notifications will carry no console link"
  fi
  # Not a preflight row: preflight is per-app and fails the whole install, and tmux is only
  # needed by the ACTION half of an optional console. Cards, coalescing, Slack and the feed
  # all work without it; an approval is refused with a reason instead of appearing to run.
  command -v tmux >/dev/null 2>&1 || \
    log "WARN: tmux not found — cards and the feed work, but approved actions cannot run. Install it (sudo apt-get install -y tmux) to use the action half."
  if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] || [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
    install -d -m 700 "$(dirname "$DEVMON_ENV_OUTPUT")"
    ( umask 077; render_dev_monitor_env \
        "$OWNER" "$DEVMON_SECRET" "$DEVMON_STATE" "${EXEC_CWD_ROOT:-$HOME}" \
        "$EXEC_SESSION" "$SLACK_WEBHOOK_URGENT" "$SLACK_WEBHOOK_ROUTINE" \
        "$CONSOLE_URL" "$SMTP_HOST" "$SMTP_PORT" "$SMTP_FROM" "$SMTP_TO" \
        "$SMTP_USER" "$SMTP_PASSWORD" "$ROSTER_PATH" >"$DEVMON_ENV_OUTPUT" )
    chmod 600 "$DEVMON_ENV_OUTPUT"
    if [ -n "$COMPAT_ENV_OUTPUT" ]; then
      install -d "$(dirname "$COMPAT_ENV_OUTPUT")"
      ( set -e
        compat_tmp="$(mktemp "$(dirname "$COMPAT_ENV_OUTPUT")/.dev-monitor-compat.XXXXXX")"
        trap 'rm -f "$compat_tmp"' EXIT
        umask 077
        render_dev_monitor_compat_env "$DEVMON_STATE" \
          "$SLACK_WEBHOOK_URGENT" "$SLACK_WEBHOOK_ROUTINE" >"$compat_tmp"
        chmod 600 "$compat_tmp"
        mv -T "$compat_tmp" "$COMPAT_ENV_OUTPUT"
        trap - EXIT
      )
    fi
  fi
elif [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] || [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  install -d -m 700 "$(dirname "$DEVMON_ENV_OUTPUT")"
  ( umask 077; render_dev_monitor_owner_env "$OWNER" "$DEVMON_SECRET" >"$DEVMON_ENV_OUTPUT" )
  chmod 600 "$DEVMON_ENV_OUTPUT"
  [ -z "$COMPAT_ENV_OUTPUT" ] || rm -f "$COMPAT_ENV_OUTPUT"
  # Turning the console off does not reach into a run that is already going. Killing
  # someone's in-flight work to honour a config change would be worse than leaving it —
  # but leaving it silently would be worse still, because the UI that could stop it is
  # about to disappear.
  if tmux has-session -t "$EXEC_SESSION" 2>/dev/null; then
    log "WARN: messages is now false, but tmux session '$EXEC_SESSION' still has running actions. \
They keep running and the console can no longer stop them — attach with 'tmux attach -t $EXEC_SESSION'."
  fi
fi

# --- 1. systemd user unit (loopback backend) ---
# AIRLOCK_RENDER_DIR forces the write branch even under AIRLOCK_DRY_RUN=1 —
# see install/lib.sh's fail-closed guard (RENDER_DIR without DRY_RUN=1 never
# reaches this line) and apps/feedback/install.sh's identical comment.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] write $UNIT_DIR/airlock-dev-monitor.service (127.0.0.1:$BACKEND_PORT, messages=$MESSAGES)"
else
  install -d "$UNIT_DIR"
  render_dev_monitor_unit "$BACKEND_PORT" "$MESSAGES" "$IDENTITY_HEADER" "$cors_hosts" "$DEVMON_ENV" \
    "$TOKEN_FRESHNESS" "$TOKEN_WARN_HOURS" "$TOKEN_STALE_HOURS" "$MESSAGES" \
    "$ACCOUNTS_STATUS_BIN" "$AGENT_PROVIDER" "$AGENT_BIN" \
    >"$UNIT_DIR/airlock-dev-monitor.service"
fi
# The card is on; the CHECKING is not. Said once at install time, because "the feature is
# enabled" and "something is looking at your tokens on a schedule" are different facts and
# the dashboard cannot tell them apart until the first snapshot exists.
if [ "$TOKEN_FRESHNESS" = true ] && [ ! -f "$HOME/.config/systemd/user/airlock-token-freshness.timer" ]; then
  log "NOTE: token_freshness is on, so the dashboard card and /api/tokens are live — but nothing checks on a schedule yet. Wire the timer with: AIRLOCK_ROOT=$ROOT AIRLOCK_APP_DIR=$HERE AIRLOCK_APP_ID=$AIRLOCK_APP_ID bash $HERE/install-token-timer.sh"
fi
airlock_run systemctl --user daemon-reload
airlock_run systemctl --user enable airlock-dev-monitor.service
airlock_run systemctl --user restart airlock-dev-monitor.service

# --- 2. dashboard UI into the hub webroot (served by the hub's static location /) ---
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] install dev-monitor.html -> $WEBROOT/monitor/index.html"
else
  install -d "$WEBROOT/monitor"
  install -m644 "$HERE/frontend/dev-monitor.html" "$WEBROOT/monitor/index.html"
fi

# --- 3. nginx subpath fragment (included inside the hub server = server-level gate) ---
# Config, not a system mutation — written unconditionally. nginx runtime vars are
# escaped as \$ so the shell never expands them; the only shell substitutions are
# the backend port and the same-box origin regex below. No per-location guard: the
# hub server-level gate ($hub_ok) covers it.
frag="$CONFD/hub-locations.d/dev-monitor.conf"
install -d "$CONFD/hub-locations.d"

# The updates endpoints are owner-only regardless of whether messages are enabled. Three
# locations, each scoped to one branch so a future message route cannot accidentally
# inherit their gate: an exact match for the snapshot itself, a prefix for the execution
# routes under it (/run, /execute), and the same prefix for the settings panel's harness
# section, which shares this gate and nothing else (devmon_harness). Each prefix is
# longer than the /monitor/api/ observability location and than the message console's
# /monitor/api/owner/ location, so nginx's longest-prefix rule keeps the owner gate on
# all three whether or not the console is installed.
# Message/action routes keep their existing conditional prefix location below.
#
# Both X-Devmon-* headers are set here, which is also what makes a client-supplied copy
# of them harmless — proxy_set_header REPLACES whatever the browser sent. The owner is
# taken from the ingress-injected identity header (never from the request body), and the
# secret proves the request came through nginx rather than straight to the loopback port.
hdr_var="$(printf '%s' "${IDENTITY_HEADER//-/_}" | tr '[:upper:]' '[:lower:]')"
updates_location="$(render_dev_monitor_owner_location "$BACKEND_PORT" "$hdr_var" "$DEVMON_SECRET" \
  '= /monitor/api/owner/updates')$(render_dev_monitor_owner_location "$BACKEND_PORT" "$hdr_var" \
  "$DEVMON_SECRET" '/monitor/api/owner/updates/')$(render_dev_monitor_owner_location \
  "$BACKEND_PORT" "$hdr_var" "$DEVMON_SECRET" '/monitor/api/owner/harness/')"
owner_location=""
if [ "$MESSAGES" = true ]; then
  owner_location="$(render_dev_monitor_owner_location "$BACKEND_PORT" "$hdr_var" "$DEVMON_SECRET")"
fi

# A dry run must not touch an EXISTING fragment. Elsewhere in Airlock the nginx fragment
# is pure config and is written unconditionally, which is safe because it is a pure
# function of the config. This one is not: it carries a freshly minted secret, and whether
# it contains the owner location at all depends on `messages`. Previewing `messages = false`
# on a live box would therefore delete the owner location from the file nginx actually
# serves, and the console would 404 at the next reload with nothing to explain why.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -e "$frag" ]; then
  log "[dry] would rewrite $frag (messages=$MESSAGES) — left as is"
  frag="$(mktemp)"
fi
# Created restricted, THEN written: the fragment carries the proxy secret, and
# `cat > file` would otherwise create it under the default umask (world-readable) with
# the secret already in it and only narrow the mode afterwards. nginx reads its config
# as root, so 0600 owned by the installing user is readable where it needs to be.
install -m 600 /dev/null "$frag"
render_dev_monitor_nginx "$BACKEND_PORT" "$updates_location" "$owner_location" >"$frag"
log "wrote nginx fragment: $frag"

# NOTE: smoke runs from the orchestrator AFTER nginx reload (gate not live before).
log "dev-monitor installed (owner: ${AIRLOCK_OWNER}; messages: ${MESSAGES})"
