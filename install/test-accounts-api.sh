#!/usr/bin/env bash
# Test bin/airlock-accounts-api: the platform account surface answers on loopback, in
# JSON, and never with a silent success.
#
# Offline and self-contained: a fake status CLI stands in for bin/airlock-accounts-status,
# the port is outside the platform's 199xx band, and nothing on the box is read or
# written. No installer runs and no unit is touched.
#
# What the controls are for. A surface that returns JSON on the one route it knows about
# still fails the contract if an unknown route or an unimplemented method leaks the
# stdlib's HTML error page — a caller doing r.json() on that gets a parse error and no
# reason. That defect was real and was found by running the server rather than reading it
# (T4/T5 below are the checks that would have caught it).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

TMP="$(mktemp -d)"
STATE_ROOT="$TMP/state"
mkdir -p "$STATE_ROOT"
PORT=29906           # outside 199xx: the platform's band is allocated in airlock-config
SRV_PID=""
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  wait "$SRV_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

fails=0
bad() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
ok() { printf 'ok: %s\n' "$*"; }

command -v curl >/dev/null || { echo "curl missing on this runner"; exit 1; }

# ---- a fake status CLI: prints progress, then JSON on the last line ----
# The real one does exactly this, which is why the server parses the LAST line.
# Executable with a shebang: the probe runs it as `python3 <path>` but the mutation verbs
# exec it directly, exactly as devterm's gate execs the account CLI. A fixture that only
# satisfies the first invocation shape tests half the surface.
cat > "$TMP/fake-status" <<'EOF'
#!/usr/bin/env python3
import json, sys
# The progress lines belong to the PROBE only. `login-url` prints the link and nothing
# else — the caller accepts it by `startswith("https://")`, exactly as devterm does, so a
# fixture that chattered here would have made a correct implementation look broken.
if "--codex" in sys.argv:
    # Local-only Codex identity — what the panel's Codex row paints from first.
    print(json.dumps({"state": "ok", "mode": "chatgpt", "email": "codex@example.test",
                      "plan": "pro", "accountId": "acct-1"}))
elif "list" in sys.argv or not sys.argv[1:]:
    print("checking pool...")
    print("refreshing...")
if "list" in sys.argv:
    # The account CLI's `list --json` shape. The parent decision pinned this vocabulary
    # deliberately ("keeping it unchanged is what makes this a re-homing"), so the
    # fixture speaks it rather than a convenient invention.
    print(json.dumps({"active": "someone@example.test",
                      "accounts": [{"email": "someone@example.test", "kind": "personal"}]}))
elif "login-url" in sys.argv:
    print("https://example.test/login?pkce=1")
elif "login-code" in sys.argv:
    # Mirror the real CLI's transport contract exactly (bin/airlock-accounts:
    # `login-code accepts protected stdin only; refusing argv input`, rc=2). A fixture
    # that took the code from argv is how the platform relay shipped that way unnoticed.
    if sys.argv[2:]:
        sys.stderr.write("airlock-accounts: login-code accepts protected stdin only; refusing argv input\n")
        sys.exit(2)
    if sys.stdin.isatty():
        sys.stderr.write("airlock-accounts: login-code requires protected stdin\n")
        sys.exit(2)
    pasted = sys.stdin.buffer.read(2048).decode("utf-8", "replace")
    if not pasted:
        sys.stderr.write("airlock-accounts: login-code stdin is empty or too large\n")
        sys.exit(2)
    if pasted.startswith("explode"):
        # The real token endpoint may reflect the submitted code in its error; a relay
        # that forwards CLI stderr would leak it. Echo it here so a test can prove the
        # response body does not carry it.
        sys.stderr.write("token exchange failed for code " + pasted + "\n")
        sys.exit(1)
    print("  registered 'someone@example.test (personal)' (first account -> active, installed as live)")
