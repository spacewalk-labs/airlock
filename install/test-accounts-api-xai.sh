#!/usr/bin/env bash
# The xAI half of the platform account surface, and its restart contract.
# Design: docs/design/account-surface-restart-contract.md
#
# Offline: a fake OpenCode binary and a fake status CLI, a scratch state directory, and a
# port outside the platform's 199xx band. Nothing on the box is read or written.
set -euo pipefail

export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368   # render-parity's pin gate; see siblings

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
PORT=29907
SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

fails=0
bad() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
ok() { printf 'ok: %s\n' "$*"; }
command -v curl >/dev/null || { echo "curl missing"; exit 1; }

STATE="$TMP/state"; mkdir -p "$STATE"
# The capture lives in the surface's own subdirectory, not the platform state root —
# the root holds the install ledger and its lock.
CAPTURE="$STATE/accounts/xai-login.out"
mkdir -p "$STATE/accounts"

# A fake OpenCode: prints the device URL and code the way the real one does, then sleeps
# so the child is still alive when the capture is read (the real flow polls a server).
cat > "$TMP/opencode" <<'EOF'
#!/usr/bin/env python3
import sys, time
if "logout" in sys.argv:
    sys.exit(0)
print("Open https://x.ai/device and enter code: ABCD-1234", flush=True)
time.sleep(60)
EOF
chmod 0755 "$TMP/opencode"

cat > "$TMP/status" <<'EOF'
#!/usr/bin/env python3
import json, sys
if "--xai" in sys.argv:
    # An older/custom probe: emits a token-shaped extra field on purpose.
    print(json.dumps({"state": "ok", "expires": 123, "accessToken": "MUST-NOT-LEAK"}))
else:
    print(json.dumps({"enabled": True}))
EOF
chmod 0755 "$TMP/status"

start() {
  AIRLOCK_HUB_ACCOUNTS_PORT="$PORT" AIRLOCK_ACCOUNTS_STATUS_BIN="$TMP/status" \
    AIRLOCK_ACCOUNTS_BIN="$TMP/status" AIRLOCK_OPENCODE_BIN="${1:-$TMP/opencode}" \
    AIRLOCK_STATE_DIR="$STATE" \
    python3 "$ROOT/bin/airlock-accounts-api" >"$TMP/srv.log" 2>&1 &
  SRV_PID=$!
  for _ in $(seq 1 40); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/xai-status" && return 0
    sleep 0.25
  done
  return 1
}
stop() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null || true; SRV_PID=""; }
body() { curl -s "http://127.0.0.1:$PORT$1"; }
post() { curl -s -X POST "http://127.0.0.1:$PORT$1"; }

# ---- T1: the allowlist holds against a probe that emits extra fields ----
start || { bad "server did not start: $(cat "$TMP/srv.log")"; exit 1; }
x="$(body /xai-status)"
printf '%s' "$x" | grep -q 'MUST-NOT-LEAK' \
  && bad "T1: the probe's extra field reached the response — the allowlist is a pass-through" \
  || ok "T1: a field the allowlist does not name is dropped"
printf '%s' "$x" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["state"]=="ok"; assert d["expires"]==123; assert d["loginState"]=="idle"' 2>/dev/null \
  && ok "T1: the named fields survive (the control on the control)" \
  || bad "T1: allowlist dropped fields it should keep: $x"

# ---- T2: startup with no stale capture reports idle and deletes nothing ----
[ -e "$CAPTURE" ] && bad "T2: a capture exists before any login"
[ "$(body /xai-status | python3 -c 'import json,sys; print(json.load(sys.stdin)["loginState"])')" = idle ] \
  && ok "T2: a clean start reports idle" || bad "T2: clean start is not idle"

# ---- T3: a stale capture at startup becomes `interrupted`, and is deleted ----
stop
printf 'Open https://x.ai/device and enter code: STALE-9999\n' > "$CAPTURE"
chmod 0600 "$CAPTURE"
start || bad "T3: server did not start with a stale capture"
[ -e "$CAPTURE" ] && bad "T3: the stale capture survived startup — a device code is still on disk" \
  || ok "T3: the stale capture is deleted before anything is served"
st="$(body /xai-status | python3 -c 'import json,sys; print(json.load(sys.stdin)["loginState"])')"
[ "$st" = interrupted ] \
  && ok "T3: the interrupted attempt is reported, not silently shown as idle" \
  || bad "T3: loginState after a stale capture was '$st', not interrupted"
