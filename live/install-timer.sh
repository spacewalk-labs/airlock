#!/usr/bin/env bash
# live/install-timer.sh — wire the weekly verification into systemd --user.
#
# Making the file and wiring it are not the same thing. The fleet has this written
# down after a timer sat committed and uninstalled for a day, and seven separate
# cases of a scheduled job dying without anyone noticing (29 days, 9 days, three
# weeks). So this script does not stop at `install`: it enables the timer, asserts
# that `list-timers` really shows it with a next elapse, and says what it did.
#
# The unit files here are TEMPLATES. The repository path, the environment file and
# the schedule are site-specific, and this tree is mirrored to a public repository
# where a hostname is a leak. The templates carry @REPO@ / @ENVFILE@ / @ONCALENDAR@
# and this script substitutes them into ~/.config/systemd/user/.
#
#   bash live/install-timer.sh [--oncalendar 'Mon 09:00'] [--envfile PATH]
#   bash live/install-timer.sh --uninstall
#
# The environment file is the one systemd reads, and it holds the same variables
# live/verify.sh documents. It must not be inside the repository.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
UNITDIR="$HOME/.config/systemd/user"
ENVFILE="$HOME/.config/airlock-live/env"
ONCALENDAR="Mon 09:00"
UNINSTALL=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --oncalendar) ONCALENDAR="${2:?}"; shift 2 ;;
    --envfile)    ENVFILE="${2:?}"; shift 2 ;;
    --uninstall)  UNINSTALL=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '[timer] %s\n' "$*"; }
die() { printf '[timer] FATAL: %s\n' "$*" >&2; exit 1; }

UNITS=(airlock-live-verify.service airlock-live-verify.timer airlock-live-failed.service)

if [ "$UNINSTALL" = 1 ]; then
  systemctl --user disable --now airlock-live-verify.timer >/dev/null 2>&1 || true
  for u in "${UNITS[@]}"; do rm -f "$UNITDIR/$u"; done
  systemctl --user daemon-reload
  say "removed"
  exit 0
fi

# A worktree is a legitimate checkout, but it is also the thing somebody deletes on
# a Friday. A weekly job pointed at one fails forever afterwards, and the failure
# looks like an airlock failure rather than a missing directory.
if [ -f "$REPO/.git" ]; then
  die "$REPO is a git worktree. Point the timer at a permanent clone — a worktree gets reclaimed and the job then fails every week for a reason that has nothing to do with airlock."
fi

[ -f "$ENVFILE" ] || die "environment file not found: $ENVFILE (see live/README.md for its contents)"
perm="$(stat -c '%a' "$ENVFILE" 2>/dev/null || echo '')"
case "$perm" in 600|400) ;; *) die "$ENVFILE is mode ${perm:-unknown}; it names an auth key file and must be 600" ;; esac
# Fail here rather than at 09:00 on a Monday.
for required in AIRLOCK_LIVE_SSH AIRLOCK_LIVE_OWNER AIRLOCK_LIVE_TSKEY_FILE; do
  grep -q "^${required}=" "$ENVFILE" || die "$ENVFILE does not set $required"
done

# Linger, or a `--user` timer stops existing the moment the session ends. Checked
# rather than assumed: it is set per user and per box, and "it was set on the box I
# tested on" is how this kind of thing goes quiet.
linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo '')"
[ "$linger" = yes ] || die "linger is not enabled for $USER — a --user timer will not survive logout. Run: loginctl enable-linger $USER"

mkdir -p "$UNITDIR"
for u in "${UNITS[@]}"; do
  sed -e "s|@REPO@|$REPO|g" -e "s|@ENVFILE@|$ENVFILE|g" -e "s|@ONCALENDAR@|$ONCALENDAR|g" \
    "$HERE/systemd/$u.in" > "$UNITDIR/$u" || die "could not render $u"
  grep -q '@[A-Z]*@' "$UNITDIR/$u" && die "$u still contains an unsubstituted placeholder"
done
say "rendered ${#UNITS[@]} units into $UNITDIR"

systemctl --user daemon-reload || die "daemon-reload failed"
systemctl --user enable --now airlock-live-verify.timer >/dev/null 2>&1 \
  || die "could not enable the timer"

# The assertion that separates this from the committed-but-never-installed case:
# ask systemd, not the filesystem.
next="$(systemctl --user list-timers airlock-live-verify.timer --no-pager --no-legend 2>/dev/null)"
[ -n "$next" ] || die "the timer is installed and enabled but does not appear in list-timers"
say "$next"
say "wired. It has NOT run yet — 'systemctl --user start airlock-live-verify.service' to see it through once."
