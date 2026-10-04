#!/usr/bin/env bash
# Airlock orchestrator: validate config -> apply configured apps -> project. Idempotent; re-run after editing airlock.toml. Set AIRLOCK_DRY_RUN=1
# to print the steps without touching the system.
#
#   bash install/airlock-install.sh
#
# May require sudo for nginx/tailscale steps depending on your box.
set -euo pipefail

_airlock_install_usage() {
  cat <<'EOF'
airlock-install — validate and install the configured Airlock box.
  bash install/airlock-install.sh
  AIRLOCK_DRY_RUN=1 bash install/airlock-install.sh
  bash install/airlock-install.sh --help
EOF
}

_airlock_arg_die() {
  printf '[airlock] FATAL: %s\n' "$*" >&2
  exit 1
}

# Classify the complete argv before sourcing helpers or looking at live state.  A
# question or an invalid invocation must not enter self-kill escape, recovery,
# config, render, or lock code merely to learn that it should have exited.
_airlock_help=0
for _airlock_install_arg in "$@"; do
  case "$_airlock_install_arg" in
    -h|--help)
      _airlock_help=$((_airlock_help + 1))
      ;;
    *)
      _airlock_arg_die "unknown installer argument: $_airlock_install_arg"
      ;;
  esac
done
if [ "$_airlock_help" -gt 0 ]; then
  _airlock_install_usage
  exit 0
fi

# AIRLOCK_FIXTURE_ROOT is executable test authority, not a harmless destination
# hint. Before sourcing helpers or reading live state, prove every path a fixture
# run may write, and every command it can invoke that can cross into systemd,
# nginx, or Tailscale, stays below that one root. This is deliberately
# fail-closed: an incomplete fixture is never allowed to become a live install.
_airlock_fixture_boundary() { # <dry|recover|mutate>
  local _mode="$1" _tool_paths=()
  [ -n "${AIRLOCK_FIXTURE_ROOT:-}" ] || return 0
  if [ "$_mode" != dry ]; then
    local _name
    for _name in sudo systemctl nginx tailscale; do
      _tool_paths+=("$(command -v "$_name" 2>/dev/null || true)")
    done
  fi
  python3 - "$_mode" "$AIRLOCK_FIXTURE_ROOT" \
    "${HOME:-}" "${AIRLOCK_STATE_DIR:-}" "${AIRLOCK_WEBROOT:-}" \
    "${AIRLOCK_CONFD:-}" "${AIRLOCK_NGINX_SITE:-}" \
    "${AIRLOCK_UNIT_DIR_USER:-}" "${AIRLOCK_UNIT_DIR_SYSTEM:-}" \
    "${_tool_paths[@]}" <<'PY'
import os
import pathlib
import sys

mode, root_raw, home, state, webroot, confd, nginx_site, unit_user, unit_system, *tools = sys.argv[1:]
root = pathlib.Path(root_raw)
if not root.is_absolute():
    raise SystemExit("fixture boundary: AIRLOCK_FIXTURE_ROOT must be absolute")

def below(label, raw, required):
    if not raw:
        if required:
            raise SystemExit(f"fixture boundary: {label} must be explicit")
        return
    path = pathlib.Path(raw)
    if not path.is_absolute():
        raise SystemExit(f"fixture boundary: {label} must be absolute")
    resolved = path.resolve(strict=False)
    if resolved != root and root not in resolved.parents:
        raise SystemExit(f"fixture boundary: {label} escapes AIRLOCK_FIXTURE_ROOT: {resolved}")

below("HOME", home, True)
if home:
    state = state or os.fspath(pathlib.Path(home) / ".local" / "state" / "airlock")
    unit_user = unit_user or os.fspath(pathlib.Path(home) / ".config" / "systemd" / "user")
below("AIRLOCK_STATE_DIR", state, True)
if mode == "mutate":
    for label, raw in (
        ("AIRLOCK_WEBROOT", webroot),
        ("AIRLOCK_CONFD", confd),
        ("AIRLOCK_NGINX_SITE", nginx_site),
        ("AIRLOCK_UNIT_DIR_USER", unit_user),
        ("AIRLOCK_UNIT_DIR_SYSTEM", unit_system),
    ):
        below(label, raw, True)
if mode != "dry":
    if len(tools) != 4 or any(not raw for raw in tools):
        raise SystemExit("fixture boundary: sudo/systemctl/nginx/tailscale shims are incomplete")
    for raw in tools:
        below("mutation command", raw, True)
PY
}

