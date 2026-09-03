#!/usr/bin/env bash
# orca — headless Orca ADE (an Electron agent IDE served in the browser) behind
# the Airlock owner gate.  Upstream: https://github.com/stablyai/orca
#
#   browser --https--> tailscale serve :https_port --(identity)--> nginx owner-gate
#           --(owner only / else 403)--> orca serve 0.0.0.0:backend_port
#                                        (nft loopback-only: only the gate reaches it)
#
# Serves the PATCHED web client vendored at apps/orca/web-bundle/dist/ (PTY-reload
# fix + runtime-rebind, so terminals survive reload) at /orca-web/, and 302-redirects
# the vendor client URL to it. Owner document navigation to the bare root is redirected
# to the patched client carrying the pairing (zero-paste); a WebSocket upgrade to / is
# proxied to the runtime. If the bundle is absent it falls back to the raw upstream
# client. Provenance: apps/orca/web-bundle/README.md; attribution: repo-root NOTICE.
#
# Config from airlock.toml ([apps.orca]). Honors AIRLOCK_DRY_RUN=1: every system
# mutation (download, apt, systemctl, nft, tailscale, sudo) prints "[dry] ..."
# instead of running. The nginx fragment is config, not a mutation — always written.
#
# Pilot findings encoded below (each cost real debugging; do NOT "simplify" away):
# - orca serve has no --host flag, so it binds 0.0.0.0 -> nft loopback-only.
# - Under systemd --user the AppImage FUSE mount fails -> --appimage-extract + APPDIR.
# - orca is Electron (Chromium): even headless `serve` needs GTK libs + an X display
#   (no GTK -> 'libgtk-3.so.0' status 127; no display -> 'Missing X server' SIGSEGV).
# - The pairing URL is only ever written to serve.log, never to journald.
# - The orca daemon self-detaches into an app-orca-*.scope (app.slice), so the
#   service's own KillMode/MemoryMax never reach it -> ExecStopPost reap.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# ABI (D5): the caller sets AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID and runs
# this script with cwd = AIRLOCK_APP_DIR. AIRLOCK_ROOT is REQUIRED: the platform
# root cannot be derived from $0, because "$0/../.." is only the platform when the
# package happens to sit in the platform's own apps/ tree — the arrangement the
# apps/ cutover ends. $0-relative self-location (this file's own directory) stays
# fine and is what AIRLOCK_APP_DIR falls back to.
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
HERE="${AIRLOCK_APP_DIR:-$HERE}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-orca}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/gate/nginx-lib.sh"
# shellcheck source=/dev/null
. "$HERE/render.sh"

airlock_load orca
# Return-widget menu attributes. With devterm installed the widget's tap opens a small
# menu (return to Airlock / subscription accounts) instead of navigating straight away —
# this app owns the whole screen, so the account panel has no other way in. Without
# devterm there is nothing to open, so the attributes stay empty and a tap navigates.
WIDGET_MENU_ATTRS=""
PANEL_URL="$(airlock_panel_url || true)"
if [ -n "$PANEL_URL" ]; then
  WIDGET_MENU_ATTRS=" data-menu=\"1\" data-panel=\"${PANEL_URL}\""
fi

GATE_PORT="${AIRLOCK_ORCA_GATE_PORT:?}"
BACKEND_PORT="${AIRLOCK_ORCA_BACKEND_PORT:?}"
HTTPS_PORT="${AIRLOCK_ORCA_HTTPS_PORT:?}"
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
WEBROOT="${AIRLOCK_WEBROOT:-/opt/airlock/hub}"
# patched web client: vendored source in the repo, and the world-readable serve path
# nginx workers alias at request time (parallel to the hub webroot; NOT under $HOME,
# which is 0700 and www-data cannot traverse).
WEB_BUNDLE="$HERE/web-bundle/dist"
ORCA_SERVE_ROOT="$(dirname "$WEBROOT")/orca-web"
ORCA_DIST_SERVE="$ORCA_SERVE_ROOT/dist"

require_cmd curl sha256sum tar systemctl tailscale python3 nft ss sudo

# The pinned SHA below is for the amd64 AppImage only.
case "$(uname -m)" in
  x86_64) ;;
  *) die "orca: unsupported arch $(uname -m) — the pinned SHA is for amd64" ;;
esac

VER=1.4.139
ASSET=orca-linux.AppImage
URL="https://github.com/stablyai/orca/releases/download/v${VER}/${ASSET}"
SHA256=35ab8dc3b1427544ea1fc67f8c54a337f0b9b4d315abee4eedd9306006b43fb2

