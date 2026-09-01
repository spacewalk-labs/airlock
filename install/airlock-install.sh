#!/usr/bin/env bash
# Airlock orchestrator: validate config -> install enabled apps -> render nginx
# -> reload. Idempotent; re-run after editing airlock.toml. Set AIRLOCK_DRY_RUN=1
# to print the steps without touching the system.
#
#   bash install/airlock-install.sh
#
# May require sudo for nginx/tailscale steps depending on your box.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# Never inherit a config reader from the caller. The private wrapper is set
# only on individual lifecycle child invocations below; accepting an ambient
# value here would recreate the rejected persistent escape switch under a
# different name.
AIRLOCK_CONFIG_BIN="$ROOT/bin/airlock-config"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

# This marker is asserted only after this process acquires or verifies the
# ledger lock below. Never trust a value inherited from a parent shell as
# proof of lock ownership.
unset AIRLOCK_LEDGER_LOCK_HELD AIRLOCK_CONFIG_SNAPSHOT \
  AIRLOCK_CONFIG_SNAPSHOT_SHA256

# The exceptional path is one exact, package-scoped argv value.  Do not add an
# environment alias: an exported value would silently remain active for later
# runs. Lifecycle argv remains empty; a private temporary config wrapper gives
# only this process tree the same package-scoped decision.
_airlock_lifecycle_args=()
_airlock_lifecycle_config_bin="$AIRLOCK_CONFIG_BIN"
_airlock_config_wrapper=""
_airlock_config_snapshot=""
for _airlock_install_arg in "$@"; do
  case "$_airlock_install_arg" in
    --dangerously-admit-unverified=*)
      [ "${#_airlock_lifecycle_args[@]}" -eq 0 ] \
        || die "--dangerously-admit-unverified is accepted only once"
      _airlock_lifecycle_args+=("$_airlock_install_arg")
      ;;
    --dangerously-admit-unverified)
      die "--dangerously-admit-unverified requires =<package-id>"
      ;;
    *)
      die "unknown installer argument: $_airlock_install_arg"
      ;;
  esac
done

_airlock_cleanup_config_wrapper() {
  [ -z "$_airlock_config_wrapper" ] || rm -f -- "$_airlock_config_wrapper"
  [ -z "$_airlock_config_snapshot" ] || rm -f -- "$_airlock_config_snapshot"
}
trap _airlock_cleanup_config_wrapper EXIT

if [ "${#_airlock_lifecycle_args[@]}" -eq 1 ]; then
  _airlock_config_wrapper="$(mktemp)" || die "cannot create break-glass config wrapper"
  python3 - "$_airlock_config_wrapper" "$AIRLOCK_CONFIG_BIN" \
    "${_airlock_lifecycle_args[0]}" <<'PY' \
    || die "cannot write break-glass config wrapper"
from pathlib import Path
import sys

path, config_bin, argument = sys.argv[1:]
source = """import os
import sys
os.execv(sys.executable, [sys.executable, %r, %r, *sys.argv[1:]])
""" % (config_bin, argument)
Path(path).write_text(source, encoding="utf-8")
PY
  chmod 0600 "$_airlock_config_wrapper" || die "cannot protect break-glass config wrapper"
  _airlock_lifecycle_config_bin="$_airlock_config_wrapper"
  # From this point every orchestrator config read, not only lifecycle reads,
  # goes through the one-run wrapper. install/lib.sh itself does not interpret
  # lifecycle argv, so running a package script with the public flag cannot
  # create an unaudited admission path.
  AIRLOCK_CONFIG_BIN="$_airlock_config_wrapper"
fi
airlock_preflight_bootstrap

# Freeze the operator file before choosing the ledger-lock predicate. Config
# edits made after this point belong to the next run; this run's validation,
# plan/remove, app order, lifecycle env and renderers all consume one immutable
# byte snapshot. AIRLOCK_CONFIG remains the original path so relative package
# paths retain their documented base directory.
_airlock_config_snapshot="$(mktemp)" || die "cannot create install config snapshot"
_snapshot_receipt="$(airlock_config install-snapshot "$_airlock_config_snapshot")" || exit 2
_snapshot_digest="$(printf '%s' "$_snapshot_receipt" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')" \
  || die "cannot read install config snapshot digest"