elif "swap" in sys.argv or "remove" in sys.argv:
    # Fail on a sentinel so the error path is exercised too; succeed otherwise.
    if "explode" in sys.argv:
        sys.stderr.write("the CLI said no, at length: " + "x" * 500 + "\n")
        sys.exit(1)
    print("done")
elif "codex-auth" in sys.argv:
    if "login-start" in sys.argv:
        # The CLI's own JSON is the ONLY thing that may cross back. This fixture also
        # emits codex-shaped noise on stderr so the test can prove it does not.
        sys.stderr.write("codex: device flow started, token=MUST-NOT-LEAK\n")
        print(json.dumps({"ok": True, "url": "https://auth.example/dev", "code": "CDX-77"}))
    elif "login-cancel" in sys.argv:
        print(json.dumps({"ok": True, "restored": True}))
    elif "shape-break" in sys.argv:
        print(json.dumps({"ok": True, "url": 12345, "code": None}))
    else:
        print(json.dumps({"ok": True}))
elif "--codex-usage" in sys.argv:
    print(json.dumps({"use7d": 42, "plan": "pro", "reset7d": 1234}))
elif "--usage" in sys.argv:
    slot = sys.argv[sys.argv.index("--usage") + 1]
    print(json.dumps({"enabled": True, "slot": slot}))
elif "--codex" not in sys.argv:
    print(json.dumps({"enabled": True, "active": "someone@example.test", "kind": "max"}))
EOF

start() {
  AIRLOCK_HUB_ACCOUNTS_PORT="$PORT" AIRLOCK_ACCOUNTS_STATUS_BIN="$1" \
    AIRLOCK_STATE_DIR="$STATE_ROOT" \
    AIRLOCK_ACCOUNTS_BIN="$1" \
    python3 "$ROOT/bin/airlock-accounts-api" >"$TMP/srv.log" 2>&1 &
  SRV_PID=$!
  for _ in $(seq 1 40); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/claude-status" && return 0
    sleep 0.25
  done
  return 1
}
stop() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null || true; SRV_PID=""; }

chmod 0755 "$TMP/fake-status"

start "$TMP/fake-status" || { bad "server did not come up: $(cat "$TMP/srv.log")"; exit 1; }

body() { curl -s "http://127.0.0.1:$PORT$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
ctype() { curl -s -D- -o /dev/null "$@" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2}'; }

# ---- T1: the one route it serves forwards the CLI's JSON ----
[ "$(body /claude-status)" = '{"enabled": true, "active": "someone@example.test", "kind": "max"}' ] \
  && ok "T1: /claude-status forwards the CLI's last JSON line" \
  || bad "T1: unexpected /claude-status body: $(body /claude-status)"

# ---- T2: it binds loopback only ----
# The owner guard is in nginx, so a wider bind would put this surface on the tailnet with
# no guard at all. Checked by asking the kernel, not by reading the source.
if command -v ss >/dev/null; then
  listen="$(ss -ltnH "sport = :$PORT" 2>/dev/null | awk '{print $4}')"
  case "$listen" in
    127.0.0.1:*) ok "T2: listening on loopback only ($listen)" ;;
    "") bad "T2: nothing is listening on :$PORT — cannot verify the bind" ;;
    *) bad "T2: bound to $listen, not 127.0.0.1 — that is this surface on the tailnet, unguarded" ;;
  esac
else
  bad "T2: ss(8) missing — the bind address is unverified rather than verified"
fi

# ---- T3: no-store, because a cached login state is a wrong one ----
curl -s -D- -o /dev/null "http://127.0.0.1:$PORT/claude-status" | tr -d '\r' \
  | grep -qi '^cache-control: no-cache, no-store, must-revalidate$' \
  && ok "T3: the answer is not cacheable" \
  || bad "T3: no no-store Cache-Control on /claude-status"