ORCA_DIR="$HOME/.local/share/airlock-orca"
APPIMAGE="$ORCA_DIR/orca-${VER}.AppImage"
SQUASHFS="$ORCA_DIR/squashfs-root"
APPRUN="$SQUASHFS/AppRun"
SERVELOG="$ORCA_DIR/serve.log"
UNIT_DIR="$HOME/.config/systemd/user"
# AIRLOCK_RENDER_DIR: harness-only destination-root override (highest
# priority). Redirects only where render output lands — install/lib.sh
# fail-closes if this is set without AIRLOCK_DRY_RUN=1, since real system
# mutations (systemctl, sudo tailscale serve, and orca's own sudo nft/
# systemctl calls) are gated on dry-run alone, not on this variable.
REAP_BIN="$HOME/.local/bin/airlock-orca-reap"
if [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  CONFD="$AIRLOCK_RENDER_DIR/confd"
  UNIT_DIR="$AIRLOCK_RENDER_DIR/units"
  REAP_BIN="$AIRLOCK_RENDER_DIR/bin/airlock-orca-reap"
fi
PAIRING_FILE="$HOME/.config/orca/airlock-pairing-code"
# Dedicated Xvfb display number so we never squat an ambient :99 someone else runs.
XDISP=59

# --- 1a. Electron runtime deps (Xvfb + GTK/nss/gbm/...) ---
# noble renamed several libs to the t64 ABI, so fall back to the non-t64 name per
# package -> distro-independent. sudo apt; skipped when already satisfied.
ORCA_DEPS="xvfb libgtk-3-0t64 libgbm1 libnss3 libasound2t64 libnotify4 libxtst6 libxss1 libatspi2.0-0t64 libsecret-1-0"
provision_runtime_deps() {
  # Capture, then match with a bash glob — NOT `ldconfig -p | grep -q`. The pipe
  # form is a race that fails precisely when the library IS there: grep -q exits at
  # the match and closes the pipe, ldconfig (whose -p output is far larger than the
  # 64 KB pipe buffer) takes SIGPIPE, and `set -o pipefail` reports the pipeline as
  # failed. Measured 2026-08-07 on a box where libgtk-3-0t64 was installed and in
  # the cache: this guard said "missing", the reinstall was a no-op, and the check
  # below said "libgtk-3 install failed". apps/fileview/smoke.sh:39 hit the same
  # race on a ~64 KB HTTP body and wrote it down; it did not reach here.
  local _libs; _libs="$(ldconfig -p 2>/dev/null || true)"
  if command -v Xvfb >/dev/null 2>&1 && [[ "$_libs" == *"libgtk-3.so.0"* ]]; then
    log "Electron runtime deps present (Xvfb + GTK)"; return
  fi
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
    log "[dry] sudo apt-get install Electron runtime deps: $ORCA_DEPS"; return
  fi
  # Every apt call here used to end in `>/dev/null 2>&1 || true`, so ten package
  # installs could all fail without a word and the only output was the die() below
  # naming a library. Measured 2026-08-07: this died with "libgtk-3 install failed"
  # on a box where libgtk-3-0t64 was installed and in the ldconfig cache, and the
  # reason is not knowable from that run — the ten apt transcripts were discarded.
  # airlock_quiet keeps them for exactly the run that needs them (install/lib.sh).
  airlock_quiet sudo apt-get update -qq \
    || log "apt-get update failed (output above) — continuing against the cached lists"
  local p missing=""
  for p in $ORCA_DEPS; do
    # noble renamed several of these to the t64 ABI; fall back to the old name.
    airlock_quiet sudo apt-get install -y "$p" \
      || airlock_quiet sudo apt-get install -y "${p%t64}" \
      || missing="$missing $p"
  done
  [ -z "$missing" ] || log "apt could not install:$missing (output above)"
  command -v Xvfb >/dev/null 2>&1 || die "Xvfb install failed — apt output above; apt could not install:${missing:- (nothing reported)}"
  # Blame the right thing: without ldconfig the next line proves nothing about GTK.
  command -v ldconfig >/dev/null 2>&1 \
    || die "ldconfig is not on PATH, so the Electron runtime libs cannot be verified (PATH=$PATH)"
  _libs="$(ldconfig -p 2>/dev/null || true)"
  [[ "$_libs" == *"libgtk-3.so.0"* ]] \
    || die "libgtk-3 is not in the ldconfig cache — Electron cannot run. apt output above; apt could not install:${missing:- (nothing reported)}"
}
provision_runtime_deps

# --- 1b. provision orca (sha256-pinned AppImage; extract for FUSE-less run) ---
provision_orca() {
  if [ -x "$APPRUN" ] && [ -f "$APPIMAGE" ] \
     && [ "$(sha256sum "$APPIMAGE" | cut -d' ' -f1)" = "$SHA256" ] \
     && [ ! "$APPIMAGE" -nt "$APPRUN" ]; then
    log "orca $VER present + extracted (sha ok)"; return
  fi
  need_restart=1   # binary missing or changed -> restart after (re)provisioning
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
    log "[dry] download+verify orca $VER ($ASSET) + --appimage-extract -> $SQUASHFS"; return
  fi
  install -d -m 700 "$ORCA_DIR"
  if [ ! -f "$APPIMAGE" ] || [ "$(sha256sum "$APPIMAGE" | cut -d' ' -f1)" != "$SHA256" ]; then
    log "downloading orca $VER: $URL"
    local td; td="$(mktemp -d)"
    curl -fsSL --max-time 300 -o "$td/$ASSET" "$URL" || { rm -rf "$td"; die "orca download failed: $URL"; }
    local got; got="$(sha256sum "$td/$ASSET" | cut -d' ' -f1)"
    [ "$got" = "$SHA256" ] || { rm -rf "$td"; die "orca sha256 mismatch got=$got want=$SHA256"; }
    mv "$td/$ASSET" "$APPIMAGE"; rm -rf "$td"
    log "orca sha256 verified ($VER)"
  fi
  chmod +x "$APPIMAGE"
  # AppImage FUSE mount fails under systemd --user -> extract and run AppRun directly.
  rm -rf "$SQUASHFS"
  ( cd "$ORCA_DIR" && "$APPIMAGE" --appimage-extract >/dev/null ) || die "orca AppImage extract failed"
  [ -x "$APPRUN" ] || die "orca AppRun missing after extract: $APPRUN"
}
# Tracks whether anything that requires a service restart changed this run. Kept 0
# on an idempotent re-run so we do NOT restart orca (which would kill the owner's
# live PTYs/browser panes — they are live-only and non-recoverable).
need_restart=0
provision_orca

# --- 2. fixed pairing code + tailnet FQDN (both baked into the unit ExecStart) ---
# A fixed pairing code -> a stable webClientUrl the owner can bookmark across
# restarts. The blob is just an endpoint pointer and sits behind the owner gate +
# nft, so it is inert if leaked. Owner-only (0600).
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] ensure fixed pairing code at $PAIRING_FILE (0600)"
  PAIRING_CODE="<pairing-code>"
  FQDN="<your-box>.ts.net"
