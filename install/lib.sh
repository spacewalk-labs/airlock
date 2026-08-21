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

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
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

# airlock_pkg_dir <app> — canonical package dir for a [packages.*] app, or
# nothing for a built-in. Callers set AIRLOCK_PKG_INFO once (the output of
# `airlock_config package-info`) so N apps cost one config run, not N.
airlock_pkg_dir() {
  local app="${1:?airlock_pkg_dir: app required}"
  [ -n "${AIRLOCK_PKG_INFO:-}" ] || return 0
  printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c '
import json, sys
d = (json.load(sys.stdin).get("packages") or {}).get(sys.argv[1])
if d:
    print(d["dir"])
' "$app"
}

# airlock_render_serve_https <app> — the platform's rendering of a packaged
# app's `[serve.https]` manifest surface (docs/design/app-package-contract.md
# D2 "Amended in child 4"; child-4 P2b STEP 0 infra). Reads AIRLOCK_PKG_INFO's
# serve_mappings (mode == "https" entries only) for <app> and runs the exact
# command devterm/code-server/orca/paseo used to call directly, inline, from
# their own install.sh — byte-identical, per install/test-serve-https-parity.sh:
#
#   sudo tailscale serve --bg --https=<listen> http://127.0.0.1:<target>
#
# Callers set AIRLOCK_PKG_INFO once (same convention as airlock_pkg_dir), and
# get airlock_run's dry-run gate for free (this is the same helper every real
# mutation in this file already goes through). A no-op for a built-in or a
# package with no https-mode serve mapping.
airlock_render_serve_https() {
  local app="${1:?airlock_render_serve_https: app required}"
  [ -n "${AIRLOCK_PKG_INFO:-}" ] || return 0
  local listen target
  while IFS=$'\t' read -r listen target; do
    [ -n "$listen" ] || continue
    airlock_run sudo tailscale serve --bg --https="$listen" "http://127.0.0.1:${target}"
  done < <(printf '%s' "$AIRLOCK_PKG_INFO" | python3 -c '
import json, sys
d = (json.load(sys.stdin).get("packages") or {}).get(sys.argv[1])
if d:
    for _key, m in sorted(d.get("serve_mappings", {}).items()):
        if m.get("mode") == "https":
            print(str(m["listen"]) + "\t" + str(m["target"]))
' "$app")
}

# airlock_panel_url — base URL of devterm's account panel for the return widget, or
# empty when devterm is not enabled. The widget is injected into tools that run on their
# own ports (orca, paseo); it can only offer the "subscription accounts" entry if there
# is a devterm to open, and only devterm knows the accounts. Empty => the widget keeps
# its plain behaviour (a tap returns to the hub) instead of showing a dead menu entry.
airlock_panel_url() {
  local port fqdn
  airlock_config apps | grep -qx devterm || return 0
  port="$(airlock_config get apps.devterm.https_port 2>/dev/null)" || return 0
  [ -n "$port" ] || return 0
  # The orchestrator measures the FQDN once and exports it (an operator override is what
  # lets CI render offline); only fall back to measuring if we were run standalone.
  fqdn="${AIRLOCK_TS_FQDN:-}"
  [ -n "$fqdn" ] || fqdn="$(ts_fqdn)" || return 0
  [ -n "$fqdn" ] || return 0
  printf 'https://%s:%s/' "$fqdn" "$port"
}

# ts_fqdn — this box's tailnet FQDN (no trailing dot), measured live.
ts_fqdn() {
  require_cmd tailscale python3
  tailscale status --json 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' \
    || die "could not determine tailnet FQDN (is tailscale up?)"
}

# ts_require_tailscale — fail-closed precondition checked before install.
# Airlock v1's trust model relies on `tailscale serve` as the sole, identity-
# injecting ingress (serve strips client-supplied identity headers and injects
# authenticated ones). The app installers CONFIGURE serve; this only requires that
# Tailscale is up and authenticated so serve can be that ingress. See SECURITY.md.
ts_require_tailscale() {
  require_cmd tailscale python3
  local state
  state="$(tailscale status --json 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true)"
  if [ "$state" != "Running" ]; then
    die "Tailscale is not up/authenticated (BackendState='${state:-unknown}'). Airlock \
v1 requires Tailscale as the ingress — run 'tailscale up' first. Running behind another \
proxy that forwards client identity headers is insecure-by-default. See SECURITY.md."
  fi
}

# ts_require_https — fail-closed precondition: the tailnet must issue TLS certs.
# Airlock serves content over https ONLY (the plaintext ports just 301). Without
# "HTTPS Certificates" enabled tailnet-wide, `tailscale serve --https` accepts the
# config but every handshake fails, so the box would come up unreachable. Catch it
# here with an actionable message instead of after the install.
ts_require_https() {
  require_cmd tailscale python3
  local domains
  domains="$(tailscale status --json 2>/dev/null \
    | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("CertDomains") or []))' 2>/dev/null || true)"
  # Distinguish "asked and got no cert domains" from "could not ask". Reporting a
  # transient LocalAPI hiccup as "HTTPS is disabled" would send the operator to the
  # admin console to fix something that is not broken.
  if [ -z "$domains" ]; then
    die "could not read the Tailscale status to confirm https is available \
('tailscale status --json' returned nothing usable). Is tailscaled running? Re-run \
once it is up."
  fi
  if [ "$domains" = 0 ]; then
    die "this tailnet does not issue TLS certificates, so https ingress cannot work. \
Enable it once at https://login.tailscale.com/admin/dns (HTTPS Certificates), then re-run. \
Airlock deliberately has no plaintext fallback — the identity header that every gate \
trusts must not cross the network in the clear. See SECURITY.md."
  fi
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
    log "serve check skipped: curl is not installed, so the entrance cannot be fetched here."
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

# ts_stale_plaintext_ports <wanted_ports> — plaintext serve mappings to retire.
# Prints the tailnet ports that are (a) currently served over plain http, and
# (b) a port Airlock knows as one of its own plaintext ports, but (c) not in the
# wanted list. `tailscale serve --bg` persists forever, so without this an app
# removed from airlock.toml — or a changed port — leaves a plaintext listener
# proxying its old target for good. Deliberately conservative: a port Airlock does
# not recognise is left alone, because the operator may have added it by hand.
ts_stale_plaintext_ports() {
  local wanted="${1:-}" known status
  known="$(airlock_config plaintext-known)" || return $?
  status="$(tailscale serve status --json 2>/dev/null)" || return 0
  [ -n "$status" ] || return 0
  printf '%s' "$status" | python3 -c '
import json, sys
wanted = set(sys.argv[1].split())
known  = set(sys.argv[2].split())
try:
    tcp = (json.load(sys.stdin).get("TCP") or {})
except Exception:
    sys.exit(0)                      # unreadable status: retire nothing
for port, spec in tcp.items():
    if (spec or {}).get("HTTPS"):    # TLS listener: not our concern here
        continue
    if port in known and port not in wanted:
        print(port)
' "$wanted" "$known"
}

# ts_absent_plaintext_retirement_ports <wanted_ports> — cleanup records whose
# mapping is already absent. A failed/unreadable Tailscale status proves nothing,
# so it preserves every record. Live stale mappings are handled by the function
# above and are dropped only after `tailscale serve ... off` succeeds.
ts_absent_plaintext_retirement_ports() {
  local wanted="${1:-}" recorded status
  recorded="$(airlock_config plaintext-retirement-known)" || return $?
  [ -n "$recorded" ] || return 0
  status="$(tailscale serve status --json 2>/dev/null)" || return 0
  [ -n "$status" ] || return 0
  printf '%s' "$status" | python3 -c '
import json, sys
wanted = set(sys.argv[1].split())
recorded = set(sys.argv[2].split())
try:
    tcp = (json.load(sys.stdin).get("TCP") or {})
except Exception:
    sys.exit(0)
live_plain = {port for port, spec in tcp.items() if not (spec or {}).get("HTTPS")}
for port in sorted(recorded - wanted - live_plain, key=int):
    print(port)
' "$wanted" "$recorded"
}

# ts_apply_plaintext_mapping <app> <listen> <redirect> — cross the ownership
# commit point for one desired mapping. The caller records all package intents
# first; this helper promotes only after the persistent mutation succeeds.
ts_apply_plaintext_mapping() {
  local app="${1:?app required}" listen="${2:?listen required}" redirect="${3:?redirect required}"
  airlock_run sudo tailscale serve --bg --http="$listen" "http://127.0.0.1:${redirect}" \
    || return $?
  if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] && [ "$app" != hub ]; then
    airlock_config plaintext-retirement-commit "$app" "$listen" "$redirect" \
      || return $?
  fi
}

# ts_reconcile_plaintext_ports <wanted_ports> — retire committed ownership only.
# `airlock_run` returning nonzero stops before the drop, so a failed off retains
# the record and the next run retries. Intent rows never enter either helper.
ts_reconcile_plaintext_ports() {
  local wanted="${1:-}" stale stale_ports absent_ports
  stale_ports="$(ts_stale_plaintext_ports "$wanted")" || return $?
  for stale in $stale_ports; do
    log "retiring stale plaintext ingress: :$stale (no longer in airlock.toml)"
    airlock_run sudo tailscale serve --http="$stale" off || return $?
    if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
      airlock_config plaintext-retirement-drop "$stale" || return $?
    fi
  done
  if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
    absent_ports="$(ts_absent_plaintext_retirement_ports "$wanted")" || return $?
    for stale in $absent_ports; do
      log "clearing plaintext retirement record: :$stale is already absent"
      airlock_config plaintext-retirement-drop "$stale" || return $?
    done
  fi
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