# ---- T4 (control): an unserved route is 404 JSON, never 200 and never HTML ----
# 🔴 Every account route has now moved, so the declaration file is empty and there is no
# "not yet ported" route left to point at. The control is RETIRED DELIBERATELY, which is
# what its own note asked for — and replaced rather than deleted, because what it was
# really guarding is still true: a path this surface does not serve must answer 404 with
# JSON, never 200 with something a caller would believe. A name that is definitionally
# absent keeps that guarantee without needing an example that goes stale.
UNSERVED=/definitely-not-a-route
c="$(code "http://127.0.0.1:$PORT$UNSERVED")"
t="$(ctype "http://127.0.0.1:$PORT$UNSERVED")"
[ "$c" = 404 ] || bad "T4: an unserved route answered $c — anything but 404 invites a consumer"
case "$t" in application/json*) ;; *) bad "T4: an unserved route answered Content-Type '$t' — HTML here is the silent-failure shape" ;; esac
body "$UNSERVED" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  || bad "T4: the 404 body is not JSON"
[ "$c" = 404 ] && case "$t" in application/json*) ok "T4: an unserved route is 404 with a JSON body" ;; esac

# ---- T5 (control): an unimplemented METHOD is JSON too ----
# This is the one that was actually broken: BaseHTTPRequestHandler answers an unknown
# method with its own HTML page, so every route could be JSON while PUT/HEAD were not.
t="$(ctype -X PUT "http://127.0.0.1:$PORT/claude-status")"
case "$t" in
  application/json*) ok "T5: an unimplemented method answers JSON, not the stdlib's HTML page" ;;
  *) bad "T5: PUT answered Content-Type '$t' — the stdlib HTML error page is leaking" ;;
esac
t="$(ctype -I "http://127.0.0.1:$PORT/claude-status")"
case "$t" in
  application/json*) ok "T5: HEAD answers JSON's content type" ;;
  *) bad "T5: HEAD answered Content-Type '$t'" ;;
esac

# ---- T5b: the two routes added in 5b-1 answer, and say which store state they are in ----
# The fixture has no fleet store configured, which is the common single-box case. "no
# store" and "no data" are different operator states and only one resolves by waiting:
# reporting the transient when no collector exists is what left seven rows "collecting"
# indefinitely on a real box.
acct="$(body /accounts)"
if printf '%s' "$acct" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("enabled") is True; assert d["thresholds"]["warn5"]; assert all(a["usage"]["err"]=="no store" for a in d["accounts"])' 2>/dev/null; then
  ok "T5b /accounts reports 'no store' when none is configured, with thresholds"
else
  bad "T5b /accounts payload wrong: $acct"
fi
[ "$(body /claude-usage-store)" = '{}' ] \
  && ok "T5b /claude-usage-store is an empty object when no store is configured" \
  || bad "T5b /claude-usage-store: $(body /claude-usage-store)"

# ---- T6: a POST to a mutation route that has not moved is 404, not a fake success ----
# Same retirement as T4, same reason: nothing is left unmoved. A POST to a path the
# surface does not implement must be a 404, not a silent 200 — that is the property
# worth keeping, and it does not need a real unported route to demonstrate it.
UNMOVED_POST=/definitely-not-a-post-route
c="$(code -X POST "http://127.0.0.1:$PORT$UNMOVED_POST")"
[ "$c" = 404 ] && ok "T6: an unmoved mutation route is 404, not a silent 200" \
  || bad "T6: POST $UNMOVED_POST answered $c"

# ---- T11 (§7 obligation): a cross-origin MUTATION is refused ----
# The identity header is injected by the ingress, not the browser, so a request that gets
# here already carries the owner's identity whichever page caused it. This guard is the
# only thing between another origin and a real account switch.
for route in /acct-switch /acct-remove /acct-login-url /acct-login-code /codex-logout; do
  c="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
        -H 'Origin: https://evil.example' -H 'Content-Type: application/json' \
        --data '{"name":"someone","code":"x"}' "http://127.0.0.1:$PORT$route")"
  [ "$c" = 403 ] || bad "T11: $route accepted a cross-origin POST ($c) — that is a CSRF into the account pool"
