#!/usr/bin/env bash
# Disposable scratch HOME: install from an airlock-apps tree, then run the
# real migrators. No live box, no tailscale serve, no systemctl.
# shellcheck disable=SC2030,SC2031 # per-app subshell exports must not escape
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
pass=0
fail=0
ok()  { printf 'ok   scratch-lifecycle: %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL scratch-lifecycle: %s\n' "$1"; fail=$((fail+1)); }

APPS_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apps-root) APPS_ROOT="$2"; shift 2 ;;
    *) echo "usage: $0 --apps-root DIR" >&2; exit 2 ;;
  esac
done
if [ -z "$APPS_ROOT" ] || [ ! -d "$APPS_ROOT/apps/devterm" ]; then
  echo "scratch-lifecycle: --apps-root must be an airlock-apps checkout" >&2
  exit 1
fi
APPS_ROOT="$(cd "$APPS_ROOT" && pwd)"

TMP="$(mktemp -d)" || { echo "FAIL scratch-lifecycle: mktemp" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export AIRLOCK_STATE_DIR="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$HOME" "$AIRLOCK_STATE_DIR"

cat >"$TMP/airlock.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "me@example.com"
[paths]
code_root = "/srv/code"
[apps.hub]
[apps.devterm]
[apps.code-server]
[apps.markwand]
[apps.publish]
[apps.notepad]
[apps.feedback]
[apps.dev-monitor]
[apps.paseo]
TOML

SHIM="$TMP/shim"
mkdir -p "$SHIM"
for c in nft nginx tailscale tmux ss sudo; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$SHIM/$c"
  chmod +x "$SHIM/$c"
done
cat >"$SHIM/curl" <<'SH'
#!/usr/bin/env bash
# Deterministic smoke endpoint fixture. The real smoke.sh entrypoints run, but
# no request may leave this disposable HOME or reach a live Airlock service.
set -u
url="" headers="" write_code=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H|--header) headers="${headers}${2}"$'\n'; shift 2 ;;
    -w|--write-out) write_code=1; shift 2 ;;
    -o|--output|--max-time|--connect-time) shift 2 ;;
    -s|-S|--silent|--http1.1) shift ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf 'curl\t%s\t%s\n' "${AIRLOCK_SMOKE_FIXTURE_APP:-?}" "$url" \
  >>"${AIRLOCK_SCRATCH_COMMAND_LOG:?}"

port="${url#*://}"; port="${port#*:}"; port="${port%%/*}"
path="/${url#*://*/}"
status=200
case " ${AIRLOCK_SMOKE_FIXTURE_DENY_PORTS:-} " in
  *" $port "*) status=403 ;;
esac
case "$headers" in
  *nobody@example.com*) status=403 ;;
  *"${AIRLOCK_IDENTITY_HEADER:-X-Webauth-User}: ${AIRLOCK_OWNER:-me@example.com}"*) status=200 ;;
esac
if [ "${AIRLOCK_SMOKE_FIXTURE_APP:-}" = dev-monitor ]; then
  case "$path" in
    /monitor/api/tokens|/monitor/api/owner/messages/preview) status=404 ;;
  esac
fi
if [ "${AIRLOCK_SMOKE_FIXTURE_APP:-}" = code-server ] \
   && [ "$path" = /s/1/ ] && [[ "$headers" == *"Upgrade: websocket"* ]]; then
  status=101
fi
if [ "${AIRLOCK_SMOKE_FIXTURE_FAIL_APP:-}" = "${AIRLOCK_SMOKE_FIXTURE_APP:-}" ]; then
  status=503
fi

if [ "$write_code" = 1 ]; then
  printf '%s' "$status"
  exit 0
