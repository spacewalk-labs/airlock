#!/usr/bin/env bash
# install/test-subscription-management.sh — verdicts for the subscription-accounts
# campaign (docs/tasks/active/subscription-accounts.md): muse-usage · agy-swap · popup-6.
#
# agy-swap owns the AGY_SWAP gate card: ① RED (2026-09-23, agy 1.2.8) —
# agy offers no non-interactive credential acquisition, so the campaign's agy goal
# is read-only + manual login guidance and no switch UI may be opened. This case
# guards that verdict: it passes while RED holds and fails the moment an agy
# login/switch path appears, so a human re-measures before any UI is opened.
# Live credentials are never read here — presence checks are stat-only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
rev="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
pass=0; fail=0
ok()  { echo "ok   subscription-management: $1"; pass=$((pass+1)); }
bad() { echo "FAIL subscription-management: $1"; fail=$((fail+1)); }

agy_swap() {
  local agy_bin help_text sub
  agy_bin="$(command -v agy || true)"
  if [ -z "$agy_bin" ]; then
    ok "agy-swap: no agy on this box — panel hides the section, nothing to switch"
    return
  fi
  # ①-a: no auth/login credential path anywhere in the CLI surface.
  help_text="$("$agy_bin" --help 2>&1)"
  for sub in agent agents models mcp plugin plugins install update remote-control changelog mic-serve; do
    help_text="$help_text
$("$agy_bin" "$sub" --help 2>&1)"
  done
  if printf '%s\n' "$help_text" | grep -qiE 'auth|login'; then
    bad "agy-swap: agy help now mentions auth/login — ① must be re-measured before any switch UI"
  else
    ok "agy-swap: agy CLI surface has no auth/login path (① RED holds)"
  fi
  # ①-b: the accounts API exposes agy read-only — /agy-usage and nothing else.
  local routes
  routes="$(grep -oE '"/agy-[a-z-]*"' "$ROOT/bin/airlock-accounts-api" | sort -u)"
  if [ "$routes" = '"/agy-usage"' ]; then
    ok "agy-swap: accounts API exposes only /agy-usage"
  else
    bad "agy-swap: unexpected agy routes in accounts API: $routes"
  fi
  # ①-c: the panel's agy section carries manual-login guidance, not a switch UI.
  if grep -q 'Manual login only' "$ROOT/hub/assets/accounts/accounts.js"; then
    ok "agy-swap: panel agy section carries manual-login guidance"
  else
    bad "agy-swap: panel agy section lost its manual-login guidance"
  fi
  if grep -qE 'agy-(switch|login|logout)' "$ROOT/hub/assets/accounts/accounts.js" \
    || grep -qE '"/agy-(switch|login|logout)"' "$ROOT/bin/airlock-accounts-api"; then
    bad "agy-swap: an agy switch/login path exists — ① must be re-measured first"
  else
    ok "agy-swap: no agy switch/login path in panel or API"
  fi
  # ①-d: live A is still on disk (presence only — values are never read).
  if [ -f "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" ]; then
    ok "agy-swap: live agy credential still present (untouched, presence only)"
  else
    bad "agy-swap: live agy credential missing — box state changed, re-measure"
  fi
}

API_SOURCE="${AIRLOCK_ACCOUNTS_API_SOURCE:-$ROOT/bin/airlock-accounts-api}"

