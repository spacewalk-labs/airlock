#!/usr/bin/env bash
# Install or remove the daily, snapshot-only update detector.  The monitor remains a
# daemon; this is deliberately a user-level oneshot so the network fetch happens once
# per day rather than once per page load.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

[ "$#" -eq 1 ] || die "usage: airlock-update-timer.sh <install|uninstall>"
mode="$1"
UNIT_DIR="${AIRLOCK_UNIT_DIR_USER:-$HOME/.config/systemd/user}"
SERVICE=airlock-update-detect.service
TIMER=airlock-update-detect.timer
STATE="${AIRLOCK_UPDATES_STATE:-$HOME/.local/state/airlock/updates.json}"

case "$mode" in install|uninstall) ;; *) die "usage: airlock-update-timer.sh <install|uninstall>" ;; esac

if [ "$mode" = uninstall ]; then
  airlock_run systemctl --user disable --now "$TIMER" || log "WARN: could not disable $TIMER"
  airlock_run rm -f -- "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER"
  airlock_run systemctl --user daemon-reload
  log "platform update detector timer removed"
  exit 0
fi

if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] render platform update detector units into $UNIT_DIR"
  airlock_run systemctl --user daemon-reload
  airlock_run systemctl --user enable --now "$TIMER"
  exit 0
fi

install -d "$UNIT_DIR"
python="$(command -v python3)" || die "python3 not found"
escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
for unit in "$SERVICE" "$TIMER"; do
  tmp="$(mktemp "$UNIT_DIR/.${unit}.XXXXXX")"
  if ! sed -e "s|@AIRLOCK_ROOT@|$(escape "$ROOT")|g" \
            -e "s|@PYTHON@|$(escape "$python")|g" \
            -e "s|@STATE@|$(escape "$STATE")|g" \
            "$HERE/systemd/$unit.in" > "$tmp"; then
    rm -f "$tmp"
    die "could not render $unit"
  fi
  if grep -q '@[A-Z_]*@' "$tmp"; then
    rm -f "$tmp"
    die "$unit still contains an unsubstituted placeholder"
  fi
  chmod 0644 "$tmp"
  mv -f "$tmp" "$UNIT_DIR/$unit"
done

systemctl --user daemon-reload || die "could not reload the user unit manager"
systemctl --user enable --now "$TIMER" >/dev/null || die "could not enable $TIMER"
next="$(systemctl --user list-timers "$TIMER" --no-pager --no-legend 2>/dev/null)"
[ -n "$next" ] || die "the timer is installed and enabled but does not appear in list-timers"
log "platform update detector timer installed: $next"