done
ok "T11: every mutation refuses a cross-origin POST"
# 🔴 The control on the control: a SAME-origin POST must still work, or the guard is just
# an outage. Origin is built from the Host the request actually carries.
c="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
      -H "Origin: http://127.0.0.1:$PORT" -H 'Content-Type: application/json' \
      --data '{"name":"someone"}' "http://127.0.0.1:$PORT/acct-switch")"
[ "$c" = 200 ] && ok "T11: a same-origin POST is still accepted" \
  || bad "T11: a same-origin POST answered $c — the guard refuses the panel itself"
# No Origin at all (curl, a unit, the terminal) is not a browser being aimed at us.
c="$(code -X POST -H 'Content-Type: application/json' --data '{"name":"someone"}' "http://127.0.0.1:$PORT/acct-switch")"
[ "$c" = 200 ] && ok "T11: a request with no Origin is accepted" \
  || bad "T11: a request with no Origin answered $c"

# ---- T12: slot names are identifiers, never paths ----
for bad_name in "../escape" "a/b" ".hidden" ""; do
  c="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
        --data "{\"name\":\"$bad_name\"}" "http://127.0.0.1:$PORT/acct-switch")"
  [ "$c" = 400 ] || bad "T12: /acct-switch accepted the slot name '$bad_name' ($c)"
done
ok "T12: a slot name containing a separator, a leading dot, or nothing is refused"

# ---- T13: a CLI refusal is reported, and its verbosity does not become the response ----
out="$(curl -s -X POST -H 'Content-Type: application/json' --data '{"name":"explode"}' \
        "http://127.0.0.1:$PORT/acct-switch")"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False; assert d["active"] is None; assert 0 < len(d["error"]) <= 200' 2>/dev/null \
  && ok "T13: a CLI refusal is reported with a truncated reason" \
  || bad "T13: unexpected refusal payload: $out"

# ---- T14: a login URL is only accepted from the CLI if it looks like one ----
out="$(curl -s -X POST "http://127.0.0.1:$PORT/acct-login-url")"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True; assert d["url"].startswith("https://")' 2>/dev/null \
  && ok "T14: /acct-login-url returns the issued link" \
  || bad "T14: unexpected login-url payload: $out"

# ---- T14b: a CLI that SUCCEEDS but does not print a link is still a refusal ----
# The check is `startswith("https://")`, not `returncode == 0`. A CLI that exits clean
# after printing a prompt, a warning, or an empty line would otherwise have that text
# handed to the browser as the account login link. Measured gap: without this case,
# dropping the startswith() entirely left every check green.
stop
cat > "$TMP/liar" <<'EOF'
#!/usr/bin/env python3
import sys
if "login-url" in sys.argv:
    print("Warning: no browser detected; open the link manually")
    sys.exit(0)
print("{}")
EOF
chmod 0755 "$TMP/liar"
start "$TMP/liar" || true
out="$(curl -s -X POST "http://127.0.0.1:$PORT/acct-login-url")"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False' 2>/dev/null \
  && ok "T14b: a clean exit that is not a link is refused, not forwarded as one" \
  || bad "T14b: a non-link was accepted as a login URL: $out"
stop
start "$TMP/fake-status" || true

# ---- T17: /claude-usage asks for ONE slot, and the slot comes from the query ----
# Asking for every account at once risks 429 when several boxes poll together, so the
# route is per-slot by design; a handler that ignored the query would look identical
# until the day two boxes polled at once.
[ "$(body '/claude-usage?slot=someone@example.test' | python3 -c 'import json,sys; print(json.load(sys.stdin)["slot"])')" = "someone@example.test" ] \
  && ok "T17: /claude-usage forwards the requested slot" \
  || bad "T17: slot not forwarded: $(body '/claude-usage?slot=someone@example.test')"
[ "$(body /claude-usage | python3 -c 'import json,sys; print(json.load(sys.stdin)["slot"])')" = live ] \
  && ok "T17: with no slot it asks for the live account" \
  || bad "T17: default slot wrong"

