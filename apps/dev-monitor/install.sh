#!/usr/bin/env bash
# dev-monitor — per-box system/service/network/storage observability, served as a
# same-origin subpath under the hub (owner + collaborators), plus an OPTIONAL
# owner-only message/action console (messages = true; default off).
#
#   browser --> hub (tailscale serve) --(identity)--> hub nginx
#     /monitor/        -> dashboard UI (static, from the hub webroot)
#     /monitor/api/    -> airlock-dev-monitor backend 127.0.0.1:BACKEND (loopback)
#
# The backend binds loopback and strips the /monitor/ prefix itself. Config from
# airlock.toml ([apps.dev-monitor]). Honors AIRLOCK_DRY_RUN=1.
set -euo pipefail

# ABI (D5): the caller sets AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID and runs
# this script with cwd = AIRLOCK_APP_DIR. AIRLOCK_ROOT is REQUIRED: the platform
# root cannot be derived from $0, because "$0/../.." is only the platform when the
# package happens to sit in the platform's own apps/ tree — the arrangement the
# apps/ cutover ends. $0-relative self-location (this file's own directory) stays
# fine and is what AIRLOCK_APP_DIR falls back to.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
HERE="${AIRLOCK_APP_DIR:-$HERE}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-dev-monitor}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
# shellcheck source=/dev/null
. "$HERE/render.sh"
# shellcheck source=/dev/null
. "$HERE/secret-check.sh"
# shellcheck source=/dev/null
. "$HERE/migration-lifecycle.sh"

require_cmd python3 systemctl journalctl realpath timeout

