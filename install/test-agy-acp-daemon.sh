#!/usr/bin/env bash
# install/test-agy-acp-daemon.sh — the agy-acp fork driven through a REAL,
# isolated Paseo daemon (whichever version apps/paseo/install.sh currently
# vendors under apps/paseo/vendor/guarded-*, discovered below — not pinned):
# own scratch $HOME, own port, fixtures/fake-agy.mjs standing in for the real
# `agy` binary. install/test-agy-acp.sh already proves the fork's own
# interrupt/respawn fix in isolation (fake ACP client <-> fork, no daemon);
# this suite proves the same fix survives Paseo's own ACP client, its
# unguarded-send interrupt path, and a daemon restart mid-conversation — the
# same path a human hits from the CLI or web UI.
#
# Registration is config-only: `agents.providers.agy` with `"extends": "acp"`
# and no `models` key (GenericACPAgentClient probes the catalog live), so this
# suite never touches Paseo's own source — apps/paseo/patches/ is untouched.
#
# Needs the npm registry for the vendored tarballs' third-party dependencies
# (same as install/test-paseo-bundle-install.sh). Nothing outside $TMP is
# touched; the daemon binds an unused loopback port with no relay, MCP, or
# web UI.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FORK_DIR="$ROOT/apps/paseo/agy-acp"
# Not pinned to one version: whichever guarded-* bundle apps/paseo/install.sh
# currently vendors is the one this daemon test proves against, so a Paseo
# version bump (0.2.5 -> 0.8.0 -> ...) does not silently go stale here.
mapfile -t bundle_dirs < <(find "$ROOT/apps/paseo/vendor" -mindepth 1 -maxdepth 1 -type d -name 'guarded-*')
[ "${#bundle_dirs[@]}" -eq 1 ] || {
  echo "FAIL agy-acp-daemon: expected exactly one apps/paseo/vendor/guarded-* bundle, found ${#bundle_dirs[@]}" >&2
  exit 1
}
BUNDLE="${bundle_dirs[0]}"
PORT="${AGY_ACP_DAEMON_TEST_PORT:-29979}"

pass=0; fail=0
ok()  { echo "ok   agy-acp-daemon: $1"; pass=$((pass+1)); }
bad() { echo "FAIL agy-acp-daemon: $1"; fail=$((fail+1)); }
die() { bad "$1"; echo "$1" >&2; exit 1; }

TMP="$(mktemp -d)"
HOME_DIR="$TMP/home"
PASEO_HOME="$TMP/paseo-home"
WS="$TMP/ws"
mkdir -p "$HOME_DIR" "$PASEO_HOME" "$WS"