# ---- T18: Codex login start/cancel forward the CLI's JSON and nothing else ----
out="$(curl -s -X POST "http://127.0.0.1:$PORT/codex-login-start")"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True; assert d["url"]=="https://auth.example/dev"; assert d["code"]=="CDX-77"' 2>/dev/null \
  && ok "T18: /codex-login-start returns the CLI's url and code" \
  || bad "T18: unexpected login-start payload: $out"
# 🔴 The CLI's stderr carried a token-shaped string. It must not be in the response, and
# it must not be in this service's log either — that is the exfiltration path the gate's
# comment warns about, and the only way to test it is to make the fixture emit one.
printf '%s' "$out" | grep -q 'MUST-NOT-LEAK' \
  && bad "T18: the CLI's stderr reached the response" \
  || ok "T18: the CLI's stderr does not reach the response"
grep -q 'MUST-NOT-LEAK' "$TMP/srv.log" \
  && bad "T18: the CLI's stderr reached the service log" \
  || ok "T18: the CLI's stderr does not reach the service log"
out="$(curl -s -X POST "http://127.0.0.1:$PORT/codex-login-cancel")"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True; assert d["restored"] is True' 2>/dev/null \
  && ok "T18: /codex-login-cancel reports whether the previous login was restored" \
  || bad "T18: unexpected login-cancel payload: $out"

# ---- T19b: `restored` must be a bool, not merely present ----
# The panel words this value ("your previous login was put back" vs not). A CLI that
# emitted a string would otherwise reach the browser and be rendered as truthy.
stop
cat > "$TMP/badrestore" <<'EOF'
#!/usr/bin/env python3
import json, sys
print(json.dumps({"ok": True, "restored": "yes"}))
EOF
chmod 0755 "$TMP/badrestore"
start "$TMP/badrestore" || true
c="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/codex-login-cancel")"
[ "$c" = 400 ] && ok "T19b: a non-bool 'restored' is refused" \
  || bad "T19b: a non-bool 'restored' was accepted ($c)"

# ---- T19c: a CLI that FAILS is a failure, whatever it printed ----
# 🔴 The exit code and the payload are two separate claims. A tool that exits non-zero
# while printing a well-formed ok:true is failing; trusting the payload alone would let a
# crashed CLI's partial stdout become an answer. Measured gap: without this case,
# deleting the returncode check left every check green.
stop
cat > "$TMP/exitfail" <<'EOF'
#!/usr/bin/env python3
import json, sys
print(json.dumps({"ok": True, "url": "https://auth.example/dev", "code": "CDX-77"}))
sys.exit(3)
EOF
chmod 0755 "$TMP/exitfail"
start "$TMP/exitfail" || true
c="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/codex-login-start")"
[ "$c" = 400 ] && ok "T19c: a non-zero exit is a failure even with a well-formed payload" \
  || bad "T19c: a failing CLI's stdout was accepted as an answer ($c)"
stop
start "$TMP/fake-status" || true

# ---- T19: a CLI answering ok:true with the wrong SHAPE is refused ----
# `ok: true` is not the contract — the fields the panel prints are. A url that is a
# number would otherwise reach the browser as a login link.
stop
cat > "$TMP/shapebreak" <<'EOF'
#!/usr/bin/env python3
import json, sys
print(json.dumps({"ok": True, "url": 12345, "code": None}))
EOF
chmod 0755 "$TMP/shapebreak"
start "$TMP/shapebreak" || true
c="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/codex-login-start")"
[ "$c" = 400 ] && ok "T19: ok:true with a non-string url/code is refused" \
  || bad "T19: a malformed shape was accepted ($c)"
stop
start "$TMP/fake-status" || true

# ---- T20: /acct-alert grades, and reports the thresholds it graded with ----
a="$(body /acct-alert)"
printf '%s' "$a" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True; assert d["level"] in ("none","warn","crit"); assert d["thresholds"]["warn5"]' 2>/dev/null \
  && ok "T20: /acct-alert returns a grade and the thresholds behind it" \
  || bad "T20: unexpected acct-alert payload: $a"