AIRLOCK_CONFIG="$(printf '%s' "$_snapshot_receipt" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["config_path"])')" \
  || die "cannot read install config snapshot origin"
[[ "$_snapshot_digest" =~ ^[0-9a-f]{64}$ ]] \
  || die "install config snapshot returned an invalid digest"
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
_pkg_ids="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c 'import sys,json; print("\n".join(sorted(json.load(sys.stdin)["packages"])))')"
_app_ids="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c 'import sys,json; print("\n".join(json.load(sys.stdin)["order"]))')"
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ "${#_airlock_lifecycle_args[@]}" -eq 1 ]; then
  log "[dry] DANGEROUS: would admit unverified package lock mismatch: ${_airlock_lifecycle_args[0]} (no audit or lock state will be written)"
fi
_state_dir="${AIRLOCK_STATE_DIR:-$HOME/.local/state/airlock}"
LEDGER_FILE="$_state_dir/app-ledger.json"
RETIREMENT_FILE="$_state_dir/plaintext-retirement.json"
# F15 amendment (child 4/P4): the gate must also open for a box that has NO
# configured packages and NO ledger file yet, but DOES have a known builtin
# on disk (apps/<id>/airlock-app.toml, hub/core and shadowed ids excluded) —
# the box that used to escape the gate entirely (hub-only, install/airlock-
# install.sh's old predicate) is exactly the one the F15 adoption sweep
# exists to reach. `known-builtins` itself needs no lock (read-only).
_known_builtins="$(airlock_config known-builtins)" || exit 2

# One writer (D6/F9c): the exclusive span covers validate -> mutate -> commit —
# a lock taken after validate would let a concurrent run's journal write
# invalidate a finished disjointness check. Only runs that can touch the ledger
# or plaintext-retirement record lock. A box with none of those records, no
# packages, and no known builtin never creates the state dir; a dry run locks
# nothing because it mutates nothing.
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] \
  && { [ -n "$_pkg_ids" ] || [ -e "$LEDGER_FILE" ] || [ -L "$LEDGER_FILE" ] \
    || [ -e "$RETIREMENT_FILE" ] || [ -L "$RETIREMENT_FILE" ] \
    || [ -n "$_known_builtins" ]; }; then
  require_cmd flock
  # `install -d -m` sets the mode on an EXISTING directory too, and that turned a
  # default into an enforcement nobody declared. dev-monitor's spool is written by a
  # second uid, so that uid has to TRAVERSE this directory
  # (apps/dev-monitor/install-spool-hardening.sh checks exactly that) — and 0700 forbids
  # it. Re-asserting the mode here meant the check could never pass: widen it and the
  # next run closes it again.
  #
  # Measured 2026-08-22 on a box updating to this revision: the install died at
  # dev-monitor four times, and setting the directory to 710 by hand did not survive a
  # single re-run.
  #
  # 0700 is still what a directory created HERE gets. What changed is that it is a
  # default rather than a reassertion — an existing directory keeps the mode its owner,
  # or an app that declared why, gave it.
  [ -d "$_state_dir" ] || install -d -m 0700 "$_state_dir"
  airlock_pin_state_dir
  _state_dir="${AIRLOCK_STATE_DIR:-$_state_dir}"
  LEDGER_FILE="$_state_dir/app-ledger.json"
  RETIREMENT_FILE="$_state_dir/plaintext-retirement.json"
  if [ -n "${AIRLOCK_LEDGER_LOCK_FD:-}" ]; then
    case "$AIRLOCK_LEDGER_LOCK_FD" in
      *[!0-9]*) die "inherited ledger lock fd must be an open descriptor >= 3" ;;
    esac
    [ "$AIRLOCK_LEDGER_LOCK_FD" -ge 3 ] 2>/dev/null \
      || die "inherited ledger lock fd must be an open descriptor >= 3"
    [ -f "/proc/self/fd/$AIRLOCK_LEDGER_LOCK_FD" ] \
      && [ "/proc/self/fd/$AIRLOCK_LEDGER_LOCK_FD" -ef "$_state_dir/app-ledger.lock" ] \
      || die "inherited ledger lock fd does not name $_state_dir/app-ledger.lock"
    flock -n "$AIRLOCK_LEDGER_LOCK_FD" \
      || die "inherited ledger lock fd is not available ($_state_dir/app-ledger.lock)"
    if [ "$AIRLOCK_LEDGER_LOCK_FD" != 9 ]; then
      eval "exec 9<&$AIRLOCK_LEDGER_LOCK_FD"
      eval "exec $AIRLOCK_LEDGER_LOCK_FD>&-"
    fi
  else
    exec 9>>"$_state_dir/app-ledger.lock"
    flock -n 9 || die "another airlock run holds the ledger lock ($_state_dir/app-ledger.lock) — one writer at a time; re-run when it finishes"
  fi
  unset AIRLOCK_LEDGER_LOCK_FD
  # Sidecar mutation commands are also directly dispatchable. Tell them this
  # process already owns the shared writer lock so they neither deadlock nor
  # admit a concurrent manual recovery mutation into this run.
  AIRLOCK_LEDGER_LOCK_HELD=1
  export AIRLOCK_LEDGER_LOCK_HELD
  # Re-read the immutable snapshot under the lock. This is intentionally the
  # same candidate as the gate probe, not a second read of a mutable operator
  # file: gate, plan/remove and app install must never observe A/B configs.
  AIRLOCK_PKG_INFO="$(airlock_config package-info)" || exit 2
  export AIRLOCK_PKG_INFO
  _pkg_ids="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c 'import sys,json; print("\n".join(sorted(json.load(sys.stdin)["packages"])))')"
  _app_ids="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c 'import sys,json; print("\n".join(json.load(sys.stdin)["order"]))')"
  if [ "${#_airlock_lifecycle_args[@]}" -eq 1 ]; then
    _breakglass_id="${_airlock_lifecycle_args[0]#*=}"
    _breakglass_receipt="$(printf '%s' "$AIRLOCK_PKG_INFO" \
      | "$ROOT/bin/airlock-ledger" audit-lock-override "$_breakglass_id")" \
      || die "failed to record break-glass admission before package mutation"
    [[ "$_breakglass_receipt" =~ ^[0-9a-f]{64}$ ]] \
      || die "break-glass audit returned an invalid current-run receipt"
  fi
  _ledger_gate=1
