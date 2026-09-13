#!/usr/bin/env bash
# Install or remove the platform account surface service.
#
# Shaped after install/airlock-update-timer.sh deliberately: same render-then-verify
# order, same fail-closed placeholder check, same explicit uninstall branch. The one
# difference is that this is a long-running service rather than a oneshot behind a timer,
# so the post-install assertion asks systemd whether it is ACTIVE rather than whether it
# appears in list-timers.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

[ "$#" -eq 1 ] || die "usage: airlock-accounts-api.sh <install|uninstall>"
mode="$1"
case "$mode" in install|uninstall) ;; *) die "usage: airlock-accounts-api.sh <install|uninstall>" ;; esac

UNIT_DIR="${AIRLOCK_UNIT_DIR_USER:-$HOME/.config/systemd/user}"
SERVICE=airlock-accounts-api.service

if [ "$mode" = uninstall ]; then
  airlock_run systemctl --user disable --now "$SERVICE" || log "WARN: could not disable $SERVICE"
  airlock_run rm -f -- "$UNIT_DIR/$SERVICE"
  airlock_run systemctl --user daemon-reload
  log "platform account surface removed"
  exit 0
fi

# The port comes from config, never from a literal here — that would be a second source
# of truth for a number bin/airlock-config validates against every app's ports.
#
# 🔴 But it is READ ONCE, by whoever is upstream. Under the orchestrator the port arrives
# in the environment, already validated at install/airlock-install.sh's single
# `airlock_config validate`. Calling `airlock_config env hub` here regardless made this a
# SECOND validation gate, and a second gate can disagree with the first: the break-glass
# fixtures deliberately hold a package lock digest mismatch while an install proceeds, so
# the re-validation failed, the port came back empty, and the whole install died inside a
# helper that had no opinion about package locks. Standalone (an operator running this by
# hand) there is no upstream, so the config read stays as the fallback.
# The fleet store pointers travel with the port: same source, same single read.
if [ -n "${AIRLOCK_HUB_ACCOUNTS_PORT:-}" ]; then
  ACCOUNTS_PORT="$AIRLOCK_HUB_ACCOUNTS_PORT"
else
  eval "$(airlock_config env hub)"
  ACCOUNTS_PORT="${AIRLOCK_HUB_ACCOUNTS_PORT:?hub accounts_port missing}"
fi
# The account panel is served by the platform surface itself (bin/airlock-accounts-api),
# so it needs the directory the installed assets land in. Same single-read rule as the
# port above: the orchestrator exports AIRLOCK_WEBROOT, and a standalone run falls back
# to the documented default rather than inventing a second webroot opinion.
PANEL_DIR="${AIRLOCK_WEBROOT:-/opt/airlock/hub}/assets/accounts"
# The account view also needs popup.css. The surface now ships its own copy
# (install/accounts-panel/), so the mount serves a complete page without depending on
# apps/devterm/web being present -- which it is not in a partial tree, and which is the
# ownership question docs/design/platform-account-surface.md:81 left open.
PANEL_STYLE_DIR="$ROOT/install/accounts-panel"
# Verified here, at install time, rather than discovered as a 404 in the panel: a mount
# that promises assets must fail while someone is still looking at the install. The
# stylesheet ships with this repository, so its absence is a broken tree, not a fixture.
[ -f "$PANEL_STYLE_DIR/popup.css" ] \
  || die "account panel stylesheet missing: $PANEL_STYLE_DIR/popup.css"
# panel.html and accounts.js are hub's to install (install/airlock-install.sh copies
# hub/assets/), so this helper does not require them: run standalone or on a scratch box
# before the hub step, they are legitimately absent, and the mount already answers their
# absence with 404/500 rather than a page. The fixture measures that layout end to end.
FLEET_STORE="${AIRLOCK_HUB_FLEET_STORE-}"
FLEET_STORE_URL="${AIRLOCK_HUB_FLEET_STORE_URL-}"

if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] render platform account surface unit into $UNIT_DIR (port $ACCOUNTS_PORT)"
  airlock_run systemctl --user daemon-reload
  airlock_run systemctl --user enable --now "$SERVICE"
  exit 0
fi

install -d "$UNIT_DIR"
python="$(command -v python3)" || die "python3 not found"
escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
tmp="$(mktemp "$UNIT_DIR/.${SERVICE}.XXXXXX")"
if ! sed -e "s|@AIRLOCK_ROOT@|$(escape "$ROOT")|g" \
          -e "s|@PYTHON@|$(escape "$python")|g" \
          -e "s|@ACCOUNTS_PORT@|$(escape "$ACCOUNTS_PORT")|g" \
          -e "s|@ACCOUNTS_STATUS_BIN@|$(escape "$AIRLOCK_ACCOUNTS_STATUS_BIN")|g" \
          -e "s|@ACCOUNTS_BIN@|$(escape "$AIRLOCK_ACCOUNTS_BIN")|g" \
          -e "s|@SECRET_BIN@|$(escape "$AIRLOCK_SECRET_BIN")|g" \
          -e "s|@FLEET_STORE@|$(escape "$FLEET_STORE")|g" \
          -e "s|@PANEL_DIR@|$(escape "$PANEL_DIR")|g" \
          -e "s|@PANEL_STYLE_DIR@|$(escape "$PANEL_STYLE_DIR")|g" \
          -e "s|@FLEET_STORE_URL@|$(escape "$FLEET_STORE_URL")|g" \
          "$HERE/systemd/$SERVICE.in" > "$tmp"; then
  rm -f "$tmp"
  die "could not render $SERVICE"
fi
# An unsubstituted placeholder is a unit that starts and fails at the first request,
# which is the failure this check exists to turn into an install-time one.
if grep -q '@[A-Z_]*@' "$tmp"; then
  rm -f "$tmp"
  die "$SERVICE still contains an unsubstituted placeholder"
fi
chmod 0644 "$tmp"
mv -f "$tmp" "$UNIT_DIR/$SERVICE"

systemctl --user daemon-reload || die "could not reload the user unit manager"
systemctl --user enable --now "$SERVICE" >/dev/null || die "could not enable $SERVICE"
# Ask systemd, not the filesystem. "The unit file is installed" and "the service is
# running" are different claims, and only the second one serves a request.
state="$(systemctl --user is-active "$SERVICE" 2>/dev/null || true)"
[ "$state" = active ] \
  || die "the account surface unit is installed and enabled but is $state (journalctl --user -u $SERVICE)"
log "platform account surface installed and active on 127.0.0.1:$ACCOUNTS_PORT"