# `paseo daemon stop` (not a raw kill) is the reliable way to end it: it waits
# for the daemon to actually release its own pid lock, not just its listening
# socket. Those two do not always let go together — measured: `ss` stops
# showing the port well before the daemon's lock clears, so a bare kill +
# "wait for the port to close" leaves a stale lock that then refuses the next
# `daemon start` as "already running", even though nothing is listening.
stop_daemon() {
  [ -x "${PASEO_BIN:-}" ] || return 0
  env HOME="$HOME_DIR" PASEO_HOME="$PASEO_HOME" \
    "$PASEO_BIN" daemon stop --home "$PASEO_HOME" --timeout 20 --force >/dev/null 2>&1 || true
}
cleanup() {
  stop_daemon
  local owner
  owner="$(fuser "$PORT/tcp" 2>/dev/null)"
  [ -n "$owner" ] && kill -KILL "$owner" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- 1. build the fork --------------------------------------------------------
# This suite runs as its own CI job (install-contracts shard), a separate
# checkout from install/test-agy-acp.sh's (config-contracts shard) — its
# node_modules is not available here, so this must install, not just build.
if ! ( cd "$FORK_DIR" && npm install --no-audit --no-fund && npm run build ) >"$TMP/fork-build.log" 2>&1; then
  bad "fork build failed — see below"
  tail -40 "$TMP/fork-build.log"
  exit 1
fi
[ -f "$FORK_DIR/dist/cli.js" ] && ok "fork builds" || die "fork build produced no dist/cli.js"

# --- 2. install the real paseo bundle into a scratch npm prefix --------------
mapfile -t packages < <(awk '{print dir "/" $2}' dir="$BUNDLE" "$BUNDLE/SHA256SUMS")
[ "${#packages[@]}" -gt 0 ] || die "no vendored paseo packages found in $BUNDLE/SHA256SUMS"
if ! env HOME="$HOME_DIR" npm_config_prefix="$HOME_DIR/.npm-global" \
    npm i -g "${packages[@]}" --no-audit --no-fund >"$TMP/paseo-npm.log" 2>&1; then
  bad "paseo bundle install failed — see below"
  tail -40 "$TMP/paseo-npm.log"
  exit 1
fi
PASEO_BIN="$HOME_DIR/.npm-global/bin/paseo"
[ -x "$PASEO_BIN" ] && ok "paseo CLI installed" || die "no paseo CLI at $PASEO_BIN"

# --- 3. an isolated config.json with the agy provider (no static models) -----
# Exactly what card C1's installer writes into the live ~/.paseo/config.json,
# minus the real agy binary path — fixtures/fake-agy.mjs stands in for it.
# AgySession spawns the "agy binary" directly (no interpreter prefix, same as
# a real native binary would be spawned), so it needs the OS executable bit —
# which the checked-in fixture deliberately does not carry (this repo's
# cutline policy disallows a newly added executable file; see
# apps/paseo/agy-acp/tests/materialize-fixture.mjs for the same reasoning on
# the JS test side). A scratch copy gets it instead.
FAKE_AGY="$TMP/fake-agy.mjs"
cp "$FORK_DIR/tests/fixtures/fake-agy.mjs" "$FAKE_AGY"
chmod 700 "$FAKE_AGY"
NODE_BIN="$(command -v node)"
cat >"$PASEO_HOME/config.json" <<JSON
{
  "version": 1,
  "daemon": { "listen": "127.0.0.1:$PORT", "cors": { "allowedOrigins": [] }, "relay": { "enabled": false } },
  "agents": {
    "providers": {
      "agy": {
        "extends": "acp",
        "label": "Antigravity (agy, fake)",
        "command": ["$NODE_BIN", "$FORK_DIR/dist/cli.js", "-b", "$FAKE_AGY"]
      }
    }
  }
}
JSON
chmod 600 "$PASEO_HOME/config.json"

start_daemon() {   # start_daemon <log-file>
  env -u PASEO_AGENT_ID HOME="$HOME_DIR" PASEO_HOME="$PASEO_HOME" \
      FAKE_AGY_STARTUP_MS=150 FAKE_AGY_TURN_MS=50 FAKE_AGY_LONG_TURN_MS=8000 \
      "$PASEO_BIN" daemon start --foreground --home "$PASEO_HOME" --listen "127.0.0.1:$PORT" \
        --no-relay --no-mcp --no-inject-mcp --no-web-ui \
      >"$1" 2>&1 &
}

wait_for_port() {   # wait_for_port <up|down>
  for _ in $(seq 1 30); do
    if [ "$1" = up ]; then
      ss -ltn 2>/dev/null | grep -q ":$PORT " && return 0
    else
      ss -ltn 2>/dev/null | grep -q ":$PORT " || return 0
    fi
    sleep 1
  done
  return 1
}

pc() { env -u PASEO_AGENT_ID HOME="$HOME_DIR" PASEO_HOME="$PASEO_HOME" "$PASEO_BIN" "$@" --host "127.0.0.1:$PORT"; }

# --- 4. start the isolated daemon ---------------------------------------------
start_daemon "$TMP/daemon.log"
wait_for_port up && ok "daemon listening on $PORT" || die "daemon never bound $PORT — $(tail -5 "$TMP/daemon.log")"

# --- 5. interrupt mid-turn, then continue on the same agent (the core fix) ---
if ! pc run -d --json --provider agy --cwd "$WS" --title agy-acp-daemon-test \
    'please sleep then reply with word ALPHA' >"$TMP/run.json" 2>"$TMP/run.err"; then
  bad "paseo run failed — $(cat "$TMP/run.err")"
  exit 1
fi
AGENT_ID="$(python3 -c "import json;print(json.load(open('$TMP/run.json'))['agentId'])" 2>/dev/null)"
[ -n "$AGENT_ID" ] && ok "agent created: $AGENT_ID" || die "no agentId in paseo run --json output"

tool_seen=0
for _ in $(seq 1 15); do
  pc logs "$AGENT_ID" --filter tools 2>/dev/null | grep -qi "run_command\|Executing" && { tool_seen=1; break; }
  sleep 1
done
[ "$tool_seen" -eq 1 ] || die "the sleep tool call never became visible — cannot test an interrupt of a running turn"

pc send "$AGENT_ID" --no-wait 'reply with word BRAVO' >"$TMP/send.out" 2>&1
if pc wait "$AGENT_ID" --timeout 30 >"$TMP/wait.out" 2>&1; then
  ok "agent settled after interrupt (did not wedge)"
else
  bad "paseo wait timed out/failed after interrupt — $(cat "$TMP/wait.out")"
fi

pc logs "$AGENT_ID" >"$TMP/timeline.txt" 2>&1
# "ALPHA" appears once already, quoted back in the "[User] ... word ALPHA"
# prompt line — that is not a reply. A second, standalone occurrence would be
# the interrupted turn's own reply arriving late; there must be none.
if grep -qi '^BRAVO$' "$TMP/timeline.txt" && [ "$(grep -ci 'alpha' "$TMP/timeline.txt")" -eq 1 ]; then
  ok "post-interrupt turn reached the model and replied; the interrupted turn's own reply never arrived"
else
  bad "timeline does not show a clean interrupt (expected a BRAVO reply, no ALPHA reply) — $(cat "$TMP/timeline.txt")"
fi

# --- 6. daemon restart: the same agy conversation resumes ---------------------
stop_daemon
wait_for_port down || die "daemon still listening 20s after 'paseo daemon stop'"

start_daemon "$TMP/daemon2.log"
wait_for_port up && ok "daemon restarted" || die "daemon never rebound after restart — $(tail -5 "$TMP/daemon2.log")"

if pc send "$AGENT_ID" 'reply with word CHARLIE' >"$TMP/send2.out" 2>&1; then
  ok "agent survives a daemon restart and keeps taking turns"
else
  bad "paseo send failed after daemon restart — $(cat "$TMP/send2.out")"
fi
pc logs "$AGENT_ID" 2>&1 | grep -qi 'CHARLIE' && ok "post-restart reply reached the transcript" \
  || bad "no CHARLIE in the timeline after daemon restart"

echo
echo "agy-acp-daemon: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