fi
case "${AIRLOCK_SMOKE_FIXTURE_APP:-}:$path:$headers" in
  code-server:/:*) printf '%s\n' '<script src="/airlock-return.js"></script>' ;;
  dev-monitor:/api/health:*) printf '%s\n' '{"token_freshness":"off","messages":"off"}' ;;
  feedback:/api/health:*) printf '%s\n' '{"enabled":false,"intake":false,"mail":false}' ;;
  publish:/publish/api/list:*|publish:/api/list:*) printf '%s\n' '{"ok":true}' ;;
  publish:/api/health:*) printf '%s\n' '{"public_enabled":false}' ;;
  markwand:/markwand/:*nobody@example.com*) printf '%s\n' "This isn't your Airlock" ;;
  markwand:/markwand/:*) printf '%s\n' '<script src="/__mw/highlight.min.js"></script>' ;;
  *) printf '%s\n' '{}' ;;
esac
SH
chmod +x "$SHIM/curl"
export PATH="$SHIM:$PATH"
export AIRLOCK_CONFIG="$TMP/airlock.toml"
export AIRLOCK_CONFD="$TMP/confd"
export AIRLOCK_WEBROOT="$TMP/web"
export AIRLOCK_DRY_RUN=1
export AIRLOCK_TS_FQDN="box.example.ts.net"
export AIRLOCK_SHIPPED_APPS_ROOT="$APPS_ROOT/apps"
export AIRLOCK_SCRATCH_COMMAND_LOG="$TMP/commands.log"

if HOME="$HOME" bash "$ROOT/install/airlock-install.sh" >"$TMP/orch.log" 2>&1; then
  ok "dry-run orchestrator used airlock-apps as the app source"
else
  bad "dry-run orchestrator (see $TMP/orch.log)"
  sed 's/^/    /' "$TMP/orch.log" | tail -40
fi

apps=(devterm code-server markwand publish notepad feedback dev-monitor paseo)
for app in "${apps[@]}"; do
  if grep -Fq "would install packaged app: $app from $APPS_ROOT/apps/$app" "$TMP/orch.log"; then
    ok "orchestrator resolved $app from airlock-apps"
  else
    bad "orchestrator did not resolve $app from airlock-apps"
  fi
  pkg="$APPS_ROOT/apps/$app"
  inst_log="$TMP/install-$app.log"
  if (
    cd "$pkg" || exit 1
    export AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$pkg" AIRLOCK_APP_ID="$app"
    export AIRLOCK_CONFIG_BIN="$ROOT/bin/airlock-config"
    if [ "$app" = paseo ]; then
      export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368
    else
      unset AIRLOCK_PASEO_MEM_CAP_BYTES
    fi
    bash "$pkg/install.sh" </dev/null >"$inst_log" 2>&1
  ); then
    ok "install.sh from airlock-apps ran dry for $app"
  else
    bad "install.sh from airlock-apps failed for $app"
    sed 's/^/    /' "$inst_log" | tail -20
  fi
done
ok "orca skipped: airlock-apps path is not BUNDLE_ROOT, elevated grants stay on TRUST_CAPABILITY_GATE"

for app in "${apps[@]}"; do
  pkg="$APPS_ROOT/apps/$app"
  smoke_log="$TMP/smoke-$app.log"
  if (
    cd "$pkg" || exit 1
    export AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$pkg" AIRLOCK_APP_ID="$app"
    export AIRLOCK_CONFIG_BIN="$ROOT/bin/airlock-config"
    set -a
    # Export the same resolved values smoke.sh loads so the curl subprocess can
    # distinguish backend ports from owner-gated ports without hard-coded ports.
    eval "$("$ROOT/bin/airlock-config" env "$app")"
    eval "$("$ROOT/bin/airlock-config" env hub)"
    set +a
    key="${app^^}"; key="${key//-/_}"
    eval "backend=\${AIRLOCK_${key}_BACKEND_PORT:-}"
    eval "gate=\${AIRLOCK_${key}_GATE_PORT:-}"
    eval "manager=\${AIRLOCK_${key}_MANAGER_PORT:-}"
    deny_ports="${gate:-${AIRLOCK_HUB_NGINX_PORT:-}} ${manager:-}"
    [ "$app" = devterm ] && deny_ports="$deny_ports ${AIRLOCK_DEVTERM_BACKEND_PORT:-}"
    export AIRLOCK_SMOKE_FIXTURE_APP="$app"
    export AIRLOCK_SMOKE_FIXTURE_DENY_PORTS="$deny_ports"
    bash "$pkg/smoke.sh" </dev/null >"$smoke_log" 2>&1
  ); then
    ok "smoke.sh from airlock-apps ran against the scratch endpoint fixture for $app"
  else
    bad "smoke.sh from airlock-apps failed for $app"
    sed 's/^/    /' "$smoke_log" | tail -30
  fi
