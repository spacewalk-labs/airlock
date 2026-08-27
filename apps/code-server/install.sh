#!/usr/bin/env bash
# code-server — browser IDE (coder/code-server, MIT) behind the Airlock owner gate.
#
#   browser --https--> tailscale serve :https_port --(identity)--> nginx owner-gate
#           --(owner only / else 403)--> tab-bar shell + slot manager
#                                        --> code-server 127.0.0.1:<backend + N - 1>
#
# Multi-instance: a small asyncio slot manager (systemd --user) spawns/stops up to
# `slots` code-server instances, each a templated unit (airlock-code-server@N) on
# its own loopback port. A static tab-bar shell (spawn/kill/rename/color/reorder +
# iframe readiness-retry) drives it over the gate's /api/ route. All counts/ports
# come from airlock.toml ([apps.code-server]). Greenfield: no legacy migration.
# Honors AIRLOCK_DRY_RUN=1.
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
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-code-server}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/gate/nginx-lib.sh"
# shellcheck source=/dev/null
. "$HERE/render.sh"

require_cmd curl sha256sum tar systemctl tailscale python3 sudo
airlock_load code-server
GATE_PORT="${AIRLOCK_CODE_SERVER_GATE_PORT:?}"
BACKEND_PORT="${AIRLOCK_CODE_SERVER_BACKEND_PORT:?}"   # slot 1's port; slot N = +N-1
HTTPS_PORT="${AIRLOCK_CODE_SERVER_HTTPS_PORT:?}"
MANAGER_PORT="${AIRLOCK_CODE_SERVER_MANAGER_PORT:?}"
SLOTS="${AIRLOCK_CODE_SERVER_SLOTS:?}"
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
WEBROOT="${AIRLOCK_WEBROOT:-/opt/airlock/hub}"
# AIRLOCK_RENDER_DIR: harness-only destination-root override (highest
# priority). Redirects only where render output lands — install/lib.sh
# fail-closes if this is set without AIRLOCK_DRY_RUN=1, since real system
# mutations (systemctl, sudo tailscale serve, and orca's own sudo nft/
# systemctl calls) are gated on dry-run alone, not on this variable.
if [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  CONFD="$AIRLOCK_RENDER_DIR/confd"
fi

case "$SLOTS" in ''|*[!0-9]*) die "code-server: slots must be a positive integer (got '$SLOTS')";; esac
[ "$SLOTS" -ge 1 ] || die "code-server: slots must be >= 1 (got $SLOTS)"
BACKEND_BASE=$(( BACKEND_PORT - 1 ))    # slot N binds BACKEND_BASE + N

# ExecCondition allow-list "1|2|...|slots" — a rogue instance (@99) is a clean skip.
SLOT_CASE=""
for (( i = 1; i <= SLOTS; i++ )); do SLOT_CASE="${SLOT_CASE:+$SLOT_CASE|}$i"; done

VER=4.128.0
# arch-aware asset + pinned sha256 — code-server ships both amd64 and arm64 builds,
# so this installs natively on Apple Silicon / arm64 OrbStack machines too.
case "$(uname -m)" in
  x86_64)        ARCH_TAG=amd64; SHA256=79ba26bf186e5268a22b7c17b30a5f288a16c37791f0b86c27859e8fef103188 ;;
  aarch64|arm64) ARCH_TAG=arm64; SHA256=f8f02c2a81d1a433a4d132716a6f0405f690f6d70dd955942e95e87356db8a10 ;;
  *) die "code-server: unsupported arch $(uname -m)" ;;
esac
ASSET="code-server-${VER}-linux-${ARCH_TAG}"
BIN="$HOME/.local/bin/code-server"
LIB="$HOME/.local/lib/${ASSET}"
SHARE="$HOME/.local/share/airlock-code-server"
UNIT_DIR="$HOME/.config/systemd/user"
[ -n "${AIRLOCK_RENDER_DIR:-}" ] && UNIT_DIR="$AIRLOCK_RENDER_DIR/units"
SLOT_LAUNCHER="$HOME/.local/bin/airlock-code-server-slot"
MANAGER_BIN="$HOME/.local/bin/airlock-code-server-manager"
MANAGER_SRC="$HERE/manager/manager.py"
SHELL_DIR="$CONFD/code-server"

# --- 1. provision code-server (sha256-pinned; no piped installer) ---
provision_code_server() {
  if [ -x "$LIB/bin/code-server" ] && "$LIB/bin/code-server" --version 2>/dev/null | head -1 | grep -q "$VER"; then
    ln -sfn "$LIB/bin/code-server" "$BIN"; log "code-server $VER present"; return
  fi
  local url="https://github.com/coder/code-server/releases/download/v${VER}/${ASSET}.tar.gz"
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then log "[dry] download+verify code-server $VER -> $BIN"; return; fi
  local td; td="$(mktemp -d)"
  curl -fsSL --max-time 90 -o "$td/cs.tgz" "$url" || { rm -rf "$td"; die "code-server download failed"; }
  local got; got="$(sha256sum "$td/cs.tgz" | cut -d' ' -f1)"
  [ "$got" = "$SHA256" ] || { rm -rf "$td"; die "code-server sha256 mismatch got=$got want=$SHA256"; }
  install -d "$HOME/.local/lib"; rm -rf "$LIB"
  tar -xzf "$td/cs.tgz" -C "$HOME/.local/lib" || { rm -rf "$td"; die "code-server extract failed"; }
  ln -sfn "$LIB/bin/code-server" "$BIN"; rm -rf "$td"
  log "code-server sha256 verified ($VER)"
}
provision_code_server

[ -f "$MANAGER_SRC" ] || die "code-server: manager not found: $MANAGER_SRC"

