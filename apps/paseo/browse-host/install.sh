#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Install the Paseo server-side browse host sidecar (a loopback WS client that
# registers a browser automation host with the paseo daemon and drives headless
# Chromium).
#
# FOLLOW-UP — NOT wired into the Airlock v1 installer. Run this manually, as the
# box owner (paseo is owner-gated), after the paseo daemon is installed. It needs
# Playwright + a SHA-pinned paseo web-ui bundle patch (patch-web-ui.js). See
# README.md in this directory. Idempotent.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
require_cmd node npm systemctl

INSTALL_DIR="$HOME/.local/share/paseo-browse-host"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/airlock-paseo-browse-host.service"
SVC="airlock-paseo-browse-host.service"

# Ports/origin. Defaults match airlock.toml [apps.paseo]; when wiring this in,
# reconcile them with your resolved airlock config.
PASEO_BACKEND_PORT="${PASEO_BACKEND_PORT:-6767}"
PASEO_BROWSE_STREAM_PORT="${PASEO_BROWSE_STREAM_PORT:-6768}"
PASEO_HTTPS_PORT="${PASEO_HTTPS_PORT:-8447}"

log() { echo "[browse-host] $*"; }
fatal() { echo "[FATAL] browse-host: $*" >&2; exit 1; }

# --- node >= 20 guard (same discipline as the paseo installer) ---
command -v node >/dev/null 2>&1 || fatal "node not found (>= 20 required)"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
[ "${NODE_MAJOR:-0}" -ge 20 ] || fatal "node >= 20 required (found $(node -v 2>/dev/null))"
NODE_BIN_DIR="$(dirname "$(readlink -f "$(command -v node)")")"
NPM_BIN="$(command -v npm)" || fatal "npm not found"

# --- stage source into a stable install dir (survives repo/redeploy churn) ---
mkdir -p "$INSTALL_DIR/test"
cp -f "$SELF_DIR/package.json" "$INSTALL_DIR/package.json"
rm -rf "$INSTALL_DIR/src" "$INSTALL_DIR/bin" "$INSTALL_DIR/web"
cp -rf "$SELF_DIR/src" "$INSTALL_DIR/src"
cp -rf "$SELF_DIR/bin" "$INSTALL_DIR/bin"
cp -rf "$SELF_DIR/web" "$INSTALL_DIR/web"
cp -f "$SELF_DIR/test/smoke.cjs" "$INSTALL_DIR/test/smoke.cjs"

# --- install deps (ws + playwright) ---
log "npm install (ws + playwright) -> $INSTALL_DIR"
( cd "$INSTALL_DIR" && "$NPM_BIN" install --omit=dev --no-audit --no-fund --loglevel=error ) \
  || fatal "npm install failed"

# --- ensure chromium (idempotent: playwright install skips if present) ---
# Downloads to ~/.cache/ms-playwright (PLAYWRIGHT_BROWSERS_PATH default).
log "ensuring playwright chromium (skips if present)"
( cd "$INSTALL_DIR" && node node_modules/playwright/cli.js install chromium ) \
  || fatal "playwright chromium install failed"

