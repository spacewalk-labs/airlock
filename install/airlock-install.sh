#!/usr/bin/env bash
# Apply platform files, then the recorded apps owned by this checkout.
# AIRLOCK_DRY_RUN=1 previews the same selection without running app hooks.
#
#   bash install/airlock-install.sh
#
# May require sudo for nginx/tailscale steps depending on your box.
set -euo pipefail

_airlock_install_usage() {
  cat <<'EOF'
airlock-install — apply the platform and its recorded core apps.
  bash install/airlock-install.sh
  AIRLOCK_DRY_RUN=1 bash install/airlock-install.sh
  bash install/airlock-install.sh --help
EOF
}

_airlock_arg_die() {
  printf '[airlock] FATAL: %s\n' "$*" >&2
  exit 1
}

# Handle help before loading platform helpers.
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

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# Use this release's config reader.
# A release install reads current config; caller hook/freeze inputs are not authority.
unset AIRLOCK_PKG_INFO_FILE AIRLOCK_PKG_INFO AIRLOCK_CONFIG_SNAPSHOT \
  AIRLOCK_CONFIG_SNAPSHOT_SHA256 AIRLOCK_INSTALL_PKG_INFO_SHA256 \
  AIRLOCK_APP_SCOPED_PLAN_SHA256 AIRLOCK_LEDGER_DEPENDENCIES_SHA256 \
  AIRLOCK_APP_ID AIRLOCK_APP_DIR
AIRLOCK_CONFIG_BIN="$ROOT/bin/airlock-config"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/apps/dev-monitor/migration-lifecycle.sh"

# Leave the hosting app cgroup before restarting its units.
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  airlock_escape_selfkill_cgroup "$0" "$@"
fi

# Resolve the operator config once; each apply reads only its own manifest.
AIRLOCK_CONFIG="$(python3 - "$ROOT/bin/airlock-config" <<'PY_CONFIG'
from importlib.machinery import SourceFileLoader
import sys
sys.dont_write_bytecode = True
config = SourceFileLoader("installer_config", sys.argv[1]).load_module()
print(config.find_config())
PY_CONFIG
)"
export AIRLOCK_CONFIG AIRLOCK_ROOT
airlock_pin_state_dir
airlock_load hub
export AIRLOCK_HUB_ACCOUNTS_PORT

WEBROOT="${AIRLOCK_WEBROOT:-/opt/airlock/hub}"
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
NGINX_SITE="${AIRLOCK_NGINX_SITE:-/etc/nginx/conf.d/airlock.conf}"
_airlock_preview=""
trap '[ -z "$_airlock_preview" ] || rm -rf -- "$_airlock_preview"' EXIT
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  if [ -n "${AIRLOCK_DRY_RUN_OUTPUT_DIR:-}" ]; then
    _scratch="$AIRLOCK_DRY_RUN_OUTPUT_DIR"
  else
    _airlock_preview="$(mktemp -d)"
    _scratch="$_airlock_preview"
  fi
  WEBROOT="$_scratch/web"; CONFD="$_scratch/confd"; NGINX_SITE="$_scratch/airlock.conf"
  install -d "$WEBROOT/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d"
elif [ -z "${AIRLOCK_TS_FQDN:-}" ]; then
  AIRLOCK_TS_FQDN="$(ts_fqdn)"
fi
export AIRLOCK_WEBROOT="$WEBROOT" AIRLOCK_CONFD="$CONFD" AIRLOCK_NGINX_SITE="$NGINX_SITE"
export AIRLOCK_TS_FQDN

# Source ownership is the recorded directory, not an id/catalog/config guess.
# Manifest edges order the selected rows. A bad manifest still reaches apply,
# reports that app's failure, and cannot prevent the other rows from running.
_core_ids="$(python3 - "$ROOT/bin/airlock-ledger" "$ROOT/apps" "$ROOT/bin/airlock-config" <<'PY_APPS'
from importlib.machinery import SourceFileLoader
import json, os, sys
sys.dont_write_bytecode = True
ledger = SourceFileLoader("installer_ledger", sys.argv[1]).load_module()
config = SourceFileLoader("installer_order_config", sys.argv[3]).load_module()
root = os.path.realpath(sys.argv[2])
rows = ledger.load_installed()
selected = {app: row for app, row in rows.items()
            if ledger._recorded_repo(row)
            and os.path.realpath(ledger._recorded_repo(row)) == os.path.join(root, app)}
deps = {}
for app, row in selected.items():
    try:
        deps[app] = ledger.read_dir_package(app, row["repo"]).get("deps", [])
    except ledger.LedgerError:
        deps[app] = []
print(json.dumps(config.dependency_order(list(selected), deps)))
PY_APPS
)"

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

# A failed app is reported once and the remaining recorded core apps continue.
install_rc=0
while IFS= read -r -d '' app; do
  log "applying app: $app"
  if "$ROOT/bin/airlock-ledger" apply -- "$app"; then
    log "applied: $app"
  else
    log "apply FAILED: $app"
    install_rc=1
  fi
done < <(printf '%s' "$_core_ids" | python3 -c 'import json,os,sys; [os.write(1, app.encode()+b"\0") for app in json.load(sys.stdin)]')

# The Hub is a platform projection; Company and Personal app hooks are separate.
if ! "$ROOT/bin/airlock-ledger" project; then
  log "platform projection FAILED"
  install_rc=1
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

if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "done (dry run)"
else
  log "finished (rc=$install_rc). Open: $(airlock_entrance_url)"
  airlock_ingress_unverified
fi
exit "$install_rc"
