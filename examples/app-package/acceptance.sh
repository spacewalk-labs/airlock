#!/usr/bin/env bash
# Live acceptance for the external app-package example: install -> rerun ->
# upgrade -> remove, on a disposable box with real systemd user units, real
# nginx, real sudo and real paths. The ONLY shimmed boundary is `tailscale`
# (ingress), because this box is not on a tailnet; everything the app-package
# contract actually governs is real here.
set -uo pipefail

ROOT="${AIRLOCK_CHECKOUT:-$HOME/airlock}"
PKG="${PKG_COPY:-$HOME/hello-example}"
UNIT="$HOME/.config/systemd/user/airlock-hello-example.service"
FRAG=/etc/airlock/nginx/hub-locations.d/hello-example.conf
XDG_RUNTIME_DIR="/run/user/$(id -u)"; export XDG_RUNTIME_DIR
export AIRLOCK_TS_FQDN="box.example.ts.net"

pass=0; fail=0
step() { printf '\n\n========== %s\n' "$*"; }
ok()   { printf 'PASS  %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'FAIL  %s\n' "$*"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 — got '$2', want '$3'"; fi; }

tree_digest() {
  python3 - "$ROOT/bin/airlock-ledger" "$1" <<'PY'
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("acceptance_ledger", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
print(module.digest_tree(sys.argv[2]))
PY
}

lock_digest() {
  python3 - "$ROOT/airlock.lock" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    print(tomllib.load(handle)["hello-example"]["digest"])
PY
}

step "0. copy the example the way the guide says to, change only owner"
rm -rf "$PKG"
cp -a "$ROOT/examples/app-package" "$PKG"
sed -i 's/^owner = .*/owner = "you@example.com"/' "$PKG/airlock.toml"
grep -n 'owner' "$PKG/airlock.toml"
export AIRLOCK_CONFIG="$PKG/airlock.toml"

step "1. INSTALL (real)"
bash "$ROOT/install/airlock-install.sh"; rc=$?
echo "installer rc=$rc"
check "install exits 0" "$rc" 0
[ -f "$UNIT" ] && ok "user unit exists at $UNIT" || bad "user unit missing at $UNIT"
[ -f "$FRAG" ] && ok "nginx fragment exists at $FRAG" || bad "nginx fragment missing at $FRAG"
systemctl --user is-active airlock-hello-example.service && ok "backend unit is active" || bad "backend unit is not active"
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:18900/health)
check "backend answers on loopback" "$code" 200
echo "--- ledger ---"
ledger="$HOME/.local/state/airlock/app-ledger.json"
if [ -f "$ledger" ]; then
  cat "$ledger"
else
  printf 'ledger missing: %s\n' "$ledger"
fi
u_sum=$(sha256sum "$UNIT" | cut -c1-16); f_sum=$(sudo sha256sum "$FRAG" | cut -c1-16)
started=$(systemctl --user show airlock-hello-example.service -p ActiveEnterTimestampMonotonic --value)
check "repository lock records the exact package digest" "$(lock_digest)" "$(tree_digest "$PKG/package")"
lock_sum=$(sha256sum "$ROOT/airlock.lock" | cut -c1-16)

step "2. RERUN (must be idempotent: same bytes, service not bounced)"
bash "$ROOT/install/airlock-install.sh"; rc=$?
check "rerun exits 0" "$rc" 0
check "unit bytes unchanged" "$(sha256sum "$UNIT" | cut -c1-16)" "$u_sum"
check "fragment bytes unchanged" "$(sudo sha256sum "$FRAG" | cut -c1-16)" "$f_sum"
check "service was not restarted" "$(systemctl --user show airlock-hello-example.service -p ActiveEnterTimestampMonotonic --value)" "$started"
check "matching rerun leaves lock bytes unchanged" "$(sha256sum "$ROOT/airlock.lock" | cut -c1-16)" "$lock_sum"

step "3. UPGRADE (change the package, same install command)"
sed -i 's/hello from the Airlock package example/hello from v2 of the example/' "$PKG/package/backend.py"
sed -i 's/^backend_port = 18900/backend_port = 18901/' "$PKG/package/airlock-app.toml"
out=$(bash "$ROOT/install/airlock-install.sh" 2>&1); mismatch_rc=$?
case "$out" in
  *"package 'hello-example': package lock digest mismatch"*"recorded digest:"*"computed digest:"*)
    if [ "$mismatch_rc" != 0 ] \
       && [ "$(sha256sum "$ROOT/airlock.lock" | cut -c1-16)" = "$lock_sum" ]; then
      ok "changed package is refused without rewriting the old lock"
    else
      bad "changed package mismatch did not preserve the old lock (rc=$mismatch_rc)"
    fi ;;
  *) bad "changed package was not refused with both lock digests (rc=$mismatch_rc)" ;;
esac
# This disposable fixture has exactly one explicit package. Removing its entry
# is the deliberate re-lock action; the successful run below machine-writes the
# new digest. The operator grant, if any, would remain a separate config fact.
rm -f "$ROOT/airlock.lock"
bash "$ROOT/install/airlock-install.sh"; rc=$?
check "upgrade exits 0" "$rc" 0
check "successful upgrade records the new exact digest" "$(lock_digest)" "$(tree_digest "$PKG/package")"
grep -q '18901' "$UNIT" && ok "unit carries the new port" || bad "unit still carries the old port"
body=$(curl -sS --max-time 6 http://127.0.0.1:18901/ 2>&1)
echo "body: $body"
case "$body" in *"v2 of the example"*) ok "the new backend is the one serving" ;; *) bad "old backend still serving: $body" ;; esac
old=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:18900/health)
check "the old port is gone" "$old" 000
grep -c 18901 "$FRAG" >/dev/null && sudo grep -q 18901 "$FRAG" && ok "fragment repointed to the new port" || bad "fragment still points at the old port"

step "4. REMOVE (drop both tables, same install command)"
python3 - "$PKG/airlock.toml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n\[apps\.hello-example\]\n', '\n', s)
s = re.sub(r'\n\[packages\.hello-example\]\n(#[^\n]*\n)?path = [^\n]*\n', '\n', s)
open(p, 'w').write(s)
print(s)
PY
bash "$ROOT/install/airlock-install.sh"; rc=$?
check "remove-run exits 0" "$rc" 0
[ -f "$UNIT" ] && bad "unit survived removal: $UNIT" || ok "unit removed"
sudo test -f "$FRAG" && bad "fragment survived removal: $FRAG" || ok "fragment removed"
systemctl --user is-active airlock-hello-example.service >/dev/null 2>&1 \
  && bad "backend still running after removal" || ok "backend stopped"
gone=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:18901/ 2>/dev/null)
check "nothing answers on the backend port" "$gone" 000

step "5. A WRONG MANIFEST NAMES WHAT IS WRONG"
rm -rf "$HOME/broken" && cp -a "$ROOT/examples/app-package" "$HOME/broken"
sed -i 's/^owner = .*/owner = "you@example.com"/' "$HOME/broken"/airlock.toml
sed -i 's|^units = .*|units = ["../not-a-unit.service"]|' "$HOME/broken"/package/airlock-app.toml
out=$(AIRLOCK_CONFIG="$HOME/broken"/airlock.toml python3 "$ROOT/bin/airlock-config" validate 2>&1); rc=$?
echo "$out"
check "validate refuses" "$rc" 1
case "$out" in *"artifacts.units"*"../not-a-unit.service"*) ok "the message names the field and the value" ;;
  *) bad "the message does not name both the field and the value" ;; esac

printf '\n\n========== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