# --- ensure chromium's OS libraries (idempotent) ---
# `playwright install` fetches the browser but not the shared libraries it links
# against. On a minimal box that leaves chromium downloaded and every launch dead
# with `libatk-1.0.so.0: cannot open shared object file` — measured. Nothing above
# notices: the download succeeded, this installer exited 0, and the sidecar came up
# and registered a browser host it could never drive.
#
# So probe by LAUNCHING, with the options host.js uses — including
# PASEO_BROWSE_CHROMIUM_PATH, or the probe answers for a different binary than the
# sidecar starts. The missing library is what a launch reports and what checking the
# download does not.
chromium_launch_error() {
  ( cd "$INSTALL_DIR" && node -e '
      const opts = { headless: true, args: ["--no-sandbox"] };
      if (process.env.PASEO_BROWSE_CHROMIUM_PATH) opts.executablePath = process.env.PASEO_BROWSE_CHROMIUM_PATH;
      require("playwright").chromium
        .launch(opts)
        .then((b) => b.close())
        .then(() => process.exit(0))
        .catch((e) => { console.error(String((e && e.message) || e).split("\n")[0]); process.exit(1); });
    ' >/dev/null ) 2>&1
}
if launch_err="$(chromium_launch_error)"; then
  log "chromium launches (OS libraries present)"
else
  log "chromium cannot launch: ${launch_err:-unknown} — installing its OS libraries (needs root)"
  # install-deps runs the distro package manager, so it needs root. Non-interactive
  # only: this installer must never sit waiting on a password prompt.
  if sudo -n true 2>/dev/null; then
    ( cd "$INSTALL_DIR" && sudo -n "$NODE_BIN_DIR/node" node_modules/playwright/cli.js install-deps chromium ) \
      || log "WARN: playwright install-deps chromium failed — re-probing to see what actually broke"
  else
    fatal "chromium is missing OS libraries and passwordless sudo is unavailable. Run:
    (cd $INSTALL_DIR && sudo node node_modules/playwright/cli.js install-deps chromium)
  then re-run this installer."
  fi
  if launch_err="$(chromium_launch_error)"; then
    log "chromium launches (OS libraries installed)"
  else
    # Fatal here, not a warning: driving this browser is the sidecar's only job. The
    # paseo installer runs us warn-only, so the hub and the daemon are unaffected.
    fatal "chromium still cannot launch after install-deps: ${launch_err:-unknown}"
  fi
fi

# --- box FQDN + allowed WS Origin (for the Level 2 live-view stream) ---
# Prefer the value passed by the caller; else derive from tailscale.
FQDN="${PASEO_BROWSE_FQDN:-}"
if [ -z "$FQDN" ]; then
  FQDN="$(tailscale status --self --json 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).Self.DNSName.replace(/\.$/,""))}catch{process.exit(1)}})' 2>/dev/null \
    || echo "")"
fi
if [ -n "$FQDN" ]; then
  ALLOWED_ORIGIN="https://${FQDN}:${PASEO_HTTPS_PORT}"
  log "live-view allowed Origin = $ALLOWED_ORIGIN"
else
  ALLOWED_ORIGIN=""
  log "WARN: FQDN not resolved — ALLOWED_ORIGIN unset (owner gate still protects; only Origin verification is relaxed)"
fi

# --- Level 2 web-ui bundle patch (live browser panel) ---
# Fail-loud patcher, but non-fatal to the sidecar: agent browsing (Level 1) works
# regardless. Skip with PASEO_BROWSE_SKIP_WEBUI_PATCH=1. On a @getpaseo version
# bump the patcher exits non-zero (SHA drift) -> we WARN loudly and continue.
if [ "${PASEO_BROWSE_SKIP_WEBUI_PATCH:-0}" = "1" ]; then
  log "web-ui patch skipped (PASEO_BROWSE_SKIP_WEBUI_PATCH=1) — live panel off (agent browsing still works)"
else
  WEBUI_DIR="${PASEO_WEBUI_DIR:-}"
  if [ -z "$WEBUI_DIR" ]; then
    # Fallback: derive the web-ui from the paseo the RUNNING daemon uses. A box can
    # carry two paseo installs (e.g. nvm + ~/.npm-global); the daemon unit runs one
    # of them, so `command -v paseo` may pick the WRONG copy and we'd patch a web-ui
    # the daemon never serves. Prefer the daemon's own argv.
    PBIN=""
    DPID="$(systemctl --user show -p MainPID --value airlock-paseo.service 2>/dev/null || true)"
    if [ -n "$DPID" ] && [ "$DPID" != "0" ] && [ -r "/proc/$DPID/cmdline" ]; then
      PBIN="$(tr '\0' '\n' < "/proc/$DPID/cmdline" | grep -m1 '/paseo$' || true)"
    fi
    [ -n "$PBIN" ] || PBIN="$(command -v paseo || true)"
    if [ -n "$PBIN" ]; then
      WEBUI_DIR="$(PBIN="$PBIN" node -e 'const p=require("path"),fs=require("fs");const b=fs.realpathSync(process.env.PBIN);const m="/@getpaseo/cli/";const i=b.indexOf(m);if(i<0)process.exit(1);console.log(p.join(b.slice(0,i+m.length-1),"node_modules/@getpaseo/server/dist/server/web-ui"))' 2>/dev/null || echo "")"
    fi
  fi
  if [ -n "$WEBUI_DIR" ] && [ -d "$WEBUI_DIR" ]; then
    if node "$INSTALL_DIR/bin/patch-web-ui.js" --browse "$WEBUI_DIR" "$INSTALL_DIR/web/browse-view-client.js"; then
      # Syntax-gate the patched bundle, then the daemon must restart so the patched
      # web-ui is served (idempotent; only when we actually patched).
      BUNDLE_JS="$(ls "$WEBUI_DIR/_expo/static/js/web/"index-*.js 2>/dev/null | head -1)"
      if [ -n "$BUNDLE_JS" ] && node --check "$BUNDLE_JS" 2>/dev/null; then
        log "web-ui live-panel patch applied (bundle node --check OK)"
      else
        log "WARN: patched bundle failed syntax check — inspect $BUNDLE_JS"
      fi
    else
      log "WARN: web-ui live-panel patch failed (version drift?) — live panel off, agent browsing still works. Re-derive anchors (see patch-web-ui.js)."
    fi
  else
    log "WARN: web-ui dir not resolved ($WEBUI_DIR) — live-panel patch skipped (agent browsing still works)"
  fi
fi

# --- enable Paseo native browser tools for agents (REQUIRED to use this host) ---
# Agents only receive the native browser_* tools (which route through the broker to
# this host) when BOTH flags are on:
#   daemon.browserTools.enabled=true   — registers the browser_* tools
#   daemon.mcp.injectIntoAgents=true   — exposes Paseo's tool catalog to spawned
#                                        provider CLIs (claude/codex/gemini)
# injectIntoAgents also exposes other Paseo tools (create_agent, list_providers,
# ...) to agents — a broader change. Skip it with PASEO_BROWSE_SKIP_MCP_INJECT=1
# (then the host stays registered but agents won't get browser tools until the
# operator enables injection). Only restarts the daemon if config changed.
PASEO_CONFIG="$HOME/.paseo/config.json"
SKIP_INJECT="${PASEO_BROWSE_SKIP_MCP_INJECT:-0}"
if [ -f "$PASEO_CONFIG" ]; then
  CHANGED="$(SKIP_INJECT="$SKIP_INJECT" node - "$PASEO_CONFIG" <<'NODE'
const fs = require("fs");
const p = process.argv[2];
const skipInject = process.env.SKIP_INJECT === "1";
let d;
try { d = JSON.parse(fs.readFileSync(p, "utf8")); } catch { d = {}; }
d.daemon = d.daemon || {};
let changed = false;
d.daemon.browserTools = d.daemon.browserTools || {};
if (d.daemon.browserTools.enabled !== true) { d.daemon.browserTools.enabled = true; changed = true; }
if (!skipInject) {
  d.daemon.mcp = d.daemon.mcp || {};
  if (d.daemon.mcp.injectIntoAgents !== true) { d.daemon.mcp.injectIntoAgents = true; changed = true; }
}
if (changed) fs.writeFileSync(p, JSON.stringify(d, null, 2));
process.stdout.write(changed ? "changed" : "unchanged");
NODE
)"
  if [ "$CHANGED" = "changed" ]; then
    log "paseo config updated (browserTools.enabled + mcp.injectIntoAgents) -> restarting daemon"
    systemctl --user restart airlock-paseo.service || log "WARN: airlock-paseo restart failed (restart manually)"
    sleep 3
  else
    log "paseo config already enabled (no change)"
  fi
