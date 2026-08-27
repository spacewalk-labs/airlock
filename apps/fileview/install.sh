#!/usr/bin/env bash
# fileview — a directory viewer and editor for this box, served as a same-origin
# subpath under the hub.
#
#   browser --> hub (tailscale serve :443) --(identity)--> hub nginx
#     /fileview/            -> the viewer (static, /__fv/viewer.html)
#     /fileview/api/   -> filebrowser 127.0.0.1:FB — headless, API only
#     /__fv/*               -> static assets from the hub webroot (viewer + the
#                              self-hosted highlight.js/marked/DOMPurify it renders with)
#
# The hub gate ($hub_ok) is asserted ONCE, at the server level, so these locations
# inherit it and an identity that is neither the owner nor a collaborator gets the
# wrong-owner page. filebrowser binds loopback only.
#
# SCOPE. filebrowser runs with `--root /`: the tree is the filesystem, and there is
# no configured boundary to set. What bounds this is the unix account the user
# service runs as — /etc and /var/log are readable, /root is not. That is stated in
# SECURITY.md, and it is the whole reason `[paths].code_root` no longer exists: the
# key was never a designed setting, it was the argument markserv and filebrowser
# each demand, promoted into config because the installer had to write it somewhere.
#
# NOTHING IS HIDDEN. There is no ignore list and no dotfile rule. `.env` is an
# ordinary file: it lists, opens, edits and saves through the same path as any
# other. filebrowser ships a real `hideDotfiles` setting that would break that, so
# the installer pins it false rather than relying on the default, and smoke.sh
# asserts a dotfile comes back from a listing.
#
# Symlinks out of the tree no longer mean anything special now that the root is /,
# but filebrowser stays pinned to a version with `followExternalSymlinks` and the
# flag is still passed explicitly.
#
# Config from airlock.toml ([apps.fileview]). Honors AIRLOCK_DRY_RUN=1.
set -euo pipefail

# ABI (D5): prefer the orchestrator-supplied AIRLOCK_ROOT/AIRLOCK_APP_DIR/
# AIRLOCK_APP_ID, falling back to $0-relative computation for a standalone
# invocation (a test harness that runs this script directly).
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
HERE="${AIRLOCK_APP_DIR:-$HERE}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-fileview}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$HERE/render.sh"

airlock_load fileview
FB_PORT="${AIRLOCK_FILEVIEW_FILEBROWSER_PORT:?}"
AUDIENCE="${AIRLOCK_FILEVIEW_AUDIENCE:-owner}"   # operator-selectable; render emits the $owner_ok guard unless "shared" (unknown fails closed)
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
WEBROOT="${AIRLOCK_WEBROOT:-/opt/airlock/hub}"

require_cmd curl sha256sum tar systemctl python3

FB_VER=2.63.18
FB_BIN="$HOME/.local/bin/filebrowser"
# Its own state directory, not filebrowser's default one. The old
# ~/.config/filebrowser/fb.db has this app's PREVIOUS baseURL (/markwand/edit) and
# branding baked into it, and a re-run would have to migrate those rather than
# start clean. It also holds no user data — noauth, no users, no shares — so the
# "retained data, do not declare" carve-out it used to get was buying nothing.
# Declared as an artifact instead, so teardown actually removes it.
FB_STATE="$HOME/.config/airlock-fileview"
FB_DB="$FB_STATE/fb.db"
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

# --- 1. provision filebrowser (sha256-pinned binary; no piped installer) ---
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