# 🔴 The alert must NOT carry an identity. It is polled by the return widget from other
# apps' origins, so a login or email here would cross a boundary the panel does not.
printf '%s' "$a" | grep -qiE 'someone@example|"email"|"active"' \
  && bad "T20: an identity appears in the alert payload" \
  || ok "T20: no identity in the alert payload"

# ---- T21: /codex-usage answers from the remembered reading ----
c="$(body /codex-usage)"
printf '%s' "$c" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("use7d")==42 or d.get("pending") or d.get("err")' 2>/dev/null \
  && ok "T21: /codex-usage answers with a reading or an explicit pending state" \
  || bad "T21: unexpected codex-usage payload: $c"

# ---- T22: /acct-usage-now is a guarded write and returns the probe verbatim ----
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: https://evil.example' \
        "http://127.0.0.1:$PORT/acct-usage-now")"
[ "$code" = 403 ] && ok "T22: /acct-usage-now refuses a cross-origin POST" \
  || bad "T22: /acct-usage-now accepted a cross-origin POST ($code)"
u="$(curl -s -X POST "http://127.0.0.1:$PORT/acct-usage-now")"
printf '%s' "$u" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["slot"]=="live"' 2>/dev/null \
  && ok "T22: /acct-usage-now asks for the live account and forwards the probe" \
  || bad "T22: unexpected acct-usage-now payload: $u"

# ---- T23: the caches live under accounts/, not the platform state root ----
# The root holds the install ledger and its lock. This is the same placement mistake the
# xAI capture made once already.
for f in codex-usage.json claude-usage.json xai-login.out; do
  [ -e "$STATE_ROOT/$f" ] && bad "T23: $f was written to the platform state ROOT"
done
ok "T23: nothing is written beside the install ledger"

# ---- T7: a missing CLI is 'disabled', not an error ----
# A box may simply not have the account feature wired; the frontend words enabled:false.
stop
start "$TMP/does-not-exist" || { bad "T7: server did not come up with an absent CLI"; }
[ "$(body /claude-status)" = '{"enabled": false}' ] \
  && ok "T7: an absent status CLI reports enabled:false rather than a 500" \
  || bad "T7: absent CLI produced: $(body /claude-status)"

# ---- T8: a CLI that prints nothing usable is a 500, not an empty success ----
printf 'print("no json here")\n' > "$TMP/bad-status"
stop
start "$TMP/bad-status" || true
[ "$(code "http://127.0.0.1:$PORT/claude-status")" = 500 ] \
  && ok "T8: unparseable CLI output is a 500, not an empty 200" \
  || bad "T8: unparseable CLI output answered $(code "http://127.0.0.1:$PORT/claude-status")"

# ---- T9: the port is refused rather than defaulted ----
# A default in the service would be a second source of truth for a number
# bin/airlock-config validates for uniqueness against every app.
out="$(AIRLOCK_HUB_ACCOUNTS_PORT= python3 "$ROOT/bin/airlock-accounts-api" 2>&1 || true)"
grep -q 'AIRLOCK_HUB_ACCOUNTS_PORT is not set' <<<"$out" \
  && ok "T9: an unset port is refused by name" \
  || bad "T9: an unset port did not fail closed: $out"
out="$(AIRLOCK_HUB_ACCOUNTS_PORT=notanumber python3 "$ROOT/bin/airlock-accounts-api" 2>&1 || true)"
grep -q 'not a number' <<<"$out" \
  && ok "T9: a non-numeric port is refused" \
  || bad "T9: a non-numeric port did not fail closed: $out"

# ---- T10: credential-shaped strings never reach the log ----
# The CLI's stderr is dropped on purpose (it can carry account emails) and access
# logging is off. This asserts the outcome rather than the mechanism.
stop
cat > "$TMP/leaky-status" <<'EOF'
import json, sys
sys.stderr.write("sk-ant-SENTINELVALUE and a@example.test\n")
print(json.dumps({"enabled": True}))
EOF
start "$TMP/leaky-status" || true
body /claude-status >/dev/null
grep -q 'SENTINELVALUE' "$TMP/srv.log" \
  && bad "T10: the CLI's stderr reached this service's log" \
  || ok "T10: the CLI's stderr does not reach the service log"
grep -q 'claude-status' "$TMP/srv.log" \
  && bad "T10: request paths are being logged (they carry account names in a later step)" \
  || ok "T10: request paths are not logged"

# The cases below need the honest fixture up — earlier cases swap in liars and empties.
stop
start "$TMP/fake-status" || bad "T15/T16: could not restart the honest fixture: $(cat "$TMP/srv.log")"

# ---- T15: the approval code travels on stdin only, and never comes back out ----
# bin/airlock-accounts refuses argv (rc=2). The relay used to pass the code as an
# argument, so every login through the platform surface failed; the old fixture took
# argv and hid it. The fixture above now refuses argv exactly like the CLI does.
r="$(curl -s -X POST -H 'Content-Type: application/json' \
      -H "Origin: http://127.0.0.1:$PORT" --data '{"code":"abc123#state"}' \
      "http://127.0.0.1:$PORT/acct-login-code")"