else
  install -d "$HOME/.config/orca"
  if [ -s "$PAIRING_FILE" ]; then
    PAIRING_CODE="$(cat "$PAIRING_FILE")"
  else
    PAIRING_CODE="$(python3 -c 'import secrets;print(secrets.token_hex(16))')"
    install -m 600 /dev/null "$PAIRING_FILE"
    printf '%s' "$PAIRING_CODE" > "$PAIRING_FILE"
    log "generated fixed pairing code ($PAIRING_FILE, 0600)"
  fi
  FQDN="$(ts_fqdn)"
fi

# --- 3. systemd --user units: reap helper + dedicated Xvfb + orca serve ---
# AIRLOCK_RENDER_DIR forces this write branch even under AIRLOCK_DRY_RUN=1 — see
# install/lib.sh's fail-closed guard (RENDER_DIR without DRY_RUN=1 never reaches
# this line) and apps/feedback/install.sh's identical comment.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] write $REAP_BIN, $UNIT_DIR/airlock-orca-xvfb.service, $UNIT_DIR/airlock-orca.service"
else
  install -d "$UNIT_DIR" "$(dirname "$REAP_BIN")"

  # Daemon reap — orca forks its daemon into app-orca-*.scope (app.slice), which
  # the service's KillMode never reaches. Runs as ExecStopPost (i.e. on every
  # restart): kill the daemon pid (PID-reuse-safe via /proc/<pid>/exe) and stop
  # every leftover app-orca-*.scope (one agent-browser child leaks per restart).
  render_orca_reap_script >"$REAP_BIN"
  # RENDER_DIR is a harness text-emission-only hook — no chmod, no touching real
  # (non-redirected) state under $HOME.
  if [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
    chmod +x "$REAP_BIN"
  fi

  # Dedicated persistent Xvfb — orca is Electron and needs a real X display even
  # headless. A per-start xvfb-run races the socket create on some boxes ('Missing
  # X server'); a standing unit removes that race. orca (below) After/Requires it.
  if render_orca_unit_xvfb "$XDISP" | write_if_changed "$UNIT_DIR/airlock-orca-xvfb.service"
  then need_restart=1; fi

  # orca serve — single instance behind the loopback gate.
  if render_orca_unit_serve "$SQUASHFS" "$XDISP" "$APPRUN" "$BACKEND_PORT" "$PAIRING_CODE" \
       "$FQDN" "$HTTPS_PORT" "$SERVELOG" "$REAP_BIN" \
     | write_if_changed "$UNIT_DIR/airlock-orca.service"
  then need_restart=1; fi

  # serve.log 0600 (it holds the pairing webClientUrl). ExecStart's '>' preserves
  # an existing file's mode, so lock it down before the first start. Skipped under
  # RENDER_DIR: SERVELOG is real (non-redirected) $HOME state, not a render target.
  if [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
    [ -e "$SERVELOG" ] || : > "$SERVELOG" 2>/dev/null || true
    chmod 600 "$SERVELOG" 2>/dev/null || true
  fi
fi

airlock_run systemctl --user daemon-reload
airlock_run systemctl --user enable airlock-orca-xvfb.service airlock-orca.service
# Restart only when something changed (or the service is down / dry-run). An
# idempotent re-run with no changes must NOT restart — that would kill the owner's
# live orca session (PTYs + browser panes are live-only and non-recoverable).
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] || [ "$need_restart" = 1 ] \
   || ! systemctl --user is-active --quiet airlock-orca.service; then
  if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
    # :59 is an exclusive singleton shared with older Orca stacks. Discover
    # the pathname/abstract listeners from /proc, then map their MainPIDs back
    # to actual user services. Their declared systemd RequiredBy consumers are
    # stopped in the same transaction. The two names below are candidate
    # artifacts we own, not guesses about legacy naming.
    airlock_handover_user_resource x-display "$XDISP" "Orca X display :$XDISP" \
      --required-by \
      airlock-orca-xvfb.service airlock-orca.service
  fi
  airlock_run systemctl --user restart airlock-orca-xvfb.service airlock-orca.service
else
  log "orca unchanged and active — not restarting (preserves the live session)"
fi

# --- 4. nft: restrict the backend to loopback callers (orca binds 0.0.0.0) ---
# orca serve has no --host flag, so it binds 0.0.0.0:BACKEND. Without this the
# backend is reachable directly over the tailnet, bypassing the owner gate.
# render_loopback_nft fills the shared gate/loopback-only.nft.tpl (table
# airlock_orca, isolated from docker's ip/ip6 tables). A systemd oneshot re-applies
# it on boot — nft rulesets are not persistent by default, so a reboot would
# otherwise silently reopen the hole.
NFT_FILE="/etc/airlock/orca-loopback.nft"
NFT_UNIT="/etc/systemd/system/airlock-orca-firewall.service"
if [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  NFT_FILE="$AIRLOCK_RENDER_DIR/etc-airlock/orca-loopback.nft"
  NFT_UNIT="$AIRLOCK_RENDER_DIR/etc-systemd-system/airlock-orca-firewall.service"
fi
# AIRLOCK_RENDER_DIR forces text emission for this sudo-tee write site even under
# AIRLOCK_DRY_RUN=1 — but unlike every other app's --user unit write, this one's
# real branch reaches sudo (system-scope nft file + unit). The RENDER_DIR branch
# below therefore CANNOT share the real branch: it writes the same rendered bytes
# with a plain redirect instead, and never touches sudo/systemctl (install/lib.sh's
# fail-closed guard means RENDER_DIR is always paired with DRY_RUN=1, so this is
# the ONLY way this path is reached without AIRLOCK_DRY_RUN=1 alone taking the
# first branch instead).
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] render_loopback_nft airlock_orca $BACKEND_PORT -> $NFT_FILE"
  log "[dry] write $NFT_UNIT + sudo nft -f (drop non-loopback -> :$BACKEND_PORT)"
elif [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  install -d "$(dirname "$NFT_FILE")" "$(dirname "$NFT_UNIT")"
  render_loopback_nft airlock_orca "$BACKEND_PORT" > "$NFT_FILE"
  render_orca_unit_firewall "$BACKEND_PORT" "$NFT_FILE" > "$NFT_UNIT"
else
  sudo install -d "$(dirname "$NFT_FILE")"
  render_loopback_nft airlock_orca "$BACKEND_PORT" | sudo tee "$NFT_FILE" >/dev/null
  render_orca_unit_firewall "$BACKEND_PORT" "$NFT_FILE" | sudo tee "$NFT_UNIT" >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable --now airlock-orca-firewall.service
fi

# --- 4b. AppArmor: let the Electron sandbox open its user namespace ---
# Ubuntu 24.04's default kernel.apparmor_restrict_unprivileged_userns=1 makes orca
# SIGTRAP on every start (see render_orca_apparmor for why the SUID fallback cannot
# rescue it under NoNewPrivileges=yes). This never showed on the dev box because that
# host has the restriction turned off; a stock 24.04 desktop restart-loops instead.
# Scoped to this AppImage's binaries, so the box-wide sysctl is left alone.
AA_PROFILE="/etc/apparmor.d/airlock-orca"
if [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  AA_PROFILE="$AIRLOCK_RENDER_DIR/etc-apparmor.d/airlock-orca"
fi
# Same three-branch shape as the nft block above: dry-run logs, RENDER_DIR emits the
# bytes with a plain redirect, and only the real branch reaches sudo.
AA_RESTRICT_SYSCTL=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] write $AA_PROFILE + sudo apparmor_parser -r (userns for $SQUASHFS)"
elif [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  install -d "$(dirname "$AA_PROFILE")"
  render_orca_apparmor "$SQUASHFS" > "$AA_PROFILE"
elif [ ! -d /sys/kernel/security/apparmor ] || ! command -v apparmor_parser >/dev/null 2>&1; then
  log "apparmor not enabled on this box — skipping the orca userns profile"
else
  # Required (not best-effort) exactly when the kernel is denying userns: without the
  # profile orca cannot start at all, so a parser failure must stop the install
  # rather than hand back a box whose orca restart-loops.
  AA_REQUIRED=0
  [ -r "$AA_RESTRICT_SYSCTL" ] && [ "$(cat "$AA_RESTRICT_SYSCTL")" = 1 ] && AA_REQUIRED=1
  render_orca_apparmor "$SQUASHFS" | sudo tee "$AA_PROFILE" >/dev/null
  if sudo apparmor_parser -r "$AA_PROFILE"; then
    log "apparmor: userns profile loaded for orca ($AA_PROFILE)"
  elif [ "$AA_REQUIRED" = 1 ]; then
    die "apparmor_parser failed on $AA_PROFILE and this kernel denies unprivileged userns — orca would restart-loop"
  else
    sudo rm -f "$AA_PROFILE"
    log "apparmor: profile rejected by this parser; kernel allows userns, so continuing without it"
  fi
fi

# --- 5. tailscale serve: HTTPS (secure context, for clipboard) -> the owner gate ---
# The platform renders this now (manifest [serve.https]; child-4 P2b STEP 0
# — install/lib.sh's airlock_render_serve_https, called from
# install/airlock-install.sh right after this script returns) — byte-
# identical to the direct call this used to make
# (install/test-serve-https-parity.sh proved the two productions equal
# before this line was removed).

# --- 6. install the patched web client (vendored dist) to a world-readable path ---
# nginx workers (www-data) serve the alias'd files at request time, so the dist must
# live somewhere they can traverse — NOT under $HOME (0700). Copy only when the entry
# HTML changed (the bundle is ~22M), so an idempotent re-run does no needless work.
ORCA_WEB_ENABLED=0
if [ -f "$WEB_BUNDLE/web-index.html" ]; then
  # Check the bundle against its provenance pin BEFORE serving it. A partial clone or a
  # truncated copy yields a client that serves 200s and renders a blank page, which is
  # indistinguishable from "installed fine" — so a mismatch fails the install loudly.
  # (The entry-HTML comparison below is a cheap staleness check, not an integrity one.)
  BUNDLE_VERIFY="$HERE/bin/verify-web-bundle.sh"
  if [ -x "$BUNDLE_VERIFY" ]; then
    bash "$BUNDLE_VERIFY" --quiet || die "orca web-bundle does not match web-bundle/VERSION — refusing to serve it"
  else
    log "warning: $BUNDLE_VERIFY missing — serving the bundle unverified"
  fi
  ORCA_WEB_ENABLED=1
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
    log "[dry] install patched web client: $WEB_BUNDLE -> $ORCA_DIST_SERVE (sudo, a+rX)"
  elif ! cmp -s "$WEB_BUNDLE/web-index.html" "$ORCA_DIST_SERVE/web-index.html" 2>/dev/null \
       || [ ! -d "$ORCA_DIST_SERVE/assets" ]; then
    sudo install -d "$ORCA_SERVE_ROOT"
    sudo rm -rf "$ORCA_DIST_SERVE"
    sudo cp -r "$WEB_BUNDLE" "$ORCA_DIST_SERVE"
    sudo chmod -R a+rX "$ORCA_SERVE_ROOT"
    log "installed patched web client -> $ORCA_DIST_SERVE ($(du -sh "$ORCA_DIST_SERVE" 2>/dev/null | cut -f1))"
  else
    log "patched web client already current -> $ORCA_DIST_SERVE"
  fi
else
  log "WARNING: web-bundle not vendored at $WEB_BUNDLE — serving the raw upstream client (no /orca-web/, no zero-paste)"
fi

# --- 7. wait for the backend + capture the pairing blob (for zero-paste) ---
# orca (Electron) cold-starts slowly. Give the backend a bounded window to bind so the
# fragment below can bake in the pairing, and so smoke doesn't race a still-booting
# daemon. Non-fatal: the orchestrator's smoke is the real gate.
pairing_frag=""
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  ready=0
  for _ in $(seq 1 30); do
    if ss -ltn 2>/dev/null | grep -qE ":${BACKEND_PORT}\b"; then ready=1; break; fi
    sleep 2
  done
  if [ "$ready" = 1 ]; then
    log "orca backend listening on 127.0.0.1:${BACKEND_PORT}"
    # webClientUrl is stable across restarts (fixed pairing-code + persisted runtime
    # key), so a prior serve.log is fine; poll briefly in case orca just cold-started.
    web_url=""
    for _ in $(seq 1 15); do
      web_url="$(grep -oE 'https://[^ "]*web-index\.html#pairing=[^ "]*' "$SERVELOG" 2>/dev/null | tail -1 || true)"
      [ -n "$web_url" ] && break
      sleep 1
    done
    if [ -n "$web_url" ]; then
      # keep only the #pairing=<blob> fragment (the blob carries the runtime deviceToken)
      pairing_frag="#pairing=${web_url#*#pairing=}"
      log "captured pairing for zero-paste entry (from $SERVELOG)"
    else
      log "pairing URL not in $SERVELOG yet — /orca-web/ will load but ask to pair once (re-run install to wire zero-paste)"
    fi
  else
    log "warning: orca backend not listening after ~60s (smoke will verify; check: journalctl --user -u airlock-orca)"
  fi
fi

# --- 8. nginx owner-gate fragment (owner-only; written unconditionally) ---
# Base gate = emit_owner_gate (WS-safe proxy + served/injected return widget). When the
# patched client is vendored we ALSO, inside the SAME gated server: serve it at
# /orca-web/ (static alias + widget injection), 302 the vendor client path to it, and
# (zero-paste) redirect the owner's bare-root document navigation to it carrying the
# pairing — while a WebSocket upgrade to / is proxied to the runtime (see the
# $orca_redir map). Each added location carries its own owner guard (a per-location `if`
# only covers its own location; emit_owner_gate guards only location /).
frag="$CONFD/servers.d/orca.conf"
install -d "$CONFD/servers.d"
render_orca_nginx "$GATE_PORT" "$BACKEND_PORT" "$WEBROOT" "$ORCA_WEB_ENABLED" \
  "$ORCA_DIST_SERVE" "$WIDGET_MENU_ATTRS" "$pairing_frag" > "$frag"
# The fragment embeds the pairing blob (deviceToken) when captured -> lock to owner/root
# (nginx master reads config as root). serve.log is already 0600 for the same reason.
if [ -n "$pairing_frag" ]; then chmod 600 "$frag" 2>/dev/null || true; fi
log "wrote nginx fragment: $frag"

# NOTE: smoke runs from the orchestrator AFTER nginx is rendered + reloaded
# (the gate isn't live until then). See install/airlock-install.sh.
if [ "$ORCA_WEB_ENABLED" = 1 ]; then
  log "orca installed (owner: ${AIRLOCK_OWNER}) — patched client at /orca-web/, open https://${FQDN}:${HTTPS_PORT}/"
else
  log "orca installed (owner: ${AIRLOCK_OWNER}) — upstream client, open https://${FQDN}:${HTTPS_PORT}/"
fi
