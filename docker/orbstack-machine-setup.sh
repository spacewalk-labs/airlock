#!/usr/bin/env bash
# Airlock on macOS — recommended path: an OrbStack Linux *machine*.
#
# Run this ON YOUR MAC (not inside the machine). It creates a full systemd
# Ubuntu 24.04 userland via OrbStack, installs Airlock's base prerequisites,
# brings up Tailscale, and then runs the STOCK installer (install/airlock-
# install.sh) unchanged. See docs/design/macos-container.md for why a machine
# (native systemd) beats a hand-rolled container here.
#
#   bash docker/orbstack-machine-setup.sh
#
# Idempotent: re-run after editing airlock.toml to re-apply. Nothing here is
# destructive to an existing machine — it never deletes the machine or its state.
#
# STATUS: the terminal path has passed on Apple Silicon hardware. The first external
# launcher run reached this script on 2026-09-03 and exposed a Finder PATH defect; the
# launcher now supplies this account's resolved orb path through AIRLOCK_ORB_BIN.
set -euo pipefail

# ---- knobs (override via env) -------------------------------------------------
MACHINE="${AIRLOCK_MACHINE:-airlock}"
DISTRO="${AIRLOCK_DISTRO:-ubuntu:24.04}"
# Architecture of the Linux machine. The default is THIS MAC'S OWN arch, so the
# machine runs natively — the path that is verified end-to-end (see README-macos.md
# "Status"). It used to default to amd64 while every doc recommended arm64, which
# meant forgetting the variable landed you on the discouraged path, silently:
# under Rosetta the installer's `systemctl reload nginx` deactivates nginx (systemd
# cannot track the process), so the hub drops mid-install.
#
# Set AIRLOCK_ARCH=amd64 deliberately if you need orca, whose upstream ships
# x86_64-only builds — accepting the Rosetta caveat above. Everything else in the
# app set installs and smokes clean on arm64.
case "$(uname -m)" in
  arm64|aarch64) ARCH_DEFAULT=arm64 ;;
  x86_64)        ARCH_DEFAULT=amd64 ;;
  *) ARCH_DEFAULT="" ;;   # unknown host: refuse to guess, below
esac
ARCH="${AIRLOCK_ARCH:-$ARCH_DEFAULT}"
if [ -n "${AIRLOCK_ARCH:-}" ]; then ARCH_SRC="AIRLOCK_ARCH"; else ARCH_SRC="detected from $(uname -m)"; fi
# Where this repo should live INSIDE the machine. Defaults to sharing the Mac
# checkout via OrbStack's /mnt/mac mount so you edit one copy.
REPO_SRC="$(cd "$(dirname "$0")/.." && pwd)"

# AIRLOCK_PROGRESS=json turns the human log into machine-readable events. It exists
# because a GUI driving this script (docs/tasks/active/macos-app-launcher.md, Phase 1c)
# has to know WHICH step is running and which one failed, and the alternative is
# parsing ANSI-coloured prose that was written for a person.
#
# Events go to STDERR, and everything the underlying commands print stays on STDOUT.
# That split is the whole contract: the caller reads two pipes — which is what
# Process gives it anyway — and never has to guess whether a line is an event or
# installer output. No line-prefix convention, no JSON-shaped installer output
# problem. In the default mode nothing about stdout changes at all.
PROGRESS="${AIRLOCK_PROGRESS:-human}"
case "$PROGRESS" in
  human|json) ;;
  *) printf 'AIRLOCK_PROGRESS must be "human" or "json"; got %s\n' "$PROGRESS" >&2; exit 2 ;;
esac