else
  log "WARN: $PASEO_CONFIG not found — browserTools/injectIntoAgents not set (host registers but agents won't get tools)"
fi

# --- systemd user unit ---
mkdir -p "$UNIT_DIR"
# Path so the unit finds node/npx regardless of box npm-prefix heterogeneity.
UNIT_PATH="$NODE_BIN_DIR:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
cat > "$UNIT" <<EOF
[Unit]
Description=Paseo server-side browse host (agent browser automation, loopback WS)
After=airlock-paseo.service
Wants=airlock-paseo.service

[Service]
Type=simple
Environment=PATH=$UNIT_PATH
Environment=HOME=$HOME
Environment=PASEO_WS_URL=ws://127.0.0.1:$PASEO_BACKEND_PORT/ws
Environment=PASEO_HOST_KIND=server
Environment=PASEO_HOST_CLIENT_ID=airlock-paseo-browse-host
Environment=PASEO_BROWSE_MAX_TABS=24
Environment=PASEO_BROWSE_STREAM_PORT=$PASEO_BROWSE_STREAM_PORT
Environment=PASEO_BROWSE_ALLOWED_ORIGIN=$ALLOWED_ORIGIN
WorkingDirectory=$INSTALL_DIR
ExecStart=$NODE_BIN_DIR/node $INSTALL_DIR/bin/paseo-browse-host.js
Restart=always
RestartSec=3
# Give chromium room but cap runaway memory.
MemoryMax=2G

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable "$SVC" >/dev/null 2>&1 || fatal "$SVC enable failed"
systemctl --user restart "$SVC" || fatal "$SVC restart failed"

# --- health: unit active + registered (registration round-trip is smoke.sh) ---
sleep 2
systemctl --user is-active --quiet "$SVC" || fatal "$SVC inactive after start"
log "installed + active. (registration + round-trip are verified by smoke.sh)"