# ================= muse-usage (owner: MUSE_USAGE) =================
# GET /muse-usage reads GET <zen>/go/v1/usage with each vault key and answers
# one uniform entry per key:
#   {provider, account, limits:[{window, percent, resetAt}], observedAt, err}
# A key that cannot be read is "확인 불가" — it carries err, an empty limits
# list, and never a fabricated 0%. MUSE_ROTATE treats err != null as inactive
# in the replacement picker. Reads happen per request; there is no background
# poll (2026-09-20 owner decision).
muse_usage() {

TMP="$(mktemp -d)"
STATE_ROOT="$TMP/state"
mkdir -p "$STATE_ROOT"
PORT=29907           # outside 199xx: the platform's band is allocated in airlock-config
SRV_PID=""
ZEN_PID=""
CATCHER_PID=""
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  wait "$SRV_PID" 2>/dev/null || true
  [ -n "$ZEN_PID" ] && kill "$ZEN_PID" 2>/dev/null
  wait "$ZEN_PID" 2>/dev/null || true
  [ -n "$CATCHER_PID" ] && kill "$CATCHER_PID" 2>/dev/null
  wait "$CATCHER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

mu_fails=0
mu_bad() { printf 'FAIL: %s\n' "$*" >&2; mu_fails=$((mu_fails + 1)); }
mu_ok() { printf 'ok: %s\n' "$*"; }

command -v curl >/dev/null || { echo "curl missing on this runner"; return 1; }

# ---- fixture vault keys: real item names, sentinel values ----
# The values must never reach a response body or the service log. Every value
# carries a SENTINEL marker so the leak controls below can prove their absence
# by name rather than by hoping.
cat > "$TMP/fake-muse-keys" <<'EOF'
#!/usr/bin/env python3
import json
print(json.dumps({
    "OPENCODE_APPS_API_KEY": "SENTINEL-APPS-KEY-VALUE",
    "OPENCODE_FINANCE_API_KEY": "SENTINEL-FINANCE-KEY-VALUE",
    "OPENCODE_I_API_KEY": "SENTINEL-I-KEY-VALUE",
    "OPENCODE_FIELD_API_KEY": "SENTINEL-FIELD-KEY-VALUE",
    "OPENCODE_SWKDEV2026_API_KEY": "SENTINEL-SWKDEV2026-KEY-VALUE",
    "OPENCODE_CHO_API_KEY": "SENTINEL-CHO-KEY-VALUE",
    "OPENCODE_DEAD_API_KEY": "SENTINEL-DEAD-KEY-VALUE",
    "OPENCODE_BADVAL_API_KEY": None,
    "OPENCODE_TAIL_API_KEY": "SENTINEL-TAIL-KEY-VALUE",
}))
EOF
chmod 0755 "$TMP/fake-muse-keys"

# ---- fixture zen: canned usage per key, one key refused, one malformed ----
# ZEN_PORT and CATCHER_PORT arrive on argv so the redirect target is exact.
cat > "$TMP/fake-zen.py" <<'EOF'
#!/usr/bin/env python3
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys

ZEN_PORT = int(sys.argv[1])
CATCHER_PORT = int(sys.argv[2])

GOOD = {"status": "mu_ok", "percent": 12, "resetsAt": "2026-09-28T00:00:00.000Z"}
LIMITED = {"status": "rate-limited", "percent": 100, "resetsAt": "2026-09-23T05:00:00.000Z"}

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/zen/go/v1/usage":
            self.send_response(404); self.end_headers(); return
        # Negative control: the real endpoint's WAF answers the stdlib default
        # UA with 403. A fetch that does not set a UA would pass every other
        # check here and misclassify all six keys in production.
        if (self.headers.get("User-Agent", "") or "").startswith("Python-urllib"):
            self.send_response(403)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"blocked client"}')
            return
        auth = self.headers.get("Authorization", "")
        if auth == "Bearer SENTINEL-TAIL-KEY-VALUE":
            # A redirect must never be followed with the credential: the catcher
            # on CATCHER_PORT records whatever arrives, and T-MU6 proves it saw
            # no Authorization at all.
            self.send_response(302)
            self.send_header("Location",
                             "http://127.0.0.1:%s/steal" % CATCHER_PORT)
            self.end_headers()
            return
        if auth == "Bearer SENTINEL-DEAD-KEY-VALUE":
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"mu_bad key"}')
            return
        if auth == "Bearer SENTINEL-CHO-KEY-VALUE":
            body = b'{"usage": {"rolling": {"status": "mu_ok"}}}'
        elif auth == "Bearer SENTINEL-FINANCE-KEY-VALUE":
            body = json.dumps({"usage": {"rolling": LIMITED, "weekly": dict(GOOD),
                                         "monthly": dict(GOOD)}}).encode()
        elif auth.startswith("Bearer SENTINEL-"):
            body = json.dumps({"usage": {"rolling": dict(GOOD), "weekly": dict(GOOD),
                                         "monthly": dict(GOOD)}}).encode()
        else:
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"mu_bad key"}')
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

ThreadingHTTPServer(("127.0.0.1", ZEN_PORT), H).serve_forever()
EOF
# ---- redirect catcher: records every header of whatever follows a redirect ----
cat > "$TMP/catcher.py" <<'EOF'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys

class C(BaseHTTPRequestHandler):
    def _rec(self):
        with open(sys.argv[2], "a") as f:
            f.write("%s %s\n" % (self.command, self.path))
            for k, v in self.headers.items():
                f.write("%s: %s\n" % (k, v))
            f.write("---\n")
        self.send_response(200); self.end_headers()
    do_GET = _rec
    do_POST = _rec
    def log_message(self, *a):
        pass

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), C).serve_forever()
EOF
ZEN_PORT=29908
CATCHER_PORT=29910
: > "$TMP/catcher.log"
python3 "$TMP/catcher.py" "$CATCHER_PORT" "$TMP/catcher.log" 2>/dev/null &
CATCHER_PID=$!
python3 "$TMP/fake-zen.py" "$ZEN_PORT" "$CATCHER_PORT" 2>"$TMP/zen.log" &
ZEN_PID=$!
for _ in $(seq 1 40); do
  curl -s -o /dev/null "http://127.0.0.1:$ZEN_PORT/zen/go/v1/usage" && break
  sleep 0.25
done
curl -s -o /dev/null "http://127.0.0.1:$CATCHER_PORT/" || true

start() {
  AIRLOCK_HUB_ACCOUNTS_PORT="$PORT" AIRLOCK_ACCOUNTS_STATUS_BIN="$TMP/does-not-exist" \
    AIRLOCK_STATE_DIR="$STATE_ROOT" \
    AIRLOCK_ACCOUNTS_BIN="$TMP/does-not-exist" \
    AIRLOCK_MUSE_KEYS_BIN="$1" \
    AIRLOCK_MUSE_USAGE_URL="http://127.0.0.1:$ZEN_PORT" \
    python3 "$API_SOURCE" >"$TMP/srv.log" 2>&1 &
  SRV_PID=$!
  for _ in $(seq 1 40); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/claude-status" && return 0
    sleep 0.25
  done
  return 1
}
stop() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null || true; SRV_PID=""; }

body() { curl -s --max-time 60 "http://127.0.0.1:$PORT$1"; }

# ---- T-MU0: no keys helper is disabled, not an error ----
start "$TMP/does-not-exist" || { mu_bad "T-MU0: server did not come up: $(cat "$TMP/srv.log")"; return 1; }
[ "$(body /muse-usage)" = '{"enabled": false, "entries": []}' ] \
  && mu_ok "T-MU0: without a keys helper /muse-usage is disabled, not a 500" \
  || mu_bad "T-MU0: unexpected body: $(body /muse-usage)"
stop

