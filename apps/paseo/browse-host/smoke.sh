#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Smoke gate for the Paseo browse host sidecar (run as owner inside the box).
# Asserts: unit active, registered with the live daemon (hello in daemon.log),
# and a network-free executor round-trip against the installed Chromium
# (catches a Playwright build lacking ariaSnapshot mode:"ai").
# Exit 0 = PASS. Used by central-deploy as a ship-gate.
set -uo pipefail

INSTALL_DIR="$HOME/.local/share/paseo-browse-host"
SVC="airlock-paseo-browse-host.service"
CLIENT_ID="airlock-paseo-browse-host"
DAEMON_LOG="$HOME/.paseo/daemon.log"
fail=0

echo "== paseo browse-host smoke =="

# 1) unit active
if systemctl --user is-active --quiet "$SVC"; then echo "  ok  unit active"; else echo "FAIL  unit inactive"; fail=1; fi

# 2) registered with live daemon: recent hello from our clientId.
# Retry — after a restart the sidecar's WS connect+hello lands a moment later.
reg=0
for _ in 1 2 3 4 5 6 7 8; do
  # grep -c (not -q) reads all input so `tail` never takes SIGPIPE under pipefail.
  if [ -f "$DAEMON_LOG" ] && \
     [ "$(tail -1200 "$DAEMON_LOG" 2>/dev/null | grep -c "\"clientId\":\"$CLIENT_ID\".*Client connected via hello")" -gt 0 ]; then
    reg=1; break
  fi
  sleep 1
done
if [ "$reg" = 1 ]; then echo "  ok  registered (hello in daemon.log)"; else echo "FAIL  no hello from $CLIENT_ID in daemon.log"; fail=1; fi

# 3) executor round-trip against installed chromium (network-free)
if [ -d "$INSTALL_DIR/node_modules/playwright" ] && [ -f "$INSTALL_DIR/test/smoke.cjs" ]; then
  if ( cd "$INSTALL_DIR" && node -e 'if (!require("./src/commands.js").SUPPORTED_COMMANDS.includes("logs")) process.exit(1)' ); then
    echo "  ok  logs advertised"
  else
    echo "FAIL  logs not advertised"; fail=1
  fi
  if ( cd "$INSTALL_DIR" && node test/smoke.cjs ); then
    echo "  ok  executor round-trip"
  else
    echo "FAIL  executor round-trip"; fail=1
  fi
else
  echo "FAIL  install incomplete in $INSTALL_DIR (playwright/test)"; fail=1
fi

# 4) Level 2 live-view stream server listening on loopback 6768.
STREAM_PORT="${PASEO_BROWSE_STREAM_PORT:-6768}"
if ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:${STREAM_PORT}\b"; then
  echo "  ok  stream server listening (127.0.0.1:${STREAM_PORT})"
else
  echo "FAIL  stream server not listening on 127.0.0.1:${STREAM_PORT}"; fail=1
fi

# 5) Level 2 web-ui live-panel patch present (warn-only — additive, may be skipped
#    or drift on a version bump; agent browsing works regardless).
WEBUI_DIR="${PASEO_WEBUI_DIR:-}"
if [ -z "$WEBUI_DIR" ]; then
  # Prefer the paseo the running daemon uses (box may carry two installs).
  PBIN=""
  DPID="$(systemctl --user show -p MainPID --value airlock-paseo.service 2>/dev/null || true)"
  if [ -n "$DPID" ] && [ "$DPID" != "0" ] && [ -r "/proc/$DPID/cmdline" ]; then
    PBIN="$(tr '\0' '\n' < "/proc/$DPID/cmdline" | grep -m1 '/paseo$' || true)"
  fi
  [ -n "$PBIN" ] || PBIN="$(command -v paseo || true)"
  [ -n "$PBIN" ] && WEBUI_DIR="$(PBIN="$PBIN" node -e 'const p=require("path"),fs=require("fs");const b=fs.realpathSync(process.env.PBIN);const m="/@getpaseo/cli/";const i=b.indexOf(m);if(i<0)process.exit(1);console.log(p.join(b.slice(0,i+m.length-1),"node_modules/@getpaseo/server/dist/server/web-ui"))' 2>/dev/null || echo "")"
fi
BUNDLE_JS="$(ls "$WEBUI_DIR/_expo/static/js/web/"index-*.js 2>/dev/null | head -1)"
if [ -n "$BUNDLE_JS" ] && grep -qF 'dataSet:{paseoBrowserId:' "$BUNDLE_JS" 2>/dev/null; then
  echo "  ok  web-ui live-panel patch present"
elif [ -n "$BUNDLE_JS" ]; then
  echo "  warn  web-ui not patched (live panel off; agent browsing unaffected)"
else
  echo "  warn  web-ui bundle not located ($WEBUI_DIR) — skip patch check"
fi

if [ "$fail" = 0 ]; then echo "SMOKE PASS"; else echo "SMOKE FAIL"; fi
exit "$fail"