# --- 2. systemd user unit (binds loopback; nginx fronts it) ---
# AIRLOCK_RENDER_DIR forces the unit-render half of this write branch even under
# AIRLOCK_DRY_RUN=1 — see install/lib.sh's fail-closed guard (RENDER_DIR without
# DRY_RUN=1 never reaches this line) and apps/feedback/install.sh's identical
# comment. The real branch keeps the ORIGINAL atomicity/order: one `install -d`
# for unit+filebrowser-config dirs together, BEFORE the unit is rendered — restored
# after review found the earlier split (unit dir made and the unit written,
# filebrowser config dirs made only afterward) meant a failure creating the
# filebrowser config dirs left the unit on disk where the original single-mkdir
# form left none. The RENDER_DIR branch stays real-dir-free (redirected UNIT_DIR
# only) — it must only emit text.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] write $UNIT_DIR/airlock-fileview.service (127.0.0.1:$FB_PORT, root /)"
elif [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  install -d "$UNIT_DIR"
  render_fileview_unit_filebrowser "$FB_PORT" "$FB_BIN" "$FB_DB" >"$UNIT_DIR/airlock-fileview.service"
else
  install -d "$UNIT_DIR" "$FB_STATE"
  render_fileview_unit_filebrowser "$FB_PORT" "$FB_BIN" "$FB_DB" >"$UNIT_DIR/airlock-fileview.service"
fi

# --- 2.5. filebrowser first-run quickSetup (noauth), then pin its settings ---
# auth none is safe ONLY because the sole external path is the hub identity gate
# and filebrowser binds loopback (see SECURITY.md).
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  # filebrowser's config get/set need an exclusive DB lock. Stop the user service
  # that ACTUALLY holds it, including a differently named legacy one — this app
  # was called markwand until recently, so a box upgrading across the rename has
  # `airlock-filebrowser.service` or `airlock-markwand.service` on the lock and
  # stopping only our own name would deadlock the config step.
  # airlock_handover_user_resource resolves lock -> PID -> systemd unit and fails
  # closed for an unmanaged or ambiguous holder; no legacy unit names are guessed.
  # Step 3 starts the candidate after migration.
  airlock_handover_user_resource file-lock "$FB_DB" "filebrowser database $FB_DB"
  install -d "$FB_STATE"
  if [ ! -f "$FB_DB" ]; then
    log "filebrowser first-run quickSetup (--noauth)"
    # Same flags as the unit: this process is short-lived but it is a real server
    # on a real port, and "the 2-second one is different" is how a difference
    # outlives the two seconds.
    "$FB_BIN" --database "$FB_DB" --root / --address 127.0.0.1 --port "$FB_PORT" --noauth \
      --followExternalSymlinks=false --disableTypeDetectionByHeader &
    qs=$!; sleep 2; kill "$qs" 2>/dev/null || true; wait "$qs" 2>/dev/null || true
  fi
  # Three settings, pinned rather than left at their defaults, each for a reason:
  #   baseURL      — the API is proxied at /fileview/, so filebrowser has to
  #                  know that prefix or its own links and auth paths are wrong.
  #   hideDotfiles — false is the default AND the promise this app makes. `.env` is
  #                  an ordinary file; one flip of this setting would silently break
  #                  that from outside our code, so state it.
  #   perm.share   — false. Share links are served at /api/public/* and /share/*
  #                  WITHOUT authentication once a share exists. Nothing proxies
  #                  those paths, but that is one wildcard include away from being
  #                  wrong, and turning the permission off costs one command.
  #   type detection — off. The unit already passes the flag and the flag wins
  #                  (measured with strace: listing a directory of extension-less
  #                  files opens 3 of 3 with detection on, 0 of 3 with the serve
  #                  flag, 0 of 3 with it off in config). Storing it too keeps
  #                  `filebrowser config cat` from telling a future reader the
  #                  opposite of what the service is doing.
  cfg="$("$FB_BIN" config cat -d "$FB_DB" 2>/dev/null || true)"
  case "$cfg" in
    *"Base URL: /fileview"*) ;;
    *) log "filebrowser baseURL migration"; "$FB_BIN" config set --baseURL /fileview -d "$FB_DB" >/dev/null ;;
  esac
  "$FB_BIN" config set --hideDotfiles=false -d "$FB_DB" >/dev/null
  "$FB_BIN" config set --perm.share=false -d "$FB_DB" >/dev/null
  "$FB_BIN" config set --disableTypeDetectionByHeader=true -d "$FB_DB" >/dev/null
fi

# --- 2.9. one-shot sweep of the pre-rename install ---------------------------
# This app was called `markwand` until 2026-08-23. On a box whose install-state
# ledger has markwand committed, the rename is handled for us: the package is gone
# from apps/, so `airlock-ledger plan` marks it `remove` and replays its recorded
# deactivator and artifact list before this installer ever runs. The hole is the
# box that predates the ledger — F15's sweep only recognises KNOWN builtins, and
# that list is derived from the shipped app directories, so renaming the directory
# makes `markwand` unknown and its leftovers invisible rather than reported.
#
# Rather than take a census of which boxes are pre-ledger, remove the four names
# unconditionally. Where the ledger already did it, every line below is a no-op.
# They are named literally — no globs — so this cannot reach anything else.
SWEEP_MARK="$FB_STATE/.markwand-swept"
if [ -e "$SWEEP_MARK" ]; then
  :   # already done on this box; re-running would delete things installed since
elif [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] sweep pre-rename markwand artifacts (units, fragment, webroot, markserv)"
else
  systemctl --user disable --now airlock-markserv.service airlock-filebrowser.service 2>/dev/null || true
  rm -f "$UNIT_DIR/airlock-markserv.service" "$UNIT_DIR/airlock-filebrowser.service"
  rm -f "$CONFD/hub-locations.d/markwand.conf"
  rm -rf "$WEBROOT/__mw"
  rm -f "$HOME/.local/bin/markserv"
  rm -rf "$HOME/.local/lib/node_modules/markserv" "$HOME"/.local/lib/node_modules/.markserv-*
  rm -rf "$HOME/.config/filebrowser/branding"
  # A marker, because this is a migration and not a policy. Without it the block
  # above runs on every install and deletes a markserv (or a branding directory,
  # or a generically-named unit) that someone put back on purpose afterwards.
  : > "$SWEEP_MARK"
fi

airlock_run systemctl --user daemon-reload
airlock_run systemctl --user enable airlock-fileview.service
airlock_run systemctl --user restart airlock-fileview.service

