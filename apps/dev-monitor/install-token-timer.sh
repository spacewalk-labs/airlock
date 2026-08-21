#!/usr/bin/env bash
# apps/dev-monitor/install-token-timer.sh — wire the credential freshness check into
# systemd --user.
#
# Deliberately NOT part of apps/dev-monitor/install.sh. The dashboard card is passive and
# costs nothing; a timer is a standing job on the operator's box, so it is switched on by
# an explicit act with an explicit schedule. `token_freshness = true` in airlock.toml
# turns the card and the backend route on; this script is what makes the checking happen.
#
# Making the file and wiring it are not the same thing — this fleet has seven recorded
# cases of a scheduled job dying without anyone noticing, one of them a timer that had
# been committed and never installed. So this does not stop at `install`: it enables the
# timer, asks SYSTEMD (not the filesystem) whether it really appears in list-timers, and
# says what it did.
#
# The unit files are TEMPLATES. The repository path, the spool and the schedule are
# site-specific, and this tree is mirrored to a public repository where a hostname is a
# leak — so they carry @REPO@ / @SPOOL@ / @SPOOLFLAG@ / @SNAPSHOT@ / @PYTHON@ /
# @WARNHOURS@ / @STALEHOURS@ / @ONCALENDAR@ and this script substitutes them.
#
#   bash apps/dev-monitor/install-token-timer.sh [--oncalendar 'daily'] [--warn-hours 24]
#                                                [--stale-hours 24] [--no-messages]
#   bash apps/dev-monitor/install-token-timer.sh --uninstall
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
UNITDIR="$HOME/.config/systemd/user"
STATE="$HOME/.local/state/airlock/dev-monitor"
SPOOL="$STATE/spool"
SNAPSHOT="$STATE/token-freshness.json"
# Twice a day. The warning threshold is a day wide, so a check every twelve hours cannot
# miss a window; hourly would be noise on a signal that moves in days.
ONCALENDAR="00/12:00:00"
WARN_HOURS=""
STALE_HOURS=""
NO_MESSAGES=0
UNINSTALL=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --oncalendar)  ONCALENDAR="${2:?}"; shift 2 ;;
    --warn-hours)  WARN_HOURS="${2:?}"; shift 2 ;;
    --stale-hours) STALE_HOURS="${2:?}"; shift 2 ;;
    --spool)       SPOOL="${2:?}"; shift 2 ;;
    --no-messages) NO_MESSAGES=1; shift ;;
    --uninstall)   UNINSTALL=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '[token-timer] %s\n' "$*"; }
die() { printf '[token-timer] FATAL: %s\n' "$*" >&2; exit 1; }

UNITS=(airlock-token-freshness.service airlock-token-freshness.timer
       airlock-token-freshness-failed.service)

if [ "$UNINSTALL" = 1 ]; then
  systemctl --user disable --now airlock-token-freshness.timer >/dev/null 2>&1 || true
  for u in "${UNITS[@]}"; do rm -f "${UNITDIR:?}/$u"; done
  systemctl --user daemon-reload
  say "removed"
  exit 0
fi

# Argument validation comes BEFORE the environment refusals below, so a bad argument is
# reported as a bad argument wherever this runs. With the order reversed, the suite that
# checks "a non-numeric threshold is refused" passed in a worktree for the wrong reason —
# the script had died at the worktree guard and never looked at the argument.
# Read the declared configuration when there is one, so the timer and the dashboard card
# cannot disagree about what "soon" means. Flags win; airlock-config is the default.
# Written out one call per key rather than through a helper taking the key as an
# argument: a key assembled at runtime is invisible to airlock-config's declaration lint,
# which can only see call sites it can read literally.
CFG="$REPO/bin/airlock-config"
[ -n "$WARN_HOURS" ]  || WARN_HOURS="$("$CFG" get apps.dev-monitor.token_freshness_warn_hours 2>/dev/null || true)"
[ -n "$STALE_HOURS" ] || STALE_HOURS="$("$CFG" get apps.dev-monitor.token_freshness_stale_hours 2>/dev/null || true)"
[ -n "$WARN_HOURS" ]  || WARN_HOURS=24
[ -n "$STALE_HOURS" ] || STALE_HOURS=24
case "$WARN_HOURS"  in ''|*[!0-9]*) die "--warn-hours must be a positive integer: got '$WARN_HOURS'" ;; esac
case "$STALE_HOURS" in ''|*[!0-9]*) die "--stale-hours must be a positive integer: got '$STALE_HOURS'" ;; esac
[ "$WARN_HOURS" -ge 1 ]  || die "--warn-hours must be at least 1"
[ "$STALE_HOURS" -ge 1 ] || die "--stale-hours must be at least 1"

