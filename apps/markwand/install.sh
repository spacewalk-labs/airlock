#!/usr/bin/env bash
# markwand — markdown/file viewer (markserv) + zero-login editor (filebrowser),
# served as a same-origin subpath under the hub (owner + collaborators).
#
#   browser --> hub (tailscale serve :443) --(identity)--> hub nginx
#     /markwand/       -> split-pane multitype viewer (static, /__mw/markwand-split.html)
#     /markwand/<file> -> markserv 127.0.0.1:MS   (renders .md / code_root as HTML — fallback)
#     /markwand/edit/  -> filebrowser 127.0.0.1:FB (baseURL=/markwand/edit)
#     /__mw/*          -> static assets from the hub webroot (viewer, tokens, enhance,
#                         editor, edit-button, + self-hosted highlight.js/marked/DOMPurify)
#
# The hub gate ($hub_ok) is asserted ONCE, at the server level, so these locations
# inherit it and an identity that is neither the owner nor a collaborator gets the
# wrong-owner page. markserv/filebrowser bind loopback only.
#
# $hub_ok = owner + collaborators. Everything UNDER code_root is therefore readable
# (markserv) and writable (filebrowser) by every collaborator, dotfiles included.
# There is no exclusion mechanism: neither server has one.
#
# The two surfaces LIST that tree differently, which reads like an exclusion and is
# not one. markserv's generated listing omits dot entries; the split-pane tree at
# /markwand/ is built from filebrowser's /api/resources and includes them. A direct
# URL serves dot paths in full either way — so ~/.claude/CLAUDE.md is reachable and
# visible in the tree, just not clickable from the markserv fallback listing.
# Measured on the pinned versions above. Left as-is deliberately: the complete view
# already exists, and patching a pinned npm dependency to duplicate it would buy
# nothing. Stated here because a missing row otherwise looks like a missing file.
#
# Symlinks out of code_root are asymmetric, so both halves are stated in SECURITY.md:
# filebrowser is pinned to a version that refuses them and we pass the flag
# explicitly below; markserv has no such notion and renders whatever the link
# points at. A curated symlink directory therefore still leaks reads.
#
# Config from airlock.toml ([apps.markwand] + paths.code_root). Honors AIRLOCK_DRY_RUN=1.
set -euo pipefail

# ABI (D5): prefer the orchestrator-supplied AIRLOCK_ROOT/AIRLOCK_APP_DIR/
# AIRLOCK_APP_ID, falling back to $0-relative computation for a standalone
# invocation (a test harness that runs this script directly).
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:-$(cd "$HERE/../.." && pwd)}"
HERE="${AIRLOCK_APP_DIR:-$HERE}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-markwand}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$HERE/render.sh"