# --- 3. static assets into the hub webroot (served by the hub's guarded location /) ---
# Everything under /__fv/ inherits the server-level hub gate (the fragment's own
# location only adds cache headers — see render.sh).
#
# The HTML is the only file that is never cached, and every asset URL inside it
# carries ?v=<content hash>. That is what lets the assets be immutable-cached for a
# year: a changed file gets a new URL, so there is no stale-cache window and no
# manual version to remember to bump. Nothing else in this app has a version to keep
# in step — the alternative, renaming files by hand on every edit, is the step
# somebody eventually forgets.
asset_v() { sha256sum "$1" | cut -c1-8; }
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] install fileview viewer + app.js + tokens + vendored libs -> $WEBROOT/__fv/ (content-hashed URLs)"
else
  install -d "$WEBROOT/__fv"
  install -m644 "$HERE/static/tokens.css"      "$WEBROOT/__fv/tokens.css"
  install -m644 "$HERE/static/hljs-theme.css"  "$WEBROOT/__fv/hljs-theme.css"
  for f in highlight.min.js marked.min.js purify.min.js; do
    install -m644 "$HERE/static/vendor/$f" "$WEBROOT/__fv/$f"
  done
  # app.js first, because it carries stylesheet URLs of its own (it builds the
  # srcdoc documents the code/JSON/CSV views render into). Stamp those, install it,
  # and only then hash it for the HTML — hashing before the stamp would name a file
  # that never got served.
  #
  # One URL here is not this app's: /assets/airlock-tokens.css is the hub's, and it
  # is where Airlock's colours, type scale and spacing actually live. This app
  # links it rather than keeping a second copy of the palette (tokens.css holds
  # only aliases over it), which means the two files have to arrive as a pair —
  # everything under /__fv/ is immutable-cached for a year, so a browser holding a
  # year-old alias sheet against a fresh palette would render neither. Stamping
  # the shared sheet from here puts it on the same content-addressed footing.
  #
  # Its absence is fatal, not a warning. tokens.css holds aliases and no values, so
  # a missing palette does not degrade the look — it removes it: measured against a
  # 403, both the viewer and every sandboxed srcdoc render as unstyled HTML, black
  # on white with no layout. The orchestrator copies hub/assets/ into the webroot
  # before it installs any app, so if this file is not here the install is already
  # wrong and finishing it quietly would only move the discovery to the browser.
  aktok="$WEBROOT/assets/airlock-tokens.css"
  [ -f "$aktok" ] || die "the design system is missing: $aktok — fileview's stylesheet is aliases over it and renders as unstyled HTML without it. The hub installs it: run install/airlock-install.sh, or copy hub/assets/ into $WEBROOT/assets/."
  stamp_shared() {
    sed -i "s|/assets/airlock-tokens.css|/assets/airlock-tokens.css?v=$(asset_v "$aktok")|g" "$1"
  }
  vjs="$(mktemp)"
  cp "$HERE/static/app.js" "$vjs"
  for f in tokens.css hljs-theme.css; do
    sed -i "s|/__fv/${f}|/__fv/${f}?v=$(asset_v "$WEBROOT/__fv/$f")|g" "$vjs"
  done
  stamp_shared "$vjs"
  install -m644 "$vjs" "$WEBROOT/__fv/app.js"; rm -f "$vjs"
  # Then the HTML. The three library URLs are matched by PREFIX in app.js
  # (script[src^=...]), so stamping them here does not break the load hook.
  vhtml="$(mktemp)"
  cp "$HERE/static/viewer.html" "$vhtml"
  for f in tokens.css hljs-theme.css app.js highlight.min.js marked.min.js purify.min.js; do
    sed -i "s|/__fv/${f}\"|/__fv/${f}?v=$(asset_v "$WEBROOT/__fv/$f")\"|g" "$vhtml"
  done
  # Where the tree opens: the home directory of the account this service runs as.
  # It is written here, from $HOME, and read nowhere else — there is no config key
  # for it and there is not going to be one. The last time this app had a
  # directory in its config it was `[paths].code_root`, which existed because the
  # installer had to put the renderer's argument somewhere and was then read as a
  # boundary it never enforced. The scope is still `/` (install/test-fileview-root.sh
  # holds that), so this changes where you land and nothing about what you can see.
  sed -i "s|<meta name=\"fileview-home\" content=\"\">|<meta name=\"fileview-home\" content=\"$HOME\">|" "$vhtml"
  stamp_shared "$vhtml"
  install -m644 "$vhtml" "$WEBROOT/__fv/viewer.html"; rm -f "$vhtml"
fi

# --- 4. nginx subpath fragment (included inside the hub server block) ---
# Quoted heredoc + sed placeholders so nginx runtime vars ($hub_ok, $host, ...)
# are never touched by the shell; only ports are substituted.
frag="$CONFD/hub-locations.d/fileview.conf"
install -d "$CONFD/hub-locations.d"
render_fileview_nginx "$FB_PORT" "$AUDIENCE" > "$frag"
log "wrote nginx fragment: $frag"

# NOTE: smoke runs from the orchestrator AFTER nginx reload (gate not live before).
log "fileview installed (owner: ${AIRLOCK_OWNER})"