# JSON string escaping, in bash alone.
#
# Not sed. This script runs on macOS and nowhere else, and BSD sed does not accept
# `\xNN` ranges (GNU does) — the first real run on a Mac died on the escaper's own
# first line, having emitted nothing else. Swapping in `[[:cntrl:]]` did not fix it
# either: BSD sed handles the `:a`/`N` label form differently and returned empty for
# every input. A Linux test suite cannot see any of this, because Linux has GNU sed.
#
# Parameter expansion has no such variance: it is bash, it is the same bash 3.2 that
# every Mac ships, and it needs no external command at all. Order is load-bearing —
# backslash first, or it escapes the escapes that follow.
#
# Newlines are the case that matters. The "airlock.toml not found" die below spans
# three lines, and unescaped it split one event object across three stderr lines,
# leaving the caller's parser broken at exactly the moment it most needed to report
# what went wrong.
_json() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  # Any other C0 byte becomes a space. These messages are literals from this file plus
  # paths, so one appearing means something is already wrong, and a readable event
  # beats a syntactically perfect one nobody can parse.
  local c
  for c in $'\001' $'\002' $'\003' $'\004' $'\005' $'\006' $'\016' $'\017' \
           $'\020' $'\021' $'\022' $'\023' $'\024' $'\025' $'\026' $'\027' \
           $'\030' $'\031' $'\032' $'\033' $'\034' $'\035' $'\036' $'\037' $'\177'; do
    s=${s//"$c"/ }
  done
  printf '%s' "$s"
}