airlock_load markwand
MS_PORT="${AIRLOCK_MARKWAND_MARKSERV_PORT:?}"
FB_PORT="${AIRLOCK_MARKWAND_FILEBROWSER_PORT:?}"
# No fallback: this directory is served read+write to the owner AND every
# collaborator, so it is stated in airlock.toml or nothing is installed. `validate`
# rejects it first; this is the second line of defence for a direct run of this
# script, where nothing has validated the config. Checked, not just non-empty:
# airlock-config stringifies whatever TOML held, so `false` arrives as "False".
CODE_ROOT="${AIRLOCK_CODE_ROOT:?not set — put code_root in [paths] of airlock.toml (see SECURITY.md: it is served read+write to owner and collaborators)}"
case "$CODE_ROOT" in
  /*) ;;
  *) die "AIRLOCK_CODE_ROOT must be an absolute path; got '$CODE_ROOT'" ;;
esac
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
WEBROOT="${AIRLOCK_WEBROOT:-/opt/airlock/hub}"

require_cmd node npm curl sha256sum tar systemctl

MS_VER=1.17.4
FB_VER=2.63.18
FB_BIN="$HOME/.local/bin/filebrowser"
FB_DB="$HOME/.config/filebrowser/fb.db"
FB_BRANDING_DIR="$HOME/.config/filebrowser/branding"
MS_BIN="$HOME/.local/bin/markserv"
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

# The markserv unit's PATH. markserv is a `#!/usr/bin/env node` script, so the
# directory node is FOUND in has to be on it — see airlock_cmd_dirs in
# install/lib.sh for the snap case that made this a crash-loop rather than a
# preference. $HOME/.local/bin first: that is where this installer puts markserv.
MS_UNIT_PATH="$HOME/.local/bin"
while IFS= read -r _d; do
  [ -n "$_d" ] || continue
  case ":${MS_UNIT_PATH}:" in *":${_d}:"*) continue ;; esac
  MS_UNIT_PATH="${MS_UNIT_PATH}:${_d}"
done <<EOF
$(airlock_cmd_dirs node)
EOF
MS_UNIT_PATH="${MS_UNIT_PATH}:/usr/local/bin:/usr/bin:/bin"

# markserv wants its code_root to exist before it starts.
airlock_run mkdir -p "$CODE_ROOT"

# --- 1. provision markserv (npm, no sudo — local prefix) ---
# --ignore-scripts: markserv@1.17.4 declares snyk in runtime dependencies, and
# snyk's postinstall (download a platform binary, rename it into place) fails
# reproducibly on clean boxes — ENOENT on the rename/chmod after a verified 200
# download — killing the whole Airlock install. markserv itself has no lifecycle
# scripts and never invokes the snyk binary, so skipping scripts removes the
# failure without changing what runs. The failure reproduced in four runs across
# two clean boxes (2026-08-01); a scripts-skipped install was separately verified
# to serve and render. Residual risk, accepted: only markserv's version is
# pinned, its dependency ranges are not, so a future in-range dependency that
# *needs* a lifecycle script would be silently skipped — which is why the check
# below runs the binary instead of testing existence, and why smoke.sh asserts
# an actual HTTP 200 from markserv after install. Vendoring the resolved tree
# is the recorded longer-term fix.
markserv_npm_install() {
  # airlock_quiet, not `>/dev/null`: npm is deafening on success and the only run
  # anyone needs to read is the one that failed. See install/lib.sh.
  airlock_quiet npm install -g --ignore-scripts --prefix "$HOME/.local" "markserv@${MS_VER}"
}
provision_markserv() {
  if [ -x "$MS_BIN" ] && "$MS_BIN" --version 2>/dev/null | grep -q "$MS_VER"; then
    log "markserv $MS_VER present"; return
  fi
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then log "[dry] npm install -g --ignore-scripts --prefix ~/.local markserv@$MS_VER"; return; fi
  # npm's own integrity check pins the tarball; we pin the version.
  if ! markserv_npm_install; then
    # A failed npm run strands a half-written node_modules/markserv that makes
    # every rerun die at the same point — "run it again" does not recover.
    # Clear the leftovers (npm's dot-prefixed staging dirs included) and retry
    # once, loudly; a second failure is a real upstream problem and stays fatal.
    log "markserv npm install failed — clearing partial install and retrying once"
    rm -rf "$HOME/.local/lib/node_modules/markserv" \
           "$HOME/.local/lib/node_modules/.markserv"-*
    markserv_npm_install || die "markserv npm install failed twice (npm output above)"
    log "markserv install recovered on retry"
  fi
  # Run it, don't just stat it: with lifecycle scripts skipped, "the file
  # exists" no longer implies "the package can boot".
  "$MS_BIN" --version 2>/dev/null | grep -q "$MS_VER" \
    || die "markserv installed but does not run at $MS_VER ($MS_BIN)"
  log "markserv $MS_VER installed"
}
provision_markserv

# --- 2. provision filebrowser (sha256-pinned binary; no piped installer) ---
provision_filebrowser() {
  if [ -x "$FB_BIN" ] && "$FB_BIN" version 2>/dev/null | grep -q "$FB_VER"; then
    log "filebrowser $FB_VER present"; return
  fi
  local asset sha
  case "$(uname -m)" in
    x86_64)  asset=linux-amd64-filebrowser.tar.gz; sha=cd599c34afad0e8e61c577d1061c820bccb7feaa3c5a4477a12db586a1cd93ff ;;
    aarch64) asset=linux-arm64-filebrowser.tar.gz; sha=29b3935c222d91522874e98dfa33195ee7d2acdac5dfbf37c1361a73704a28de ;;
    *) die "filebrowser: unsupported arch $(uname -m)" ;;
  esac
  local url="https://github.com/filebrowser/filebrowser/releases/download/v${FB_VER}/${asset}"
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then log "[dry] download+verify filebrowser $FB_VER -> $FB_BIN"; return; fi
  local td; td="$(mktemp -d)"
  curl -fsSL --max-time 90 -o "$td/fb.tgz" "$url" || { rm -rf "$td"; die "filebrowser download failed: $url"; }
  local got; got="$(sha256sum "$td/fb.tgz" | cut -d' ' -f1)"
  [ "$got" = "$sha" ] || { rm -rf "$td"; die "filebrowser sha256 mismatch got=$got want=$sha"; }
  tar -xzf "$td/fb.tgz" -C "$td" filebrowser || { rm -rf "$td"; die "filebrowser extract failed"; }
  install -D -m755 "$td/filebrowser" "$FB_BIN"; rm -rf "$td"
  log "filebrowser sha256 verified ($FB_VER)"
}
provision_filebrowser

# --- 3. systemd user units (both bind loopback; nginx fronts them) ---
# AIRLOCK_RENDER_DIR forces the unit-render half of this write branch even under
# AIRLOCK_DRY_RUN=1 — see install/lib.sh's fail-closed guard (RENDER_DIR without
# DRY_RUN=1 never reaches this line) and apps/feedback/install.sh's identical
# comment. The real branch keeps the ORIGINAL atomicity/order: one `install -d`
# for unit+filebrowser-config dirs together, BEFORE either unit is rendered —
# restored after review found the earlier split (unit dir made and both units
# written, filebrowser config dirs made only afterward) meant a failure
# creating the filebrowser config dirs left both units on disk where the
# original single-mkdir form left none. The RENDER_DIR branch stays real-dir-
# free (redirected UNIT_DIR only) — it must only emit text.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] write $UNIT_DIR/airlock-markserv.service (127.0.0.1:$MS_PORT, root $CODE_ROOT)"
  log "[dry] write $UNIT_DIR/airlock-filebrowser.service (127.0.0.1:$FB_PORT, root $CODE_ROOT)"
elif [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  install -d "$UNIT_DIR"
  render_markwand_unit_markserv "$CODE_ROOT" "$MS_PORT" "$MS_BIN" "$MS_UNIT_PATH" >"$UNIT_DIR/airlock-markserv.service"
  render_markwand_unit_filebrowser "$CODE_ROOT" "$FB_PORT" "$FB_BIN" "$FB_DB" >"$UNIT_DIR/airlock-filebrowser.service"
else
  install -d "$UNIT_DIR" "$HOME/.config/filebrowser" "$FB_BRANDING_DIR"
  render_markwand_unit_markserv "$CODE_ROOT" "$MS_PORT" "$MS_BIN" "$MS_UNIT_PATH" >"$UNIT_DIR/airlock-markserv.service"
  render_markwand_unit_filebrowser "$CODE_ROOT" "$FB_PORT" "$FB_BIN" "$FB_DB" >"$UNIT_DIR/airlock-filebrowser.service"
fi

# --- 3.5. filebrowser first-run quickSetup (noauth), then persist baseURL/branding ---
# auth none is safe ONLY because the sole external path is the hub identity gate
# and filebrowser binds loopback (see SECURITY.md).
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  install -m644 "$HERE/filebrowser/custom.css" "$FB_BRANDING_DIR/custom.css"
  # filebrowser's config get/set need an exclusive DB lock. On a re-run the
  # service is already up and holds it, so stop it first (step 4 restarts it).
  # No-op on first run (unit not loaded yet).
  systemctl --user stop airlock-filebrowser.service 2>/dev/null || true
  if [ ! -f "$FB_DB" ]; then
    log "filebrowser first-run quickSetup (--noauth)"
    "$FB_BIN" --database "$FB_DB" --root "$CODE_ROOT" --address 127.0.0.1 --port "$FB_PORT" --noauth &
    qs=$!; sleep 2; kill "$qs" 2>/dev/null || true; wait "$qs" 2>/dev/null || true
  fi
  cfg="$("$FB_BIN" config cat -d "$FB_DB" 2>/dev/null || true)"
  baseurl="$(printf '%s\n' "$cfg" | awk '/Base URL:/ {print $3; exit}' || true)"
  if [ "$baseurl" != "/markwand/edit" ] || ! printf '%s\n' "$cfg" | grep -Fq "$FB_BRANDING_DIR"; then
    log "filebrowser baseURL + branding migration"
    "$FB_BIN" config set --baseURL /markwand/edit -d "$FB_DB" >/dev/null
    "$FB_BIN" config set --branding.name "Markwand Editor" --branding.files "$FB_BRANDING_DIR" -d "$FB_DB" >/dev/null
  fi
fi

airlock_run systemctl --user daemon-reload
airlock_run systemctl --user enable airlock-markserv.service airlock-filebrowser.service
airlock_run systemctl --user restart airlock-markserv.service airlock-filebrowser.service

# --- 4. static assets into the hub webroot (served by the hub's guarded location /) ---
# Everything under /__mw/ is served by the hub server's `location /` (try_files from
# WEBROOT), so it inherits the server-level hub gate — no per-asset location needed.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] install markwand static assets + split viewer + vendored libs -> $WEBROOT/__mw/"
else
  install -d "$WEBROOT/__mw"
  install -m644 "$HERE/static/markwand-tokens.css"  "$WEBROOT/__mw/markwand-tokens.css"
  install -m644 "$HERE/static/markwand-enhance.js"  "$WEBROOT/__mw/markwand-enhance.js"
  install -m644 "$HERE/static/markwand-editor.js"   "$WEBROOT/__mw/markwand-editor.js"
  install -m644 "$HERE/static/edit-button.js"       "$WEBROOT/__mw/edit-button.js"
  # split-pane multitype viewer (default /markwand/ entry) + its self-hosted libs
  install -m644 "$HERE/static/markwand-split.html"  "$WEBROOT/__mw/markwand-split.html"
  install -m644 "$HERE/static/hljs-theme.css"       "$WEBROOT/__mw/hljs-theme.css"
  install -m644 "$HERE/static/vendor/highlight.min.js" "$WEBROOT/__mw/highlight.min.js"
  install -m644 "$HERE/static/vendor/marked.min.js"    "$WEBROOT/__mw/marked.min.js"
  install -m644 "$HERE/static/vendor/purify.min.js"    "$WEBROOT/__mw/purify.min.js"
fi

# --- 5. nginx subpath fragment (included inside the hub server block) ---
# Quoted heredoc + sed placeholders so nginx runtime vars ($hub_ok, $host, ...)
# are never touched by the shell; only ports are substituted.
frag="$CONFD/hub-locations.d/markwand.conf"
install -d "$CONFD/hub-locations.d"
render_markwand_nginx "$MS_PORT" "$FB_PORT" > "$frag"
log "wrote nginx fragment: $frag"

# NOTE: smoke runs from the orchestrator AFTER nginx reload (gate not live before).
log "markwand installed (owner: ${AIRLOCK_OWNER})"