else
  # Decided ONCE, with the lock: a run that chose not to lock must never
  # touch the ledger later, even if a concurrent run creates the file
  # between this decision and reconcile (one writer, D6/F9c).
  _ledger_gate=0
fi

log "validating airlock.toml"
airlock_config validate || exit 2
airlock_preflight

# Fail-closed: Airlock v1 requires Tailscale up as the ingress (see SECURITY.md).
# (The app installers configure `tailscale serve`; this only requires Tailscale is
# authenticated.) Only a dry run may skip the live check.
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  ts_require_tailscale
  ts_require_https
fi

airlock_load hub    # AIRLOCK_HUB_NGINX_PORT / _HTTPS_PORT / _HTTP_PORT / _REDIRECT_PORT

# Measure the deployment FQDN ONCE and hand it to everything downstream (the
# renderers' redirect target, the launcher's cross-port links). Every one of those
# must name the FQDN: the Tailscale cert covers it and nothing else, so a short
# hostname produces links the browser refuses. An operator override wins, which is
# also what lets CI render offline.
if [ -z "${AIRLOCK_TS_FQDN:-}" ] && [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  AIRLOCK_TS_FQDN="$(ts_fqdn)"
fi
export AIRLOCK_TS_FQDN
WEBROOT="${AIRLOCK_WEBROOT:-/opt/airlock/hub}"
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
NGINX_SITE="${AIRLOCK_NGINX_SITE:-/etc/nginx/conf.d/airlock.conf}"

# A dry run must not take root, and the mkdir below is inside airlock_run — so on a
# box that has never been installed, $CONFD does not exist when the app installers
# run. Each of them then writes its nginx fragment with a bare `install -d`, because
# the fragments are config the renderer needs (install/test-integration.sh asserts
# them from a dry run). Without root that died on EACCES in the first app installer:
#
#   install: cannot create directory '/etc/airlock': Permission denied
#
# meaning `AIRLOCK_DRY_RUN=1` only worked on a box that had already completed a real
# install — the preview step failed for exactly the people who had not installed
# yet, and told them nothing about why. So a dry run that cannot use the real
# directories gets scratch ones, and says where they went.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  for _d in "$WEBROOT/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d"; do
    [ -d "$_d" ] || install -d "$_d" 2>/dev/null || { _dry_scratch=1; break; }
  done
  if [ "${_dry_scratch:-0}" = 1 ]; then
    _scratch="$(mktemp -d)"
    log "[dry] $WEBROOT / $CONFD are not writable without root, which a dry run will not \
take — previewing into $_scratch instead. Paths in the lines below are the scratch ones."
    WEBROOT="$_scratch/hub"; CONFD="$_scratch/nginx"
    install -d "$WEBROOT/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d"
    AIRLOCK_WEBROOT="$WEBROOT"; AIRLOCK_CONFD="$CONFD"
  fi
fi
export AIRLOCK_WEBROOT AIRLOCK_CONFD

# Resolve every read-only candidate projection now, while all recorded apps are
# still active and after dry-run scratch roots have reached their final values.
# A bad manifest icon, launcher tile, env projection, plaintext mapping, or
# prerequisite must not surface for the first time after reconcile has already
# deactivated a working app.
log "validating the complete install candidate"
_candidate_preflight="$(printf '%s' "$AIRLOCK_PKG_INFO" \
  | airlock_config install-preflight --package-info-stdin)" || exit 2
[[ "$_candidate_preflight" =~ ^[0-9a-f]{64}$ ]] \
  || die "complete install candidate preflight returned an invalid digest"

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
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] airlock-config webjson > $WEBROOT/__airlock.json"
else
  airlock_config webjson > "$WEBROOT/__airlock.json"
