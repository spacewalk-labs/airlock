#!/usr/bin/env bash
# Retirement-record contract: a plaintext port remains identifiable after the
# package config, payload, and installed-state ledger have all disappeared.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CFG="$ROOT/bin/airlock-config"
TMP="$(mktemp -d)" || { echo "FAIL could not create test directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok(){ printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
WITNESS_ID="retire-witness"
WITNESS_APPS="$TMP/witness-apps"
mkdir -p "$WITNESS_APPS/$WITNESS_ID"
cat >"$WITNESS_APPS/$WITNESS_ID/airlock-app.toml" <<EOF
contract = 1
id = "$WITNESS_ID"
[config.defaults]
public_port = 45678
redirect_port = 45679
[plaintext_redirect]
public_port = "redirect_port"
EOF
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$WITNESS_APPS/$WITNESS_ID/install.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$WITNESS_APPS/$WITNESS_ID/smoke.sh"
chmod +x "$WITNESS_APPS/$WITNESS_ID/install.sh" "$WITNESS_APPS/$WITNESS_ID/smoke.sh"

# Production BUNDLE_ENTITLEMENTS no longer entitles shipped devterm.
# The recorder substrate is class-neutral: this test owns the witness and
# patches only the loaded module. D-DEVTERM-9900 is why the witness exists.
run(){
  AIRLOCK_CONFIG="$1" AIRLOCK_STATE_DIR="$STATE" \
  AIRLOCK_SHIPPED_APPS_ROOT="$2" AIRLOCK_WITNESS_APPS="$WITNESS_APPS" \
  AIRLOCK_WITNESS_ID="$WITNESS_ID" python3 - "$CFG" "${@:3}" <<'PY'
import importlib.machinery, importlib.util, os, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("airlock_config", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
shipped = Path(os.environ["AIRLOCK_SHIPPED_APPS_ROOT"]).resolve()
witness = Path(os.environ["AIRLOCK_WITNESS_APPS"]).resolve()
if shipped == witness:
    wid = os.environ["AIRLOCK_WITNESS_ID"]
    module.BUNDLE_ENTITLEMENTS = {wid: ("plaintext-redirect",)}
    module.BUNDLE_ROOT = witness
raise SystemExit(module.main(sys.argv[2:]))
PY
}

STATE="$TMP/state"
EMPTY_APPS="$TMP/empty-apps"
mkdir -p "$STATE" "$EMPTY_APPS"
export AIRLOCK_WITNESS_APPS="$WITNESS_APPS" AIRLOCK_WITNESS_ID="$WITNESS_ID"
cat >"$TMP/witness_mod.py" <<'PY'
def patch(module):
    import os
    from pathlib import Path
    wid = os.environ["AIRLOCK_WITNESS_ID"]
    module.BUNDLE_ENTITLEMENTS = {wid: ("plaintext-redirect",)}
    module.BUNDLE_ROOT = Path(os.environ["AIRLOCK_WITNESS_APPS"])
    return module
PY
export PYTHONPATH="$TMP${PYTHONPATH:+:$PYTHONPATH}"

cat >"$TMP/active.toml" <<EOF
[auth]
provider = "tailscale"
owner = "owner@example.com"
[apps.hub]
[apps.$WITNESS_ID]
public_port = 45678
redirect_port = 45679
EOF

cat >"$TMP/removed.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "owner@example.com"
[apps.hub]
TOML

# Healthy-ledger control: plaintext_redirect is not recorded in today's ledger
# at all. Config/payload removal already forgets the port; ledger loss merely
# proves why moving the fact into a future ledger version would not close it.
printf '%s\n' '{"version":4,"entries":{}}' >"$STATE/app-ledger.json"
healthy_known="$(run "$TMP/removed.toml" "$EMPTY_APPS" plaintext-known 2>/dev/null)"; healthy_rc=$?
if [ "$healthy_rc" -eq 0 ] && ! grep -qx '45678' <<<"$healthy_known"; then
  ok "healthy ledger: config/payload removal already forgets plaintext_redirect"
else
  bad "healthy ledger: unexpected custom port witness (rc=$healthy_rc known=$healthy_known)"
fi
rm -f "$STATE/app-ledger.json"

# Negative control: hiding the witness must drop the custom row.
# If this stays green after deleting the witness, the suite is not watching it.
mv "$WITNESS_APPS/$WITNESS_ID/airlock-app.toml" "$TMP/hidden-witness.toml"
no_wit="$(run "$TMP/active.toml" "$WITNESS_APPS" plaintext 2>/dev/null || true)"
mv "$TMP/hidden-witness.toml" "$WITNESS_APPS/$WITNESS_ID/airlock-app.toml"
if ! grep -qx $'retire-witness\t45678\t45679' <<<"$no_wit"; then
  ok "negative: hidden witness emits no custom plaintext row"
else
  bad "negative: hidden witness still emitted the custom row (rows=$no_wit)"
fi

active_rows="$(run "$TMP/active.toml" "$WITNESS_APPS" plaintext 2>/dev/null)"; active_rc=$?
if [ "$active_rc" -eq 0 ] && grep -qx $'retire-witness\t45678\t45679' <<<"$active_rows"; then
  ok "fixture: production resolver emits the custom plaintext row"
else
  bad "fixture: production resolver emits the custom plaintext row (rc=$active_rc rows=$active_rows)"
fi

# Record before the persistent Tailscale mapping can be created. The command is
# class-neutral. The witness is this test's retire-witness package, not
# shipped devterm (D-DEVTERM-9900). A later grant path can reuse the same
# recorder without changing this substrate.
record_out="$(run "$TMP/active.toml" "$WITNESS_APPS" plaintext-retirement-record 2>&1)"; record_rc=$?
if [ "$record_rc" -eq 0 ] && python3 - "$STATE/plaintext-retirement.json" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
assert value == {"version": 1, "entries": [
    {"package": "retire-witness", "listen": 45678, "target": 45679, "state": "intent"},
]}
PY
then
  ok "record: exact package/listen/target intent is durably recorded"
else
  bad "record: exact package/listen/target intent is durably recorded (rc=$record_rc out=$record_out)"
fi

commit_out="$(run "$TMP/active.toml" "$WITNESS_APPS" plaintext-retirement-commit retire-witness 45678 45679 2>&1)"; commit_rc=$?
if [ "$commit_rc" -eq 0 ] && python3 - "$STATE/plaintext-retirement.json" <<'PY' 2>/dev/null
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["entries"][0]["state"] == "committed"
PY
then
  ok "record: successful mapping promotes the exact intent to committed"
else
  bad "record: successful mapping promotes intent (rc=$commit_rc out=$commit_out)"
fi

# A mapping may already be persistent when promotion storage fails. Preserve
# the intent and fail loudly; an intent is diagnostic-only, so this never turns
# uncertain durability into automatic removal authority.
rm -f "$STATE/plaintext-retirement.json"
run "$TMP/active.toml" "$WITNESS_APPS" plaintext-retirement-record >/dev/null 2>&1
commit_fail_out="$(AIRLOCK_CONFIG="$TMP/active.toml" AIRLOCK_STATE_DIR="$STATE" \
  AIRLOCK_SHIPPED_APPS_ROOT="$WITNESS_APPS" python3 - "$CFG" <<'PY' 2>&1
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("retirement_commit_failure", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
module.os.replace = lambda *_args: (_ for _ in ()).throw(OSError("injected commit replace failure"))
from witness_mod import patch
patch(module)
module.cmd_plaintext_retirement_commit(module.load(), "retire-witness", 45678, 45679)
PY
)"; commit_fail_rc=$?
if [ "$commit_fail_rc" -ne 0 ] && python3 - "$STATE/plaintext-retirement.json" <<'PY' 2>/dev/null
import json, sys
entry = json.load(open(sys.argv[1], encoding="utf-8"))["entries"][0]
assert entry["state"] == "intent"
PY
then
  ok "commit write failure: mapping ownership remains diagnostic-only intent"
else
  bad "commit write failure: intent was lost or promoted (rc=$commit_fail_rc out=$commit_fail_out)"
fi
run "$TMP/active.toml" "$WITNESS_APPS" plaintext-retirement-commit retire-witness 45678 45679 >/dev/null 2>&1

# The recovery command is independently dispatchable, so it must not race the
# orchestrator between map and commit. Hold the production lock in this shell:
# a concurrent drop must fail and preserve the exact committed bytes.
cp "$STATE/plaintext-retirement.json" "$TMP/locked-drop.before"
exec 8>>"$STATE/app-ledger.lock"
flock -n 8
locked_drop="$(run "$TMP/active.toml" "$WITNESS_APPS" plaintext-retirement-drop 45678 2>&1)" \
  && locked_drop_rc=0 || locked_drop_rc=$?
flock -u 8
exec 8>&-
if [ "$locked_drop_rc" -ne 0 ] \
   && grep -Fq 'another airlock run holds the ledger lock' <<<"$locked_drop" \
   && cmp -s "$TMP/locked-drop.before" "$STATE/plaintext-retirement.json"; then
  ok "manual drop race: whole-run writer lock preserves mapping ownership"
else
  bad "manual drop race: recovery mutation bypassed run lock (rc=$locked_drop_rc out=$locked_drop)"
fi

# The shared lock helper crosses into the ledger module for state-directory
# preparation. Its typed failure must remain an operator diagnostic, never a
# Python traceback from a private module exception.
printf 'not-a-directory\n' >"$TMP/state-file"
state_file_out="$(AIRLOCK_CONFIG="$TMP/active.toml" \
  AIRLOCK_STATE_DIR="$TMP/state-file" AIRLOCK_SHIPPED_APPS_ROOT="$WITNESS_APPS" \
  python3 "$CFG" plaintext-retirement-drop 45678 2>&1)" \
  && state_file_rc=0 || state_file_rc=$?
if [ "$state_file_rc" -eq 2 ] \
   && grep -Fq 'cannot prepare plaintext retirement lock' <<<"$state_file_out" \
   && ! grep -Fq 'Traceback' <<<"$state_file_out"; then
  ok "lock preparation failure: typed ledger error stays a clean diagnostic"
else
  bad "lock preparation failure: private exception escaped (rc=$state_file_rc out=$state_file_out)"
fi

# Remove every ordinary naming input: config row, package payload view, and the
# complete ledger file. Only the independent retirement record remains.
rm -f "$STATE/app-ledger.json"
known="$(run "$TMP/removed.toml" "$EMPTY_APPS" plaintext-known 2>/dev/null)"; known_rc=$?
if [ "$known_rc" -eq 0 ] && grep -qx '45678' <<<"$known"; then
  ok "missing ledger: removed package port is still named"
else
  bad "missing ledger: removed package port is still named (rc=$known_rc known=${known:-<empty>})"
fi

# Freeze the actual stale-sweep boundary too: the fake live state contains the
# forgotten mapping, and the production helper must now return it from the
# independent record even though config/payload/ledger no longer do.
SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat >"$SHIM/tailscale" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "serve status --json" ]; then
  printf '%s\n' '{"TCP":{"45678":{"HTTP":true,"Web":{"/":{"Proxy":"http://127.0.0.1:45679"}}}}}'
  exit 0
fi
exit 1
SH
chmod +x "$SHIM/tailscale"
stale="$(PATH="$SHIM:$PATH" AIRLOCK_CONFIG="$TMP/removed.toml" \
  AIRLOCK_STATE_DIR="$STATE" AIRLOCK_SHIPPED_APPS_ROOT="$EMPTY_APPS" \
  bash -c '. "$1/install/lib.sh"; ts_stale_plaintext_ports ""' _ "$ROOT" 2>&1)"; stale_rc=$?
if [ "$stale_rc" -eq 0 ] && grep -qx '45678' <<<"$stale"; then
  ok "missing ledger: live stale-sweep returns the recorded port"
else
  bad "missing ledger: live stale-sweep returns the recorded port (rc=$stale_rc out=${stale:-<empty>})"
fi

# A corrupt ledger must remain fail-closed, but the fatal diagnostic can still
# use the independent record to tell a human exactly which package/port pair may
# need manual retirement.
printf 'garbage\n' >"$STATE/app-ledger.json"
corrupt="$(run "$TMP/removed.toml" "$EMPTY_APPS" plaintext-known 2>&1)"; corrupt_rc=$?
if [ "$corrupt_rc" -ne 0 ] \
   && grep -Fq 'retire-witness' <<<"$corrupt" \
   && grep -Fq '45678' <<<"$corrupt"; then
  ok "corrupt ledger: fatal diagnostic names package and port"
else
  bad "corrupt ledger: fatal diagnostic names package and port (rc=$corrupt_rc out=$corrupt)"
fi

# The sidecar is itself fail-closed. Silently treating a damaged record as empty
# would recreate the exact forgotten-port gap it exists to close.
printf 'garbage\n' >"$STATE/plaintext-retirement.json"
rm -f "$STATE/app-ledger.json"
damaged="$(run "$TMP/removed.toml" "$EMPTY_APPS" plaintext-known 2>&1)"; damaged_rc=$?
if [ "$damaged_rc" -ne 0 ] \
   && grep -Fq 'plaintext-retirement.json' <<<"$damaged" \
   && grep -Fq 'NOT treated as empty' <<<"$damaged"; then
  ok "retirement record: corruption fails closed and names the file"
else
  bad "retirement record: corruption fails closed (rc=$damaged_rc out=$damaged)"
fi

# An atomic replacement failure must leave the prior valid record byte-for-byte
# intact. This imports the production module only to inject the filesystem error;
# the record path and writer remain the real ones.
cat >"$STATE/plaintext-retirement.json" <<'JSON'
{"entries":[{"listen":40000,"package":"old","state":"committed","target":40001}],"version":1}
JSON
cp "$STATE/plaintext-retirement.json" "$TMP/record.before"
atomic_out="$(AIRLOCK_CONFIG="$TMP/active.toml" AIRLOCK_STATE_DIR="$STATE" \
  AIRLOCK_SHIPPED_APPS_ROOT="$WITNESS_APPS" python3 - "$CFG" <<'PY' 2>&1
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("retirement_record_config", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
from witness_mod import patch
patch(module)
def fail_replace(*_args):
    raise OSError("injected replace failure")
module.os.replace = fail_replace
module.cmd_plaintext_retirement_record(module.load())
PY
)"; atomic_rc=$?
if [ "$atomic_rc" -ne 0 ] \
   && grep -Fq 'injected replace failure' <<<"$atomic_out" \
   && cmp -s "$TMP/record.before" "$STATE/plaintext-retirement.json"; then
  ok "record: failed atomic replacement preserves prior bytes"
else
  bad "record: failed atomic replacement preserves prior bytes (rc=$atomic_rc out=$atomic_out)"
fi

cat >"$STATE/plaintext-retirement.json" <<'JSON'
{"entries":[{"listen":40000,"package":"old","state":"committed","target":40001}],"version":1}
JSON
cp "$STATE/plaintext-retirement.json" "$TMP/file-fsync.before"
file_sync_out="$(AIRLOCK_CONFIG="$TMP/active.toml" AIRLOCK_STATE_DIR="$STATE" \
  AIRLOCK_SHIPPED_APPS_ROOT="$WITNESS_APPS" python3 - "$CFG" <<'PY' 2>&1
import importlib.machinery, importlib.util, os, stat, sys
loader = importlib.machinery.SourceFileLoader("retirement_record_file_fsync", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
from witness_mod import patch
patch(module)
original = module.os.fsync
def injected(fd):
    if stat.S_ISREG(os.fstat(fd).st_mode):
        raise OSError("injected file fsync failure")
    return original(fd)
module.os.fsync = injected
module.cmd_plaintext_retirement_record(module.load())
PY
)"; file_sync_rc=$?
if [ "$file_sync_rc" -ne 0 ] \
   && grep -Fq 'injected file fsync failure' <<<"$file_sync_out" \
   && cmp -s "$TMP/file-fsync.before" "$STATE/plaintext-retirement.json"; then
  ok "record: file fsync failure preserves prior bytes"
else
  bad "record: file fsync failure contract (rc=$file_sync_rc out=$file_sync_out)"
fi

# Pin both sides of the durability commit point. A directory fsync failure
# before replace is fatal and byte-preserving; the same failure after replace
# is a loud committed success because rollback would require another fallible
# replacement.
fsync_case() {
  local fail_at="$1"
  AIRLOCK_CONFIG="$TMP/active.toml" AIRLOCK_STATE_DIR="$STATE" \
    AIRLOCK_SHIPPED_APPS_ROOT="$WITNESS_APPS" python3 - "$CFG" "$fail_at" <<'PY'
import importlib.machinery, importlib.util, os, stat, sys
loader = importlib.machinery.SourceFileLoader("retirement_record_fsync", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
from witness_mod import patch
patch(module)
original = module.os.fsync
fail_at = int(sys.argv[2])
directory_calls = 0
def injected(fd):
    global directory_calls
    if stat.S_ISDIR(os.fstat(fd).st_mode):
        directory_calls += 1
        if directory_calls == fail_at:
            raise OSError(f"injected directory fsync failure {fail_at}")
    return original(fd)
module.os.fsync = injected
module.cmd_plaintext_retirement_record(module.load())
PY
}

cat >"$STATE/plaintext-retirement.json" <<'JSON'
{"entries":[{"listen":40000,"package":"old","state":"committed","target":40001}],"version":1}
JSON
cp "$STATE/plaintext-retirement.json" "$TMP/fsync.before"
pre_out="$(fsync_case 1 2>&1)"; pre_rc=$?
if [ "$pre_rc" -ne 0 ] \
   && grep -Fq 'injected directory fsync failure 1' <<<"$pre_out" \
   && cmp -s "$TMP/fsync.before" "$STATE/plaintext-retirement.json"; then
  ok "record: pre-replace directory fsync failure preserves prior bytes"
else
  bad "record: pre-replace fsync contract (rc=$pre_rc out=$pre_out)"
fi
post_out="$(fsync_case 2 2>&1)"; post_rc=$?
if [ "$post_rc" -eq 0 ] \
   && grep -Fq 'treating the replacement as committed' <<<"$post_out" \
   && grep -Fq '"package":"retire-witness"' "$STATE/plaintext-retirement.json"; then
  ok "record: post-replace directory fsync failure is loud committed success"
else
  bad "record: post-replace fsync commit point (rc=$post_rc out=$post_out)"
fi

# The pre-map row is only an intent. If the mapping command never succeeds and
# config later disappears, even an operator-owned live listener on that port is
# not removal authority: validation must stop with an exact diagnostic, and the
# stale helper must never return the port.
rm -f "$STATE/plaintext-retirement.json" "$STATE/app-ledger.json"
run "$TMP/active.toml" "$WITNESS_APPS" plaintext-retirement-record >/dev/null 2>&1
map_fail="$(AIRLOCK_CONFIG="$TMP/active.toml" AIRLOCK_STATE_DIR="$STATE" \
  AIRLOCK_SHIPPED_APPS_ROOT="$WITNESS_APPS" bash -c '
    . "$1/install/lib.sh"
    airlock_run(){ return 42; }
    ts_apply_plaintext_mapping retire-witness 45678 45679
  ' _ "$ROOT" 2>&1)"; map_fail_rc=$?
intent_diag="$(run "$TMP/removed.toml" "$EMPTY_APPS" validate 2>&1)"; intent_diag_rc=$?
intent_known="$(run "$TMP/removed.toml" "$EMPTY_APPS" plaintext-known 2>&1)"; intent_known_rc=$?
if [ "$map_fail_rc" -eq 42 ] && [ "$intent_diag_rc" -ne 0 ] \
   && grep -Fq 'retire-witness' <<<"$intent_diag" \
   && grep -Fq '45678' <<<"$intent_diag" \
   && [ "$intent_known_rc" -ne 0 ]; then
  ok "mapping failure: abandoned intent is diagnostic, never removal authority"
else
  bad "mapping failure: intent ownership confusion (map_rc=$map_fail_rc map=$map_fail validate_rc=$intent_diag_rc known_rc=$intent_known_rc known=$intent_known)"
fi

# A failed `off` must retain the committed row. Exercise the production helper,
# not source order, with a failing airlock_run shim.
run "$TMP/active.toml" "$WITNESS_APPS" plaintext-retirement-commit retire-witness 45678 45679 >/dev/null 2>&1
off_fail="$(PATH="$SHIM:$PATH" AIRLOCK_CONFIG="$TMP/removed.toml" \
  AIRLOCK_STATE_DIR="$STATE" AIRLOCK_SHIPPED_APPS_ROOT="$EMPTY_APPS" \
  bash -c '. "$1/install/lib.sh"; airlock_run(){ return 1; }; ts_reconcile_plaintext_ports ""' _ "$ROOT" 2>&1)"; off_fail_rc=$?
if [ "$off_fail_rc" -ne 0 ] && python3 - "$STATE/plaintext-retirement.json" <<'PY' 2>/dev/null
import json, sys
entry = json.load(open(sys.argv[1], encoding="utf-8"))["entries"][0]
assert entry == {"package":"retire-witness", "listen":45678, "target":45679, "state":"committed"}
PY
then
  ok "off failure: committed responsibility record is retained"
else
  bad "off failure: responsibility record was lost (rc=$off_fail_rc out=$off_fail)"
fi

# A successful `off` followed by a failed drop write remains safely committed
# for retry. Inject the storage failure through the real drop command.
drop_fail_out="$(AIRLOCK_CONFIG="$TMP/removed.toml" AIRLOCK_STATE_DIR="$STATE" \
  AIRLOCK_SHIPPED_APPS_ROOT="$EMPTY_APPS" python3 - "$CFG" <<'PY' 2>&1
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("retirement_drop_failure", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
module.os.replace = lambda *_args: (_ for _ in ()).throw(OSError("injected drop replace failure"))
module.cmd_plaintext_retirement_drop(45678)
PY
)"; drop_fail_rc=$?
if [ "$drop_fail_rc" -ne 0 ] && python3 - "$STATE/plaintext-retirement.json" <<'PY' 2>/dev/null
import json, sys
assert json.load(open(sys.argv[1], encoding="utf-8"))["entries"][0]["state"] == "committed"
PY
then
  ok "drop write failure: committed responsibility remains for retry"
else
  bad "drop write failure: committed responsibility was lost (rc=$drop_fail_rc out=$drop_fail_out)"
fi

# Retirement is a lifecycle, not a forever reservation. Exercise the real
# stale reconciliation helper: successful off must be followed by record drop.
rm -f "$STATE/app-ledger.json"
drop_out="$(PATH="$SHIM:$PATH" AIRLOCK_CONFIG="$TMP/removed.toml" \
  AIRLOCK_STATE_DIR="$STATE" AIRLOCK_SHIPPED_APPS_ROOT="$EMPTY_APPS" \
  bash -c '. "$1/install/lib.sh"; airlock_run(){ return 0; }; ts_reconcile_plaintext_ports ""' _ "$ROOT" 2>&1)"; drop_rc=$?
after_drop="$(run "$TMP/removed.toml" "$EMPTY_APPS" plaintext-known 2>/dev/null)"; after_drop_rc=$?
if [ "$drop_rc" -eq 0 ] && [ "$after_drop_rc" -eq 0 ] \
   && ! grep -qx '45678' <<<"$after_drop"; then
  ok "lifecycle: successful retirement drops the responsibility record"
else
  bad "lifecycle: successful retirement helper drops record (drop_rc=$drop_rc known=$after_drop out=$drop_out)"
fi

printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