airlock_load dev-monitor
BACKEND_PORT="${AIRLOCK_DEV_MONITOR_BACKEND_PORT:?}"
MESSAGES="${AIRLOCK_DEV_MONITOR_MESSAGES:-false}"
SLACK_WEBHOOK_URGENT_ENV="${AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT_ENV:-}"
EXEC_CWD_ROOT="${AIRLOCK_DEV_MONITOR_EXEC_CWD_ROOT:-}"
EXEC_SESSION="${AIRLOCK_DEV_MONITOR_EXEC_SESSION:-devmon-exec}"
SPOOL_WRITER_USER="${AIRLOCK_DEV_MONITOR_SPOOL_WRITER_USER:-airlock-dev-monitor-writer}"
SPOOL_WRITER_GROUP="${AIRLOCK_DEV_MONITOR_SPOOL_WRITER_GROUP:-airlock-dev-monitor-writers}"
TOKEN_FRESHNESS="${AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS:-false}"
TOKEN_WARN_HOURS="${AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS_WARN_HOURS:-24}"
TOKEN_STALE_HOURS="${AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS_STALE_HOURS:-24}"
# D5 hands the platform capability in. Pin its resolved absolute path before a unit
# records it, matching devterm's P2a handoff: an app may validate a capability path but
# must never reconstruct $ROOT/bin/... for itself.
case "$AIRLOCK_ACCOUNTS_STATUS_BIN" in
  /*) ;;
  *) die "AIRLOCK_ACCOUNTS_STATUS_BIN must be an absolute D5 platform path" ;;
esac
[ -f "$AIRLOCK_ACCOUNTS_STATUS_BIN" ] && [ -x "$AIRLOCK_ACCOUNTS_STATUS_BIN" ] \
  || die "AIRLOCK_ACCOUNTS_STATUS_BIN does not name an executable platform file"
ACCOUNTS_STATUS_BIN="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' \
  "$AIRLOCK_ACCOUNTS_STATUS_BIN")"
# The box-wide default agent, and the second D5 capability that resolves it. Same handoff
# rule as above: this app validates the path it is given and never rebuilds $ROOT/bin/... .
#
# The value itself is NOT validated here against a list of names. airlock-config already
# refuses an unknown [agent].provider at validate time, and a second copy of the vocabulary
# in this file would go stale the day a third CLI is added — the failure would be an install
# that refuses a value the platform accepts, which reads as a broken installer.
AGENT_PROVIDER="${AIRLOCK_AGENT_PROVIDER:-}"
# Both values land on `Environment=` lines in a unit file, where a newline is a new
# directive. The orchestrator runs `airlock-config validate` first and that refuses a
# provider outside auto/claude/codex, so this is the second lock and not the first —
# but an app installer run on its own must not be able to write a unit nobody wrote.
# Same guard this file already applies to the resolved Slack and SMTP values below.
#
# Newline only, and that is the whole list on purpose. Measured on systemd 255, 2026-09-01,
# because two reviewers disagreed about the backslash and neither had run it:
#
#   Environment=A=val\        -> systemctl show -p Environment
#   Environment=B=second         Environment=A=val Environment=B=second
#
# The trailing backslash DOES join the two physical lines (systemd.syntax line continuation
# applies to unit directives, not only to EnvironmentFile), but the joined line is still one
# `Environment=` directive — so the worst it does is swallow the next assignment, which now
# surfaces as the loud half-configured case in action_runner.resolve_agent() rather than as a
# silent wrong CLI. A raw newline is different in kind, and that is the one blocked here:
#
#   Environment=A=val
#   ExecStartPre=/bin/echo INJECTED
#                             -> ExecStartPre={ path=/bin/echo ; argv[]=/bin/echo INJECTED ; … }
#
# A space or a `%` stays inside the value the same way it does for the existing
# ACCOUNTS_STATUS_BIN and cors_origins lines. Only a newline can start a new DIRECTIVE.
for _pair in "agent.provider:$AGENT_PROVIDER" "AIRLOCK_AGENT_BIN:$AIRLOCK_AGENT_BIN"; do
  case "${_pair#*:}" in
    *[$'\n\r']*) die "resolved ${_pair%%:*} must not contain newlines — it is written onto a systemd Environment= line" ;;
  esac
done
case "$AIRLOCK_AGENT_BIN" in
  /*) ;;
  *) die "AIRLOCK_AGENT_BIN must be an absolute D5 platform path" ;;
esac
# Readable, not executable: bin/airlock-agent is mode 100644 by design and every caller
# spawns python3 for it, the same way install/lib.sh spawns bin/airlock-config.
[ -f "$AIRLOCK_AGENT_BIN" ] && [ -r "$AIRLOCK_AGENT_BIN" ] \
  || die "AIRLOCK_AGENT_BIN does not name a readable platform file"
AGENT_BIN="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' \
  "$AIRLOCK_AGENT_BIN")"
# The orchestrator resolves AIRLOCK_CONFIG to the absolute operator pathname before
# invoking any package installer. Persist that origin for the long-lived backend: its
# cwd is the app directory, where airlock-config's fallback search can otherwise select
# the repository's own airlock.toml. Never persist AIRLOCK_CONFIG_SNAPSHOT or its digest;
# those pin one installer run and would make the service read stale bytes forever.
case "${AIRLOCK_CONFIG:-}" in
  /*) AIRLOCK_CONFIG_PATH="$AIRLOCK_CONFIG" ;;
  *) die "AIRLOCK_CONFIG must be the absolute original config path" ;;
esac
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
WEBROOT="${AIRLOCK_WEBROOT:-/opt/airlock/hub}"
IDENTITY_HEADER="${AIRLOCK_IDENTITY_HEADER:?}"
# This value is interpolated into an nginx variable name below. airlock-config derives it
# from a fixed provider map so it is always well formed, but this script can be run
# standalone with the env var set — and a value carrying whitespace or a brace would either
# break the hub config (reload fails, whole hub down) or inject directives.
case "$IDENTITY_HEADER" in
  *[!A-Za-z0-9-]*|'') die "AIRLOCK_IDENTITY_HEADER must be a bare HTTP header name (letters, digits, '-'): got '$IDENTITY_HEADER'" ;;
esac
# Same reasoning one level down: these values feed a systemd EnvironmentFile,
# where a newline would inject additional environment entries.
for _v in "$EXEC_CWD_ROOT" "$EXEC_SESSION" "$SLACK_WEBHOOK_URGENT_ENV"; do
  case "$_v" in *[$'\n\r']*) die "config values must not contain newlines" ;; esac
done
# Precedence treats surrounding whitespace as unset, matching the documented table.
trim_config_value() {
  python3 -c 'import sys; print(sys.argv[1].strip(), end="")' "$1"
}
SLACK_WEBHOOK_URGENT_ENV="$(trim_config_value "$SLACK_WEBHOOK_URGENT_ENV")"
OWNER="${AIRLOCK_OWNER:?}"
UNIT_DIR="$HOME/.config/systemd/user"
DEVMON_STATE="$HOME/.local/state/airlock/dev-monitor"
DEVMON_ENV="$HOME/.config/airlock/dev-monitor.env"
DEVMON_SECRETS="$HOME/.config/airlock/dev-monitor-secrets.env"
SLACK_WEBHOOK_NAME="$SLACK_WEBHOOK_URGENT_ENV"
render_dev_monitor_check_secret_names "$SLACK_WEBHOOK_NAME" || exit 1
# This optional file is loaded by the service even without selected credentials
# or messages. Existing files always cross the same ownership/mode boundary.
if [ -e "$DEVMON_SECRETS" ] || [ -L "$DEVMON_SECRETS" ]; then
  [ -f "$DEVMON_SECRETS" ] && [ ! -L "$DEVMON_SECRETS" ] \
    || die "dev-monitor-secrets.env must exist as a regular file (not a symlink)"
  [ "$(stat -c %u "$DEVMON_SECRETS")" = "$(id -u)" ] \
    || die "dev-monitor-secrets.env must be owned by the installing user"
  [ "$(stat -c %a "$DEVMON_SECRETS")" = 600 ] \
    || die "dev-monitor-secrets.env must have mode 0600"
fi
secret_check_args=(--file "$DEVMON_SECRETS")
for secret_name in "$SLACK_WEBHOOK_NAME"; do
  [ -n "$secret_name" ] || continue
  secret_check_args+=(--allow "$secret_name")
done
if [ "$MESSAGES" = true ]; then
  for secret_name in "$SLACK_WEBHOOK_NAME"; do
    [ -n "$secret_name" ] || continue
    [ -f "$DEVMON_SECRETS" ] \
      || die "dev-monitor-secrets.env must exist when a credential name is configured"
    secret_check_args+=("$secret_name")
  done
fi
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  secret_check_args+=(--static)
fi
if [ -f "$DEVMON_SECRETS" ]; then
  python3 "$HERE/check-secrets.py" "${secret_check_args[@]}" \
    || die "dev-monitor-secrets.env validation failed (file security/names, empty value, or user systemd unavailable)"
fi
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] secret name/owner/mode checked; systemd value semantics NOT checked"
fi
DEVMON_ENV_OUTPUT="$DEVMON_ENV"
# AIRLOCK_RENDER_DIR: harness-only destination-root override (highest
# priority). Redirects only where render output lands — install/lib.sh
# fail-closes if this is set without AIRLOCK_DRY_RUN=1, since real system
# mutations (systemctl, sudo tailscale serve, and orca's own sudo nft/
# systemctl calls) are gated on dry-run alone, not on this variable.
if [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  CONFD="$AIRLOCK_RENDER_DIR/confd"
  UNIT_DIR="$AIRLOCK_RENDER_DIR/units"
  # Capture output under the harness root, but keep EnvironmentFile= pointed at
  # the path the real service will read. Confusing these paths makes a golden pass
  # while the rendered unit reads a file that exists only in the test harness.
  DEVMON_ENV_OUTPUT="$AIRLOCK_RENDER_DIR/files/dev-monitor.env"
fi
# The spool is written by a SECOND UID, which therefore has to traverse every directory
# above it. The one in the way is Airlock's own state directory: install/airlock-install.sh
# creates it 0700, which is right for a directory holding the ledger and wrong for a
# parent this app needs a foreign uid to walk through. So widen exactly that one bit,
# here, where it is the OPERATOR doing it to their own directory — no sudo, and nothing
# root-owned is involved.
#
# `o+x` and not `o+rx`: traverse, never list. The ledger beside us stays 0600 and the
# directory stays unlistable, so what this grants is the ability to reach a path you
# already know the name of, which is the whole requirement. Group would be narrower
# still, but chgrp to a group the operator does not belong to needs root, and
# install/test-monitor-spool-hardening.sh deliberately forbids root from touching the
# user-owned state path at all.
#
# Measured 2026-08-22: without this the install dies in install-spool-hardening.sh's
# cross-UID check, which is the check written to catch precisely this.
_devmon_state_parent="$(dirname "$DEVMON_STATE")"
if [ -d "$_devmon_state_parent" ]; then
  chmod o+x "$_devmon_state_parent" \
    || die "cannot make $_devmon_state_parent traversable for the spool writer"
fi

# A legacy messages DB cannot be opened by the current backend.  Convert it here, inside
# the existing install lifecycle, after the platform has deactivated an upgraded package
# and before this script renders or starts the replacement.  Reinstall plans do not run a
# deactivator, so this boundary also stops and verifies every in-repository DB writer and
# producer itself.  The dedicated cross-UID publisher is fenced at the spool directories
# while the DB snapshot is made; queued files are retained and need no conversion.
_devmon_migration_state=idle
_devmon_outer_receipt_durable=0

devmon_migration_finish() {
  local outcome="$1" rc="${2:-0}" recovery_ready=1
  [ "$outcome" = success ] || trap - EXIT
  if [ "$outcome" = failure ] && [ "$_devmon_outer_receipt_durable" = 1 ]; then
    log "dev-monitor database compensation deferred to the install transaction"
    exit "$rc"
  fi
  if [ "$outcome" = failure ]; then
    devmon_migration_quiesce || recovery_ready=0
    if [ "$recovery_ready" = 1 ] && [ "$_devmon_migration_state" = converted ]; then
      devmon_migration_restore_db unconditional "$DEVMON_DB" \
        "$HERE/migrate-legacy-state.py" || recovery_ready=0
    fi
    [ "$recovery_ready" != 1 ] \
      || devmon_migration_restore_spool "$DEVMON_STATE" || recovery_ready=0
    [ "$recovery_ready" != 1 ] \
      || devmon_migration_start_saved all || recovery_ready=0
    [ "$recovery_ready" = 1 ] \
      || log "FATAL: dev-monitor database compensation degraded after installer rc=$rc; legacy backup retained"
    exit "$rc"
  fi
  # Backend and heartbeat are reconciled by the normal install path. Token
  # freshness is separate, so only its formerly-active units resume here.
  devmon_migration_start_saved unmanaged \
    || die "cannot restore previously-active migration units"
  _devmon_migration_state=idle
  trap - EXIT
}

devmon_write_outer_receipt() {
  local receipt="${AIRLOCK_DEVMON_MIGRATION_RECEIPT:-}"
  local transaction_id="${AIRLOCK_INSTALL_TRANSACTION_ID:-}" expected
  [ -n "$receipt$transaction_id" ] || return 0
  [[ "$transaction_id" =~ ^[0-9a-f]{32}$ ]] \
    || die "invalid outer install transaction id"
  expected="${AIRLOCK_STATE_DIR:?outer transaction state is missing}/install-checkpoints/$transaction_id/dev-monitor-migration.json"
  [ "$receipt" = "$expected" ] \
    || die "outer dev-monitor migration receipt path does not match its transaction"
  python3 - "$receipt" "$transaction_id" "$DEVMON_DB" "$SPOOL_WRITER_USER" \
    "$DEVMON_MIGRATION_TMP_MODE" "$DEVMON_MIGRATION_NEW_MODE" \
    "${DEVMON_MIGRATION_ACTIVE[@]}" <<'PY' \
    || die "cannot persist outer dev-monitor migration receipt"
import json
import os
from pathlib import Path
import sys
import tempfile

path = Path(sys.argv[1])
transaction_id, database, writer, tmp_mode, new_mode = sys.argv[2:7]
if path.is_symlink() or path.exists():
    raise SystemExit('migration receipt already exists')
if path.parent.is_symlink() or not path.parent.is_dir():
    raise SystemExit('migration checkpoint directory is unsafe')
payload = {
    'version': 1,
    'transaction_id': transaction_id,
    'database': database,
    'writer_user': writer,
    'spool_modes': {
        'tmp': None if tmp_mode == '-' else tmp_mode,
        'new': None if new_mode == '-' else new_mode,
    },
    'active_units': sys.argv[7:],
}
fd, raw = tempfile.mkstemp(prefix='.dev-monitor-migration.', dir=path.parent)
temp = Path(raw)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as handle:
        json.dump(payload, handle, sort_keys=True)
        handle.write('\n')
        handle.flush()
        os.fchmod(handle.fileno(), 0o600)
        os.fsync(handle.fileno())
    os.replace(temp, path)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
finally:
    if temp.exists():
        temp.unlink()
PY
  _devmon_outer_receipt_durable=1
}

DEVMON_DB="$DEVMON_STATE/messages.db"
if [ "$MESSAGES" = true ] && { [ -e "$DEVMON_DB" ] || [ -L "$DEVMON_DB" ]; }; then
  _devmon_schema="$(python3 "$HERE/migrate-legacy-state.py" --schema-state "$DEVMON_DB")" \
    || die "cannot classify the existing messages database"
  case "$_devmon_schema" in
    canonical) log "messages database already uses the current schema" ;;
    legacy)
      if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
        log "[dry] would quiesce dev-monitor writers/producers and convert the legacy messages database"
      else
        # Record the pre-migration state before the first mutation. A standalone app
        # keeps it in memory; the outer transaction persists the same facts beside its
        # package checkpoint so a crash or a later nginx/smoke failure can compensate.
        devmon_migration_snapshot "$DEVMON_STATE" \
          || die "cannot inspect DB writers, producers, or spool lanes"
        _devmon_migration_state=quiesced
        trap 'devmon_migration_finish failure $?' EXIT
        devmon_write_outer_receipt

        devmon_migration_quiesce \
          || die "cannot stop and verify DB writers or spool producers"
        # The identity check closes the receipt-write interval without another walk.
        devmon_migration_fence "$DEVMON_STATE" "$SPOOL_WRITER_USER" true \
          || die "cannot fence and verify cross-UID spool publishing"

        _devmon_conversion_receipt="$(python3 "$HERE/migrate-legacy-state.py" \
          --endstate "$DEVMON_DB" --offline)" \
          || die "legacy messages database conversion failed; original/backup retained"
        [ "$_devmon_conversion_receipt" = 'converted=1 backup_retained=1' ] \
          || die "legacy messages database conversion returned no completion receipt"
        _devmon_migration_state=converted
      fi
      ;;
    *) die "unknown messages database schema classification" ;;
  esac
fi

# Establish (or remove, when messages=false) the system-scope writer boundary before
# rendering or restarting the user service. The rendered unit independently checks that
# the firewall unit is active, so a missing rule fails closed on every later restart too.
bash "$HERE/install-spool-hardening.sh" --state "$DEVMON_STATE" \
  --messages "$MESSAGES" --writer-user "$SPOOL_WRITER_USER" \
  --writer-group "$SPOOL_WRITER_GROUP"

# The unread badge (hub/assets/airlock-return.js) polls owner/messages/preview
# cross-origin from the separate-port tools (devterm/code-server/orca/paseo — same box,
# different ports). That path matches the OWNER location in the fragment below, not the
# general one, because nginx picks the longest matching prefix. So the echo has to come
# from the backend — which is also the only place that knows this particular route is
# the badge's rather than the owner's data.
#
# We name the exact ORIGINS, port included. Naming hosts admitted every listener on this
# box, and one of them — the publish document port — serves generated HTML by the
# thousand. A script in any published page could then read the owner's message preview:
# the ingress injects the reader's identity, and an echoed ACAO hands back the response.
# The document port is therefore absent from this list on purpose. It is the surface
# whose content is bulk-generated, so it is the one that must not be able to ask.
#
# BADGE_APPS is the list from the paragraph above, not "every app with a port". Adding an
# app here grants its pages the owner's message preview; that is a decision, not upkeep.
BADGE_APPS="devterm code-server orca paseo"
FQDN="${AIRLOCK_TS_FQDN:-}"
# Two statements, not `$(... || true)`: ts_fqdn ends in `die`, and an `exit` inside a
# command substitution kills the substitution before `|| true` can run. Same trap
# install/render-nginx.sh documents.
[ -n "$FQDN" ] || FQDN="$(ts_fqdn 2>/dev/null)" || FQDN=""
cors_origins=""
if [ -n "$FQDN" ]; then
  # Ports come from the platform's own package-info, so a box that does not install a
  # tool grants nothing for it, and a re-configured port cannot drift away from reality.
  #
  # package-info is exported by install/airlock-install.sh; a standalone app install has
  # to ask for it. It is the SAME projection either way — one method, so the two entry
  # points cannot answer differently. An earlier draft re-derived the ports here from
  # individual config keys and got it wrong twice: it granted `compat_https` even when
  # that listener is disabled (only serve_port_values knows), and it swallowed lookup
  # failures into a short list nobody was told about.
  _pkg_info="${AIRLOCK_PKG_INFO:-}"
  if [ -z "$_pkg_info" ]; then
    log "note: package-info absent (standalone app install) — asking airlock-config for it"
    _pkg_info="$(airlock_config package-info)" \
      || die "could not read package-info; badge origins are unresolvable"
  fi
  # An empty projection would reach the parser as `json.loads("")`, whose message names a
  # column rather than a cause. Say the cause here instead.
  [ -n "$_pkg_info" ] || die "package-info was empty; badge origins are unresolvable"
  cors_origins="$(BADGE_APPS="$BADGE_APPS" FQDN="$FQDN" AIRLOCK_PKG_INFO="$_pkg_info" \
    python3 - <<'DEVMON_CORS_PY'
import json, os, sys
# No `or "{}"`: an empty projection here is a bug upstream, not a quiet empty set.
info = json.loads(os.environ["AIRLOCK_PKG_INFO"])
packages = info.get("packages") or {}
fqdn = os.environ["FQDN"].strip().lower()
hosts = [fqdn]
short = fqdn.split(".")[0]
if short and short != fqdn:
    hosts.append(short)
out = []
for app in os.environ["BADGE_APPS"].split():
    pkg = packages.get(app)
    if not pkg:
        continue                                  # not installed -> grants nothing
    # BADGE_APPS names the SHIPPED tools. An operator may point [packages.<id>] at a
    # local tree that takes one of those ids, and that package is not the audited thing
    # the name refers to — it is whatever is on disk, on whatever port it declares.
    # Matching by id alone would hand it the owner's message preview by inheritance.
    if pkg.get("source_class") != "shipped":
        sys.stderr.write(
            "skip %s: a local package shadows this id, so it is not the shipped tool "
            "this grant is for\n" % app)
        continue
    for port in sorted(set((pkg.get("serve_port_values") or {}).values())):
        if not isinstance(port, int) or not 1 <= port <= 65535:
            continue
        out += ["https://%s:%d" % (h, port) for h in hosts]
# dict.fromkeys: stable order, not a set shuffle, so the rendered unit is
# byte-identical across runs and the golden stays meaningful.
sys.stdout.write(",".join(dict.fromkeys(out)))
DEVMON_CORS_PY
)"
  [ -n "$cors_origins" ] \
    || log "WARN: no badge-drawing tool is installed — the unread badge stays hub-only"
else
  log "WARN: tailnet FQDN unresolved — the unread badge stays hub-only (no cross-origin read)"
fi

# --- 0. owner gate + optional message/action console state ---
# The update API always needs its two-value owner gate; the message feature additionally
# needs spool/DB state. The same 0600 file carries the full set when messages=true and
# only the gate when false, so turning messages off cannot also turn off updates.
#
# The proxy secret is what proves a request came through nginx rather than straight to
# the loopback port. A real install rotates it: nginx and the unit are rewritten in the
# same run, so rotation costs nothing and bounds the lifetime of a value that leaked from
# an old config.
#
# A DRY RUN must not rotate it, so it reuses the deployed secret when it can read one.
# That alone is not enough — an unreadable env file leaves nothing to reuse — which is why
# the fragment write further down also refuses to overwrite an existing file on a dry run.
# Between them, a preview can never hand nginx a secret the running backend has not seen.
#
# The spool is 0700 and owned by the operator. Anything that can write it can create a
# card — including an `action` card — so treat spool write access as equivalent to
# console access. It is not equivalent to execution: an action card still has to be
# approved by the owner in the console, and the approved plan is hash-pinned, before
# anything runs. See SECURITY.md.
DEVMON_SECRET=""
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -r "$DEVMON_ENV" ]; then
  DEVMON_SECRET="$(sed -n 's/^DEV_MONITOR_PROXY_SECRET=//p' "$DEVMON_ENV" | head -1)"
fi
# Nothing to reuse (no env file yet, or it is unreadable): mint one. Safe on a dry run
# only because the fragment write below will not overwrite an existing file.
[ -n "$DEVMON_SECRET" ] || DEVMON_SECRET="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
if [ "$MESSAGES" = true ]; then
  if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ]; then
    install -d -m 700 "$(dirname "$DEVMON_ENV")"
  fi
  # The console link that Slack messages carry. Without a resolvable tailnet FQDN there
  # is no address that works from a phone, so the link is omitted rather than guessed.
  CONSOLE_URL=""
  if [ -n "$FQDN" ]; then
    CONSOLE_URL="https://${FQDN}/monitor/#messages"
  else
    log "WARN: tailnet FQDN unresolved — Slack notifications will carry no console link"
  fi
  # Not a preflight row: preflight is per-app and fails the whole install, and tmux is only
  # needed by the ACTION half of an optional console. Cards, coalescing, Slack and the feed
  # all work without it; an approval is refused with a reason instead of appearing to run.
  command -v tmux >/dev/null 2>&1 || \
    log "WARN: tmux not found — cards and the feed work, but approved actions cannot run. Install it (sudo apt-get install -y tmux) to use the action half."
  if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] || [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
    install -d -m 700 "$(dirname "$DEVMON_ENV_OUTPUT")"
    ( umask 077; render_dev_monitor_env \
        "$OWNER" "$DEVMON_SECRET" "$DEVMON_STATE" "${EXEC_CWD_ROOT:-$HOME}" \
        "$EXEC_SESSION" "$SLACK_WEBHOOK_NAME" "$CONSOLE_URL" >"$DEVMON_ENV_OUTPUT" )
    chmod 600 "$DEVMON_ENV_OUTPUT"

  fi
elif [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] || [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
  install -d -m 700 "$(dirname "$DEVMON_ENV_OUTPUT")"
  ( umask 077; render_dev_monitor_owner_env "$OWNER" "$DEVMON_SECRET" >"$DEVMON_ENV_OUTPUT" )
  chmod 600 "$DEVMON_ENV_OUTPUT"
  # Turning the console off does not reach into a run that is already going. Killing
  # someone's in-flight work to honour a config change would be worse than leaving it —
  # but leaving it silently would be worse still, because the UI that could stop it is
  # about to disappear.
  if tmux has-session -t "$EXEC_SESSION" 2>/dev/null; then
    log "WARN: messages is now false, but tmux session '$EXEC_SESSION' still has running actions. \
They keep running and the console can no longer stop them — attach with 'tmux attach -t $EXEC_SESSION'."
  fi
fi

# --- 1. systemd user unit (loopback backend) ---
# AIRLOCK_RENDER_DIR forces the write branch even under AIRLOCK_DRY_RUN=1 —
# see install/lib.sh's fail-closed guard (RENDER_DIR without DRY_RUN=1 never
# reaches this line) and apps/feedback/install.sh's identical comment.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -z "${AIRLOCK_RENDER_DIR:-}" ]; then
  log "[dry] write $UNIT_DIR/airlock-dev-monitor.service (127.0.0.1:$BACKEND_PORT, messages=$MESSAGES)"
else
  install -d "$UNIT_DIR"
  render_dev_monitor_unit "$BACKEND_PORT" "$MESSAGES" "$IDENTITY_HEADER" "$cors_origins" "$DEVMON_ENV" \
    "$TOKEN_FRESHNESS" "$TOKEN_WARN_HOURS" "$TOKEN_STALE_HOURS" "$MESSAGES" \
    "$ACCOUNTS_STATUS_BIN" "$AGENT_PROVIDER" "$AGENT_BIN" "$SLACK_WEBHOOK_NAME" \
    "$AIRLOCK_CONFIG_PATH" \
    >"$UNIT_DIR/airlock-dev-monitor.service"
fi
# The card is on; the CHECKING is not. Said once at install time, because "the feature is
# enabled" and "something is looking at your tokens on a schedule" are different facts and
# the dashboard cannot tell them apart until the first snapshot exists.
if [ "$TOKEN_FRESHNESS" = true ] && [ ! -f "$HOME/.config/systemd/user/airlock-token-freshness.timer" ]; then
  log "NOTE: token_freshness is on, so the dashboard card and /api/tokens are live — but nothing checks on a schedule yet. Wire the timer with: AIRLOCK_ROOT=$ROOT AIRLOCK_APP_DIR=$HERE AIRLOCK_APP_ID=$AIRLOCK_APP_ID bash $HERE/install-token-timer.sh"
fi
# The heartbeat is part of the message pipeline, so messages=false stops it too.
if [ "$MESSAGES" = true ]; then
  if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] || [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
    for kind in service timer; do
      render_dev_monitor_heartbeat "$kind" "$DEVMON_STATE/spool" \
        >"$UNIT_DIR/airlock-devmon-heartbeat.$kind"
    done
  fi
else
  # Query the manager, not just fragment existence: a removed file may still
  # have an active timer or in-flight oneshot loaded. Never delete its recovery
  # files when disable/stop failed or the manager still reports it running.
  if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
    airlock_run systemctl --user disable --now airlock-devmon-heartbeat.timer
    airlock_run systemctl --user disable --now airlock-devmon-heartbeat.service
  else
    require_cmd timeout
    heartbeat_state() {
      local unit="$1" state key value
      state="$(timeout 30 systemctl --user show "$unit" --property=LoadState \
        --property=ActiveState --property=UnitFileState --property=MainPID)" \
        || die "cannot query heartbeat unit state: $unit"
      hb_load='' hb_active='' hb_enabled='' hb_pid=''
      # Timer units have no MainPID property; services must report it.
      case "$unit" in *.timer) hb_pid=0 ;; esac
      while IFS='=' read -r key value; do
        case "$key" in
          LoadState) hb_load="$value" ;;
          ActiveState) hb_active="$value" ;;
          UnitFileState) hb_enabled="$value" ;;
          MainPID) hb_pid="$value" ;;
        esac
      done <<< "$state"
      [ -n "$hb_load" ] && [ -n "$hb_active" ] && [ -n "$hb_pid" ] \
        || die "incomplete heartbeat unit state: $unit"
    }
    for heartbeat_unit in airlock-devmon-heartbeat.timer airlock-devmon-heartbeat.service; do
      heartbeat_state "$heartbeat_unit"
      if [ "$hb_load" = not-found ] && [ "$hb_active" = inactive ] \
          && [ "$hb_pid" = 0 ] && [ -z "$hb_enabled" ]; then
        continue
      fi
      timeout 30 systemctl --user disable --now "$heartbeat_unit" \
        || die "cannot disable and stop heartbeat unit: $heartbeat_unit; files preserved"
      heartbeat_state "$heartbeat_unit"
      case "$hb_active:$hb_pid:$hb_enabled" in
        inactive:0:disabled|inactive:0:static|inactive:0:linked|inactive:0:linked-runtime|inactive:0:|\
        failed:0:disabled|failed:0:static|failed:0:linked|failed:0:linked-runtime|failed:0:) ;;
        *) die "heartbeat unit is still active or enabled: $heartbeat_unit ($hb_active/$hb_pid/$hb_enabled); files preserved" ;;
      esac
    done
  fi
  if [ "${AIRLOCK_DRY_RUN:-0}" != 1 ] || [ -n "${AIRLOCK_RENDER_DIR:-}" ]; then
    rm -f "$UNIT_DIR/airlock-devmon-heartbeat.service" "$UNIT_DIR/airlock-devmon-heartbeat.timer"
  fi
fi
airlock_run systemctl --user daemon-reload
airlock_run systemctl --user enable airlock-dev-monitor.service
airlock_run systemctl --user restart airlock-dev-monitor.service
if [ "$MESSAGES" = true ]; then
  airlock_run systemctl --user enable --now airlock-devmon-heartbeat.timer
fi

# --- 2. dashboard UI into the hub webroot (served by the hub's static location /) ---
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] install dev-monitor.html -> $WEBROOT/monitor/index.html"
else
  install -d "$WEBROOT/monitor"
  install -m644 "$HERE/frontend/dev-monitor.html" "$WEBROOT/monitor/index.html"
fi

# --- 3. nginx subpath fragment (included inside the hub server = server-level gate) ---
# Config, not a system mutation — written unconditionally. nginx runtime vars are
# escaped as \$ so the shell never expands them; the only shell substitutions are
# the backend port and the same-box origin regex below. No per-location guard: the
# hub server-level gate ($hub_ok) covers it.
frag="$CONFD/hub-locations.d/dev-monitor.conf"
install -d "$CONFD/hub-locations.d"

# Owner-only non-message endpoints are always rendered as separately-scoped branches:
# updates has an exact snapshot plus its execution prefix, harness has its own prefix,
# the app store has an exact inventory plus its action prefix, and home order is exact.
# Keeping each branch narrow means a future message route cannot accidentally inherit
# this gate. Each prefix is longer than /monitor/api/ and than the conditional message
# console /monitor/api/owner/ location, so nginx's longest-prefix rule keeps these
# owner gates active whether or not the console is installed.
# Message/action routes keep their existing conditional prefix location below.
#
# Both X-Devmon-* headers are set here, which is also what makes a client-supplied copy
# of them harmless — proxy_set_header REPLACES whatever the browser sent. The owner is
# taken from the ingress-injected identity header (never from the request body), and the
# secret proves the request came through nginx rather than straight to the loopback port.
hdr_var="$(printf '%s' "${IDENTITY_HEADER//-/_}" | tr '[:upper:]' '[:lower:]')"
updates_location="$(render_dev_monitor_owner_location "$BACKEND_PORT" "$hdr_var" "$DEVMON_SECRET" \
  '= /monitor/api/owner/updates')$(render_dev_monitor_owner_location "$BACKEND_PORT" "$hdr_var" \
  "$DEVMON_SECRET" '/monitor/api/owner/updates/')$(render_dev_monitor_owner_location \
  "$BACKEND_PORT" "$hdr_var" "$DEVMON_SECRET" '/monitor/api/owner/harness/')"
apps_location="$(render_dev_monitor_owner_location "$BACKEND_PORT" "$hdr_var" "$DEVMON_SECRET" \
  '= /monitor/api/owner/apps')$(render_dev_monitor_owner_location "$BACKEND_PORT" "$hdr_var" \
  "$DEVMON_SECRET" '/monitor/api/owner/apps/')"
home_order_location="$(render_dev_monitor_owner_location "$BACKEND_PORT" "$hdr_var" "$DEVMON_SECRET" \
  '= /monitor/api/owner/home/order')"
owner_location="${apps_location}${home_order_location}"
if [ "$MESSAGES" = true ]; then
  owner_location+="$(render_dev_monitor_owner_location "$BACKEND_PORT" "$hdr_var" "$DEVMON_SECRET")"
fi

# A dry run must not touch an EXISTING fragment. Elsewhere in Airlock the nginx fragment
# is pure config and is written unconditionally, which is safe because it is a pure
# function of the config. This one is not: it carries a freshly minted secret, and whether
# it contains the owner location at all depends on `messages`. Previewing `messages = false`
# on a live box would therefore delete the owner location from the file nginx actually
# serves, and the console would 404 at the next reload with nothing to explain why.
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ] && [ -e "$frag" ]; then
  log "[dry] would rewrite $frag (messages=$MESSAGES) — left as is"
  frag="$(mktemp)"
fi
# Created restricted, THEN written: the fragment carries the proxy secret, and
# `cat > file` would otherwise create it under the default umask (world-readable) with
# the secret already in it and only narrow the mode afterwards. nginx reads its config
# as root, so 0600 owned by the installing user is readable where it needs to be.
install -m 600 /dev/null "$frag"
render_dev_monitor_nginx "$BACKEND_PORT" "$updates_location" "$owner_location" >"$frag"
log "wrote nginx fragment: $frag"

# NOTE: smoke runs from the orchestrator AFTER nginx reload (gate not live before).
devmon_migration_finish success
log "dev-monitor installed (owner: ${AIRLOCK_OWNER}; messages: ${MESSAGES})"