_airlock_fixture_mode=mutate
[ "${AIRLOCK_DRY_RUN:-0}" != 1 ] || _airlock_fixture_mode=dry
# AIRLOCK_FIXTURE_BOUNDARY_CALL — the regression fixture mutates this exact call.
_airlock_fixture_boundary "$_airlock_fixture_mode" \
  || _airlock_arg_die "unsafe fixture execution refused before live effects"
if [ -n "${AIRLOCK_FIXTURE_ROOT:-}" ]; then
  printf '[airlock] verified fixture targets before effects: WEBROOT=%s CONFD=%s NGINX_SITE=%s\n' \
    "${AIRLOCK_WEBROOT:-<private-dry-preview>}" \
    "${AIRLOCK_CONFD:-<private-dry-preview>}" \
    "${AIRLOCK_NGINX_SITE:-<no-site-write>}" >&2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# Never inherit a config reader from the caller. The private wrapper is set
# only on individual lifecycle child invocations below; accepting an ambient
# value here would recreate the rejected persistent escape switch under a
# different name.
AIRLOCK_CONFIG_BIN="$ROOT/bin/airlock-config"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/apps/dev-monitor/migration-lifecycle.sh"

# Never trust caller markers as proof of lock, snapshot, or transaction
# ownership. This must precede self-kill escape so the re-exec cannot forward
# stale authority into the recovered process.
unset AIRLOCK_LEDGER_LOCK_HELD AIRLOCK_CONFIG_SNAPSHOT \
  AIRLOCK_CONFIG_SNAPSHOT_SHA256 AIRLOCK_INSTALL_PKG_INFO_SHA256 \
  AIRLOCK_APP_SCOPED_PLAN_SHA256 AIRLOCK_LEDGER_DEPENDENCIES_SHA256 \
  AIRLOCK_INSTALL_TRANSACTION_ID AIRLOCK_PKG_INFO
# Before a normal mutating install can stop anything: if this run is hosted by one
# of the units it may restart, move it out of that cgroup so it survives teardown.
# Help, invalid argv, dry-run, and recovery-debt refusal have already returned.
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  airlock_escape_selfkill_cgroup "$0" "$@"
fi

# Keep one immutable operator config for a complete box install.
_airlock_config_snapshot=""
_airlock_dry_preview_root=""
_airlock_cleanup_config_wrapper() {
  local rc=$?
  trap - EXIT INT TERM HUP
  [ -z "$_airlock_config_snapshot" ] || rm -f -- "$_airlock_config_snapshot"
  [ -z "$_airlock_dry_preview_root" ] || rm -rf -- "$_airlock_dry_preview_root"
  exit "$rc"
}
trap _airlock_cleanup_config_wrapper EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
  _airlock_config_snapshot="$(mktemp)" || die "cannot create install config snapshot"
  _snapshot_receipt="$(airlock_config install-snapshot "$_airlock_config_snapshot")" || exit 2
  _snapshot_digest="$(printf '%s' "$_snapshot_receipt" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')" \
    || die "cannot read install config snapshot digest"
  AIRLOCK_CONFIG="$(printf '%s' "$_snapshot_receipt" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["config_path"])')" \
    || die "cannot read install config snapshot origin"
  AIRLOCK_CONFIG_SNAPSHOT="$_airlock_config_snapshot"
  AIRLOCK_CONFIG_SNAPSHOT_SHA256="$_snapshot_digest"
  export AIRLOCK_CONFIG AIRLOCK_CONFIG_SNAPSHOT AIRLOCK_CONFIG_SNAPSHOT_SHA256