# event <name> <key=value>...  — one JSON object per line, on stderr.
event() {
  [ "$PROGRESS" = json ] || return 0
  local name="$1"; shift
  local out
  out="{\"event\":\"$(_json "$name")\""
  local pair
  for pair in "$@"; do
    out="$out,\"$(_json "${pair%%=*}")\":\"$(_json "${pair#*=}")\""
  done
  printf '%s}\n' "$out" >&2
}

log()  {
  if [ "$PROGRESS" = json ]; then event log "message=$*"; return 0; fi
  printf '\033[1;36m[airlock-mac]\033[0m %s\n' "$*"
}
die()  {
  if [ "$PROGRESS" = json ]; then event fatal "message=$*"; exit 1; fi
  printf '\033[1;31m[airlock-mac] FATAL:\033[0m %s\n' "$*" >&2; exit 1
}
# step <id> — the run reached a named stage. Paired with `step_ok` so a caller can
# tell "started and still going" from "finished", which is the difference between a
# progress bar that moves and one that lies.
step()    { event step "step=$1" "status=start"; }
step_ok() { event step "step=$1" "status=ok"; }

# Say which arch this run uses, and where that came from, BEFORE anything happens.
# The old silent default is what let people spend a debugging session on the
# Rosetta nginx breakage without knowing they were on Rosetta.
[ -n "$ARCH" ] || die "cannot tell this Mac's architecture from 'uname -m' ($(uname -m)) — \
set AIRLOCK_ARCH=arm64 (Apple Silicon) or AIRLOCK_ARCH=amd64 (Intel) explicitly."
event arch "arch=$ARCH" "source=$ARCH_SRC"
log "architecture: $ARCH ($ARCH_SRC)"

if [ -n "${AIRLOCK_ORB_BIN:-}" ]; then
  case "$AIRLOCK_ORB_BIN" in
    /*) ;;
    *) die "AIRLOCK_ORB_BIN must be an absolute path; got '$AIRLOCK_ORB_BIN'" ;;
  esac
  if [ ! -x "$AIRLOCK_ORB_BIN" ] || [ -d "$AIRLOCK_ORB_BIN" ]; then
    die "OrbStack is installed, but its 'orb' command is not available at '$AIRLOCK_ORB_BIN'. Open OrbStack once in this account, then try again."
  fi
  ORB_BIN="$AIRLOCK_ORB_BIN"
else
  ORB_BIN="$(command -v orb 2>/dev/null || true)"
  if [ -z "$ORB_BIN" ]; then
    if [ -d /Applications/OrbStack.app ]; then
      die "OrbStack is installed, but its 'orb' command is not available for this account. Open OrbStack once, then try again."
    fi
    die "OrbStack 'orb' CLI not found. Install OrbStack: https://orbstack.dev"
  fi
fi
command -v orbctl >/dev/null 2>&1 || true
orb_cmd() { "$ORB_BIN" "$@"; }

# ---- 1. create the machine (idempotent) --------------------------------------
step machine
if orb_cmd list 2>/dev/null | awk '{print $1}' | grep -qx "$MACHINE"; then
  log "machine '$MACHINE' already exists — reusing"
else
  log "creating machine '$MACHINE' ($DISTRO, $ARCH via Rosetta if amd64)"
  orb_cmd create -a "$ARCH" "$DISTRO" "$MACHINE"
fi

step_ok machine

# Helper: run a command inside the machine as the default user (has passwd-less sudo).
inmc() { orb_cmd -m "$MACHINE" "$@"; }
# Helper: run as root inside the machine.
inroot() { orb_cmd -m "$MACHINE" -u root "$@"; }

# ---- 2. base prerequisites ----------------------------------------------------
step packages
# Everything the installers require but don't install themselves: nginx, node/npm,
# python3, curl/tar, nft (orca), tmux (devterm), and Tailscale. Kept minimal;
# each app installer fetches its own upstream tool.
# ---- 2a. nginx systemd drop-in — MUST come BEFORE `apt install nginx` --------
# The packaged nginx unit is Type=forking; under an amd64/Rosetta OrbStack
# machine systemd fails to detect the fork and the service start times out
# (~90s) even though nginx itself starts fine. A Type=simple + `daemon off`
# drop-in fixes it.
#   ⚠️ ORDERING IS LOAD-BEARING: if nginx is installed *before* this drop-in
#   exists, its own postinstall runs `systemctl start nginx`, that times out,
#   `dpkg --configure nginx` fails, and the ENTIRE apt run aborts — so node,
#   tailscale, etc. never install and the setup dies. (Reproduced on an M2 Mac
#   mini, 2026-07: the earlier "apply drop-in after install" ordering never let
#   a real install finish.) The drop-in dir may exist before the package;
#   systemd picks it up when the postinstall starts nginx. Harmless on
#   arm64-native machines (no fork-detect problem there).
log "pre-seeding nginx systemd drop-in (Type=simple) BEFORE install"
inroot bash -lc '
  set -e
  mkdir -p /etc/systemd/system/nginx.service.d
  cat > /etc/systemd/system/nginx.service.d/override.conf <<EOF
[Service]
Type=simple
ExecStart=
ExecStart=/usr/sbin/nginx -g "daemon off; master_process on;"
PIDFile=
TimeoutStartSec=30
EOF
  systemctl daemon-reload || true
'

# ---- 2b. base prerequisites ---------------------------------------------------
log "installing base packages inside the machine"
inroot bash -lc '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    nginx curl ca-certificates tar gnupg git python3 tmux nftables sudo
  # Node 20+ (paseo). NodeSource keeps npm current; skip if node>=20 present.
  if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed "s/v//;s/\..*//")" -lt 20 ]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  fi
  # GitHub CLI (gh) — repo clone/create workflows (harness starter clone, gh repo create).
  if ! command -v gh >/dev/null 2>&1; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list
    apt-get update -qq && apt-get install -y gh
  fi
  # Tailscale (official repo).
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
'

step_ok packages

# ---- 2c. make sure nginx is actually up (drop-in already applied in 2a) -------
step nginx
log "ensuring nginx is active"
inroot bash -lc '
  systemctl reset-failed nginx 2>/dev/null || true
  systemctl restart nginx || true
'

# ---- 2c. enable user lingering (VERIFIED on an Apple Silicon machine) ---------
# The app services are `systemctl --user` units. Without lingering they only run
# while the user has an active login session — so a headless machine loses them.
# enable-linger keeps the user systemd instance up across the box's life.
step_ok nginx
step linger
DEFAULT_USER="$(inmc whoami | tr -d '\r\n')"
log "enabling systemd lingering for '$DEFAULT_USER' (persistent --user services)"
inroot loginctl enable-linger "$DEFAULT_USER"