fi

# 1b) reconcile the installed-state ledger (packaged apps only). Repairs
# crashed runs, removes what config no longer desires — a refusal (recorded
# app without a deactivator) aborts here, before any install touches the box.
# Sits after the roots above because teardown resolves against $CONFD/$WEBROOT.
_active_ports=""
_deactivate_failed=""
if [ "$_ledger_gate" = 1 ] || { [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] \
  && { [ -n "$_pkg_ids" ] || [ -f "$LEDGER_FILE" ] || [ -n "$_known_builtins" ]; }; }; then
  # Close the read-to-reconcile window.  The first pass proved every static
  # projection before any install mutation; this repeat proves it is still the
  # same candidate immediately before the first ledger removal/deactivation.
  _candidate_preflight_now="$(printf '%s' "$AIRLOCK_PKG_INFO" \
    | airlock_config install-preflight --package-info-stdin)" || exit 2
  [ "$_candidate_preflight_now" = "$_candidate_preflight" ] \
    || die "install candidate changed before reconcile — no recorded app was deactivated"
  # Computed only on ledger-touching runs: a built-in-only box must see the
  # exact byte stream it saw before packages existed.
  _active_ports="$(airlock_config plaintext | awk '{print $2}' | tr '\n' ' ')"
  _plan="$(printf '%s' "$AIRLOCK_PKG_INFO" | "$ROOT/bin/airlock-ledger" plan)" || {
    _rc=$?
    [ "$_rc" = 3 ] && die "a recorded app without a deactivator blocks this change (see above) — the one exit is the explicit teardown command it names"
    die "installed-state ledger plan failed (rc=$_rc)"
  }
  # 🔴 One package's failed teardown must not strand the others. This loop
  # deactivates EVERY changed package before ANY of them reinstalls (so a port
  # an old install still holds is free before the new one binds), which means
  # aborting in the middle leaves the packages already processed deactivated
  # with nothing to bring them back. Measured twice on a real box (2026-08-26):
  # one deactivator exited 1 and four unrelated apps stayed down.
  # So: record the failure, keep going, skip only that package's install, and
  # fail loudly at the end. The ledger keeps a failed package's record, so the
  # next run re-plans exactly the same teardown.
  while IFS=$'\t' read -r _action _id; do
    [ -n "${_action:-}" ] || continue
    case "$_action" in
      remove|teardown-intent)
        # airlock-ledger honours AIRLOCK_DRY_RUN itself ([dry] per artifact),
        # which previews more than airlock_run's one-line command echo would.
        log "reconcile: removing '$_id' (recorded but no longer in config)"
        printf '%s' "$AIRLOCK_PKG_INFO" | "$ROOT/bin/airlock-ledger" remove "$_id" --active-ports "$_active_ports" \
          || { log "reconcile FAILED: could not remove '$_id' (see above)"; _deactivate_failed="$_deactivate_failed $_id"; } ;;
      upgrade-deactivate)
        log "reconcile: '$_id' changed — deactivating the recorded install before the fresh one"
        printf '%s' "$AIRLOCK_PKG_INFO" | "$ROOT/bin/airlock-ledger" remove "$_id" --for-upgrade --active-ports "$_active_ports" \
          || { log "reconcile FAILED: could not deactivate '$_id' (see above); its install is skipped, the rest continue"; _deactivate_failed="$_deactivate_failed $_id"; } ;;
      fresh|reinstall|upgrade-diff)
        : ;;  # handled by the install/commit path below
      *)
        die "unknown ledger plan action: $_action ($_id)" ;;
    esac
  done <<<"$_plan"

  # F15 sweep (child 4/P4, amended: runs on EVERY ledger-enabled run, not
  # only the first): known builtins with no config entry and no ledger
  # record are reported here — loudly, never removed on their own. Read-only
  # (adopt-scan mutates nothing); the operator runs the printed `--adopt`
  # line by hand. Captured into a variable with an explicit failure check
  # (not `done < <(...)`): a process-substitution's exit status is invisible
  # to `set -e` — a failing sweep would otherwise vanish silently instead of
  # aborting the run.
  _adopt_scan="$(airlock_config adopt-scan)" || die "known-builtin adoption sweep failed (rc=$?)"
  while IFS=$'\t' read -r _kind _kid _detail; do
    [ -n "${_kind:-}" ] || continue
    case "$_kind" in
      ADOPT)
        log "pre-ledger artifact(s) found for known builtin '$_kid': $_detail — reclaim with: bin/airlock-teardown --adopt $_kid"
        ;;
      EXCLUDE)
        log "known builtin '$_kid' has artifacts but its claims overlap live state — resolve by hand ($_detail)"
        ;;
      *)
        die "unknown adopt-scan line: $_kind ($_kid)" ;;
    esac
  done <<<"$_adopt_scan"
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