done

# The fixture must be load-bearing: break one app's endpoints and require its
# real smoke entrypoint to turn red, then leave the normal matrix green above.
if (
  app=feedback; pkg="$APPS_ROOT/apps/$app"
  cd "$pkg" || exit 1
  export AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$pkg" AIRLOCK_APP_ID="$app"
  export AIRLOCK_CONFIG_BIN="$ROOT/bin/airlock-config"
  export AIRLOCK_SMOKE_FIXTURE_APP="$app" AIRLOCK_SMOKE_FIXTURE_FAIL_APP="$app"
  export AIRLOCK_SMOKE_FIXTURE_DENY_PORTS="${AIRLOCK_HUB_NGINX_PORT:-8080}"
  bash "$pkg/smoke.sh" </dev/null >/dev/null 2>&1
); then
  bad "negative: feedback smoke accepted broken scratch endpoints"
else
  ok "negative: feedback smoke rejects broken scratch endpoints"
fi

for app in "${apps[@]}"; do
  if grep -Fq $'curl\t'"$app"$'\t' "$AIRLOCK_SCRATCH_COMMAND_LOG"; then
    ok "actual smoke entrypoint reached the isolated curl fixture for $app"
  else
    bad "smoke entrypoint did not reach the isolated curl fixture for $app"
  fi
done

# shellcheck source=/dev/null
. "$APPS_ROOT/apps/paseo/state.sh"
if grep -Fq 'paseo_memory_cap_bytes' "$APPS_ROOT/apps/paseo/install.sh" \
   && grep -Fq 'no trustworthy memory budget' "$APPS_ROOT/apps/paseo/install.sh" \
   && ! paseo_memory_cap_bytes '' max 137438953472 1 >/dev/null 2>&1; then
  ok "negative: unbounded container without AIRLOCK_PASEO_MEM_CAP_BYTES still fails"
else
  bad "negative: memory guard missing or accepts unbounded container without AIRLOCK_PASEO_MEM_CAP_BYTES"
fi

CS_MIG="$APPS_ROOT/apps/code-server/bin/migrate-legacy-state"
mkdir -p "$HOME/.local/share/code-server-slots/1"
printf 'legacy-slot\n' >"$HOME/.local/share/code-server-slots/1/marker"
if python3 "$CS_MIG" && [ -f "$HOME/.local/share/airlock-code-server/slots/1/marker" ]; then
  ok "code-server migrate-legacy-state copied scratch HOME state"
else
  bad "code-server migrate-legacy-state"
fi

DM_MIG="$APPS_ROOT/apps/dev-monitor/migrate-legacy-state.py"
LEG="$TMP/legacy-devmon"
CAN="$TMP/canonical-devmon"
mkdir -p "$LEG/spool/new" "$CAN"
printf 'job\n' >"$LEG/spool/new/a"
dm_migrate_args=("$DM_MIG" "$LEG" "$CAN")
if python3 "$DM_MIG" --help 2>&1 | grep -q -- '--offline'; then
  dm_migrate_args+=(--offline)
fi
if out="$(python3 "${dm_migrate_args[@]}")" && printf '%s\n' "$out" | grep -q 'spool_copied=1'; then
  ok "dev-monitor migrate-legacy-state.py imported scratch spool"
else
  bad "dev-monitor migrate-legacy-state.py ($out)"
fi

if [ ! -f "$CS_MIG" ] || [ ! -f "$DM_MIG" ]; then
  bad "migrator missing under airlock-apps"
else
  ok "both standalone migrators are regular files under airlock-apps"
fi

printf 'scratch-lifecycle: %s ok, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