start "$TMP/fake-muse-keys" || { mu_bad "server did not come up with fixture keys: $(cat "$TMP/srv.log")"; return 1; }
MUSE="$(body /muse-usage)"

# ---- T-MU1: every good key answers all three windows ----
printf '%s' "$MUSE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d.get("enabled") is True, d
by = {e["account"]: e for e in d["entries"]}
for name in ("apps", "finance", "i", "field", "swkdev2026"):
    e = by[name]
    assert e["provider"] == "muse", e
    assert e["err"] is None, e
    assert [w["window"] for w in e["limits"]] == ["rolling", "weekly", "monthly"], e
    assert all(isinstance(w["percent"], int) and 0 <= w["percent"] <= 100 for w in e["limits"]), e
    assert all(isinstance(w["resetAt"], str) and w["resetAt"] for w in e["limits"]), e
    assert isinstance(e["observedAt"], int), e
' 2>/dev/null \
  && mu_ok "T-MU1: five good keys each answer rolling/weekly/monthly numbers" \
  || mu_bad "T-MU1: unexpected payload: $MUSE"

# ---- T-MU2: rate-limited is read through, not rewritten ----
printf '%s' "$MUSE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
by = {e["account"]: e for e in d["entries"]}
e = by["finance"]
assert e["err"] is None, e
assert e["limits"][0] == {"window": "rolling", "percent": 100, "resetAt": "2026-09-23T05:00:00.000Z"}, e
' 2>/dev/null \
  && mu_ok "T-MU2: a rate-limited window keeps its status and percent" \
  || mu_bad "T-MU2: rate-limited misclassified: $MUSE"

# ---- T-MU3: an unreadable key is 확인 불가 — never a fabricated 0% ----
printf '%s' "$MUSE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
by = {e["account"]: e for e in d["entries"]}
dead = by.get("dead", by.get("OPENCODE_DEAD_API_KEY"))
assert dead is not None, d
assert dead["limits"] == [], dead
assert isinstance(dead["err"], str) and dead["err"], dead
assert "percent" not in json.dumps(dead), dead
cho = by["cho"]
assert cho["limits"] == [] and isinstance(cho["err"], str) and cho["err"], cho
# An item the helper names but cannot supply a usable value for is still an
# entry — it must not silently disappear from the list the picker reads.
badval = by["badval"]
assert badval["limits"] == [] and isinstance(badval["err"], str) and badval["err"], badval
' 2>/dev/null \
  && mu_ok "T-MU3: refused, malformed and valueless keys carry err with empty limits, never 0%" \
  || mu_bad "T-MU3: failure misclassified as a number or dropped: $MUSE"

# ---- T-MU4: fixture key values reach neither the response nor the log ----
printf '%s' "$MUSE" | grep -q 'SENTINEL-' \
  && mu_bad "T-MU4: a key value reached the /muse-usage response" \
  || mu_ok "T-MU4: no key value in the /muse-usage response"
grep -q 'SENTINEL-' "$TMP/srv.log" \
  && mu_bad "T-MU4: a key value reached the service log" \
  || mu_ok "T-MU4: no key value in the service log"

# ---- T-MU5: the answer is not cacheable ----
curl -s -D- -o /dev/null "http://127.0.0.1:$PORT/muse-usage" | tr -d '\r' \
  | grep -qi '^cache-control: no-cache, no-store, must-revalidate$' \
  && mu_ok "T-MU5: the answer is not cacheable" \
  || mu_bad "T-MU5: no no-store Cache-Control on /muse-usage"

# ---- T-MU6: a redirect is refused, and the credential never follows it ----
printf '%s' "$MUSE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
by = {e["account"]: e for e in d["entries"]}
tail = by["tail"]
assert tail["limits"] == [] and isinstance(tail["err"], str) and tail["err"], tail
' 2>/dev/null \
  && mu_ok "T-MU6: a redirected key is an err entry, not a followed read" \
  || mu_bad "T-MU6: a redirect was followed or misclassified: $MUSE"
grep -q 'SENTINEL-TAIL' "$TMP/catcher.log" \
  && mu_bad "T-MU6: the credential reached the redirect target" \
  || mu_ok "T-MU6: no credential reached the redirect target"

# ---- T-MU7: the vault helper maps discovered items, nothing else ----
# Fake readers speak the same argv contract as the real ones (list/get,
# read <ref>); the helper under test is the repository file, run with an
# explicit interpreter exactly like the service runs it.
cat > "$TMP/fake-secret" <<'EOF'
#!/bin/sh
if [ "$1" = list ]; then
  printf '# fixture vault: 3 items\nOPENCODE_MU_A_API_KEY\nNOT_A_KEY\nOPENCODE_MU_C_API_KEY\n'
elif [ "$1" = get ]; then
  printf 'SENTINEL-MU-%s-VALUE' "$2"
fi
EOF
chmod 0755 "$TMP/fake-secret"
cat > "$TMP/fake-cho" <<'EOF'
#!/bin/sh
if [ "$1" = read ]; then
  printf 'SENTINEL-MU-CHO-VALUE'
fi
EOF
chmod 0755 "$TMP/fake-cho"
HELPER_OUT="$(AIRLOCK_MUSE_SECRET_BIN="$TMP/fake-secret" \
  AIRLOCK_MUSE_CHO_BIN="$TMP/fake-cho" \
  AIRLOCK_MUSE_CHO_REF='op://fixture-vault/OPENCODE_MU_B_API_KEY/password' \
  python3 "$ROOT/bin/airlock-muse-keys" 2>"$TMP/helper.err")"