# 🔴 Sticky, not one-shot. A second read must still say interrupted — the first draft
# cleared it on read and this suite's own readiness poll swallowed it, which is what a
# health check or a second tab would do to a person mid-login.
st2="$(body /xai-status | python3 -c 'import json,sys; print(json.load(sys.stdin)["loginState"])')"
[ "$st2" = interrupted ] && ok "T3: a second reader still sees interrupted (not one-shot)" \
  || bad "T3: interrupted was consumed by the first read (became '$st2')"
# It clears when a NEW attempt starts, because then the old news is superseded.
post /xai-login-start >/dev/null
st3="$(body /xai-status | python3 -c 'import json,sys; print(json.load(sys.stdin)["loginState"])')"
[ "$st3" = pending ] && ok "T3: a new attempt supersedes the interrupted notice" \
  || bad "T3: state after a new login start is '$st3'"
post /xai-login-cancel >/dev/null

# ---- T4: a login capture yields the device values and leaves nothing named on disk ----
out="$(post /xai-login-start)"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True; assert d["url"].startswith("https://x.ai/"); assert d["code"]=="ABCD-1234"' 2>/dev/null \
  && ok "T4: the device URL and code are captured and returned" \
  || bad "T4: unexpected login-start payload: $out"
[ -e "$CAPTURE" ] && bad "T4: the capture is still on disk after the values were read" \
  || ok "T4: the capture is unlinked as soon as the values are read"
[ "$(body /xai-status | python3 -c 'import json,sys; print(json.load(sys.stdin)["loginState"])')" = pending ] \
  && ok "T4: the running login reports pending" || bad "T4: a running login is not pending"

# ---- T5: cancel stops it ----
c="$(post /xai-login-cancel)"
printf '%s' "$c" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True; assert d["stopped"] is True' 2>/dev/null \
  && ok "T5: cancel reports that it stopped a running login" || bad "T5: cancel payload: $c"
[ "$(body /xai-status | python3 -c 'import json,sys; print(json.load(sys.stdin)["loginState"])')" = idle ] \
  && ok "T5: after cancel the state is idle" || bad "T5: state after cancel is not idle"

# ---- T6: mutations are same-origin guarded, like every other write here ----
for r in /xai-login-start /xai-login-cancel /xai-logout; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: https://evil.example' \
          "http://127.0.0.1:$PORT$r")"
  [ "$code" = 403 ] || bad "T6: $r accepted a cross-origin POST ($code)"
done
ok "T6: every xAI mutation refuses a cross-origin POST"

# ---- T7: the device code never reaches the service log ----
grep -q 'ABCD-1234\|STALE-9999' "$TMP/srv.log" \
  && bad "T7: a device code reached the service log" \
  || ok "T7: no device code in the service log"

# ---- T8 🔴 the contract's sharpest control: shutdown cancels xAI and NOT Codex ----
# A generic "clean up children on exit" passes every check above while silently taking
# away Codex's contract, which is that a device login SURVIVES a redeploy.
# 🔴 grep the FILE, never `printf "$var" | grep -q`. `grep -q` exits at the first match,
# the producer dies of SIGPIPE, and under `set -o pipefail` the pipeline status goes
# non-zero — so the check fails exactly when the string IS present. This repository
# already documents that trap in install/test-render-parity.sh's RAM pin gate; this suite
# reproduced it anyway.
#
# It was dormant until this step: the file was 41KB and fit in the 64KB pipe buffer, so
# printf finished before grep exited and no SIGPIPE happened. Porting the last three
# routes took it to 66KB and the check began failing whenever the string WAS found. A
# latent bug whose trigger is a file crossing a buffer size is not one anybody reviews
# into existence — which is the argument for not writing the shape at all.
SRC="$ROOT/bin/airlock-accounts-api"
grep -q '_cancel_xai_login()' "$SRC" \
  && ok "T8: shutdown cancels the xAI login" || bad "T8: shutdown does not cancel xAI"
if grep -qiE 'kill.*(all|every).*child|terminate_all|reap_all|for .* in .*children' "$SRC"; then
  bad "T8: something sweeps children generically — Codex's login must survive a redeploy"
else
  ok "T8: nothing sweeps children generically (Codex's login survives a redeploy)"
fi
grep -qE 'KillMode=process|Codex' "$SRC" \
  && ok "T8: the Codex exception is stated where the cancel happens" \
  || bad "T8: the shutdown cancel does not say why Codex is excluded"

if [ "$fails" -gt 0 ]; then printf '\n%d check(s) failed\n' "$fails" >&2; exit 1; fi
printf '\nall xAI surface checks passed\n'
