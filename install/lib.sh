# shellcheck shell=bash
# Airlock installer helpers. Source this from install scripts:
#   . "$(dirname "$0")/../install/lib.sh"
# Site facts come ONLY from airlock-config (which reads airlock.toml).

# No `set` here, deliberately. A sourced library runs in the CALLER's shell, so a
# `set -euo pipefail` on this line is not this file's discipline — it is an edit to
# whoever sourced it, applied after they already chose.
#
# Measured on a live box, 2026-08-07: every apps/*/smoke.sh opens with
# `set -uo pipefail` — errexit off on purpose, because a smoke's job is to collect
# every status code and print one summary line, including the failing ones. Then it
# sources this file, errexit comes back on, and the first probe that cannot connect
# kills the script before it prints anything. Three apps failed their smoke that way
# and the entire diagnostic was the orchestrator's own "smoke FAILED: <app>".
#
# Every consumer already sets its own options (installers `-euo pipefail`, smokes and
# suites `-uo pipefail`), which install/test-shell-options.sh asserts — so removing
# this line takes nothing away from anyone and gives the smokes back the behaviour
# they asked for.

_lib_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRLOCK_ROOT="$(cd "$_lib_here/.." && pwd)"
# The orchestrator may give a lifecycle child a private, per-process config
# wrapper. It is not an admission switch: only the exact installer argv can
# create it, and it disappears with that run.
AIRLOCK_CONFIG_BIN="${AIRLOCK_CONFIG_BIN:-$AIRLOCK_ROOT/bin/airlock-config}"
# The sbin directories, whatever the caller's shell put in PATH. The
# install reaches for nft, useradd, sshd and friends, which live in sbin; a
# hosted session (an agent harness, a login shell with a user-only PATH) can
# lack /usr/sbin and the run dies half way with "required command not
# found: nft" -- measured 2026-09-10, after seven apps had already been
# reinstalled and before the rest were. The selfkill escape forwards the
# caller's PATH by design (the escaped run must resolve the same binaries),
# so the fix belongs here, where every installer starts, not in the escape.
# Appended, never prepended: the caller's own ordering keeps precedence.
for _d in /usr/local/sbin /usr/sbin /sbin; do
  case ":${PATH:-}:" in *":${_d}:"*) ;; *) PATH="${PATH:+$PATH:}${_d}" ;; esac
done
export PATH
unset _d
# The account tools stay two binaries rather than one with a `status` subcommand,
# because devterm reaches them through two separate unit variables today and the
# whole point of the re-homing is that its call sites do not change.
AIRLOCK_ACCOUNTS_BIN="${AIRLOCK_ACCOUNTS_BIN:-$AIRLOCK_ROOT/bin/airlock-accounts}"
AIRLOCK_ACCOUNTS_STATUS_BIN="${AIRLOCK_ACCOUNTS_STATUS_BIN:-$AIRLOCK_ROOT/bin/airlock-accounts-status}"
AIRLOCK_SECRET_BIN="${AIRLOCK_SECRET_BIN:-$AIRLOCK_ROOT/bin/airlock-secret}"
# Answers "which agent CLI does this box run" for a tool that cannot import the
# platform's Python — it resolves [agent].provider, including what `auto` means.
AIRLOCK_AGENT_BIN="${AIRLOCK_AGENT_BIN:-$AIRLOCK_ROOT/bin/airlock-agent}"
# shellcheck source=/dev/null
. "$AIRLOCK_ROOT/install/preflight.sh"

log()  { printf '[airlock] %s\n' "$*" >&2; }
die()  { printf '[airlock] FATAL: %s\n' "$*" >&2; exit 1; }