# 2) enabled app installers (each drops its own nginx fragment into $CONFD/*)
# Child 4/P3: validate already refused any enabled app that is neither hub
# nor a resolvable package (shipped or explicit) — pkg_dir is unconditionally
# non-empty here, so the legacy "apps/$app/install.sh not present yet"
# fallback branch is retired.
_installed_pkgs=""
while read -r app; do
  [ "$app" = hub ] && continue
  pkg_dir="$(airlock_pkg_dir "$app")"
  inst="$pkg_dir/install.sh"
  if [ ! -f "$inst" ] || [ -L "$inst" ]; then
    # Validate proved this was a regular non-symlink file (F6). Absence is
    # a validate-then-delete race; a symlink is worse — the D6 digest
    # records only a symlink's target string, so following it here would
    # run unverified content behind an unchanged digest.
    die "packaged app '$app': $inst is missing or not a regular non-symlink file (F6)"
  elif [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
    # A dry run never executes an uncertified package's scripts: their
    # AIRLOCK_DRY_RUN discipline is unknown third-party code (D4), and
    # running it without lock or journal would break both contracts. Every
    # canonical bundle app's immutable policy certifies full AIRLOCK_DRY_RUN
    # discipline, so its install.sh DOES run here.  Consume that derived fact;
    # source_class remains provenance and an id/path classification is not an
    # authorization decision. The ledger is never touched on this path (no
    # intent/icon-stage/commit): those stay gated to a real run, below.
    _dry_certified="$(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c '
import json, sys
pkg = (json.load(sys.stdin).get("packages") or {}).get(sys.argv[1]) or {}
print("1" if "dry-run-exec" in (pkg.get("certifications") or []) else "0")
' "$app")"
    if [ "$_dry_certified" = 1 ]; then
      log "[dry] installing packaged app: $app ($pkg_dir) (shipped app — dry run executes)"
      (cd "$pkg_dir" && AIRLOCK_CONFD="$CONFD" AIRLOCK_ROOT="$ROOT" \
        AIRLOCK_APP_DIR="$pkg_dir" AIRLOCK_APP_ID="$app" \
        AIRLOCK_CONFIG_BIN="$_airlock_lifecycle_config_bin" \
        bash "$inst" </dev/null) 9>&-
      # serve.https platform render (D2 manifest surface; child-4 P2b STEP
      # 0 infra) — byte-identical to the direct `sudo tailscale serve
      # --bg --https=...` call devterm/code-server/orca/paseo used to run
      # inline from their own install.sh (install/test-serve-https-parity.sh).
      # Runs here, not inside the subshell above: it only reads
      # AIRLOCK_PKG_INFO/$app, same as the hub's own https serve call
      # below (step 5), which also runs un-subshelled in this scope.
      airlock_render_serve_https "$app"
    else
      log "[dry] would install packaged app: $app from $pkg_dir (script not run)"
    fi
  elif case " $_deactivate_failed " in *" $app "*) true ;; *) false ;; esac; then
    # Its recorded teardown failed above, so the box still holds the OLD
    # install's artifacts. Installing over them would let the ledger commit a
    # new record while the old one still names artifacts nobody will reclaim.
    log "skipping install of '$app': its recorded deactivation failed above"
  else
    log "installing packaged app: $app ($pkg_dir)"
    printf '%s' "$AIRLOCK_PKG_INFO" | "$ROOT/bin/airlock-ledger" intent "$app" --active-ports "$_active_ports" >/dev/null
    # F4: stage the tile icon ONLY NOW that the intent above names its
    # destination (record before mutate) — a crash after the copy leaves an
    # artifact the ledger already knows how to reclaim. icon-stage is one
    # process: it re-checks containment, proves the tree still matches the
    # journaled intent (digest), refuses symlinks at every destination
    # component, and writes atomically.
    _icon_out="$(airlock_config icon-stage "$app")" \
      || die "packaged app '$app': tile icon staging failed (F4)"
    [ -z "$_icon_out" ] || log "staged tile icon: $app -> $WEBROOT/$_icon_out"
    # 9>&-: lifecycle children must not inherit the lock fd — a background
    # process an installer leaves behind would hold the flock forever.
    (cd "$pkg_dir" && AIRLOCK_CONFD="$CONFD" AIRLOCK_ROOT="$ROOT" \
      AIRLOCK_APP_DIR="$pkg_dir" AIRLOCK_APP_ID="$app" \
      AIRLOCK_CONFIG_BIN="$_airlock_lifecycle_config_bin" \
      bash "$inst" </dev/null) 9>&-
    # serve.https platform render — see the dry-run branch above for the
    # full rationale; same call, same position relative to install.sh.
    airlock_render_serve_https "$app"
    _installed_pkgs="$_installed_pkgs $app"
  fi