# --- 2. config + slot launcher + manager binary ---
# `changed` gates service restarts so re-running the installer (e.g. after editing
# an unrelated app) does not needlessly restart a live IDE session.
changed=0
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] write config.yaml + install slot launcher + manager (slots=$SLOTS base=$BACKEND_BASE mgr=$MANAGER_PORT)"
else
  install -d "$HOME/.config/code-server" "$UNIT_DIR" "$HOME/.local/bin" "$SHARE/extensions"
  # auth none is safe ONLY because the sole external path is the identity gate and
  # each slot binds loopback (see SECURITY.md).
  if write_if_changed "$HOME/.config/code-server/config.yaml" <<'YAML'
auth: none
cert: false
disable-telemetry: true
disable-update-check: true
YAML
  then changed=1; fi

  cmp -s "$HERE/bin/airlock-code-server-slot" "$SLOT_LAUNCHER" 2>/dev/null || changed=1
  install -m755 "$HERE/bin/airlock-code-server-slot" "$SLOT_LAUNCHER"
  cmp -s "$MANAGER_SRC" "$MANAGER_BIN" 2>/dev/null || changed=1
  install -m755 "$MANAGER_SRC" "$MANAGER_BIN"
fi

# --- 3. systemd units (templated slot unit + manager), idempotent ---
# AIRLOCK_RENDER_DIR forces this write branch even under AIRLOCK_DRY_RUN=1 — see
# install/lib.sh's fail-closed guard (RENDER_DIR without DRY_RUN=1 never reaches
# this line) and apps/feedback/install.sh's identical comment.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] write airlock-code-server@.service (ExecCondition case $SLOT_CASE) + airlock-code-server-manager.service"
else
  # Slot template: the port math lives in the launcher (see bin/airlock-code-server-slot)
  # to avoid systemd/shell arithmetic on %i.
  if render_code_server_unit_slot "$BACKEND_BASE" "$SLOT_CASE" "$SLOTS" | write_if_changed "$UNIT_DIR/airlock-code-server@.service"
  then changed=1; fi

  if render_code_server_unit_manager "$MANAGER_PORT" "$SLOTS" "$BACKEND_PORT" "$AIRLOCK_OWNER" "$AIRLOCK_IDENTITY_HEADER" \
     | write_if_changed "$UNIT_DIR/airlock-code-server-manager.service"
  then changed=1; fi
fi

airlock_run systemctl --user daemon-reload
airlock_run systemctl --user enable airlock-code-server@1.service
airlock_run systemctl --user enable airlock-code-server-manager.service
if [ "$changed" = 1 ]; then
  airlock_run systemctl --user restart airlock-code-server-manager.service
  airlock_run systemctl --user restart airlock-code-server@1.service
else
  # nothing changed — just ensure slot 1 + manager are up (first run / after stop).
  airlock_run systemctl --user start airlock-code-server-manager.service
  airlock_run systemctl --user start airlock-code-server@1.service
fi

# --- 4. tab-bar shell (served static by the gate; MAX_SLOTS templated from config) ---
# Config (not a system mutation) — written unconditionally so the gate's root is real.
install -d "$SHELL_DIR"
sed "s/@@MAX_SLOTS@@/${SLOTS}/g" "$HERE/web/shell.html" > "$SHELL_DIR/shell.html"
# [branding] icon_ring: the shell's favicon is an inline data URI (the gate serves
# shell.html as a single static file and 204s /favicon.ico), so ring it in place:
# decode the mark, wrap it, put it back as one base64 data URI.
if [ -n "${AIRLOCK_ICON_RING:-}" ]; then
  mark="$(grep -o 'href="data:image/svg+xml,[^"]*"' "$SHELL_DIR/shell.html" \
          | head -1 | sed -e 's/^href="//' -e 's/"$//')"
  if [ -n "$mark" ]; then
    tmp_mark="$(mktemp --suffix=.svg)"
    python3 -c 'import sys,urllib.parse; sys.stdout.write(urllib.parse.unquote(sys.argv[1].split(",",1)[1]))' \
      "$mark" > "$tmp_mark"
    ringed="$(ring_icon_svg "$AIRLOCK_ICON_RING" "$tmp_mark" | base64 -w0)"
    rm -f "$tmp_mark"
    # | delimiter: base64's alphabet has / but no |
    sed -i "s|href=\"data:image/svg+xml,[^\"]*\"|href=\"data:image/svg+xml;base64,${ringed}\"|" \
      "$SHELL_DIR/shell.html"
    log "shell favicon ringed (${AIRLOCK_ICON_RING})"
  else
    log "warning: shell.html has no inline favicon to ring — icon_ring skipped"
  fi
fi
log "wrote shell: $SHELL_DIR/shell.html (maxSlots=$SLOTS)"

# --- 5. nginx slot gate fragment (owner-only shell + /s/N/ per slot + /api/) ---
frag="$CONFD/servers.d/code-server.conf"
install -d "$CONFD/servers.d"
render_code_server_nginx "$GATE_PORT" "$BACKEND_PORT" "$SLOTS" "$MANAGER_PORT" "$SHELL_DIR" "$WEBROOT" > "$frag"
log "wrote nginx fragment: $frag"

# --- 6. tailscale serve (https only — code-server wants a secure context) ---
# The platform renders this now (manifest [serve.https]; child-4 P2b STEP 0
# — install/lib.sh's airlock_render_serve_https, called from
# install/airlock-install.sh right after this script returns) — byte-
# identical to the direct call this used to make
# (install/test-serve-https-parity.sh proved the two productions equal
# before this line was removed).

# NOTE: smoke runs from the orchestrator AFTER nginx reload (gate not live before).
log "code-server installed (owner: ${AIRLOCK_OWNER}, slots: ${SLOTS})"