# AIRLOCK_RENDER_DIR is a test-harness-only destination-root override (child
# 4 P1b, apps/<id>/install.sh): when set, an app's render output is written
# under it instead of the real UNIT_DIR/CONFD/etc. That guarantee is
# meaningless if the rest of the run still does real work — every installer
# still reaches `airlock_run systemctl --user ...` / `sudo tailscale serve`
# for its ACTUAL system mutations (those are gated on AIRLOCK_DRY_RUN alone,
# never on AIRLOCK_RENDER_DIR), and orca additionally reaches `sudo install`/
# `sudo tee`/`sudo systemctl enable --now` for its nft firewall unit outside
# any render-dir redirect at all. An operator who exports AIRLOCK_RENDER_DIR
# for a real (non-dry) install would get artifacts silently written to a
# scratch tree while services actually (re)start against whatever was there
# before — a quietly broken box. Fail closed instead: this variable may only
# be set alongside AIRLOCK_DRY_RUN=1, checked once here (every installer
# sources this file before doing anything else).
if [ -n "${AIRLOCK_RENDER_DIR:-}" ] && [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
  die "AIRLOCK_RENDER_DIR is a test-harness hook; requires AIRLOCK_DRY_RUN=1"
fi

# Fresh callers apply only operator-selected apps. Existing rows keep their source;
# explicit directories belong only to apps that have not been installed yet.
airlock_install_selected() {
  local install_rc=0
  bash "$AIRLOCK_ROOT/install/airlock-install.sh" </dev/null || install_rc=$?
  python3 -B - "$AIRLOCK_ROOT" "$install_rc" "$@" <<'PY_SELECTED_APPS'
from importlib.machinery import SourceFileLoader
from pathlib import Path
import os, subprocess, sys

root = Path(sys.argv[1])
rc = int(sys.argv[2])
config = SourceFileLoader("fresh_config", str(root / "bin/airlock-config")).load_module()
ledger = SourceFileLoader("fresh_ledger", str(root / "bin/airlock-ledger")).load_module()
# load() is operator input; resolved JSON adds installed apps outside the selection.
os.environ.pop("AIRLOCK_CONFIG_SNAPSHOT", None)
os.environ["AIRLOCK_CONFIG_BIN"] = str(root / "bin/airlock-config")
cfg = config.load()
selected = [app for app in cfg.get("apps", {}) if app != "hub"]
installed = ledger.load_installed()
overrides = dict(zip(sys.argv[3::2], sys.argv[4::2]))
sources = {app: overrides.get(app, str(root / "apps" / app))
           for app in selected if app not in installed}
deps = {}
for app in selected:
    try:
        directory = (ledger._source_from_row(app, installed[app])["dir"]
                     if app in installed else sources[app])
        deps[app] = ledger.read_dir_package(app, directory).get("deps", [])
    except (ledger.LedgerError, KeyError, TypeError, ValueError):
        # apply reports this app's bad source/manifest; the other apps still run.
        deps[app] = []
for app in config.dependency_order(selected, deps):
    argv = [sys.executable, "-B", str(root / "bin/airlock-ledger"), "apply"]
    if app not in installed:
        argv.extend(["--source", sources[app]])
    argv.extend(["--", app])
    if subprocess.run(argv).returncode:
        rc = 1
raise SystemExit(rc)
PY_SELECTED_APPS
}

require_cmd() {
  local c
  for c in "$@"; do
    airlock_find_cmd "$c" >/dev/null || die "required command not found: $c"
  done
}

# airlock_cmd_dirs <command> — every directory a unit's PATH needs to find it.
#
# `dirname "$(readlink -f "$(command -v node)")"` looks careful and is wrong for a
# snap: /snap/bin/node is a symlink to /usr/bin/snap, so it resolves to /usr/bin and
# the directory that actually holds `node` never reaches the unit. Measured on a
# fresh box, 2026-08-07 — this repo's own preflight prints `snap install node` as the
# fix, the install then reports success, and airlock-paseo and airlock-markserv
# crash-loop on `/usr/bin/env: 'node': No such file or directory`, 43 and 85 restarts
# in. Nothing caught it because the installer's own shell had /snap/bin on PATH.
#
# The FOUND directory is the one a `#!/usr/bin/env node` shebang resolves through, so
# it is the one that must be there. The resolved directory is added after it for the
# version-farm layouts (nvm, asdf) where the wrapper and the real binary live apart.
airlock_cmd_dirs() {
  local _p _real _d _rd
  _p="$(command -v "$1" 2>/dev/null || true)"
  [ -n "$_p" ] || return 0
  _d="$(dirname "$_p")"
  printf '%s\n' "$_d"
  _real="$(readlink -f "$_p" 2>/dev/null || true)"
  [ -n "$_real" ] || return 0
  _rd="$(dirname "$_real")"
  [ "$_rd" = "$_d" ] || printf '%s\n' "$_rd"
  return 0
}

# airlock_snap_probe FOUND REAL RUNTIME — is this interpreter behind a snap wrapper?
#
# Prints the names of the probes that fired, space-separated; empty output and rc 1
# mean "not a snap". Three inputs, three strings, no I/O: the caller does the
# measuring, so this is testable on a truth table on a runner with no snapd at all —
# which matters, because the failure it exists to prevent cannot be reproduced in CI.
#
# Why it takes three readings and not one. `/snap/bin/node` is a symlink to
# `/usr/bin/snap`, which re-executes the real interpreter through the setuid-root
# `snap-confine`. `NoNewPrivileges=yes` neuters setuid, snap swallows the failure,
# and the unit dies with status=1 and zero bytes of output — measured on 2026-08-07,
# 4,242 restarts of airlock-paseo with nothing in the journal but the restart lines.
# Isolated with `systemd-run`: same env, same MemoryMax/TasksMax, same port, active
# without the directive and failed with it.
#
#   path      the command as found on PATH sits under /snap/bin/
#   resolved  `readlink -f` lands on the snap launcher (basename `snap`, or under
#             /snap/) — this is the probe airlock_cmd_dirs above already describes,
#             and it sees the wrapper rather than the interpreter
#   runtime   the interpreter's own idea of where it lives (`process.execPath`) is
#             under /snap/ — the only probe that survives a wrapper installed
#             somewhere other than /snap/bin
#
# Any one of them is enough. Each alone has a blind spot, and the diagnostic prints
# all three, because an operator who cannot see which probe fired is being asked to
# trust a verdict rather than check it.
airlock_snap_probe() {
  local found="$1" real="$2" runtime="$3" fired=""
  case "$found" in /snap/bin/*) fired="$fired path" ;; esac
  case "$real" in
    /snap/*)          fired="$fired resolved" ;;
    */snap)           fired="$fired resolved" ;;
  esac
  case "$runtime" in /snap/*) fired="$fired runtime" ;; esac
  fired="${fired# }"
  printf '%s\n' "$fired"
  [ -n "$fired" ]
}

# airlock_run <cmd...> — run, or just print when AIRLOCK_DRY_RUN=1 (for testing
# the install flow without mutating the system). Used by the orchestrator and
# every app installer.
airlock_run() {
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
    printf '[dry] %s\n' "$*" >&2
  else
    "$@"
  fi
}

# airlock_resource_holder_pids <probe-args...> — the read-only holder probe as
# part of the app ABI.
#
# The probe is a platform-internal script (install/resource-holder-pids.py) and
# its path is NOT part of the D5 ABI, which names install/lib.sh and gate/ and
# nothing else. An app that wants to re-measure a singleton after a handover —
# apps/paseo does, to decide whether a released pidfile may be cleared — must
# come through this function, because after the apps/ cutover a package cannot
# reach into the platform tree by path at all.
#
# Prints one holder PID per line (possibly none) and returns non-zero when the
# probe itself could not run; the caller owns the policy decision, exactly as it
# does for the two internal call sites below.
airlock_resource_holder_pids() {
  [ "$#" -gt 0 ] || die "airlock_resource_holder_pids requires probe arguments"
  require_cmd python3
  python3 "$AIRLOCK_ROOT/install/resource-holder-pids.py" "$@"
}

# airlock_handover_user_resource KIND RESOURCE LABEL [OPTIONS] [OWN_UNIT ...]
#
# Find the actual same-user process that owns an exclusive resource, ask the
# user manager which unit contains that PID, prove that it is the service's
# MainPID, and stop only that measured unit.  --required-by also stops services
# that systemd reports as directly requiring the measured provider (used when
# handing over an X server and its declared consumer). --service-environment
# ENV=VALUE permits a child PID only when both the process probe and its user
# service declare that exact singleton environment (used for pidfile daemons).
# --service-exec-prefix adds an application-declared exact argv-prefix proof;
# pidfile children are also required to descend from that service's MainPID.
# Legacy unit names are intentionally absent: old stacks used unrelated naming
# schemes, so a guessed list is both incomplete and an authority escalation.
# The optional OWN_UNIT names are the
# candidate artifacts this installer itself owns; an already-running candidate
# may keep its resource until the caller's ordinary restart transaction.

airlock_handover_user_resource() {
  local kind="${1:?resource kind required}" resource="${2:?resource required}" \
        label="${3:?resource label required}"
  shift 3
  local include_required_by=0 expected_service_environment="" expected_service_exec_prefix=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --required-by) include_required_by=1; shift ;;
      --service-environment)
        [ "$#" -ge 2 ] || die "--service-environment requires ENV=VALUE"
        expected_service_environment="$2"; shift 2
        ;;
      --service-exec-prefix)
        [ "$#" -ge 2 ] || die "--service-exec-prefix requires a value"
        expected_service_exec_prefix="$2"; shift 2
        ;;
      *) break ;;
    esac
  done
  local -a own_units=("$@") stop_units=()
  local -a probe_args=("$kind" "$resource")
  local pids pid unit main_pid own seen required required_unit unit_environment unit_exec

  [ -z "$expected_service_environment" ] || probe_args+=("$expected_service_environment")

  require_cmd python3 systemctl
  pids="$(python3 "$AIRLOCK_ROOT/install/resource-holder-pids.py" "${probe_args[@]}")" \
    || die "cannot inspect holders of $label — no service was stopped"

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if ! unit="$(systemctl --user whoami "$pid" 2>/dev/null)"; then
      [ -e "/proc/$pid" ] || continue  # holder exited between the two measurements
      die "$label is held by PID $pid outside a loaded user unit — no service was stopped"
    fi
    # A resource this mechanism cannot safely release: killing a whole scope or a
    # unit type other than a plain service on the strength of one member PID is
    # not a narrower version of stopping the measured holder, it is a different,
    # broader operation this call never asked for.
    case "$unit" in
      *.service) ;;
      *) die "$label is held by PID $pid in non-stoppable user unit '$unit' — no service was stopped" ;;
    esac

    own=0
    for seen in "${own_units[@]}"; do
      [ "$unit" = "$seen" ] && own=1
    done
    [ "$own" = 0 ] || continue

    # A child PID inside a broader service authorizes stopping the whole unit
    # only when the caller's declared environment and exec-prefix both match
    # the unit that PID actually belongs to (pidfile daemons) — matching
    # environment alone would let an unrelated process holding the same env
    # var impersonate the declared app (install/test-legacy-singleton-handover.sh
    # exercises exactly that).
    if [ -n "$expected_service_environment" ]; then
      if ! unit_environment="$(systemctl --user show "$unit" --property=Environment --value 2>/dev/null)" \
         || ! python3 -c 'import shlex,sys; raise SystemExit(0 if sys.argv[1] in shlex.split(sys.argv[2]) else 1)' \
              "$expected_service_environment" "$unit_environment"; then
        die "$label PID $pid belongs to '$unit', but that service does not declare $expected_service_environment — refusing to stop it"
      fi
      if [ -n "$expected_service_exec_prefix" ]; then
        if ! unit_exec="$(systemctl --user show "$unit" --property=ExecStart --value 2>/dev/null)" \
           || ! python3 -c 'import re,shlex,sys; m=re.search(r"(?:^|; )argv\[\]=(.*?)(?: ;|$)",sys.argv[2]); want=shlex.split(sys.argv[1]); got=shlex.split(m.group(1)) if m else []; raise SystemExit(0 if want and got[:len(want)]==want else 1)' \
                "$expected_service_exec_prefix" "$unit_exec"; then
          die "$label PID $pid belongs to '$unit', but that service ExecStart does not match the declared application signature — refusing to stop it"
        fi
      fi
    fi

    if ! main_pid="$(systemctl --user show "$unit" --property=MainPID --value 2>/dev/null)" \
       || [ "$main_pid" != "$pid" ]; then
      [ -n "$expected_service_environment" ] \
        || die "$label is held by child PID $pid in broad service '$unit' (MainPID ${main_pid:-unknown}) — refusing to stop the whole service"
      python3 "$AIRLOCK_ROOT/install/resource-holder-pids.py" process-descendant "$pid" "$main_pid" \
        || die "$label PID $pid is not a descendant of '$unit' MainPID ${main_pid:-unknown} — refusing to stop the whole service"
    fi

    seen=0
    for own in "${stop_units[@]}"; do
      [ "$unit" = "$own" ] && seen=1
    done
    [ "$seen" = 1 ] || stop_units+=("$unit")

    if [ "$include_required_by" = 1 ]; then
      required="$(systemctl --user show "$unit" --property=RequiredBy --value 2>/dev/null)" \
        || die "cannot inspect services requiring measured holder unit '$unit' for $label"
      for required_unit in $required; do
        case "$required_unit" in
          *.service) ;;
          *) die "$label holder '$unit' has unsupported RequiredBy unit '$required_unit' — no service was stopped" ;;
        esac
        own=0
        for seen in "${own_units[@]}"; do
          [ "$required_unit" = "$seen" ] && own=1
        done
        [ "$own" = 0 ] || continue
        seen=0
        for own in "${stop_units[@]}"; do
          [ "$required_unit" = "$own" ] && seen=1
        done
        [ "$seen" = 1 ] || stop_units+=("$required_unit")
      done
    fi
  done <<<"$pids"

  if [ "${#stop_units[@]}" -gt 0 ]; then
    log "handover $label: stopping measured holder unit(s): ${stop_units[*]}"
    systemctl --user stop "${stop_units[@]}" \
      || die "failed to stop holder unit(s) for $label: ${stop_units[*]}"
  fi
}

# airlock_quiet <cmd...> — quiet while it works, talkative when it does not.
#
# The pattern this replaces was `noisy-command >/dev/null 2>&1 || die "..."`. It reads
# like tidiness and is a trap: the only run whose output anyone wants is the one that
# failed, and that is exactly the run whose output was thrown away. Measured on a live
# box, 2026-08-07 — markserv's npm install failed twice and the fatal line said
# "(npm output above)" with nothing above it, so the cause is now unknowable; the same
# call in paseo discarded stderr too and died with just the package name.
#
# Output is buffered rather than streamed because npm prints hundreds of lines on a
# healthy install and drowning the log is how the previous author got here.
airlock_quiet() {
  local _log _rc=0
  _log="$(mktemp)"
  "$@" >"$_log" 2>&1 || _rc=$?
  if [ "$_rc" != 0 ]; then
    printf -- '--- output of: %s (exit %s, last 40 lines) ---\n' "$*" "$_rc" >&2
    tail -40 "$_log" >&2
    printf -- '--- end of output ---\n' >&2
  fi
  rm -f "$_log"
  return "$_rc"
}

# airlock_config <subcommand> [args...] — the only config entry point.
airlock_config() {
  require_cmd python3
  python3 "$AIRLOCK_CONFIG_BIN" "$@"
}

# airlock_load <app> — eval that app's KEY=VALUE env into the current shell.
# Exposes AIRLOCK_OWNER / AIRLOCK_IDENTITY_HEADER / AIRLOCK_<APP>_<KEY> / ...
airlock_load() {
  local app="$1" env
  env="$(airlock_config env "$app")" || die "config env failed for app: $app"
  eval "$env"
}

# A relative (or symlinked) AIRLOCK_STATE_DIR must mean one directory from
# every cwd — packaged scripts run from their package dir and inherit the
# value — so pin it to the kernel-resolved path once, up front. No-op when
# unset or not yet created (a built-in-only run never creates it).
airlock_pin_state_dir() {
  [ -n "${AIRLOCK_STATE_DIR:-}" ] || return 0
  if [ -d "$AIRLOCK_STATE_DIR" ]; then
    AIRLOCK_STATE_DIR="$(cd "$AIRLOCK_STATE_DIR" && pwd -P)"
  else
    # Not created yet (read-only entry points never create it): absolutize
    # lexically so a later cd in a packaged script cannot reinterpret it.
    case "$AIRLOCK_STATE_DIR" in /*) ;; *) AIRLOCK_STATE_DIR="$PWD/$AIRLOCK_STATE_DIR" ;; esac
  fi
  export AIRLOCK_STATE_DIR
}

# airlock_package_info — read the hook projection without exporting JSON bytes.
# Legacy callers may still supply AIRLOCK_PKG_INFO while they migrate.
airlock_package_info() {
  if [ -n "${AIRLOCK_PKG_INFO_FILE:-}" ]; then
    cat -- "$AIRLOCK_PKG_INFO_FILE"
  elif [ -n "${AIRLOCK_PKG_INFO:-}" ]; then
    printf '%s' "$AIRLOCK_PKG_INFO"
  else
    airlock_config package-info
  fi
}

# airlock_pkg_dir <app> — directory from config's engine-backed projection.
airlock_pkg_dir() {
  local app="${1:?airlock_pkg_dir: app required}"
  airlock_package_info | python3 -c '
import json, sys
d = (json.load(sys.stdin).get("packages") or {}).get(sys.argv[1])
if d:
    print(d["dir"])
' "$app"
}

# airlock_doc_assets_dir — platform-owned, public-neutral document assets.
# Apps receive this path through the sourced D5 ABI instead of reaching into the
# platform tree themselves; package directories may live outside AIRLOCK_ROOT.
airlock_doc_assets_dir() {
  printf '%s\n' "$AIRLOCK_ROOT/docker/student-harness/skills/share-docs/assets"
}

# Installation membership is ③, regardless of retained app input tables.
# Return a JSON array: an id may itself contain tabs, newlines or spaces.
airlock_installed_app_ids() {
  local installed
  installed="$("$AIRLOCK_ROOT/bin/airlock-ledger" list --json)" || return "$?"
  printf '%s' "$installed" | python3 -c 'import json,sys; print(json.dumps(list(json.load(sys.stdin))))'
}

# Recorded source only: absent directories must never fall back to candidates.
airlock_installed_app_dir() {
  python3 - "$AIRLOCK_ROOT/bin/airlock-ledger" "$1" "${2:-}" <<'PY_INSTALLED_DIR'
import os
import sys
from importlib.machinery import SourceFileLoader
sys.dont_write_bytecode = True
ledger = SourceFileLoader("installed_source_ledger", sys.argv[1]).load_module()
directory = ledger.app_dirs({}).get(sys.argv[2])
if not directory or not os.path.isdir(directory):
    sys.exit(2)
sys.stdout.write(directory + ("\0" if sys.argv[3] == "--null" else "\n"))
PY_INSTALLED_DIR
}

airlock_app_installed() {
  local installed
  installed="$(airlock_installed_app_ids)" || return "$?"
  printf '%s' "$installed" | python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' "$1"
}

# airlock_panel_url — base URL of devterm's account panel for the return widget, or
# empty when devterm is not installed. The widget is injected into tools that run on their
# own ports (orca, paseo); it can only offer the "subscription accounts" entry if there
# is a devterm to open, and only devterm knows the accounts. Empty => the widget keeps
# its plain behaviour (a tap returns to the hub) instead of showing a dead menu entry.
airlock_panel_url() {
  local port fqdn
  airlock_app_installed devterm || return 0
  port="$(airlock_config get apps.devterm.https_port 2>/dev/null)" || return 0
  [ -n "$port" ] || return 0
  # The orchestrator measures the FQDN once and exports it (an operator override is what
  # lets CI render offline); only fall back to measuring if we were run standalone.
  fqdn="${AIRLOCK_TS_FQDN:-}"
  [ -n "$fqdn" ] || fqdn="$(ts_fqdn)" || return 0
  [ -n "$fqdn" ] || return 0
  printf 'https://%s:%s/' "$fqdn" "$port"
}

# airlock_secret_panel_url — base URL of the PLATFORM secret drop for the return widget,
# or empty when no FQDN can be measured. Unlike airlock_panel_url this never depends on
# devterm: the drop's UI and API are the platform account surface under the hub's
# owner-gated /airlock-accounts/ prefix (bin/airlock-accounts-api), which the platform
# installs unconditionally. docs/tasks/active/platform-secret-drop.md.
airlock_secret_panel_url() {
  local fqdn
  fqdn="${AIRLOCK_TS_FQDN:-}"
  # ts_fqdn dies rather than returning empty; offline is a reduced widget, not noise.
  [ -n "$fqdn" ] || fqdn="$(ts_fqdn 2>/dev/null)" || return 0
  [ -n "$fqdn" ] || return 0
  printf 'https://%s/airlock-accounts/\n' "$fqdn"
}

# airlock_accounts_port — the platform account/secret surface's loopback port. An app
# that exposes the platform secret routes on its own origin (devterm) proxies to this.
# The orchestrator exports the value it already validated; only a standalone run reads
# the config, the same single-read rule install/airlock-accounts-api.sh follows.
airlock_accounts_port() {
  local port="${AIRLOCK_HUB_ACCOUNTS_PORT:-}"
  if [ -z "$port" ]; then
    port="$(eval "$(airlock_config env hub)" && printf '%s' "${AIRLOCK_HUB_ACCOUNTS_PORT:-}")" \
      || return 1
  fi
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$port"
}

# airlock_publish_doc_url — the link a reader can actually open, or empty.
#
# The hub path (/publish/files/) and the dedicated document port serve the SAME
# directory, but they sit behind different gates: the hub is owner+collaborators,
# the document port is every tailnet member when tailnet_view is on. So the hub
# link works for the person who published and 403s for everyone they send it to —
# and both look identical in the manager UI. Handing the UI the openable URL is
# what stops that link from being copied out of here at all.
#
# Empty when tailnet_view is off: then no link is open to others and the UI has
# nothing better to offer than the hub path it already uses.
airlock_publish_doc_url() {
  local port fqdn
  [ "$(airlock_config get apps.publish.tailnet_view 2>/dev/null)" = true ] || return 0
  port="$(airlock_config get apps.publish.https_port 2>/dev/null)" || return 0
  [ -n "$port" ] || return 0
  fqdn="${AIRLOCK_TS_FQDN:-}"
  [ -n "$fqdn" ] || fqdn="$(ts_fqdn)" || return 0
  [ -n "$fqdn" ] || return 0
  if [ "$port" = 443 ]; then printf 'https://%s' "$fqdn"; else printf 'https://%s:%s' "$fqdn" "$port"; fi
}

airlock_emit_owner_v1_map() { # <owner>
  local owner="${1:?owner-v1 map requires an owner}"
  # shellcheck disable=SC2016 # nginx runtime variables are emitted literally
  printf 'map $http_tailscale_user_login $owner_ok {\n'
  printf '    default 0;\n'
  printf '    "%s" 1;\n' "$owner"
  printf '}\n'
}

airlock_emit_owner_v1_unit() { # <owner>
  local owner="${1:?owner-v1 unit requires an owner}"
  printf '# airlock-owner-v1 owner=%s\n' "$owner"
  airlock_emit_owner_v1_map "$owner"
}

# airlock_escape_selfkill_cgroup SCRIPT [ARGS...] — survive stopping our own host.
#
# An install stops and restarts the app units it manages. When the run was started
# from INSIDE one of those units — an agent session hosted by airlock-paseo.service
# is the everyday case, but a shell opened through devterm, code-server or orca is
# the same shape — stopping that unit kills the whole cgroup, and the installer is
# in it. The run dies at the "stop" step and never reaches the "start again" step,
# so the box is left with units stopped, disabled, and unit files reclaimed. That
# happened three times on one box on 2026-09-01 (21:41, 22:01, 23:04); each time
# the journal named the caller: "Reloading requested from client PID N ('systemctl')
# (unit airlock-paseo.service)".
#
# This does NOT refuse the run. Restarting its own host is a legitimate thing for an
# agent to ask for, and refusing would block it. Instead the run is moved out of the
# doomed cgroup into its own transient scope (measured: a --user --scope started
# inside a service lands in app.slice/run-uN.scope, a sibling of that service), so
# the very same command now survives the restart it asked for and completes.
#
# Always says what it measured and what it did — the condition only reproduces
# inside such a session, so the cgroup path it read is the evidence for the next
# person. If it cannot escape, it warns and continues rather than blocking.
airlock_escape_selfkill_cgroup() {
  # A dry run stops nothing, so there is nothing to survive.
  [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && return 0
  # Re-exec exactly once. Without this a scope that still matched would loop.
  [ -n "${AIRLOCK_SELFKILL_ESCAPED:-}" ] && return 0
  # Test seam only (install/test-selfkill-escape.sh): where the cgroup is read
  # from. Production never sets it, so the guard always measures this process.
  local cgroup_file="${AIRLOCK_SELFKILL_CGROUP_FILE:-/proc/self/cgroup}"
  [ -r "$cgroup_file" ] || return 0

  local cgroup path unit
  cgroup="$(cat "$cgroup_file" 2>/dev/null || true)"
  # cgroup v2 writes one "0::<path>" line; take that and read the LEAF, which is
  # the unit actually containing this process.
  path="$(printf '%s\n' "$cgroup" | sed -n 's|^0::||p' | head -n1)"
  [ -n "$path" ] || return 0
  unit="${path##*/}"

  # Two conditions, both required, and both learned the hard way:
  #
  #  - a --user unit. This installer stops `systemctl --user` units, so a system
  #    unit is not the unit it is about to stop.
  #  - the LEAF is exactly an airlock-*.service, not merely a path containing that
  #    text. A substring match reported a CI runner's own system unit,
  #    actions.runner.<org>-<repo>.<runner>.service, as the host unit and
  #    moved every install in CI into a scope it could not create.
  case "$path" in */user@*.service/*) ;; *) return 0 ;; esac
  case "$unit" in airlock-*.service) ;; *) return 0 ;; esac

  log "this run is inside ${unit} — the same unit the install stops and restarts"
  log "  measured cgroup: ${cgroup}"
  log "  stopping ${unit} from in here would kill this run mid-install (units left"
  log "  stopped and reclaimed, never restarted), so moving out to its own scope"

  # Test seam only: which binary performs the move. Production leaves it unset.
  local runner="${AIRLOCK_SELFKILL_SYSTEMD_RUN:-systemd-run}"
  if ! command -v "$runner" >/dev/null 2>&1; then
    log "WARNING: ${runner} not found — continuing INSIDE ${unit}. If the install"
    log "  stops that unit this run dies mid-way. Re-run detached instead:"
    log "    systemd-run --user --scope --collect bash $*"
    return 0
  fi
  # Ask the user manager BEFORE trying to move. Without this, a box with no user
  # bus (a CI container is the everyday case) gets "Failed to connect to bus" from
  # the move, and the run cannot tell "the escaped install ran and failed" from
  # "nothing was ever launched" — it aborted a healthy install on the second.
  # No manager also means no unit here can be stopped the way this guard fears.
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    log "  no systemd --user manager reachable — nothing here stops that unit,"
    log "  so continuing in place"
    return 0
  fi

  # A transient SERVICE, not a --scope. The first version of this guard used a scope
  # and was not enough: a scope leaves the run in the caller's process group and on
  # the caller's stdout pipe, and the session being torn down takes both with it.
  # Measured on one box, killing each coupling in turn:
  #
  #                                  --scope     --unit=
  #   cgroup torn down (the stop)    survives    survives
  #   process group killed           DIES        survives
  #   stdout pipe closed (SIGPIPE)   DIES        survives
  #
  # Both extra deaths were real: an update escaped into a scope, the session that
  # launched it went away with the daemon, and the install died at rc=141 (SIGPIPE)
  # having reclaimed the units and not yet reinstalled them — the exact damage this
  # guard exists to prevent, through a door it had left open.
  #
  # A --unit= service is parented by the user manager (own process group) and writes
  # to the journal (no pipe), so all three couplings are cut at once.
  local esc_unit
  esc_unit="airlock-install-$$-$(date +%s)"
  log "  moving to: ${runner} --user --unit=${esc_unit} -- bash $*"
  log "  live output: journalctl --user -u ${esc_unit} -f"

  # --wait blocks here for the exit status, so an operator watching a terminal still
  # gets one. It is only this waiter that is fragile: if the caller dies, the service
  # keeps running and finishes the install, which is the whole point.
  # The transient unit inherits the user manager's environment. Forward the
  # caller's AIRLOCK_* inputs and PATH so it uses the same config and paths.
  # Shadow manager-only AIRLOCK_* names with empty values to avoid stale inputs.
  #
  # NAME-ONLY --setenv, never NAME=VALUE. systemd-run reads the value out of
  # its own environment for the bare form, so the value never enters argv.
  # With NAME=VALUE it does, and /proc/<pid>/cmdline is world-readable unless
  # the box mounts /proc with hidepid -- measured here: no hidepid, and a
  # secret passed as NAME=VALUE was readable from another account's view for
  # the whole install (--wait keeps systemd-run alive the entire time). The
  # values still reach `systemctl show` for this same UID while the unit
  # lives, and --collect drops the unit at exit.
  #
  # AIRLOCK_SELFKILL_ESCAPED is excluded from EVERY loop below, not just the
  # shadowing one. It is passed explicitly as =1 before these arguments, and
  # systemd resolves duplicate --setenv by LAST ONE WINS (measured). A caller
  # that exported it EMPTY passes the guard at the top of this function (-n on
  # an empty string is false), so without the exclusion its empty value would
  # be forwarded after the =1 and blank the guard -- and the escaped run would
  # escape again, forever.
  local -a esc_env=()
  local _n
  for _n in $(compgen -e 2>/dev/null | grep '^AIRLOCK_' || true); do
    [ "$_n" = AIRLOCK_SELFKILL_ESCAPED ] && continue
    esc_env+=("--setenv=${_n}")
  done
  esc_env+=("--setenv=PATH")

  # Read the manager's list -- there is no other way to
  # learn which AIRLOCK_* it holds. A failed query is reported rather than read
  # as "the manager holds nothing", which would silently skip the shadowing.
  local _manager_env _manager_rc=0
  _manager_env="$(systemctl --user show-environment 2>/dev/null)" || _manager_rc=$?
  if [ "$_manager_rc" -ne 0 ]; then
    log "  WARNING: could not read the user manager's environment (rc=${_manager_rc});"
    log "    a stale AIRLOCK_* it holds could reach the escaped run"
    _manager_env=""
  else
    _manager_env="$(printf '%s\n' "$_manager_env" \
      | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p')"
  fi
  # Same shadowing rule for the platform inputs.
  for _n in $(printf '%s\n' "$_manager_env" | grep '^AIRLOCK_' || true); do
    [ "$_n" = AIRLOCK_SELFKILL_ESCAPED ] && continue
    [ -n "${!_n+x}" ] || esc_env+=("--setenv=${_n}=")
  done

  local rc=0
  "$runner" --user --unit="$esc_unit" --service-type=exec --collect --quiet --wait \
    --same-dir \
    --setenv=AIRLOCK_SELFKILL_ESCAPED=1 \
    "${esc_env[@]}" \
    -- bash "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then
    log "  escaped run finished (unit ${esc_unit})"
    exit 0
  fi
  # Past the manager probe above, a failure here is the escaped install's own exit
  # status, so it is reported as the run's result. 126/127 stay carved out: those
  # mean the command never started, which is this guard's problem, not the install's.
  if [ "$rc" -eq 127 ] || [ "$rc" -eq 126 ]; then
    log "WARNING: could not move out of ${unit} (${runner} rc=${rc}) — continuing in"
    log "  place. If this run dies at a 'Stopping ${unit}' line, that is why."
    return 0
  fi
  log "  escaped run failed (unit ${esc_unit}, rc=${rc}) — its log:"
  log "    journalctl --user -u ${esc_unit}"
  exit "$rc"
}

# ts_fqdn — this box's tailnet FQDN (no trailing dot), measured live.
ts_fqdn() {
  require_cmd tailscale python3
  tailscale status --json 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' \
    || die "could not determine tailnet FQDN (is tailscale up?)"
}

# airlock_enable_linger <user> — arm --user units to survive a reboot, idempotently.
#
# Why not `loginctl enable-linger || log WARN`: the exit code is the wrong oracle.
# The operation is a no-op once lingering holds, and in a container it can fail
# while Linger=yes is already true — so that form warned "apps may NOT auto-start"
# on a perfectly healthy box. docker/orbstack-machine-setup.sh enables lingering on
# that path, which means the same repo armed the state and then warned the state
# might be missing. Everyone installing that way saw it. A warning that is
# routinely wrong on a healthy install is worse than no warning: it teaches people
# to skip the ones that are real.
#
# So read the state, act only if it is not already satisfied, and re-read before
# saying anything is wrong.
airlock_linger_on() {
  local out
  # Not `--value`: older systemd lacks it. `-p Linger` prints "Linger=yes".
  out="$(loginctl show-user -p Linger "${1:?}" 2>/dev/null)" || return 1
  case "$out" in *yes) return 0 ;; *) return 1 ;; esac
}

airlock_enable_linger() {
  local user="${1:?airlock_enable_linger: user required}"
  if ! command -v loginctl >/dev/null 2>&1; then
    log "WARN: loginctl not found — boot persistence for --user units cannot be armed here. \
Apps may NOT auto-start after reboot."
    return 0
  fi
  if airlock_linger_on "$user"; then
    log "lingering already on for '$user' — --user units survive reboot"
    return 0
  fi
  airlock_run loginctl enable-linger "$user" || true
  [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && return 0
  if airlock_linger_on "$user"; then
    log "lingering enabled for '$user' — --user units survive reboot"
  else
    log "WARN: lingering is still off for '$user' — apps may NOT auto-start after reboot on a \
headless box. Fix: loginctl enable-linger $user"
  fi
  return 0
}

# airlock_entrance_url — the https URL this box is served at, or nothing.
#
# [apps.hub].https_port is user-settable and airlock-install.sh maps `tailscale serve` on
# exactly that port, so assuming 443 would name a port nothing was ever mapped on. Prefer
# a value the caller already loaded; else ask config. The guard is OUTSIDE the
# substitution on purpose: airlock_config die()s when python3 is missing, and an exit
# skips an inner `|| true`, which under set -e would take the caller down with it.
airlock_entrance_url() {
  local fqdn port
  fqdn="${AIRLOCK_TS_FQDN:-}"
  [ -n "$fqdn" ] || fqdn="$(ts_fqdn 2>/dev/null)" || fqdn=""
  [ -n "$fqdn" ] || return 1
  port="${AIRLOCK_HUB_HTTPS_PORT:-}"
  [ -n "$port" ] || port="$(airlock_config get apps.hub.https_port 2>/dev/null)" || port=""
  [ -n "$port" ] || port=443
  if [ "$port" = 443 ]; then printf 'https://%s/\n' "$fqdn"; else printf 'https://%s:%s/\n' "$fqdn" "$port"; fi
}

# airlock_serve_check — is the `tailscale serve` frontend assembled and answering?
#
# ⚠️ READ THE NAME. This does NOT test whether another device can reach this box, and
# nothing here may be worded as if it did. A request from here to our OWN tailnet name
# is delivered over loopback — `ip route get <own tailnet IP>` reports `local … dev lo`,
# and six HTTPS requests to our own FQDN moved the tailscale0 counters by only the
# background keepalive. So an inbound-path fault (a tailscaled that still sends but no
# longer receives, an ACL change, DERP trouble) answers this check exactly like a
# healthy box. Verifying reachability needs a probe from a second tailnet node; that is
# out of scope, and the caller ends its run with INGRESS UNVERIFIED instead of pretending
# otherwise.
#
# What it DOES test is worth testing, because every apps/<app>/smoke.sh talks to
# 127.0.0.1 and therefore says nothing about the layer in front: the `tailscale serve`
# mapping, TLS termination for the FQDN, and whether the loopback target behind the
# mapping is alive. Any of those can be gone while every unit is `active running`.
#
# Three outcomes, because two would force a lie: 0 = checked and healthy, 1 = checked and
# broken, 2 = NOT CHECKED (a precondition was missing). Callers must not fold 2 into 0 —
# an earlier revision returned 0 for both, and its summary line said "the serve frontend
# answered" after the check had skipped. That is the same false green this exists to remove.
#
# Fails ONLY on deterministic local invariants. Correlated-but-inconclusive signals are
# warnings, never failures: a check that cries wolf gets disabled, and then the original
# green-but-dead bug is back.
airlock_serve_check() {
  local code rc=0 port url
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
    log "serve check skipped: AIRLOCK_DRY_RUN=1 (nothing is serving)"
    return 2
  fi
  # NOT require_cmd: that die()s, which would abort an otherwise-successful install at
  # its last line over a check that is allowed to skip.
  if ! command -v curl >/dev/null 2>&1; then
    log "serve check skipped: curl is not installed, so the hub URL cannot be fetched here."
    return 2
  fi
  url="$(airlock_entrance_url)" || url=""
  if [ -z "$url" ]; then
    log "serve check skipped: could not measure this box's tailnet FQDN (is tailscale up?). \
Set AIRLOCK_TS_FQDN=<box>.<tailnet>.ts.net to check anyway."
    return 2
  fi
  # Only for the diagnostics below. A port appears in the URL only when it is not 443.
  case "$url" in
    https://*:*/) port="${url##*:}"; port="${port%%/*}" ;;
    *)            port=443 ;;
  esac
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null)" || rc=$?
  # curl 6 = "couldn't resolve host": with MagicDNS off this box cannot look up its own
  # name, which says nothing about serve. A skip, and no retry will change it.
  if [ "$rc" = 6 ]; then
    log "serve check skipped: this box cannot resolve its own tailnet name (MagicDNS off?)."
    return 2
  fi
  if [ "$rc" != 0 ] || [ -z "$code" ] || [ "$code" = 000 ]; then
    # One retry. A box's first-ever request issues the tailnet cert during the handshake
    # and can outrun the timeout; ts_require_https proves certs are ENABLED, not that
    # this box has one yet. Failing a good install on a slow first handshake would be
    # the false alarm this check is written to avoid.
    log "no answer on the first try (curl exit ${rc}, http '${code:-none}') — retrying once, \
because a first-ever TLS handshake issues the tailnet cert and can outrun the timeout"
    sleep 3
    rc=0
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$url" 2>/dev/null)" || rc=$?
  fi
  if [ "$rc" != 0 ] || [ -z "$code" ] || [ "$code" = 000 ]; then
    log "FAIL: ${url} does not answer on this box (curl exit ${rc}, http '${code:-none}') \
while the loopback smokes passed — the apps are up and the serve frontend is not. \
Check 'sudo tailscale serve status' (is :${port} still mapped to the hub?) and \
'systemctl status nginx'."
    return 1
  fi
  # A WHITELIST, not a blacklist. `tailscale serve` answers with its OWN status without
  # ever contacting a target: 404 when no handler is mounted at the requested path (the
  # mapping for / is gone or was re-pathed) and 500 for an unknown destination or an empty
  # handler. Those are exactly the faults this check is for, so a blacklist that knew only
  # 502 called them healthy. What a working hub answers at / is short and known: it serves
  # a static index, and its gate returns 403 to an identity it does not recognise.
  case "$code" in
    200|301|302|403) ;;
    *)
      log "FAIL: ${url} answered HTTP ${code}, which a working hub does not serve at '/'. \
Either the serve mapping no longer reaches the hub (serve answers 404 for an unmounted \
path and 500 for an unknown destination, without ever touching a backend), or what is \
behind it is down (502/503/504). Check 'sudo tailscale serve status' and \
'systemctl status nginx'."
      return 1 ;;
  esac
  log "serve frontend OK: ${url} -> HTTP ${code} (TLS terminates and the mapping reaches the hub)"
  return 0
}