# Packaged apps (docs/design/app-package-contract.md). One read-only probe up
# front answers three things: the resolved config path (exported so app scripts
# resolve the SAME config from any cwd — a packaged app's cwd is its package
# dir, from which the upward search would find nothing), the packaged-app set,
# and whether this run touches the installed-state ledger at all.
AIRLOCK_PKG_INFO="$(airlock_config package-info)" || exit 2
export AIRLOCK_PKG_INFO
AIRLOCK_CONFIG="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin)["config_path"])')"
export AIRLOCK_CONFIG AIRLOCK_ROOT
_app_ids="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c 'import sys,json; print("\n".join(json.load(sys.stdin)["order"]))')"
_known_builtin_ids="$(airlock_config known-builtins)" || exit 2
airlock_pin_state_dir
_core_root="${AIRLOCK_SHIPPED_APPS_ROOT:-$ROOT/apps}"
_previous_platform_root="$(systemctl --user show airlock-update-detect.service -p WorkingDirectory --value 2>/dev/null || true)"
# Once installation state exists, only ③ says which core apps to update.
# An explicitly empty store is an installed box, not a bootstrap request.
_install_selection="$(python3 - "$ROOT/bin/airlock-ledger" "$_core_root" "$_previous_platform_root" "$_app_ids" "$_known_builtin_ids" "$ROOT/bin/airlock-config" <<'PY_CORE'
from importlib.machinery import SourceFileLoader
import os, sys
sys.dont_write_bytecode = True
ledger = SourceFileLoader("installer_ledger", sys.argv[1]).load_module()
core_root, previous_root, configured, known, config_path = sys.argv[2:]
import json
core = set(known.splitlines())
existing = os.path.lexists(ledger.installed_path()) or os.path.lexists(ledger.legacy_ledger_path())
if existing:
    rows = ledger.load_installed()
    config = SourceFileLoader("installer_config", config_path).load_module()
    core = set(config.known_builtin_specs({}))
    # The installed platform unit names the previous checkout. Only its cores
    # move with the platform; same-id Personal/Company sources keep their owner.
    roots = [core_root]
    if os.path.isabs(previous_root):
        roots.append(os.path.join(previous_root, "apps"))
    ids = [app for app, row in rows.items() if app in core
           and any(os.path.realpath(row["repo"]) == os.path.join(os.path.realpath(root), app)
                   for root in roots)]
else:
    ids = [app for app in configured.splitlines() if app in core]
print(json.dumps({"core": ids, "project": list(rows) if existing else ids, "bootstrap": not existing}))
PY_CORE
)" || exit 2
_bootstrap="$(printf '%s' "$_install_selection" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin)["bootstrap"] else "0")')"
_app_ids="$(printf '%s' "$_install_selection" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["core"]))')"
export AIRLOCK_PROJECT_IDS="$(printf '%s' "$_install_selection" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["project"]))')"

airlock_load hub    # AIRLOCK_HUB_NGINX_PORT / _HTTPS_PORT / _HTTP_PORT / _REDIRECT_PORT
# The platform account/secret surface's port, validated once here. devterm proxies the
# platform secret routes to it (airlock_accounts_port); exporting it keeps that a read of
# this validation rather than a second one.
export AIRLOCK_HUB_ACCOUNTS_PORT

WEBROOT="${AIRLOCK_WEBROOT:-/opt/airlock/hub}"
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
NGINX_SITE="${AIRLOCK_NGINX_SITE:-/etc/nginx/conf.d/airlock.conf}"
_airlock_installed_manifest="$WEBROOT/__airlock.json"

# Measure the deployment FQDN ONCE and hand it to everything downstream (the
# renderers' redirect target, the launcher's cross-port links). Every one of those
# must name the FQDN: the Tailscale cert covers it and nothing else, so a short
# hostname produces links the browser refuses. An operator override wins, which is
# also what lets CI render offline.
if [ -z "${AIRLOCK_TS_FQDN:-}" ]; then
  if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
    AIRLOCK_TS_FQDN="$(ts_fqdn)"
  elif [ -f "$_airlock_installed_manifest" ] \
      && [ ! -L "$_airlock_installed_manifest" ]; then
    AIRLOCK_TS_FQDN="$(python3 - "$_airlock_installed_manifest" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8")).get("fqdn")
if isinstance(value, str) and value:
    print(value)
PY
)" || die "cannot read the installed FQDN for dry-run discovery comparison"
  fi
fi
export AIRLOCK_TS_FQDN