done <<<"$_app_ids"

# 3) render the main site (includes the fragments from step 2)
log "rendering nginx site -> $NGINX_SITE"
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] render-nginx.sh > $NGINX_SITE"
else
  tmp="$(mktemp)"
  AIRLOCK_CONFIG_BIN="$_airlock_lifecycle_config_bin" \
    bash "$ROOT/install/render-nginx.sh" > "$tmp"
  airlock_run sudo cp "$tmp" "$NGINX_SITE"
  rm -f "$tmp"
fi

# 4) validate + reload
airlock_run sudo nginx -t
airlock_run sudo systemctl reload nginx

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

# 5) expose the hub entrance over https via tailscale serve
airlock_run sudo tailscale serve --bg --https="${AIRLOCK_HUB_HTTPS_PORT}" "http://127.0.0.1:${AIRLOCK_HUB_NGINX_PORT}"

# 5b) plaintext ports — ONE owner, and only now that nginx is reloaded and actually
# serving the redirect ports. Each plaintext port is pointed at its app's
# redirect_port, whose sole response is a 301 to https: no page and no identity
# header ever crosses a non-TLS connection.
#
# Then RETIRE stale mappings. `tailscale serve --bg` persists until explicitly
# turned off, so a port that config no longer asks for (app removed, port changed)
# would keep proxying its old target — a plaintext hole that survives every
# re-install. Only Airlock's own plaintext ports are considered; mappings an
# operator added by hand are left alone.
want_ports=""
# The sidecar is the retirement authority when config, payload, and ledger are
# all gone. Commit it BEFORE opening a persistent Tailscale mapping. A later
# mapping/smoke failure deliberately leaves the record behind for retry/cleanup.
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  airlock_config plaintext-retirement-record || exit 2
fi
while IFS=$'\t' read -r app listen redirect; do
  [ -n "${listen:-}" ] || continue
  log "plaintext ingress: :$listen -> 301 https (${app})"
  ts_apply_plaintext_mapping "$app" "$listen" "$redirect"
  want_ports="$want_ports $listen"