# airlock_ingress_unverified — close a run by naming what was NOT established.
#
# Deliberately a separate, final line rather than a clause inside a pass message. "We did
# not check this" and "this passed" are different results, and burying the first inside
# the second is how a green run in front of a dead box happens in the first place.
airlock_ingress_unverified() {
  local url health
  # tailscaled's own view — the only inbound-adjacent signal available locally. A warning,
  # never a failure: this box's Health right now carries a benign DNS gripe.
  health="$(tailscale status --json 2>/dev/null \
    | python3 -c 'import sys,json; print("; ".join(json.load(sys.stdin).get("Health") or []))' 2>/dev/null || true)"
  [ -n "$health" ] && log "WARN: tailscaled reports degraded health — ${health}"
  url="$(airlock_entrance_url)" || url=""
  [ -n "$url" ] || url="your Airlock URL"
  log "INGRESS UNVERIFIED — nothing here proves another device can reach this box. A \
request to our own tailnet name never leaves the machine, so this run cannot tell a \
healthy box from one whose inbound path is broken. Open ${url} from your phone or \
laptop once; that is the check."
  return 0
}

# ring_icon_svg <color> <source> — print an SVG that wraps <source> in a ring.
#
# Why: someone who runs more than one Airlock cannot tell the boxes apart from the
# browser tab — devterm on box A and devterm on box B ship the same mark. Setting
# [branding] icon_ring on ONE box tints its app favicons so the tab says which box
# it is. The hub keeps the untouched brand mark.
#
# <source> is a PNG or SVG file, embedded as a data URI inside an <image> element —
# so this needs no image library and works for both formats. Browsers render SVG
# favicons (including a nested SVG payload); the ring is drawn on top of the inset
# mark, so it reads as an outline AROUND the icon.
#
# LIMITATION — the ring reaches browser tabs, not iOS home screens. The output is
# always an SVG, and iOS ignores an SVG apple-touch-icon: it takes a PNG or nothing.
# So every app's <link rel="apple-touch-icon"> (apps/*/web/apple-touch-icon.png and
# hub/assets/app-icons/*.png, both generated by bin/gen-app-icons.py) installs
# unringed, and two boxes' home-screen icons for the same app are identical. Ringing
# them means rasterising a PNG, which means an image library at install time —
# Pillow, or a headless browser — and neither is a prerequisite of this installer
# today. Anyone adding one: ring the PNG where the SVG is ringed and delete this
# paragraph. Recorded rather than left silent, because a half-covered feature that
# says nothing is indistinguishable from a broken one.
ring_icon_svg() {
  local color="${1:?ring_icon_svg: color required}" src="${2:?ring_icon_svg: source required}"
  [ -f "$src" ] || die "ring_icon_svg: no such icon: $src"
  local mime b64
  case "$src" in
    *.svg) mime="image/svg+xml" ;;
    *.png) mime="image/png" ;;
    *) die "ring_icon_svg: unsupported icon type (want .svg or .png): $src" ;;
  esac
  b64="$(base64 -w0 "$src")"
  cat <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <image href="data:${mime};base64,${b64}" x="5" y="5" width="54" height="54" preserveAspectRatio="xMidYMid meet"/>
  <rect x="3" y="3" width="58" height="58" rx="15" fill="none" stroke="${color}" stroke-width="6"/>
