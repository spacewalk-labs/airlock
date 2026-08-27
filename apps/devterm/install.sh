#!/usr/bin/env bash
# devterm — browser web terminal: a custom xterm.js client + a programmable gate in
# front of a ttyd PTY backend, all behind the Airlock owner gate.
#
#   browser --https--> tailscale serve :HTTPS --(identity)--> nginx owner-gate
#           --(owner only / else 403)--> devterm-gate 127.0.0.1:BACKEND
#                                        --> serves web/ + API, proxies /ws,/token --> ttyd --> tmux
#
# Config comes from airlock.toml ([apps.devterm]). Optional features (Claude account
# pool, Codex login, fileview file-open, Orca worktree sidebar) turn on only when their
# config + tools are present; otherwise they no-op cleanly.
# Honors AIRLOCK_DRY_RUN=1 (print system-mutating steps instead of running them).
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
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-devterm}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/gate/nginx-lib.sh"
# shellcheck source=/dev/null
. "$HERE/render.sh"

airlock_load devterm
TTYD_PORT="${AIRLOCK_DEVTERM_TTYD_PORT:?}"
BACKEND_PORT="${AIRLOCK_DEVTERM_BACKEND_PORT:?}"
GATE_PORT="${AIRLOCK_DEVTERM_GATE_PORT:?}"
HTTPS_PORT="${AIRLOCK_DEVTERM_HTTPS_PORT:?}"
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
TTYD_BIN="${TTYD_BIN:-$HOME/.local/bin/ttyd}"
DEVTERM_LANG="${AIRLOCK_DEVTERM_LANG:-C.UTF-8}"
FONT_SIZE="${AIRLOCK_DEVTERM_FONT_SIZE:-15}"
IDENTITY_HEADER="${AIRLOCK_IDENTITY_HEADER:?}"
ACCOUNTS="${AIRLOCK_DEVTERM_ACCOUNTS:-false}"
XAI="${AIRLOCK_DEVTERM_XAI:-false}"
REMOTE_HOSTS="${AIRLOCK_DEVTERM_REMOTE_HOSTS:-}"
CLAUDE_SWITCH_CFG="${AIRLOCK_DEVTERM_CLAUDE_SWITCH:-}"
CLAUDE_STATUS_CFG="${AIRLOCK_DEVTERM_CLAUDE_STATUS:-}"
FLEET_STORE="${AIRLOCK_DEVTERM_FLEET_STORE:-}"
FLEET_STORE_URL="${AIRLOCK_DEVTERM_FLEET_STORE_URL:-}"
ORCA_SHIM_CFG="${AIRLOCK_DEVTERM_ORCA_SHIM:-}"
WEB_ROOT="$HOME/.local/share/airlock-devterm/web"
GATE_PY="$HERE/backend/devterm-gate.py"
UNIT_DIR="$HOME/.config/systemd/user"
# AIRLOCK_RENDER_DIR: harness-only destination-root override (highest
# priority). Redirects only where render output lands — install/lib.sh
# fail-closes if this is set without AIRLOCK_DRY_RUN=1, since real system
# mutations (systemctl, sudo tailscale serve, and orca's own sudo nft/
# systemctl calls) are gated on dry-run alone, not on this variable.
if [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  CONFD="$AIRLOCK_RENDER_DIR/confd"
  UNIT_DIR="$AIRLOCK_RENDER_DIR/units"
fi

require_cmd tmux python3 curl sha256sum systemctl tailscale sudo
PY="$(command -v python3)"

# The D5 ABI hands platform tools in as paths. Resolve them once here, before either
# the unit or the terminal compatibility shim records them: an interactive shell has
# none of these AIRLOCK_* variables, and baking a variable reference into the shim
# would preserve the filename while breaking the command it promises. realpath also
# makes a caller-supplied symlink or relative segment stable across later cwd changes.
resolve_platform_bin() {
  local abi_name="$1" path="$2" resolved
  case "$path" in
    /*) ;;
    *) die "$abi_name must be an absolute path; got: $path" ;;
  esac
  resolved="$(python3 - "$path" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
)"
  [ -f "$resolved" ] && [ -x "$resolved" ] \
    || die "$abi_name does not name an executable platform file: $resolved"
  printf '%s\n' "$resolved"
}

PLATFORM_ACCOUNTS_BIN="$(resolve_platform_bin AIRLOCK_ACCOUNTS_BIN "$AIRLOCK_ACCOUNTS_BIN")"
PLATFORM_ACCOUNTS_STATUS_BIN="$(resolve_platform_bin AIRLOCK_ACCOUNTS_STATUS_BIN "$AIRLOCK_ACCOUNTS_STATUS_BIN")"
PLATFORM_SECRET_BIN="$(resolve_platform_bin AIRLOCK_SECRET_BIN "$AIRLOCK_SECRET_BIN")"

# These app config keys remain compatibility overrides. Their empty default now means
# the platform-owned binary rather than an app-bundled copy; see airlock-app.toml for
# why the fail-closed config schema prevents retiring them without a real replacement.
CLAUDE_SWITCH="${CLAUDE_SWITCH_CFG:-$PLATFORM_ACCOUNTS_BIN}"
CLAUDE_STATUS="${CLAUDE_STATUS_CFG:-$PLATFORM_ACCOUNTS_STATUS_BIN}"

# is app <name> enabled in airlock.toml?
app_enabled() { airlock_config apps | grep -qx "$1"; }

# --- resolve optional feature wiring ---
# fileview file-open: on whenever [apps.fileview] is enabled. It used to also
# require a code_root; fileview serves the filesystem now, so there is no second
# condition and no path to thread through.
FILEVIEW=false
if app_enabled fileview; then FILEVIEW=true; fi
# Orca worktree sidebar: use the configured shim path, else the conventional one when
# [apps.orca] is enabled, else empty (feature off). The gate checks the file at runtime.
ORCA_SHIM=""
if [ -n "$ORCA_SHIM_CFG" ]; then ORCA_SHIM="$ORCA_SHIM_CFG"
elif app_enabled orca; then ORCA_SHIM="~/.config/orca/linux-orca-cli-shim/orca"; fi  # gate expanduser()s the ~
# --- 1. provision ttyd (sha256-pinned) ---
provision_ttyd() {
  [ -x "$TTYD_BIN" ] && { log "ttyd present: $TTYD_BIN"; return; }
  # Both hashes are the ones upstream publishes in the release's own SHA256SUMS
  # asset, not a hash observed from a single download of our own — trust-on-first-use
  # cannot tell a tampered download from a genuine one. That manifest carries no
  # signature, so this pins the bytes against a swapped asset, not against a
  # compromise of the publishing account.
  local ver=1.7.7 asset sha
  case "$(uname -m)" in
    x86_64)  asset=ttyd.x86_64;  sha=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55 ;;
    aarch64) asset=ttyd.aarch64; sha=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165 ;;
    *) die "ttyd: unsupported arch $(uname -m) — install manually (github.com/tsl0922/ttyd)" ;;
  esac
  local url="https://github.com/tsl0922/ttyd/releases/download/${ver}/${asset}"
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then log "[dry] download+verify ttyd ${ver} -> $TTYD_BIN"; return; fi
  local tmp; tmp="$(mktemp)"
  curl -fsSL --max-time 60 -o "$tmp" "$url" || { rm -f "$tmp"; die "ttyd download failed: $url"; }
  if [ -n "$sha" ]; then
    local got; got="$(sha256sum "$tmp" | cut -d' ' -f1)"
    [ "$got" = "$sha" ] || { rm -f "$tmp"; die "ttyd sha256 mismatch got=$got want=$sha"; }
    log "ttyd sha256 verified ($ver)"
  else
    log "warning: no sha256 pin for $(uname -m) — ttyd downloaded unverified"
  fi
  install -D -m755 "$tmp" "$TTYD_BIN"; rm -f "$tmp"
}
provision_ttyd

# --- 2. shell wrapper ---
airlock_run install -D -m755 "$HERE/bin/devterm-shell" "$HOME/.local/bin/devterm-shell"

# --- 2b. Account-tool terminal compatibility shims ---
# These two paths remain devterm artifacts because the installed-state ledger has no
# ownership-transfer operation: dropping them from the manifest would make record-diff
# delete them on upgrade. Replace each existing file atomically with a tiny shim instead.
# The temp file lives beside the destination, so mv(1) cannot cross filesystems and the
# promised terminal path is never briefly absent — important on boxes with live logins.
install_exec_shim() {
  local target="$1" dest="$2" tmp
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
    log "[dry] atomically replace $dest with exec shim -> $target"
    return
  fi
  install -d "$(dirname "$dest")"
  tmp="$(mktemp "${dest}.tmp.XXXXXX")"
  if ! render_devterm_exec_shim "$target" > "$tmp"; then
    rm -f "$tmp"
    die "could not render compatibility shim: $dest"
  fi
  if ! chmod 755 "$tmp" || ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    die "could not atomically install compatibility shim: $dest"
  fi
}

# Feature flags decide whether a fresh install promises the terminal affordance, but
# they must not protect a stale file from an upgrade. Both paths are unconditional
# manifest artifacts, so record-diff deliberately leaves them alone; if an older
# devterm already installed its full credential writer, replace that existing path
# even when the feature has since been disabled. -L also catches a broken symlink.
if [ "$ACCOUNTS" = true ] || [ -e "$HOME/.local/bin/claude-switch" ] || [ -L "$HOME/.local/bin/claude-switch" ]; then
  install_exec_shim "$PLATFORM_ACCOUNTS_BIN" "$HOME/.local/bin/claude-switch"
fi
if [ "$ACCOUNTS" = true ] || [ "$XAI" = true ] \
   || [ -e "$HOME/.local/bin/claude-status" ] || [ -L "$HOME/.local/bin/claude-status" ]; then
  install_exec_shim "$PLATFORM_ACCOUNTS_STATUS_BIN" "$HOME/.local/bin/claude-status"
fi

# --- 3. custom web client into WEB_ROOT (index.html templated with runtime config) ---
CFG_JSON="{\"accounts\":${ACCOUNTS},\"xai\":${XAI},\"fileview\":${FILEVIEW},\"orca\":$([ -n "$ORCA_SHIM" ] && echo true || echo false)}"
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] install web/ -> $WEB_ROOT (index.html config=${CFG_JSON}, + ui.js/popup.css/panel.html)"
else
  install -d "$WEB_ROOT/vendor"
  install -m644 "$HERE/web/app.js" "$HERE/web/accounts.js" "$HERE/web/ui.js" \
                "$HERE/web/secretdrop.js" "$HERE/web/popup.css" "$HERE/web/panel.html" \
                "$HERE/web/favicon.svg" "$HERE/web/apple-touch-icon.png" "$WEB_ROOT/"
  install -m644 "$HERE"/web/vendor/* "$WEB_ROOT/vendor/"
  # template the config placeholder (JSON has no sed metachars; use | as delimiter)
  sed "s|%%DEVTERM_CONFIG%%|${CFG_JSON}|" "$HERE/web/index.html" > "$WEB_ROOT/index.html"
  chmod 644 "$WEB_ROOT/index.html"
  # [branding] icon_ring: same filename, ringed content — index.html needs no edit.
  if [ -n "${AIRLOCK_ICON_RING:-}" ]; then
    ring_icon_svg "$AIRLOCK_ICON_RING" "$HERE/web/favicon.svg" > "$WEB_ROOT/favicon.svg"
    chmod 644 "$WEB_ROOT/favicon.svg"
    log "favicon ringed (${AIRLOCK_ICON_RING})"
  fi
fi

# --- 4. systemd user units (write_if_changed -> restart only when content changes) ---
# ttyd unit: pure PTY backend, loopback only. KillMode=process so a redeploy that does
# change the unit restarts ttyd without killing tmux sessions born in its cgroup.
install -d "$UNIT_DIR"
changed_ttyd=0
# AIRLOCK_RENDER_DIR forces this write branch even under AIRLOCK_DRY_RUN=1 — see
# install/lib.sh's fail-closed guard (RENDER_DIR without DRY_RUN=1 never reaches
# this line) and apps/feedback/install.sh's identical comment.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] write $UNIT_DIR/airlock-devterm.service (ttyd -i 127.0.0.1 -p $TTYD_PORT)"
else
  if render_devterm_unit_ttyd "$DEVTERM_LANG" "$TTYD_PORT" "$TTYD_BIN" "$FONT_SIZE" \
     | write_if_changed "$UNIT_DIR/airlock-devterm.service"
  then changed_ttyd=1; fi
fi

# gate unit: serves the custom client + API, proxies /ws,/token to ttyd. A content
# revision (hash of gate + web) is embedded so write_if_changed triggers a restart when
# the code changes — and NOT on a no-op re-run.
REV="$(cat "$GATE_PY" "$HERE"/backend/bin_discovery.py \
        "$HERE"/web/app.js "$HERE"/web/accounts.js "$HERE"/web/ui.js \
        "$HERE"/web/secretdrop.js "$HERE"/web/popup.css "$HERE"/web/panel.html \
        "$HERE"/web/index.html 2>/dev/null | sha256sum | cut -c1-12)"

# Unit PATH. This unit was the only one of the four that shipped without one, and it
# is the one that spawns the most: codex, claude-switch/claude-status, and through
# them `claude`. A systemd --user unit inherits a PATH with none of the directories a
# node CLI installs into, so every `which` in the gate came back empty and the whole
# Codex feature reported itself unavailable on a box where codex worked fine from a
# shell. The gate now resolves those binaries itself (backend/bin_discovery.py), but
# resolving is not enough: `codex` and `claude` are `#!/usr/bin/env node` scripts, so
# node has to be findable through PATH or the exec fails after a successful lookup.
#
# Same shape as apps/paseo/install.sh: entries are added whether or not they exist
# yet (the agent CLIs normally arrive after Airlock, and a non-existent PATH entry
# costs nothing), and the node directories come from airlock_cmd_dirs — the FOUND
# directory, not just the resolved one, because a snap wrapper resolves to /usr/bin
# and would take node off the unit's PATH entirely (see install/lib.sh).
NODE_DIRS="$(airlock_cmd_dirs node)"
UNIT_PATH=""
# shellcheck disable=SC2086  # NODE_DIRS is newline-separated and deliberately split
for d in "$HOME/.local/bin" "$HOME/.npm-global/bin" $NODE_DIRS; do
  case ":${UNIT_PATH}:" in *":${d}:"*) continue ;; esac   # de-dupe
  UNIT_PATH="${UNIT_PATH}${d}:"
done
UNIT_PATH="${UNIT_PATH}/usr/local/bin:/usr/bin:/bin"

gate_env=""
add_env() { gate_env="${gate_env}Environment=$1=$2
"; }
add_env PATH "$UNIT_PATH"
add_env DEVTERM_REV "$REV"
add_env DEVTERM_LISTEN_HOST 127.0.0.1
add_env DEVTERM_LISTEN_PORT "$BACKEND_PORT"
add_env DEVTERM_TTYD_HOST 127.0.0.1
add_env DEVTERM_TTYD_PORT "$TTYD_PORT"
add_env DEVTERM_WEB "$WEB_ROOT"
add_env AIRLOCK_IDENTITY_HEADER "$IDENTITY_HEADER"
add_env AIRLOCK_OWNER "$AIRLOCK_OWNER"
add_env DEVTERM_FILEVIEW "$FILEVIEW"
add_env DEVTERM_ACCOUNTS "$ACCOUNTS"
add_env DEVTERM_XAI "$XAI"
add_env DEVTERM_REMOTE_HOSTS "$REMOTE_HOSTS"
add_env DEVTERM_ORCA_SHIM "$ORCA_SHIM"
# Always hand the non-overridable platform account path to the Codex lifecycle
# endpoints. DEVTERM_CLAUDE_SWITCH may intentionally name an operator compatibility
# tool, which is not required to know the platform-only codex-auth verb.
add_env DEVTERM_ACCOUNTS_BIN "$PLATFORM_ACCOUNTS_BIN"
# The drop exists independently of the account feature. Hand the platform store in on
# every gate unit; deriving $ROOT/bin here would make this package depend on its source
# layout again after the apps/ split.
add_env DEVTERM_SECRET_BIN "$PLATFORM_SECRET_BIN"
# claude-status also carries the xAI adapter, so wire it for either feature.
if [ "$ACCOUNTS" = true ] || [ "$XAI" = true ]; then
  add_env DEVTERM_CLAUDE_STATUS "$CLAUDE_STATUS"
fi
# Claude pool-only tools and stores remain behind accounts.
if [ "$ACCOUNTS" = true ]; then
  add_env DEVTERM_CLAUDE_SWITCH "$CLAUDE_SWITCH"
  add_env DEVTERM_FLEET_STORE "$FLEET_STORE"
  add_env DEVTERM_FLEET_STORE_URL "$FLEET_STORE_URL"
fi

changed_gate=0
# AIRLOCK_RENDER_DIR forces this write branch even under AIRLOCK_DRY_RUN=1 — see
# install/lib.sh's fail-closed guard (RENDER_DIR without DRY_RUN=1 never reaches
# this line) and apps/feedback/install.sh's identical comment.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] write $UNIT_DIR/airlock-devterm-gate.service (127.0.0.1:$BACKEND_PORT; accounts=$ACCOUNTS xai=$XAI fileview=$FILEVIEW orca=$([ -n "$ORCA_SHIM" ] && echo true || echo false))"
else
  if render_devterm_unit_gate "$BACKEND_PORT" "$gate_env" "$PY" "$GATE_PY" \
     | write_if_changed "$UNIT_DIR/airlock-devterm-gate.service"
  then changed_gate=1; fi
fi

airlock_run systemctl --user daemon-reload
airlock_run systemctl --user enable airlock-devterm.service airlock-devterm-gate.service
# restart only what changed (no needless restarts on idempotent re-runs)
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] restart ttyd/gate units if changed"
else
  systemctl --user is-active --quiet airlock-devterm.service || changed_ttyd=1
  systemctl --user is-active --quiet airlock-devterm-gate.service || changed_gate=1
  [ "$changed_ttyd" = 1 ] && airlock_run systemctl --user restart airlock-devterm.service || true
  [ "$changed_gate" = 1 ] && airlock_run systemctl --user restart airlock-devterm-gate.service || true
fi

# --- 5. nginx owner-gate fragment (proxies GATE_PORT -> devterm-gate; owner-only) ---
# Written unconditionally: it is config the renderer includes, not a system mutation.
frag="$CONFD/servers.d/devterm.conf"
install -d "$CONFD/servers.d"
render_devterm_nginx "$GATE_PORT" "$BACKEND_PORT" > "$frag"
log "wrote nginx fragment: $frag"

# --- 6. tailscale serve: HTTPS carries devterm ---
# HTTPS gives a secure context (clipboard, OSC52). Needs the FQDN cert Tailscale
# issues — which is also why the redirect targets the FQDN and not the short name.
# The platform renders this now (manifest [serve.https]; child-4 P2b STEP 0 —
# install/lib.sh's airlock_render_serve_https, called from
# install/airlock-install.sh right after this script returns) — byte-identical
# to the direct call this used to make (install/test-serve-https-parity.sh
# proved the two productions equal before this line was removed).
# D-DEVTERM-9900: no plaintext tailnet mapping is declared. The
# orchestrator will not open :9900 from this manifest.

# NOTE: smoke runs from the orchestrator AFTER nginx is rendered + reloaded.
log "devterm installed (owner: ${AIRLOCK_OWNER}; accounts=${ACCOUNTS}, xai=${XAI}, fileview=${FILEVIEW}, orca=$([ -n "$ORCA_SHIM" ] && echo true || echo false))"