done < <(airlock_config plaintext)

ts_reconcile_plaintext_ports "$want_ports" \
  || die "cannot reconcile stale plaintext ingress"

# 6) smoke each enabled app now that the gate is live
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  smoke_fail=0
  _smoke_failed=""
  while read -r app; do
    [ "$app" = hub ] && continue
    pkg_dir="$(airlock_pkg_dir "$app")"
    s="$pkg_dir/smoke.sh"
    # Validate proved smoke.sh was a regular non-symlink file (F6); a
    # silent skip would commit an app nothing ever smoked, and a symlink
    # would run content the digest never covered.
    { [ -f "$s" ] && [ ! -L "$s" ]; } \
      || die "packaged app '$app': $s is missing or not a regular non-symlink file (F6)"
    log "smoke: $app"
    (cd "$pkg_dir" && AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$pkg_dir" AIRLOCK_APP_ID="$app" \
      AIRLOCK_CONFIG_BIN="$_airlock_lifecycle_config_bin" \
      bash "$s" </dev/null) 9>&- \
      || { log "smoke FAILED: $app"; smoke_fail=1; _smoke_failed="$_smoke_failed $app"; }
  done <<<"$_app_ids"

  # 6b-ledger) commit packaged installs that met the commit condition:
  # install.sh succeeded AND smoke.sh ran and succeeded (F6 guarantees the
  # script exists, so "or absent" is gone from the condition). Committed
  # BEFORE the any-smoke-failed die below, so app B's clean install is
  # recorded even when app A's smoke fails — the failed app stays an intent
  # the next run repairs.
  _commit_fail=0
  for app in $_installed_pkgs; do
    case " $_smoke_failed " in *" $app "*) continue ;; esac
    printf '%s' "$AIRLOCK_PKG_INFO" | "$ROOT/bin/airlock-ledger" commit "$app" --active-ports "$_active_ports" \
      || { log "installed-state ledger commit failed for '$app' (intent kept; the next run repairs it)"; _commit_fail=1; }
  done
  [ "$smoke_fail" = 0 ] || die "one or more app smokes failed"
  [ "$_commit_fail" = 0 ] || die "one or more ledger commits failed (see above)"
fi
# Last, so the run still reinstalls, renders, smokes and commits everything it
# could before it reports the packages it could not take down.
if [ -n "$_deactivate_failed" ]; then
  die "reconcile could not deactivate:$_deactivate_failed — every other app was reinstalled; re-run after fixing the deactivator(s) named above"
fi

# 6b) the layer in front of the loopback smokes: is the serve mapping assembled, is TLS
# terminating, is something alive behind it. Skips itself, loudly, under a dry run.
serve_rc=0; airlock_serve_check || serve_rc=$?
# 2 = the check could not run and said why. Not a pass, and not a reason to abort a
# finished install — the closing lines below already refuse to claim what was not
# established.
[ "$serve_rc" != 1 ] || die "the apps are up but the tailscale serve frontend is not — fix that before handing this box over"

# Trust-on-first-use records are the final write of a successful real run.
# Validation, install, smoke, ledger, and the runnable serve check have all
# crossed their fatal edges above. A dry run never writes machine trust state.
if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  if [ "${#_airlock_lifecycle_args[@]}" -eq 1 ]; then
    airlock_config lock-finalize "$_breakglass_receipt" || exit 2
  else
    airlock_config lock-finalize || exit 2
  fi
fi

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