# A worktree is a legitimate checkout and also the thing somebody deletes on a Friday. A
# timer pointed at one fails forever afterwards, and the failure looks like a broken
# checker rather than a missing directory. Same refusal as live/install-timer.sh.
if [ -f "$REPO/.git" ]; then
  die "$REPO is a git worktree. Point the timer at a permanent clone — a worktree gets reclaimed and the job then fails on every tick for a reason that has nothing to do with airlock."
fi

# The templates end up as absolute paths inside unit files; a newline would inject
# further directives, and the placeholder check below cannot see that.
for v in "$SPOOL" "$SNAPSHOT" "$ONCALENDAR"; do
  case "$v" in *[$'\n\r']*) die "unit values must not contain newlines" ;; esac
done

# sed's REPLACEMENT side is not a literal: '&' means "the whole match" and a backslash
# escapes. A path containing either would render a unit line that is not the path the
# operator gave. The leftover-placeholder check below catches the '&' case loudly by
# accident; a backslash it would not catch at all.
sed_replacement() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

PYTHON="$(command -v python3)" || die "python3 not found"

# The loud channel. Without the spool the run still writes its snapshot and the dashboard
# card still shows the verdict, but nothing pushes — so that is a deliberate choice
# (--no-messages), never a default that quietly happens.
# One decision, made here and carried into the unit as a flag, so that "snapshot only"
# is what the service actually runs rather than something the script has to infer from an
# empty value at every tick.
if [ "$NO_MESSAGES" = 1 ]; then
  SPOOLFLAG="--no-spool"
  SPOOL=""
else
  SPOOLFLAG="--spool $SPOOL"
  [ -d "$SPOOL/new" ] || die "spool not found: $SPOOL/new. The message console is where this timer raises its voice; set 'messages = true' for dev-monitor and install it first, or pass --no-messages to run snapshot-only."
fi

# Linger, or a --user timer stops existing the moment the session ends. Checked rather
# than assumed: it is per user and per box, and "it was set on the box I tested on" is
# exactly how this goes quiet.
# $USER is not set in every non-login context (sudo -u ... bash -c, some CI runners), and
# under `set -u` an unset one kills this script with a raw bash message instead of the
# explanation written two lines down.
who="${USER:-$(id -un)}"
linger="$(loginctl show-user "$who" -p Linger --value 2>/dev/null || echo '')"
[ "$linger" = yes ] || die "linger is not enabled for $who — a --user timer will not survive logout. Run: loginctl enable-linger $who"

mkdir -p "$UNITDIR" "$STATE"
for u in "${UNITS[@]}"; do
  sed -e "s|@REPO@|$(sed_replacement "$REPO")|g" \
      -e "s|@SPOOLFLAG@|$(sed_replacement "$SPOOLFLAG")|g" \
      -e "s|@SPOOL@|$(sed_replacement "$SPOOL")|g" \
      -e "s|@SNAPSHOT@|$(sed_replacement "$SNAPSHOT")|g" \
      -e "s|@PYTHON@|$(sed_replacement "$PYTHON")|g" -e "s|@WARNHOURS@|$WARN_HOURS|g" \
      -e "s|@STALEHOURS@|$STALE_HOURS|g" -e "s|@ONCALENDAR@|$(sed_replacement "$ONCALENDAR")|g" \
    "$HERE/systemd/$u.in" > "$UNITDIR/$u" || die "could not render $u"
  grep -q '@[A-Z]*@' "$UNITDIR/$u" && die "$u still contains an unsubstituted placeholder"
done
say "rendered ${#UNITS[@]} units into $UNITDIR (warn=${WARN_HOURS}h stale=${STALE_HOURS}h)"

systemctl --user daemon-reload || die "daemon-reload failed"
systemctl --user enable --now airlock-token-freshness.timer >/dev/null 2>&1 \
  || die "could not enable the timer"

# The assertion that separates this from the committed-but-never-installed case: ask
# systemd, not the filesystem.
next="$(systemctl --user list-timers airlock-token-freshness.timer --no-pager --no-legend 2>/dev/null)"
[ -n "$next" ] || die "the timer is installed and enabled but does not appear in list-timers"
say "$next"
say "wired. It has NOT run yet — 'systemctl --user start airlock-token-freshness.service' to see it through once."