# A normal dry run always renders into a private scratch tree.  Trying the requested
# live roots first is itself a write when their parent is writable, and app installers
# write nginx fragments unconditionally because the renderer consumes them.  The old
# fallback therefore made preview safety depend on permissions: root-owned /etc was
# safe while a user-owned installed root was changed.
#
# Hermetic render suites may request a pre-existing output directory explicitly.  It
# is an output contract, not a live-root override: the orchestrator derives both
# writable roots below it and never treats AIRLOCK_WEBROOT/AIRLOCK_CONFD as preview
# destinations on their own.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  if [ -n "${AIRLOCK_DRY_RUN_OUTPUT_DIR:-}" ]; then
    case "$AIRLOCK_DRY_RUN_OUTPUT_DIR" in
      /*) ;;
      *) die "AIRLOCK_DRY_RUN_OUTPUT_DIR must be an absolute pre-existing directory" ;;
    esac
    [ -d "$AIRLOCK_DRY_RUN_OUTPUT_DIR" ] && [ ! -L "$AIRLOCK_DRY_RUN_OUTPUT_DIR" ] \
      && [ "$(stat -c %u "$AIRLOCK_DRY_RUN_OUTPUT_DIR")" = "$(id -u)" ] \
      || die "AIRLOCK_DRY_RUN_OUTPUT_DIR must be a real directory owned by this user"
    _scratch="$AIRLOCK_DRY_RUN_OUTPUT_DIR"
  else
    _airlock_dry_preview_root="$(mktemp -d)" || die "cannot create private dry-run render root"
    chmod 0700 "$_airlock_dry_preview_root" || die "cannot protect dry-run render root"
    _scratch="$_airlock_dry_preview_root"
    log "[dry] previewing into private scratch $_scratch; live render roots stay untouched"
  fi
  WEBROOT="$_scratch/web"; CONFD="$_scratch/confd"; NGINX_SITE="$_scratch/airlock.conf"
  AIRLOCK_WEBROOT="$WEBROOT"; AIRLOCK_CONFD="$CONFD"; AIRLOCK_NGINX_SITE="$NGINX_SITE"
fi

_airlock_canonical_nginx_site() { # <path>; resolve parent aliases, preserve final symlink
  python3 - "$1" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.is_absolute():
    path = pathlib.Path.cwd() / path
print(path.parent.resolve(strict=False) / path.name)
PY
}
NGINX_SITE="$(_airlock_canonical_nginx_site "$NGINX_SITE")" \
  || die "cannot canonicalize nginx output path"
AIRLOCK_NGINX_SITE="$NGINX_SITE"
export AIRLOCK_WEBROOT AIRLOCK_CONFD AIRLOCK_NGINX_SITE

if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  install -d "$WEBROOT/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d"
fi

# Resolve every read-only candidate projection now, while all recorded apps are
# still active and after dry-run scratch roots have reached their final values.
# A bad manifest icon, launcher tile, env projection, plaintext mapping, or
# prerequisite must not surface for the first time after reconcile has already
# deactivated a working app.
log "validating the complete install candidate"
_candidate_preflight="$(airlock_config install-preflight)" || exit 2

# 1) hub static + frontend config
# WEBROOT and CONFD live under system paths nginx can read. Create them with sudo
# and hand ownership to the installing user, so the hub write + each app's fragment
# write need no further sudo (nginx still reads them — dirs are world-readable).
log "installing hub -> $WEBROOT"
airlock_run sudo mkdir -p "$WEBROOT/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d"
airlock_run sudo chown -R "$(id -un):$(id -gn)" "$WEBROOT" "$CONFD"
airlock_run cp "$ROOT/hub/index.html" "$ROOT/hub/wrong-owner.html" "$WEBROOT/"
# hub brand marks (favicon.png + apple-touch-icon.png), app brand icons, and the
# per-app icon set generated from the launcher sprite (assets/app-icons/, see
# bin/gen-app-icons.py) — all served from /assets/, which same-origin subpath apps
# reference directly. A recursive copy, so a new asset directory needs no wiring here.
[ -d "$ROOT/hub/assets" ] && airlock_run cp -r "$ROOT/hub/assets/." "$WEBROOT/assets/"
# [branding] icon_ring: the subpath apps (notepad, publish, fileview, dev-monitor)
# take their favicon from assets/app-icons/, so ringing only each gate's own copy
# left most tabs on a multi-box tailnet identical. Same filenames, ringed content —
# no page is edited. SVG only; see ring_icon_svg's note on the PNG half.
_icon_ring="$(airlock_config get branding.icon_ring 2>/dev/null || true)"
if [ -n "$_icon_ring" ]; then
  # A dry run must not touch the live webroot. This loop rewrites files in place,
  # so unlike the copy above it cannot go through airlock_run — and the copy above
  # is what restores the unringed original, so a dry run that rang anyway would
  # ring the already-ringed icon, nesting the mark smaller on every re-run.
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
    log "[dry] ring app favicons in $WEBROOT/assets/app-icons/ (${_icon_ring})"
  elif [ -d "$WEBROOT/assets/app-icons" ]; then
    for _icon in "$WEBROOT"/assets/app-icons/*.svg; do
      [ -f "$_icon" ] || continue
      if ring_icon_svg "$_icon_ring" "$_icon" > "$_icon.ringed"; then
        mv "$_icon.ringed" "$_icon"
      else
        rm -f "$_icon.ringed"      # never leave a half-written icon in the webroot
        die "icon_ring: could not ring $_icon"
      fi
    done
    log "app favicons ringed (${_icon_ring})"
  fi
fi
# 1c) The first platform-owned user unit. Apps own their own units below, but the secret
# drop's TTL must remain enforced when no consuming app is installed or running. The
# helper owns both render/install and the symmetric explicit teardown path.
log "installing platform secret TTL timer"
AIRLOCK_ROOT="$ROOT" bash "$ROOT/install/airlock-secret-timer.sh" install

# Update discovery is likewise platform-owned: it compares the platform release,
# package ledger and local harness once per day, then dev-monitor only reads its snapshot.
log "installing platform update detector timer"
AIRLOCK_ROOT="$ROOT" bash "$ROOT/install/airlock-update-timer.sh" install

# 1c-2) The platform account surface (ACCT_SURFACE). A service rather than a oneshot:
# the hub proxies /airlock-accounts/ to it behind an owner-only guard. It stays behind
# nginx on loopback and never binds the tailnet itself.
log "installing platform account surface"
AIRLOCK_ROOT="$ROOT" AIRLOCK_HUB_ACCOUNTS_PORT="$AIRLOCK_HUB_ACCOUNTS_PORT" \
  AIRLOCK_HUB_FLEET_STORE="${AIRLOCK_HUB_FLEET_STORE-}" \
  AIRLOCK_HUB_FLEET_STORE_URL="${AIRLOCK_HUB_FLEET_STORE_URL-}" \
  AIRLOCK_HUB_XAI="${AIRLOCK_HUB_XAI-false}" \
  AIRLOCK_HUB_MUSE_SECRET_BIN="${AIRLOCK_HUB_MUSE_SECRET_BIN-}" \
  AIRLOCK_HUB_MUSE_REGISTRY="${AIRLOCK_HUB_MUSE_REGISTRY-}" \
  bash "$ROOT/install/airlock-accounts-api.sh" install

# 1d) Retire platform units this tree no longer declares. Runs AFTER the installs above,
# so a failure up there aborts (set -e) before anything is swept — the declared set is
# only trustworthy once it has actually been written. The list below is this installer's
# complete platform unit set; adding a unit above without adding it here deletes it on the
# next run, which is what the test's "declared units survive" control is for.
# live/systemd/* is a different owner and a different installer (live/install-timer.sh) —
# see airlock_sweep_platform_units for why the marker names one.
airlock_sweep_platform_units airlock-install \
  airlock-secret-sweep.service airlock-secret-sweep.timer \
  airlock-update-detect.service airlock-update-detect.timer \
  airlock-accounts-api.service

# 2) Update installed core apps, or bootstrap a box without installation state.
# An initial preview has no installed dependencies: validate and show the plan,
# without running hooks against a fictional ③. Existing-box dry previews keep
# executing certified shipped hooks in the private render roots.
while read -r app; do
  [ -n "$app" ] || continue
  [ "$app" = hub ] && continue
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
    pkg_dir="$_core_root/$app"
    _dry_certified="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c '
import json, sys
pkg = (json.load(sys.stdin).get("packages") or {}).get(sys.argv[1]) or {}
print("1" if "dry-run-exec" in (pkg.get("certifications") or []) else "0")
' "$app")"
    if [ "$_bootstrap" = 0 ] && [ "$_dry_certified" = 1 ]; then
      log "[dry] installing packaged app: $app ($pkg_dir) (shipped app — dry run executes)"
      (cd "$pkg_dir" && AIRLOCK_CONFD="$CONFD" AIRLOCK_ROOT="$ROOT" \
        AIRLOCK_APP_DIR="$pkg_dir" AIRLOCK_APP_ID="$app" \
        bash "$pkg_dir/install.sh" </dev/null)
    else
      log "[dry] would install packaged app: $app from $pkg_dir (script not run)"
    fi
  else
    log "applying app: $app"
    "$ROOT/bin/airlock-ledger" apply "$app" --source "$_core_root/$app" </dev/null
  fi
done <<<"$_app_ids"

# Config tables are app inputs. Removing one never removes an installed app.
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  "$ROOT/bin/airlock-ledger" project
else
  _preview_ids=()
  while read -r app; do
    [ -z "$app" ] || _preview_ids+=("$app")
  done <<<"${AIRLOCK_PROJECT_IDS// /$'\n'}"
  "$ROOT/bin/airlock-ledger" project "${_preview_ids[@]}"
fi

# 4b) reboot survival. Each app installer already `systemctl --user enable`s its
# units, but on a headless box --user units only start at boot when the installing
# user has lingering enabled. Also make sure nginx + tailscaled come up on boot.
# Idempotent; safe to re-run. Warnings are loud but non-fatal (don't abort a
# working install just because boot-persistence couldn't be armed).
airlock_enable_linger "$(id -un)"
# The two below keep exit-code warnings on purpose: nothing else in this repo
# enables them, so a failure here is genuinely news, and both messages already say
# "usually already enabled by the package" rather than claiming something is broken.
airlock_run sudo systemctl enable nginx \
  || log "WARN: could not enable nginx on boot (usually already enabled by the package)"
airlock_run sudo systemctl enable tailscaled \
  || log "WARN: could not enable tailscaled on boot (usually already enabled by the Tailscale package)"

# 6) smoke each enabled app now that the gate is live
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  smoke_fail=0
  _smoke_failed=""
  while read -r app; do
    [ -n "$app" ] || continue
    [ "$app" = hub ] && continue
    pkg_dir="$_core_root/$app"
    s="$pkg_dir/smoke.sh"
    # Validate proved smoke.sh was a regular non-symlink file (F6); a
    # silent skip would commit an app nothing ever smoked, and a symlink
    # would run content the digest never covered.
    { [ -f "$s" ] && [ ! -L "$s" ]; } \
      || die "packaged app '$app': $s is missing or not a regular non-symlink file (F6)"
    log "smoke: $app"
    (cd "$pkg_dir" && AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$pkg_dir" AIRLOCK_APP_ID="$app" \
      bash "$s" </dev/null) \
      || { log "smoke FAILED: $app"; smoke_fail=1; _smoke_failed="$_smoke_failed $app"; }
  done <<<"$_app_ids"

  [ "$smoke_fail" = 0 ] || die "one or more app smokes failed"
fi

# 6b) the layer in front of the loopback smokes: is the serve mapping assembled, is TLS
# terminating, is something alive behind it. Skips itself, loudly, under a dry run.
serve_rc=0; airlock_serve_check || serve_rc=$?
# 2 = the check could not run and said why; 1 = it ran and the frontend is not up
# yet. Neither aborts a finished install — the closing lines below already say
# what was not established, rather than claiming it and being wrong.
[ "$serve_rc" != 1 ] || log "WARN: the apps are up but the tailscale serve frontend is not — check bin/airlock-status"

# The closing lines name the URL to open and then name what was not established. The
# second is not a footnote on the first: an install that ends "done" while the box is
# unreachable is the failure this whole check exists for, and only the operator, on
# another device, can rule it out.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "done (dry run — nothing was changed). You would open: https://<your-box>.<tailnet>.ts.net/"
else
  log "done. Open: $(airlock_entrance_url)"
  airlock_ingress_unverified
fi