# ---- 3. bring up Tailscale (the fail-closed ingress precondition) -------------
# The installer aborts unless BackendState=Running. Authenticate here first.
# TS_AUTHKEY (from an env, never hardcoded) = non-interactive; otherwise the
# script prints the login URL for you to approve in a browser.
# --ssh advertises this node for Tailscale SSH (keyless, identity-gated remote
# login). Actual access still requires an `ssh` rule in the tailnet ACL policy.
step_ok linger
step tailscale
log "starting tailscaled + tailscale up"
inroot systemctl enable --now tailscaled
if [ -n "${TS_AUTHKEY:-}" ]; then
  inroot tailscale up --authkey "$TS_AUTHKEY" --hostname "$MACHINE" --ssh || die "tailscale up failed"
else
  log "no TS_AUTHKEY set — running interactive 'tailscale up' (approve the printed URL)"
  if [ "$PROGRESS" = json ]; then
    # The login URL exists only in tailscale's own stdout, and a GUI cannot ask the
    # operator to approve a link it never saw. Tee rather than capture: the line still
    # reaches stdout unchanged, so nothing about the human-visible output moves — this
    # branch only ADDS the event. (Only in json mode: piping an interactive command in
    # the default path would buy nothing and could delay the URL behind a buffer.)
    # `|| die` below is load-bearing and depends on `set -o pipefail` at the top of
    # this file: without it the pipeline's status is the while-loop's, which is 0 even
    # when `tailscale up` failed, and the run would sail past a failed login into the
    # installer. Verified by removing pipefail — the failure then exits 0.
    inroot tailscale up --hostname "$MACHINE" --ssh 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
      # `|| [ -n "$line" ]`: a final line with no trailing newline is a real shape for
      # a prompt, and plain `read` would discard it — losing exactly the URL this
      # branch exists to find.
      printf '%s\n' "$line"
      case "$line" in
        *https://login.tailscale.com/*)
          event login-url "url=$(printf '%s' "$line" \
            | grep -o 'https://login\.tailscale\.com/[^[:space:]]*' | head -1)" ;;
      esac
    done || die "tailscale up failed"
  else
    inroot tailscale up --hostname "$MACHINE" --ssh || die "tailscale up failed"
  fi
fi
inroot tailscale status >/dev/null 2>&1 || die "Tailscale not Running after 'up'"

step_ok tailscale

# ---- 4. make the repo + config available inside the machine -------------------
step repo
# OrbStack mounts the Mac fs under /mnt/mac. We run the installer directly from
# the shared checkout so there is a single copy of the code.
MC_REPO="/mnt/mac${REPO_SRC}"
log "using repo at (in-machine path): $MC_REPO"
inmc test -f "$MC_REPO/install/airlock-install.sh" \
  || die "repo not visible at $MC_REPO — is $REPO_SRC under your Mac home? (OrbStack shares /mnt/mac)"

if ! inmc test -f "$MC_REPO/airlock.toml"; then
  die "airlock.toml not found. Copy airlock.toml.example -> airlock.toml and fill it in
       (set owner; recommend leaving [apps.orca] out for the first run).
       See docs/design/macos-container.md §8."
fi

step_ok repo

# ---- 5. run the STOCK installer ----------------------------------------------
step install
log "running install/airlock-install.sh inside the machine"
inmc bash -lc "cd '$MC_REPO' && bash install/airlock-install.sh"

FQDN="$(inroot tailscale status --json 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)"
step_ok install
# No FQDN means the machine's tailnet name could not be read — which the script
# tolerates (`|| true` above) because the install itself succeeded. Emit no `url` at
# all rather than "https:///": an absent key makes the caller handle the case, while
# a syntactically valid URL pointing nowhere gets opened. The human line below says
# the same thing with a placeholder, which a person can read and a program cannot.
if [ -n "${FQDN:-}" ]; then
  event finished "url=https://$FQDN/" "fqdn=$FQDN"
else
  event finished "fqdn=" "note=could not read the machine's tailnet name; the install itself succeeded"
fi
log "done ($ARCH, $ARCH_SRC). Open:  https://${FQDN:-<your-machine>.<tailnet>.ts.net}/  and add to home screen."
log "re-run this script anytime after editing airlock.toml to re-apply."