printf '%s' "$HELPER_OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d == {"OPENCODE_MU_A_API_KEY": "SENTINEL-MU-OPENCODE_MU_A_API_KEY-VALUE",
             "OPENCODE_MU_C_API_KEY": "SENTINEL-MU-OPENCODE_MU_C_API_KEY-VALUE",
             "OPENCODE_MU_B_API_KEY": "SENTINEL-MU-CHO-VALUE"}, d
' 2>/dev/null \
  && mu_ok "T-MU7: the helper maps discovered items and the brokered ref" \
  || mu_bad "T-MU7: unexpected helper map: $HELPER_OUT"
[ -s "$TMP/helper.err" ] \
  && mu_bad "T-MU7: the helper spoke on stderr" \
  || mu_ok "T-MU7: the helper is silent on stderr"
# A misaddressed brokered ref must not smuggle an arbitrary item into the map.
HELPER_OUT2="$(AIRLOCK_MUSE_SECRET_BIN="$TMP/fake-secret" \
  AIRLOCK_MUSE_CHO_BIN="$TMP/fake-cho" \
  AIRLOCK_MUSE_CHO_REF='op://fixture-vault/NOT_A_KEY/password' \
  python3 "$ROOT/bin/airlock-muse-keys" 2>/dev/null)"
printf '%s' "$HELPER_OUT2" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "NOT_A_KEY" not in d and len(d) == 2, d
' 2>/dev/null \
  && mu_ok "T-MU7: a non-key ref is refused, not mapped" \
  || mu_bad "T-MU7: misaddressed ref leaked into the map: $HELPER_OUT2"

if [ "$mu_fails" -gt 0 ]; then
  printf '\n%d muse-usage check(s) failed\n' "$mu_fails" >&2
  return 1
fi
printf '\nall muse-usage checks passed\n'
}