</svg>
SVG
}

# render_loopback_nft <table> <port> — fill the loopback-only nft template.
# Prints the rendered ruleset to stdout (install scripts write + `nft -f`).
render_loopback_nft() {
  local table="${1:?render_loopback_nft: table required}" port="${2:?port required}"
  local tpl="$AIRLOCK_ROOT/gate/loopback-only.nft.tpl"
  [ -f "$tpl" ] || die "missing template: $tpl"
  sed -e "s/@@TABLE@@/${table}/g" -e "s/@@PORT@@/${port}/g" "$tpl"
}

# write_if_changed <path> — write stdin to <path> only if the content differs.
# Returns 0 if the file was written (new/changed), 1 if it was already identical.
# Use to gate service restarts on idempotent re-runs so re-running the installer
# (e.g. after editing an unrelated app's config) does not needlessly restart a
# service and kill the owner's live session:
#   changed=0
#   if write_if_changed "$unit" <<UNIT
#   ...
#   UNIT
#   then changed=1; fi
write_if_changed() {
  local path="${1:?write_if_changed: path required}"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp"
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
  install -D -m 0644 "$tmp" "$path"
  rm -f "$tmp"
  return 0
}

# install_if_changed MODE SRC DEST — install SRC over DEST only when the bytes or the
# mode differ. An identical re-install must leave DEST untouched, mtime included: the
# ledger checkpoints artifacts with their metadata, so rewriting an unchanged file makes
# a later rollback in the same transaction judge that app "changed with no lossless
# checkpoint" and leave the whole transaction degraded (notes, 2026-09-14 and 09-15).
install_if_changed() {
  local mode="${1:?install_if_changed: mode required}"
  local src="${2:?install_if_changed: source required}"
  local dest="${3:?install_if_changed: destination required}"
  if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest" \
     && [ "$(stat -c %a "$dest")" = "$mode" ]; then
    return 0
  fi
  install -m "$mode" "$src" "$dest"
}