[ "$r" = '{"ok": true, "msg": "registered"}' ] \
  && ok "T15: a pasted code reaches the CLI on stdin and registers" \
  || bad "T15: login-code via stdin answered: $r"
r="$(curl -s -X POST -H 'Content-Type: application/json' \
      -H "Origin: http://127.0.0.1:$PORT" --data '{"code":"explode-SECRETCODE#state"}' \
      "http://127.0.0.1:$PORT/acct-login-code")"
case "$r" in
  *SECRETCODE*) bad "T15: the error body reflected the submitted code: $r" ;;
  *) printf '%s' "$r" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False and d["error"] == "registration failed \u2014 request a new login link"' 2>/dev/null \
       && ok "T15: a failed exchange answers a fixed sentence, never the code" \
       || bad "T15: unexpected failure body: $r" ;;
esac
grep -q "SECRETCODE" "$TMP/srv.log" && bad "T15: the submitted code reached the service log" \
  || ok "T15: the submitted code is not in the service log either"
for bad_code in '{"code":"a b"}' '{"code":""}' '{}' "{\"code\":\"$(printf 'x%.0s' $(seq 1 401))\"}"; do
  r="$(curl -s -X POST -H 'Content-Type: application/json' -H "Origin: http://127.0.0.1:$PORT" \
        --data "$bad_code" "http://127.0.0.1:$PORT/acct-login-code")"
  [ "$r" = '{"ok": false, "error": "not a code"}' ] \
    || bad "T15: malformed code $bad_code was not refused before the CLI: $r"
done
ok "T15: whitespace, empty, missing and oversized codes are refused before the CLI"

# ---- T16: /codex-status is the local identity, GET and HEAD ----
r="$(body /codex-status)"
case "$r" in
  *'"email": "codex@example.test"'*)
    printf '%s' "$r" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert set(d) <= {"state","mode","email","plan","accountId","lastRefresh","reason"}, sorted(d)' 2>/dev/null \
      && ok "T16: /codex-status answers the local Codex identity and nothing outside the identity key set" \
      || bad "T16: /codex-status carries keys outside the identity set: $r" ;;
  *) bad "T16: /codex-status body: $r" ;;
esac
c="$(curl -s -o /dev/null -w '%{http_code}' -I "http://127.0.0.1:$PORT/codex-status")"
[ "$c" = 404 ] && ok "T16: /codex-status is GET-only — HEAD is a JSON 404, not a 200 that ignores the probe" || bad "T16: HEAD /codex-status answered $c"

if [ "$fails" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nall account surface checks passed\n'