popup_6() {
node --check "$ROOT/hub/assets/accounts/accounts.js" \
  || { echo "FAIL accounts.js is not parseable JS"; exit 1; }

node - "$ROOT/hub/assets/accounts/accounts.js" "$rev" <<'NODE'
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const srcFile = process.argv[2], rev = process.argv[3];
const src = fs.readFileSync(srcFile, 'utf8');

let pass = 0, fail = 0;
const AC = [];
function ok(name, ac, expected, observed) {
  pass++;
  console.log('ok   ' + name);
  AC.push({ ac, expected, observed, verdict: 'PASS' });
}
function bad(name, ac, expected, observed) {
  fail++;
  console.log('FAIL ' + name);
  AC.push({ ac, expected, observed, verdict: 'FAIL' });
}

// ---------- 가짜 DOM ----------
function queryAll(root, sel, out) {
  out = out || [];
  const isClass = sel[0] === '.';
  const tok = isClass ? sel.slice(1) : sel.toUpperCase();
  (function walk(n) {
    if (n !== root) {
      const hit = isClass ? (n.className || '').split(/\s+/).includes(tok) : n.tagName === tok;
      if (hit) out.push(n);
    }
    (n.children || []).forEach(walk);
  })(root);
  return out;
}
function queryFirst(root, sel) { return queryAll(root, sel)[0] || null; }
function makeEl(tag) {
  const el = {
    tagName: String(tag || 'div').toUpperCase(), children: [], parent: null,
    className: '', _text: '', style: {}, dataset: {}, title: '', href: '',
    target: '', rel: '', disabled: false, value: '', placeholder: '',
    type: '', autocomplete: '', spellcheck: false, width: 0, height: 0,
    _listeners: {}, onclick: null, offsetHeight: 50, offsetWidth: 300,
    appendChild(c) { c.parent = el; el.children.push(c); return c; },
    remove() { if (el.parent) { el.parent.children = el.parent.children.filter(x => x !== el); el.parent = null; } },
    addEventListener(t, f) { (el._listeners[t] = el._listeners[t] || []).push(f); },
    querySelector(s) { return queryFirst(el, s); },
    querySelectorAll(s) { return queryAll(el, s); },
    getBoundingClientRect() { return { bottom: 100, top: 50, right: 300, left: 0, width: 300, height: 50 }; },
    focus() {},
  };
  Object.defineProperty(el, 'textContent', {
    get() { return el._text + el.children.map(c => c.textContent).join(''); },
    set(v) { el._text = String(v); el.children = []; },
  });
  Object.defineProperty(el, 'innerHTML', {
    get() { return el._text; },
    set(v) { el._text = String(v); el.children = []; },
  });
  return el;
}
function fire(el, type, ev) {
  const e = Object.assign({ preventDefault() {}, stopPropagation() {}, target: el }, ev || {});
  if (type === 'click' && typeof el.onclick === 'function') el.onclick(e);
  (el._listeners[type] || []).forEach(f => f(e));
}
function textOf(root) { return root.textContent; }
function btnByText(root, sub) {
  return queryAll(root, 'button').find(b => textOf(b).includes(sub)) || null;
}

// ---------- fixture 응답 ----------
const TH = { warn5: 60, crit5: 90, warn7: 60, crit7: 90, rtWarnDays: 5 };
const FIX = {
  'accounts': {
    enabled: true, thresholds: TH,
    accounts: [
      { name: 'a1', email: 'me@example.test', kind: 'personal', sub: 'Max', active: true,
        usage: { use5h: 4, use7d: 22, reset5h: '2026-09-23T05:20:00Z', reset7d: '2026-09-28T05:20:00Z' },
        rtExpiry: Date.now() + 28 * 86400000, holders: [] },
      { name: 'a2', email: 'team@example.test', kind: 'team', sub: 'Max', active: false,
        usage: {}, rtExpiry: Date.now() + 11 * 86400000, holders: [] },
      { name: 'a3', email: 'gone@example.test', kind: 'personal', sub: 'Max', active: false,
        health: { state: 'dead', reason: '로그인 만료' }, usage: {},
        rtExpiry: null, holders: [] },
    ],
  },
  'acct-usage-now': { email: 'me@example.test', kind: 'personal',
    usage: { use5h: 4, use7d: 22, reset5h: '2026-09-23T05:20:00Z', reset7d: '2026-09-28T05:20:00Z' } },
  'codex-status': { state: 'none' },
  'codex-usage': null,                       // 로그인 없음 → 호출되지 않아야 한다
  // xAI 섹션 제거 (POPUP_SHELL 재작업): 셸이 xai-* 를 호출하면 실패로 —
  // 백엔드 라우트는 살아 있으나 팝업이 다시 폴링하는 일이 없어야 한다.
  'agy-usage': { enabled: true, account: 'me@example.test', age: 30, refreshing: false,
    groups: [{ name: 'GEMINI MODELS', fiveHourRemaining: 69, weeklyRemaining: 82,
      fiveHourResetAt: 1758600000, weeklyResetAt: 1759000000 }] },
  'muse-swap-candidates': { enabled: true, box: 'test-box', active: 'apps', choVisible: false,
    sheet: 'ok', candidates: [
      { account: 'apps', item: 'OPENCODE_APPS_API_KEY', eligible: true, err: null,
        limits: [{ window: 'rolling', percent: 12 }, { window: 'weekly', percent: 12 },
                 { window: 'monthly', percent: 12 }] },
      { account: 'finance', item: 'OPENCODE_FINANCE_API_KEY', eligible: true, err: null,
        limits: [{ window: 'rolling', percent: 34 }, { window: 'weekly', percent: 34 },
                 { window: 'monthly', percent: 34 }] },
    ] },
  'acct-alert': { level: 'ok', thresholds: TH },
  'claude-status': { codex: { state: 'none' } },
  'acct-login-url': { ok: true, url: 'https://claude.ai/approve-mock' },
  'acct-login-code': { ok: true, msg: '등록됐습니다' },
  'acct-switch': { ok: true },
  'acct-remove': { ok: true },
  'codex-login-start': { ok: true, code: 'KXPD-7QMB', url: 'https://chatgpt.com/auth-mock' },
  'codex-login-cancel': { ok: true, restored: true },
  'codex-logout': { ok: true },
};
const calls = [];
function route(url, body) {
  const key = Object.keys(FIX).find(k => url.endsWith(k));
  calls.push(key || url);
  if (key === 'codex-usage') throw new Error('codex-usage must not be called while logged out');
  if (/xai-status|xai-login|xai-logout/.test(url)) throw new Error('xai route must not be called: xAI section removed from popup');
  const v = key ? FIX[key] : { ok: false, error: 'no route' };
  if (v instanceof Error) throw v;
  if (v === null) throw new Error('no fixture for ' + url);
  return v;
}

const errorLog = [];
function sandbox() {
  const doc = {
    createElement: t => makeEl(t),
    querySelectorAll: () => [],
    body: makeEl('body'),
  };
  doc.body.contains = function (n) {
    let x = n;
    while (x) { if (x === doc.body) return true; x = x.parent; }
    return false;
  };
  const ctx = {
    console: { log() {}, warn() {}, error(...a) { errorLog.push(a.join(' ')); } },
    document: doc,
    window: {},
    navigator: {},
    location: { pathname: '/' },
    fetch: (url) => new Promise((res, rej) => {
      setTimeout(() => {
        try { res({ json: () => Promise.resolve(route(String(url))) }); }
        catch (e) { rej(e); }
      }, 0);
    }),
    setTimeout, clearTimeout,
    setInterval: () => 0, clearInterval: () => {},   // 아이콘 감시는 테스트에서 돌리지 않는다
  };
  ctx.window.console = ctx.console;
  ctx.window.confirm = () => true;
  ctx.window.navigator = ctx.navigator;
  ctx.window.location = ctx.location;
  ctx.__deps = {
    flash() {},
    postJson: (path, body) => ctx.fetch(path, {}).then(r => r.json()),
    mkFocus() {}, closeTabPops() {}, placePop() {},
  };
  vm.createContext(ctx);
  vm.runInContext(src + '\nthis.__acct = window.initAccounts(this.__deps);', ctx);
  return { ctx, doc, api: ctx.__acct };
}
function postJson(ctx) {
  return (path, body) => ctx.fetch(path, {}).then(r => r.json());
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function drain(n) { for (let i = 0; i < (n || 12); i++) await sleep(25); }

(async () => {
  // ---------- P1: 접힘 + 헤더 한 줄 (4섹션: xAI 제거) ----------
  {
    const { ctx, doc, api } = sandbox();
    const host = doc.createElement('div'); doc.body.appendChild(host);
    api.renderAcctPanel(host);
    await drain();
    const secs = queryAll(host, '.sec');
    const bodies = queryAll(host, '.sec-body').filter(b => b.style.display !== 'none');
    const heads = queryAll(host, '.sec-head').map(textOf);
    // 5 -> 4 sections with the POPUP_SHELL rework (사람 결정 9dac31a6 팝업에서
    // 제거): xAI is gone, not passing — assert its absence outright. Muse keeps
    // its header as current-key-only (사람 결정 5a5e34fe 후보 숨기기): no 교체 count.
    const cond = secs.length === 4 && bodies.length === 1 &&
      heads.some(h => h.includes('Claude') && h.includes('me@example') && h.includes('%')) &&
      heads.some(h => h.includes('Codex')) &&
      heads.some(h => h.includes('Gemini') || h.includes('agy')) &&
      heads.some(h => h.includes('Muse') && h.includes('apps') && h.includes('사용 중') && !h.includes('교체')) &&
      !heads.some(h => /xai/i.test(h));
    const observed = `sec=${secs.length},open=${bodies.length},heads=[${heads.map(h => JSON.stringify(h.slice(0, 40))).join('|')}]`;
    if (cond) ok('P1 네 섹션 접힘 + 헤더 한 줄(누구·얼마·리셋, xAI 없음·Muse 현재 키만)', 'AC-SUB-POPUP-1',
      'sec==4 && open==1(Claude) && 각 헤더에 제공자+누구+잔여 && xAI 헤더 없음 && Muse 헤더에 교체 없음', observed);
    else bad('P1 네 섹션 접힘 + 헤더 한 줄(누구·얼마·리셋, xAI 없음·Muse 현재 키만)', 'AC-SUB-POPUP-1',
      'sec==4 && open==1(Claude) && 각 헤더에 제공자+누구+잔여 && xAI 헤더 없음 && Muse 헤더에 교체 없음', observed);
  }

  // ---------- P1b: Muse 섹션은 현재 키만 (후보 목록·교체 버튼 없음) ----------
  {
    const { ctx, doc, api } = sandbox();
    const host = doc.createElement('div'); doc.body.appendChild(host);
    api.renderAcctPanel(host);
    await drain();
    // fixture offers apps(active) + finance(eligible): the old shell rendered a
    // 교체 button for finance. Open the Muse section and prove it is gone.
    // calls[] is shared across blocks, so only calls made in this block count;
    // the candidates GET (numbers stay) is fine, a swap POST is not.
    const n0 = calls.length;
    const museHead = queryAll(host, '.sec-head').find(h => textOf(h).includes('Muse'));
    let cond = false, note = '';
    if (!museHead) { note = 'no muse head;'; }
    else {
      fire(museHead, 'click'); await drain(4);
      const museSec = queryAll(host, '.sec').find(s => {
        const h = queryFirst(s, '.sec-head');
        return h && textOf(h).includes('Muse');
      });
      const t = museSec ? textOf(museSec) : '';
      const noSwapBtn = !(museSec && btnByText(museSec, '교체'));
      const noFinance = !t.includes('finance');
      const curOk = t.includes('현재 키') && t.includes('apps') && t.includes('rolling');
      const fresh = calls.slice(n0);
      const noSwapCall = !fresh.some(c => String(c).includes('muse-swap') && !String(c).includes('candidates'));
      if (museSec && noSwapBtn && noFinance && curOk && noSwapCall) cond = true;
      else note = `swapBtn=${!noSwapBtn},finance=${!noFinance},cur=${curOk},swapCall=${!noSwapCall};`;
    }
    const observed = cond ? '현재 키+사용량만, 후보·교체 버튼·swap 호출 없음' : note;
    if (cond) ok('P1b Muse 현재 키만 (후보 숨기기)', 'AC-SUB-POPUP-1B',
      'Muse 섹션에 현재 키+사용량만 && 교체 버튼 없음 && finance 미표시 && muse-swap 미호출', observed);
    else bad('P1b Muse 현재 키만 (후보 숨기기)', 'AC-SUB-POPUP-1B',
      'Muse 섹션에 현재 키+사용량만 && 교체 버튼 없음 && finance 미표시 && muse-swap 미호출', observed);
  }

  // ---------- P2: 조치 필요 요약 줄 ----------
  {
    const { ctx, doc, api } = sandbox();
    const host = doc.createElement('div'); doc.body.appendChild(host);
    api.renderAcctPanel(host);
    await drain();
    const needs = queryFirst(host, '.needs');
    const t = needs ? textOf(needs) : '';
    // fixture: codex 미로그인 + Claude 로그인 만료 1건 → 요약 2건. 링크를 누르면 해당 섹션이 열린다.
    // 팝업이 교체 UI를 갖지 않으므로 Muse pill이 뜨면 안 된다 (교체는 플릿 몫).
    let opened = false;
    if (needs) {
      const link = queryAll(needs, 'a').find(a => (a.dataset.go || '') === 'codex');
      if (link) { fire(link, 'click'); await drain(4); opened = queryAll(host, '.sec-body').filter(b => b.style.display !== 'none').length === 2; }
    }
    const cond = !!needs && t.includes('조치 필요 2건') && !t.includes('Muse') && opened;
    if (cond) ok('P2 조치 필요 요약 줄 + 이동', 'AC-SUB-POPUP-2',
      '".needs"에 조치 필요 2건 + Muse pill 없음 + 링크 클릭에 Codex 섹션 열림',
      `needs=${JSON.stringify(t.slice(0, 60))},opened=${opened}`);
    else bad('P2 조치 필요 요약 줄 + 이동', 'AC-SUB-POPUP-2',
      '".needs"에 조치 필요 2건 + Muse pill 없음 + 링크 클릭에 Codex 섹션 열림',
      `needs=${JSON.stringify(t.slice(0, 60))},opened=${opened}`);
  }

  // ---------- P3: 전환은 확인 띠 → 진행 → ✓, 패널 유지 ----------
  {
    const { ctx, doc, api } = sandbox();
    const host = doc.createElement('div'); doc.body.appendChild(host);
    api.renderAcctPanel(host);
    await drain();
    const rows = queryAll(host, '.acctrow').filter(r => !textOf(r).startsWith('✓') && !textOf(r).includes('❌'));
    const target = rows.find(r => textOf(r).includes('team@example')) || rows[0];
    let cond = true, note = '';
    if (!target) { cond = false; note = 'no non-active row;'; }
    else {
      const before = calls.filter(c => c === 'acct-switch').length;
      fire(target, 'click'); await drain(4);
      const strip = queryFirst(host, '.confirm-strip');
      const noEarlySwitch = calls.filter(c => c === 'acct-switch').length === before;
      const confirmBtn = strip && btnByText(strip, '전환');
      const cancelBtn = strip && btnByText(strip, '취소');
      if (!strip || !confirmBtn || !cancelBtn || !noEarlySwitch) {
        cond = false; note += `strip=${!!strip},confirm=${!!confirmBtn},cancel=${!!cancelBtn},noEarly=${noEarlySwitch};`;
      } else {
        fire(confirmBtn, 'click');
        const prog = queryFirst(host, '.prog');   // fetch가 닿기 전 동기 상태
        const progOk = !!prog && textOf(prog).includes('전환 중');
        await sleep(1600); await drain();
        const done = queryFirst(host, '.flow-done');
        const doneOk = !!done && textOf(done).includes('✓');
        const moved = queryAll(host, '.acctrow').some(r => textOf(r).startsWith('✓') && textOf(r).includes('team@example'));
        const kept = doc.body.contains(host);
        if (!(progOk && doneOk && moved && kept)) {
          cond = false; note += `prog=${progOk},done=${doneOk},moved=${moved},kept=${kept};`;
        }
        // 취소 경로: 다른 행 확인 띠에서 취소를 누르면 호출 없이 닫힌다.
        const rows2 = queryAll(host, '.acctrow').filter(r => !textOf(r).startsWith('✓') && !textOf(r).includes('❌'));
        const t2 = rows2.find(r => !textOf(r).includes('team@example'));
        if (t2) {
          const n0 = calls.filter(c => c === 'acct-switch').length;
          fire(t2, 'click'); await drain(4);
          const s2 = queryFirst(host, '.confirm-strip');
          const c2 = s2 && btnByText(s2, '취소');
          if (!c2) { cond = false; note += 'cancel-missing;'; }
          else {
            fire(c2, 'click'); await drain(4);
            const n1 = calls.filter(c => c === 'acct-switch').length;
            if (queryFirst(host, '.confirm-strip') || n1 !== n0) { cond = false; note += 'cancel-leak;'; }
          }
        }
      }
    }
    const observed = cond ? 'confirm→prog(전환 중)→done(✓ 이동), 패널 유지, 취소 무호출' : note;
    if (cond) ok('P3 전환 확인 띠 → 진행 → ✓ (닫지 않음)', 'AC-SUB-POPUP-3', observed, observed);
    else bad('P3 전환 확인 띠 → 진행 → ✓ (닫지 않음)', 'AC-SUB-POPUP-3',
      'confirm→prog(전환 중)→done(✓ 이동), 패널 유지, 취소 무호출', observed);
  }

  // ---------- P4: 코드 라벨 방향 ----------
  {
    const { ctx, doc, api } = sandbox();
    const host = doc.createElement('div'); doc.body.appendChild(host);
    api.renderAcctPanel(host);
    await drain();
    let claudeOk = false, codexOk = false, claudeSeen = '', codexSeen = '';
    const add = btnByText(host, '계정 추가');
    if (add) {
      fire(add, 'click'); await drain(4);
      const open = btnByText(host, '승인 페이지 열기');
      if (open) {
        fire(open, 'click'); await drain(4);
        claudeSeen = textOf(host);
        claudeOk = claudeSeen.includes('승인 페이지에서 받은') && claudeSeen.includes('여기에 붙여넣기');
      }
    }
    // Codex 섹션 안에서 로그인 버튼을 찾는다 (Claude 만료 행도 '로그인'을 품고 있어서 전역 탐색은 오답).
    // 흐름은 한 번에 하나라 Claude 흐름을 먼저 닫는다.
    const cancelClaude = btnByText(host, '취소');
    if (cancelClaude) { fire(cancelClaude, 'click'); await drain(4); }
    const codexHead = queryAll(host, '.sec-head').find(h => textOf(h).includes('Codex'));
    let codexSec = null;
    if (codexHead) {
      fire(codexHead, 'click'); await drain(4);
      codexSec = queryAll(host, '.sec').find(s => {
        const h = queryFirst(s, '.sec-head');
        return h && textOf(h).includes('Codex');
      });
    }
    const login = codexSec && btnByText(codexSec, '로그인');
    if (login) {
      fire(login, 'click'); await drain(4);
      const start = btnByText(host, '재로그인 시작');
      if (start) {
        fire(start, 'click'); await drain(4);
        codexSeen = textOf(host);
        codexOk = codexSeen.includes('Airlock') && codexSeen.includes('만든 코드') && codexSeen.includes('브라우저에 입력');
      }
    }
    if (claudeOk && codexOk) ok('P4 코드 라벨 방향(Claude 붙여넣기/Codex 입력)', 'AC-SUB-POPUP-4',
      'Claude=승인 페이지에서 받은 코드→여기에 붙여넣기 && Codex=Airlock이 만든 코드→브라우저에 입력', 'both found');
    else bad('P4 코드 라벨 방향(Claude 붙여넣기/Codex 입력)', 'AC-SUB-POPUP-4',
      'Claude=승인 페이지에서 받은 코드→여기에 붙여넣기 && Codex=Airlock이 만든 코드→브라우저에 입력',
      `claude=${claudeOk} codex=${codexOk}`);
  }

  // ---------- P5: 확인 중 + 한국어 ----------
  {
    const { ctx, doc, api } = sandbox();
    const host = doc.createElement('div'); doc.body.appendChild(host);
    api.renderAcctPanel(host);
    await drain();
    // 미판독 슬롯(a2, usage {})은 확인 중.
    const a2 = queryAll(host, '.acctrow').find(r => textOf(r).includes('team@example'));
    const unknownOk = !!a2 && textOf(a2).includes('확인 중');
    // 모든 흐름의 문구를 렌더해 모은다.
    const add = btnByText(host, '계정 추가'); if (add) { fire(add, 'click'); await drain(4); }
    const open = btnByText(host, '승인 페이지 열기'); if (open) { fire(open, 'click'); await drain(4); }
    const full = textOf(host);
    const banned = ['Loading', 'reading', 'Re-login', 'Log in', 'Log out', 'Switch account',
      'Not logged in', 'Register', 'Cancel', 'Check', 'Approve', 'paste the code', 'Open in',
      'Enter this', 'click to copy', 'After logging', 'Copied', 'Signed in', 'Not signed in',
      'Credential', 'revoked', 'Collecting', 'No usage', 'Query failed', 'Remove', 'Switch failed',
      'Switched to', 'Already using', 'Code from the', 'resets', 'credits', 'Expires', 'Expired',
      'expires', '5h', '7d', 'usage', ' days', 'min ago', 'just now', 'refreshing'];
    const hits = banned.filter(w => full.includes(w));
    const panelHtml = fs.readFileSync(path.join(path.dirname(srcFile), 'panel.html'), 'utf8');
    const chromeOk = panelHtml.includes('구독 계정') && panelHtml.includes('닫기') &&
      !panelHtml.includes('Subscription accounts');
    const cond = unknownOk && hits.length === 0 && chromeOk;
    if (cond) ok('P5 미판독=확인 중 + 한국어 통일', 'AC-SUB-POPUP-5',
      '미판독 슬롯에 확인 중 && 영어 UI 잔재 0 && 패널 크롬 한국어', 'clean');
    else bad('P5 미판독=확인 중 + 한국어 통일', 'AC-SUB-POPUP-5',
      '미판독 슬롯에 확인 중 && 영어 UI 잔재 0 && 패널 크롬 한국어',
      `unknown=${unknownOk},hits=[${hits.join(',')}],chrome=${chromeOk}`);
  }

  // ---------- P6: 콘솔 오류 0 (실패 fixture 포함) ----------
  {
    errorLog.length = 0;
    // 실패 경로 fixture: codex 토큰 거부, agy 읽기 실패, 임계값 미수신.
    const keep = { codex: FIX['codex-status'], usage: FIX['codex-usage'], agy: FIX['agy-usage'],
      accts: FIX['accounts'], alert: FIX['acct-alert'] };
    FIX['codex-status'] = { state: 'ok', email: 'me@example.test', plan: 'pro', accountId: 'A1' };
    FIX['codex-usage'] = { use7d: null, lastErr: 'auth', accountId: 'A1' };
    FIX['agy-usage'] = new Error('agy failed');
    FIX['accounts'] = Object.assign({}, keep.accts, { thresholds: null });
    FIX['acct-alert'] = { level: 'unknown' };
    const { ctx, doc, api } = sandbox();
    // 실패 경로: codex-usage 거부, agy 읽기 실패, 사용량 조회 실패.
    const host = doc.createElement('div'); doc.body.appendChild(host);
    api.renderAcctPanel(host);
    await drain();
    const codexHead = queryAll(host, '.sec-head').find(h => textOf(h).includes('Codex'));
    if (codexHead) { fire(codexHead, 'click'); await drain(4); }
    const rendered = textOf(host).length > 50;
    const cond = errorLog.length === 0 && rendered;
    Object.assign(FIX, { 'codex-status': keep.codex, 'codex-usage': keep.usage,
      'agy-usage': keep.agy, 'accounts': keep.accts, 'acct-alert': keep.alert });
    if (cond) ok('P6 콘솔 오류 0', 'AC-SUB-POPUP-6', 'console.error==0 && 렌더 유지',
      `errors=${errorLog.length},rendered=${rendered}`);
    else bad('P6 콘솔 오류 0', 'AC-SUB-POPUP-6', 'console.error==0 && 렌더 유지',
      `errors=${JSON.stringify(errorLog.slice(0, 3))},rendered=${rendered}`);
  }

  console.log('---');
  AC.forEach(a => console.log(
    `${a.ac} | expected: ${a.expected} | observed: ${a.observed} | verdict: ${a.verdict} | signal: fixture | evidence: install/test-subscription-management.sh@${rev}`));
  console.log(`passed=${pass} failed=${fail}`);
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.log('FAIL harness threw: ' + (e && e.stack || e)); process.exit(1); });
NODE
}

case "${1:-}" in
  agy-swap) agy_swap ;;
  muse-usage) if muse_usage; then ok "muse-usage: verdict green (T-MU0..7)"; else bad "muse-usage: verdict red"; fi ;;
  popup-6) if popup_6; then ok "popup-6: verdict green (P1,P1b,P2..6)"; else bad "popup-6: verdict red"; fi ;;
  *) echo "usage: $0 {muse-usage|agy-swap|popup-6}" >&2; exit 2 ;;
esac

echo "subscription-management: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
