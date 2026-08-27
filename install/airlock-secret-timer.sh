#!/usr/bin/env bash
# Install or remove the platform-owned secret TTL timer. This is separate from every app
# lifecycle because the store's TTL must hold with zero consuming apps installed.
#
#   bash install/airlock-secret-timer.sh install
#   bash install/airlock-secret-timer.sh uninstall
#
# AIRLOCK_DRY_RUN=1 reports the exact actions without writing or calling systemd.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

[ "$#" -eq 1 ] || die "usage: airlock-secret-timer.sh <install|uninstall>"
mode="$1"
UNIT_DIR="${AIRLOCK_UNIT_DIR_USER:-$HOME/.config/systemd/user}"
SERVICE=airlock-secret-sweep.service
TIMER=airlock-secret-sweep.timer

case "$mode" in
  install|uninstall) ;;
  *) die "usage: airlock-secret-timer.sh <install|uninstall>" ;;
esac

if [ "$mode" = uninstall ]; then
  # Disable first so systemd cannot race a final activation against file removal. A user
  # manager that is already absent must not strand files nothing else knows to remove.
  airlock_run systemctl --user disable --now "$TIMER" \
    || log "WARN: could not disable $TIMER; removing its unit files anyway"
  airlock_run rm -f -- "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER"
  airlock_run systemctl --user daemon-reload
  log "platform secret timer removed"
  exit 0
fi

case "$AIRLOCK_SECRET_BIN" in
  /*) ;;
  *) die "AIRLOCK_SECRET_BIN must be an absolute D5 platform path" ;;
esac
[ -f "$AIRLOCK_SECRET_BIN" ] && [ -x "$AIRLOCK_SECRET_BIN" ] \
  || die "AIRLOCK_SECRET_BIN does not name an executable platform file"
case "$AIRLOCK_SECRET_BIN" in
  *[$'\n\r']*) die "AIRLOCK_SECRET_BIN must not contain a newline" ;;
esac

if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] render platform secret units into $UNIT_DIR"
  airlock_run systemctl --user daemon-reload
  airlock_run systemctl --user enable --now "$TIMER"
  exit 0
fi

install -d "$UNIT_DIR"
sed_replacement() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
for unit in "$SERVICE" "$TIMER"; do
  tmp="$(mktemp "$UNIT_DIR/.${unit}.XXXXXX")"
  if ! sed "s|@AIRLOCK_SECRET_BIN@|$(sed_replacement "$AIRLOCK_SECRET_BIN")|g" \
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
systemctl --user enable --now "$TIMER" >/dev/null \
  || die "could not enable the platform secret timer"
log "platform secret timer installed and enabled"
