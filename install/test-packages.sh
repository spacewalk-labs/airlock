#!/usr/bin/env bash
# install/test-packages.sh — executable fixtures for the app package contract,
# child 2 (docs/design/app-package-contract.md): F1 round trip, F2(a), F3,
# F7, F8, F9, F10's resolver cases, plus the D5 re-run rule and the dry-run /
# no-packages non-interference guarantees.
#
# Everything runs against scratch roots (state dir, webroot, confd, unit dirs)
# with permissive shims for sudo/systemctl/tailscale/nginx/curl — no live
# units, no real sudo, no network. Fixture packages live OUTSIDE the repo
# checkout (mktemp -d), so nothing can pass by accidentally resolving
# $ROOT/apps.
set -uo pipefail
# Pin the RAM the paseo installer takes its memory share from (32GiB), so nothing in
# this suite depends on the RAM of whichever box runs it: the share is 11/16 of the
# box, so unpinned, every runner writes a different MemoryMax and the goldens bake in
# whichever the runner happened to have. install/test-render-parity.sh gates that every
# suite running a real app installer sets this — the gate does not reason about WHICH
# app a dynamic path resolves to, so suites that only run other apps carry it too; the
# seam is inert for them. (An intermediate design REFUSED below 8 GiB, which is what
# made this urgent. The refusal is gone — owner, 2026-08-17 — the pin is still right.)
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)" || { echo "FAIL could not create test directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

CFG="$ROOT/bin/airlock-config"

# ---- scratch roots -----------------------------------------------------------
STATE="$TMP/state"; WEB="$TMP/web"; CONFD="$TMP/confd"
UU="$TMP/units-user"; US="$TMP/units-system"
FAKEHOME="$TMP/home"; DATA="$TMP/data"
export AIRLOCK_STATE_DIR="$STATE" AIRLOCK_WEBROOT="$WEB" AIRLOCK_CONFD="$CONFD"
export AIRLOCK_UNIT_DIR_USER="$UU" AIRLOCK_UNIT_DIR_SYSTEM="$US"
export AIRLOCK_TS_FQDN="box.example.ts.net"

reset_box() {
  rm -rf "$STATE" "$WEB" "$CONFD" "$UU" "$US" "$FAKEHOME" "$DATA"
  mkdir -p "$WEB/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d" \
           "$UU" "$US" "$FAKEHOME" "$DATA"
}

# ---- shims -------------------------------------------------------------------
# sudo execs its command (dropping -n/-u <user>); systemctl/tailscale log and
# succeed; nginx -t succeeds; curl answers 200 so the serve check passes.
SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat >"$SHIM/sudo" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac
done
# Deterministic config A/B race seam for the orchestrator regression below.
# The first mutation command runs after the installer has frozen and fully
# preflighted A; replace the operator file with B before ledger reconcile.
if [ -n "${AIRLOCK_TEST_CONFIG_RACE_REPLACEMENT:-}" ] \
   && [ -n "${AIRLOCK_TEST_CONFIG_RACE_DONE:-}" ] \
   && [ ! -e "$AIRLOCK_TEST_CONFIG_RACE_DONE" ]; then
  cp "$AIRLOCK_TEST_CONFIG_RACE_REPLACEMENT" "$AIRLOCK_CONFIG"
  : > "$AIRLOCK_TEST_CONFIG_RACE_DONE"
fi
exec "$@"
STUB
cat >"$SHIM/systemctl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/systemctl.log"
case "\$*" in *list-timers*) printf '%s\n' 'Mon 2026-09-02 00:00:00 KST 1d left airlock-update-detect.timer airlock-update-detect.service' ;; esac
case "\$*" in *daemon-reload*) [ -e "$TMP/reload-fails" ] && exit 1 ;; esac
# Real systemd's \`disable\` REMOVES a symlinked unit file itself. Opt-in seam
# (flag file) so a test can model that; every other test sees the old shim.
if [ -e "$TMP/disable-removes-unit" ]; then
  case "\$*" in
    *disable*)
      for _a in "\$@"; do
        case "\$_a" in *.service|*.timer) rm -f "$UU/\$_a" ;; esac
      done ;;
  esac
fi
exit 0
STUB
cat >"$SHIM/tailscale" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = status ] && [ "\${2:-}" = --json ]; then
  printf '{"BackendState":"Running","CertDomains":["example.ts.net"],"Self":{"DNSName":"box.example.ts.net."},"Health":[]}\n'
  exit 0
fi
if [ "\${1:-}" = serve ] && [ "\${2:-}" = status ]; then
  printf '{"TCP":{}}\n'; exit 0
fi
case "\$*" in serve\ --http=*\ off) [ -e "$TMP/serve-off-fails" ] && { printf '%s\n' "\$*" >> "$TMP/tailscale.log"; exit 1; } ;; esac
printf '%s\n' "\$*" >> "$TMP/tailscale.log"
exit 0
STUB
cat >"$SHIM/nginx" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$SHIM/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in *http_code*) printf 200 ;; esac
exit 0
STUB
chmod +x "$SHIM"/*
PATH="$SHIM:$PATH"; export PATH

# ---- helpers -----------------------------------------------------------------
run() { AIRLOCK_CONFIG="$1" python3 "$CFG" "${@:2}"; }

# mkcfg <path> <extra-toml...>
mkcfg() {
  local path="$1"; shift
  { printf '[auth]\nprovider = "tailscale"\nowner = "me@example.com"\n[apps.hub]\n'
    printf '%s\n' "$@"; } >"$path"
}

# manifest <path> <id> [config-key ...] — write a minimal child-3 manifest
# header, then append the artifact body from stdin.  Most child-2 fixtures set
# backend_port in [apps.X], so that is the default declared key.
manifest() {
  local path="$1" id="$2" key
  shift 2
  [ "$#" -gt 0 ] || set -- backend_port
  {
    printf 'contract = 1\nid = "%s"\n' "$id"
    if [ "${1:-}" != "-" ]; then
      printf '[config.defaults]\n'
      for key in "$@"; do
        printf '%s = 18900\n' "$key"
      done
    fi
    cat
  } >"$path"
}

# mkpkg <dir> <id> [with_deactivate:1|0] — a minimal contract-conforming
# package. Its scripts use ONLY the D5 ABI variables and record how they were
# invoked, so the fixtures can assert env + cwd. install.sh writes one declared
# webroot marker and one data file; deactivate removes the marker, keeps data.
mkpkg() {
  local dir="$1" id="$2" deact="${3:-1}" env_id
  env_id="${id^^}"
  env_id="${env_id//-/_}"
  mkdir -p "$dir"
  cat >"$dir/airlock-app.toml" <<EOF
contract = 1
id = "$id"
[config.defaults]
backend_port = 18900
[artifacts]
webroot = ["$id/"]
serve_ports = ["backend_port"]
EOF
  cat >"$dir/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_${env_id}_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
printf 'ROOT=%s DIR=%s ID=%s CWD=%s\n' "\$AIRLOCK_ROOT" "\$AIRLOCK_APP_DIR" "\$AIRLOCK_APP_ID" "\$PWD" >> "$TMP/invoke-\$AIRLOCK_APP_ID.log"
mkdir -p "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID"
printf 'marker\n' > "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID/marker"
printf 'data\n' >> "$DATA/\$AIRLOCK_APP_ID.data"
EOF
  cat >"$dir/smoke.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'SMOKE ID=%s CWD=%s\n' "\$AIRLOCK_APP_ID" "\$PWD" >> "$TMP/invoke-\$AIRLOCK_APP_ID.log"
[ -f "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID/marker" ]
EOF
  if [ "$deact" = 1 ]; then
    cat >"$dir/deactivate.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
rm -f "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID/marker"
rmdir "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID" 2>/dev/null || true
exit 0
EOF
  fi
  chmod +x "$dir"/*.sh 2>/dev/null || true
}

# orch <config> [VAR=val...] — the real orchestrator against the scratch box.
orch() {
  local cfg="$1"; shift
  env HOME="$FAKEHOME" AIRLOCK_CONFIG="$cfg" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
      "$@" bash "$ROOT/install/airlock-install.sh"
}

ledger_json() { cat "$STATE/app-ledger.json" 2>/dev/null || printf '{"version":1,"entries":{}}'; }
ledger_field() { # ledger_field <id> <python-expr over rec dict e> — committed record field
  ledger_json | python3 -c '
import json, sys
e = json.load(sys.stdin)["entries"].get(sys.argv[1]) or {}
print(eval(sys.argv[2], {"e": e}))
' "$1" "$3" 2>/dev/null
}

# =============================================================================
# F10 resolver cases + artifact grammar (validate-time, no orchestrator run)
# =============================================================================
reset_box
PKGROOT="$TMP/pkgs"; mkdir -p "$PKGROOT"
mkpkg "$PKGROOT/good" t1 1

CFGDIR="$TMP/cfgs"; mkdir -p "$CFGDIR"

mkcfg "$CFGDIR/ok.toml" "[apps.t1]" "backend_port = 18900" "[packages.t1]" "path = \"$PKGROOT/good\""
if run "$CFGDIR/ok.toml" validate >/dev/null 2>&1; then
  ok "resolver: a conforming package validates"
else
  bad "resolver: a conforming package validates"
fi

preflight_a="$(run "$CFGDIR/ok.toml" install-preflight 2>/dev/null)" || preflight_a=""
preflight_b="$(run "$CFGDIR/ok.toml" install-preflight 2>/dev/null)" || preflight_b=""
if [[ "$preflight_a" =~ ^[0-9a-f]{64}$ ]] && [ "$preflight_a" = "$preflight_b" ]; then
  ok "candidate preflight: every static projection resolves to one deterministic digest"
else
  bad "candidate preflight: digest is missing or unstable ($preflight_a / $preflight_b)"
fi
pkginfo="$(run "$CFGDIR/ok.toml" package-info 2>/dev/null)" || pkginfo=""
preflight_bound="$(printf '%s' "$pkginfo" | AIRLOCK_CONFIG="$CFGDIR/ok.toml" \
  python3 "$CFG" install-preflight --package-info-stdin 2>/dev/null)" \
  || preflight_bound=""
if [[ "$preflight_bound" =~ ^[0-9a-f]{64}$ ]]; then
  ok "candidate preflight: exact ledger package-info authority is bound into the digest"
else
  bad "candidate preflight: exact package-info authority was not accepted"
fi
out="$(printf '{}' | AIRLOCK_CONFIG="$CFGDIR/ok.toml" python3 "$CFG" \
  install-preflight --package-info-stdin 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && grep -q "differs from the orchestrator snapshot" <<<"$out"; then
  ok "candidate preflight: ledger package-info authority must exactly match the candidate"
else
  bad "candidate preflight: mismatched package-info authority was accepted (rc=$rc)"
fi

# PRIVATE_RELEASE_PATH launcher oracle: these are explicit package manifests,
# with no [shortcuts] or other fallback catalog input. webjson must project the
# three private tiles verbatim (except the documented staged icon URL rewrite).
TILES="$TMP/private-tiles"; mkdir -p "$TILES"
for private_id in vm-monitor slides-manager notes-stack; do
  mkpkg "$TILES/$private_id" "$private_id" 1
done
cat >>"$TILES/vm-monitor/airlock-app.toml" <<'EOF'
[tile]
label = "Windows VM"
sub = "Private Windows monitor"
cat = "system"
path = "/vm-monitor/"
glyph = "monitor"
EOF
printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' >"$TILES/slides-manager/tile.svg"
cat >>"$TILES/slides-manager/airlock-app.toml" <<'EOF'
[tile]
label = "Slides"
sub = "Private gallery"
cat = "docs"
path = "/slides/"
icon = "tile.svg"
EOF
cat >>"$TILES/notes-stack/airlock-app.toml" <<'EOF'
[tile]
label = "Notes"
sub = "Private notes"
cat = "docs"
path = "/notes/"
glyph = "note"
EOF
mkcfg "$TILES/airlock.toml" \
  "[apps.vm-monitor]" "backend_port = 18931" \
  "[apps.slides-manager]" "backend_port = 18932" \
  "[apps.notes-stack]" "backend_port = 18933" \
  "[packages.vm-monitor]" "path = \"$TILES/vm-monitor\"" \
  "[packages.slides-manager]" "path = \"$TILES/slides-manager\"" \
  "[packages.notes-stack]" "path = \"$TILES/notes-stack\""
tiles_json="$(run "$TILES/airlock.toml" webjson 2>/dev/null)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && printf '%s' "$tiles_json" | python3 -c '
import json, sys
apps = json.load(sys.stdin)["apps"]
assert {k for k, v in apps.items() if v.get("packaged")} == {
    "vm-monitor", "slides-manager", "notes-stack"
}
assert sum(bool(v.get("shortcut")) for v in apps.values()) == 0
assert apps["vm-monitor"]["tile"] == {
    "label": "Windows VM", "sub": "Private Windows monitor", "cat": "system",
    "path": "/vm-monitor/", "glyph": "monitor",
}
assert apps["slides-manager"]["tile"] == {
    "label": "Slides", "sub": "Private gallery", "cat": "docs",
    "path": "/slides/", "icon": "/assets/apps/slides-manager/tile.svg",
}
assert apps["notes-stack"]["tile"] == {
    "label": "Notes", "sub": "Private notes", "cat": "docs",
    "path": "/notes/", "glyph": "note",
}
' >/dev/null 2>&1; then
  ok "private tiles: vm-monitor/slides-manager/notes manifests project into webjson with fallback inputs=0"
else
  bad "private tiles: manifest-to-webjson projection drifted (rc=$rc)"
fi

mkcfg "$CFGDIR/git.toml" "[apps.t1]" "[packages.t1]" 'source = "git+https://example.com/x.git"'
msg="$(run "$CFGDIR/git.toml" validate 2>&1)" && bad "F10: git+ source rejected" || {
  grep -q "unknown key(s) in \[packages.t1\]: source" <<<"$msg" \
    && ok "F10: git+ source rejected (path is the only key)" \
    || bad "F10: git+ source rejected — wrong message: $msg"; }

mkcfg "$CFGDIR/grammar.toml" '[apps.a_b]' '[packages.a_b]' "path = \"$PKGROOT/good\""
msg="$(run "$CFGDIR/grammar.toml" validate 2>&1)" && bad "F10: id grammar (a_b)" || {
  grep -q "invalid package id 'a_b'" <<<"$msg" \
    && ok "F10: id grammar rejects a_b (env-key collision class)" \
    || bad "F10: id grammar rejects a_b — wrong message: $msg"; }

mkcfg "$CFGDIR/noapps.toml" "[packages.t1]" "path = \"$PKGROOT/good\""
msg="$(run "$CFGDIR/noapps.toml" validate 2>&1)" && bad "F2a: package without [apps.X]" || {
  grep -q "no \[apps.t1\] table" <<<"$msg" \
    && ok "F2a: [packages.X] without [apps.X] is fatal" \
    || bad "F2a: wrong message: $msg"; }

mkcfg "$CFGDIR/hub.toml" "[packages.hub]" "path = \"$PKGROOT/good\""
msg="$(run "$CFGDIR/hub.toml" validate 2>&1)" && bad "F3a: [packages.hub] rejected" || {
  grep -q "reserved platform core" <<<"$msg" \
    && ok "F3a: hub is reserved core and cannot be shadowed" \
    || bad "F3a: wrong message: $msg"; }

mkcfg "$CFGDIR/nodir.toml" "[apps.t1]" "[packages.t1]" "path = \"$TMP/does-not-exist\""
msg="$(run "$CFGDIR/nodir.toml" validate 2>&1)" && bad "resolver: missing dir fatal" || {
  grep -q "does not resolve to a directory" <<<"$msg" \
    && ok "resolver: missing package dir is fatal" \
    || bad "resolver: missing dir — wrong message: $msg"; }

nomani="$PKGROOT/nomani"; mkdir -p "$nomani"; touch "$nomani/install.sh" "$nomani/smoke.sh"
mkcfg "$CFGDIR/nomani.toml" "[apps.t1]" "[packages.t1]" "path = \"$nomani\""
msg="$(run "$CFGDIR/nomani.toml" validate 2>&1)" && bad "resolver: missing manifest fatal" || {
  grep -q "has no airlock-app.toml" <<<"$msg" \
    && ok "resolver: missing airlock-app.toml is fatal (ledger needs it)" \
    || bad "resolver: missing manifest — wrong message: $msg"; }

# Child 4/P3 review finding (Minor 1): the case above is the EXPLICIT path
# (a [packages.X] line pointing at a dir with no manifest). The IMPLICIT
# shipped path needs its own fail-closed fixture — a real built-in id
# configured with no [packages.X] line at all resolves through
# AIRLOCK_SHIPPED_APPS_ROOT/<id>/airlock-app.toml; if THAT manifest is
# missing (a stripped-down install, a bad AIRLOCK_SHIPPED_APPS_ROOT
# override), validate must still die — this is the P3 flip's "missing
# manifest fatal" bullet exercised on the path that has no [packages.X]
# line to trigger on.
noship="$TMP/noship-apps"; mkdir -p "$noship/notepad"   # dir exists, manifest does not
mkcfg "$CFGDIR/noship.toml" "[apps.notepad]"
msg="$(AIRLOCK_SHIPPED_APPS_ROOT="$noship" run "$CFGDIR/noship.toml" validate 2>&1)" \
  && bad "resolver: implicit shipped manifest missing is not fatal" || {
  grep -q "unknown app \[apps.notepad\]" <<<"$msg" \
    && ok "resolver: a built-in with no manifest at its implicit shipped path is fatal (P3 fail-closed)" \
    || bad "resolver: implicit shipped manifest missing — wrong message: $msg"; }

badart="$PKGROOT/badart"; mkpkg "$badart" t1 1
manifest "$badart/airlock-app.toml" t1 <<'EOF'
[artifacts]
units = ["../evil.service"]
EOF
mkcfg "$CFGDIR/badart.toml" "[apps.t1]" "[packages.t1]" "path = \"$badart\""
msg="$(run "$CFGDIR/badart.toml" validate 2>&1)" && bad "F10: unit name escape" || {
  grep -q "bare unit file name" <<<"$msg" \
    && ok "F10: units entry with a path separator / '..' is fatal" \
    || bad "F10: unit escape — wrong message: $msg"; }

manifest "$badart/airlock-app.toml" t1 <<'EOF'
[artifacts]
webroot = ["../outside/"]
EOF
msg="$(run "$CFGDIR/badart.toml" validate 2>&1)" && bad "F10: webroot escape" || {
  grep -q "no '.' or '..' segments" <<<"$msg" \
    && ok "F10: webroot '..' segment is fatal (containment by construction)" \
    || bad "F10: webroot escape — wrong message: $msg"; }

manifest "$badart/airlock-app.toml" t1 <<'EOF'
[artifacts]
bogus = ["x"]
EOF
msg="$(run "$CFGDIR/badart.toml" validate 2>&1)" && bad "F10: artifact class typo" || {
  grep -q "unknown \[artifacts\] key" <<<"$msg" \
    && ok "F10: unknown artifact class is fatal (we validate what we read)" \
    || bad "F10: class typo — wrong message: $msg"; }

cat > "$badart/airlock-app.toml" <<'EOF'
contract = 1
id = "t1"
[artifacts]
serve_ports = ["backend_port"]
EOF
mkcfg "$CFGDIR/noport.toml" "[apps.t1]" "[packages.t1]" "path = \"$badart\""
msg="$(run "$CFGDIR/noport.toml" validate 2>&1)" && bad "F10: undeclared serve key" || {
  grep -q "artifacts.serve_ports names 'backend_port', which is not a declared config key" <<<"$msg" \
    && ok "F10: serve_ports key absent from the manifest config schema is fatal" \
    || bad "F10: undeclared serve key — wrong message: $msg"; }

# Pattern overlap: two packages, same webroot dir; then the fnmatch-blind pair.
ovA="$PKGROOT/ovA"; mkpkg "$ovA" o1 1; ovB="$PKGROOT/ovB"; mkpkg "$ovB" o2 1
manifest "$ovA/airlock-app.toml" o1 - <<'EOF'
[artifacts]
webroot = ["shared/"]
EOF
manifest "$ovB/airlock-app.toml" o2 - <<'EOF'
[artifacts]
webroot = ["shared/"]
EOF
mkcfg "$CFGDIR/ov.toml" "[apps.o1]" "[apps.o2]" \
  "[packages.o1]" "path = \"$ovA\"" "[packages.o2]" "path = \"$ovB\""
msg="$(run "$CFGDIR/ov.toml" validate 2>&1)" && bad "F10: pattern overlap (configured)" || {
  grep -q "overlapping artifacts" <<<"$msg" \
    && ok "F10: two packages claiming one webroot path is fatal" \
    || bad "F10: overlap — wrong message: $msg"; }

manifest "$ovA/airlock-app.toml" o1 - <<'EOF'
[artifacts]
webroot = ["shared/a*"]
EOF
manifest "$ovB/airlock-app.toml" o2 - <<'EOF'
[artifacts]
webroot = ["shared/*b"]
EOF
msg="$(run "$CFGDIR/ov.toml" validate 2>&1)" && bad "F10: glob overlap a* vs *b" || {
  grep -q "overlapping artifacts" <<<"$msg" \
    && ok "F10: 'a*' vs '*b' is caught (bidirectional fnmatch would miss it)" \
    || bad "F10: glob overlap — wrong message: $msg"; }

# Cross-class alias: a fragments entry vs a files entry naming the same real path.
manifest "$ovA/airlock-app.toml" o1 - <<'EOF'
[artifacts]
fragments = ["hub-locations.d/x.conf"]
EOF
manifest "$ovB/airlock-app.toml" o2 - <<EOF
[artifacts]
files = ["$CONFD/hub-locations.d/x.conf"]
EOF
msg="$(run "$CFGDIR/ov.toml" validate 2>&1)" && bad "F10: cross-class alias" || {
  grep -q "overlapping artifacts" <<<"$msg" \
    && ok "F10: fragments vs files naming one real path is fatal (resolved-root space)" \
    || bad "F10: cross-class alias — wrong message: $msg"; }

# Distinct literal prefixes stay allowed (the conservative rule must not
# reject everything).
manifest "$ovA/airlock-app.toml" o1 - <<'EOF'
[artifacts]
webroot = ["o1/"]
EOF
manifest "$ovB/airlock-app.toml" o2 - <<'EOF'
[artifacts]
webroot = ["o2/"]
EOF
if run "$CFGDIR/ov.toml" validate >/dev/null 2>&1; then
  ok "F10: disjoint literal prefixes still validate"
else
  bad "F10: disjoint literal prefixes still validate"
fi

# Serve-port value overlap between two configured packages.
manifest "$ovA/airlock-app.toml" o1 <<'EOF'
[artifacts]
serve_ports = ["backend_port"]
EOF
manifest "$ovB/airlock-app.toml" o2 <<'EOF'
[artifacts]
serve_ports = ["backend_port"]
EOF
mkcfg "$CFGDIR/ovp.toml" "[apps.o1]" "backend_port = 18900" "[apps.o2]" "backend_port = 18900" \
  "[packages.o1]" "path = \"$ovA\"" "[packages.o2]" "path = \"$ovB\""
msg="$(run "$CFGDIR/ovp.toml" validate 2>&1)" && bad "F10: serve value overlap" || {
  # the generic *_port uniqueness check may fire first — either refusal is the contract
  grep -qE "serve port 18900|port 18900 is used twice" <<<"$msg" \
    && ok "F10: two packages claiming serve port 18900 is fatal" \
    || bad "F10: serve overlap — wrong message: $msg"; }

# FIFO in the package tree: fatal at validate (D6 digest serialization).
fifopkg="$PKGROOT/fifo"; mkpkg "$fifopkg" t1 1
mkfifo "$fifopkg/pipe"
mkcfg "$CFGDIR/fifo.toml" "[apps.t1]" "backend_port = 18900" "[packages.t1]" "path = \"$fifopkg\""
msg="$(run "$CFGDIR/fifo.toml" validate 2>&1)" && bad "F10: FIFO fatal at validate" || {
  grep -q "special file" <<<"$msg" \
    && ok "F10: a FIFO in the package tree is fatal at validate" \
    || bad "F10: FIFO — wrong message: $msg"; }
rm -rf "$fifopkg"

# F9a: a corrupt ledger fails validate closed, naming the file — never "empty".
mkdir -p "$STATE"; printf 'garbage' > "$STATE/app-ledger.json"
msg="$(run "$CFGDIR/ok.toml" validate 2>&1)" && bad "F9a: corrupt ledger fails validate" || {
  grep -q "app-ledger.json" <<<"$msg" && grep -q "NOT treated as empty" <<<"$msg" \
    && ok "F9a: corrupt ledger fails validate, naming the file" \
    || bad "F9a: corrupt ledger — wrong message: $msg"; }
rm -f "$STATE/app-ledger.json"

# F9a: parseable-but-malformed ledgers fail validate too — record shape, not
# just JSON syntax (validate shares the ledger tools' one store schema).
printf '{"version":1,"entries":{"x":[]}}\n' > "$STATE/app-ledger.json"
msg="$(run "$CFGDIR/ok.toml" validate 2>&1)" && bad "F9a: malformed entry fails validate" || {
  grep -q "NOT treated as empty" <<<"$msg" \
    && ok "F9a: a parseable ledger with a malformed entry still fails validate" \
    || bad "F9a: malformed entry — wrong message: $msg"; }
printf '{"version":1,"entries":{"x":{"committed":{"path":"/p","digest":"zz","lifecycle":{"install":true,"smoke":true,"deactivate":true},"artifacts":{"units":[],"fragments":[],"webroot":[],"files":[],"serve_ports":[]}}}}}\n' > "$STATE/app-ledger.json"
msg="$(run "$CFGDIR/ok.toml" validate 2>&1)" && bad "F9a: bad digest fails validate" || {
  grep -q "digest" <<<"$msg" \
    && ok "F9a: a committed record with a malformed digest fails validate" \
    || bad "F9a: bad digest — wrong message: $msg"; }
rm -f "$STATE/app-ledger.json"

# The shell orchestrator computes the lock path from AIRLOCK_STATE_DIR
# verbatim; the python tools must read the same value the same way, or a
# literal ~ would put the lock and the ledger in different directories.
mkdir -p "$TMP/tilde/~/state"; printf 'garbage' > "$TMP/tilde/~/state/app-ledger.json"
msg="$(cd "$TMP/tilde" && env HOME="$FAKEHOME" AIRLOCK_STATE_DIR="~/state" AIRLOCK_CONFIG="$CFGDIR/ok.toml" python3 "$CFG" validate 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && grep -q "unreadable" <<<"$msg"; then
  ok "F9a: AIRLOCK_STATE_DIR with a literal ~ is read verbatim (lock and ledger agree)"
else
  bad "F9a: literal ~ in AIRLOCK_STATE_DIR was expanded away (rc=$rc)"
fi
rm -rf "$TMP/tilde"

# ...and a symlink followed by `..`: the kernel resolves the symlink first,
# a lexical abspath() would not — the tools must see the shell's directory.
mkdir -p "$TMP/sl/a/b"; ln -s "$TMP/sl/a/b" "$TMP/sl/sym"
printf 'garbage' > "$TMP/sl/a/app-ledger.json"
msg="$(env HOME="$FAKEHOME" AIRLOCK_STATE_DIR="$TMP/sl/sym/.." AIRLOCK_CONFIG="$CFGDIR/ok.toml" python3 "$CFG" validate 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && grep -q "unreadable" <<<"$msg"; then
  ok "F9a: symlink+.. in AIRLOCK_STATE_DIR reads the kernel-resolved directory"
else
  bad "F9a: symlink+.. state dir diverged from the shell's view (rc=$rc)"
fi
rm -rf "$TMP/sl"

# =============================================================================
# F1 — out-of-tree round trip (real orchestrator, relative path, foreign cwd)
# =============================================================================
reset_box
F1DIR="$TMP/f1"; mkdir -p "$F1DIR/cfg" "$F1DIR/elsewhere"
mkpkg "$F1DIR/pkg" t1 1
mkpkg "$F1DIR/sibling" t9 1   # fully formed, named in no [packages] table
mkcfg "$F1DIR/cfg/airlock.toml" "[apps.t1]" "backend_port = 18900" \
  "[packages.t1]" 'path = "../pkg"'

out="$(cd "$F1DIR/elsewhere" && orch "$F1DIR/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ]; then ok "F1: orchestrator run with a packaged app succeeds"; else
  bad "F1: orchestrator run failed (rc=$rc): $(tail -5 <<<"$out")"; fi

# Relative path resolved against the CONFIG dir, not the (unrelated) cwd.
grep -q "installing packaged app: t1 ($F1DIR/pkg)" <<<"$out" \
  && ok "F1: relative package path resolves against the config's directory" \
  || bad "F1: relative path resolution (log: $(grep -m1 'packaged app' <<<"$out" || echo none))"

inv="$(cat "$TMP/invoke-t1.log" 2>/dev/null || true)"
grep -q "ROOT=$ROOT DIR=$F1DIR/pkg ID=t1 CWD=$F1DIR/pkg" <<<"$inv" \
  && ok "F1: install ran under the D5 ABI (ROOT/DIR/ID set, cwd = package dir)" \
  || bad "F1: ABI env/cwd (got: $(head -1 <<<"$inv"))"
grep -q "SMOKE ID=t1 CWD=$F1DIR/pkg" <<<"$inv" \
  && ok "F1: smoke ran from the same resolution" \
  || bad "F1: smoke resolution (got: $inv)"

st="$(ledger_field t1 x '("committed" in e) and e["committed"]["path"]')"
[ "$st" = "$F1DIR/pkg" ] \
  && ok "F1: committed ledger entry carries the canonical path" \
  || bad "F1: committed path (got: $st)"
dg="$(ledger_field t1 x 'len(e.get("committed",{}).get("digest",""))')"
[ "$dg" = 64 ] \
  && ok "F1: committed entry carries a D6 digest (64 hex chars)" \
  || bad "F1: digest length (got: $dg)"
lf="$(ledger_field t1 x 'e.get("committed",{}).get("lifecycle",{}).get("deactivate")')"
[ "$lf" = True ] \
  && ok "F1: committed entry records the lifecycle capability" \
  || bad "F1: lifecycle capability (got: $lf)"
exp="$(ledger_field t1 x '[p for p in e.get("committed",{}).get("artifacts",{}).get("webroot",[])]')"
grep -q "$WEB/t1" <<<"$exp" \
  && ok "F1: committed entry carries the expanded artifact list" \
  || bad "F1: expanded artifacts (got: $exp)"

# Sibling non-discovery: present on disk, referenced nowhere -> never touched.
if [ ! -f "$TMP/invoke-t9.log" ] && ! grep -q t9 <<<"$out" \
   && [ "$(ledger_field t9 x '"committed" in e')" != True ]; then
  ok "F1: a sibling package named in no [packages] table is never resolved"
else
  bad "F1: sibling package leaked into the run"
fi

# The platform mapped the declared serve port (D2 serve_ports lifecycle).
grep -q -- "serve --bg --http=18900 http://127.0.0.1:18900" "$TMP/tailscale.log" \
  && ok "F1: declared serve port mapped by the platform" \
  || bad "F1: serve mapping (log: $(grep 18900 "$TMP/tailscale.log" 2>/dev/null || echo none))"

# D5: same digest, second run -> installer runs AGAIN (the digest never skips).
out2="$(cd "$F1DIR/elsewhere" && orch "$F1DIR/cfg/airlock.toml" 2>&1)" || true
n_inst="$(grep -c '^ROOT=' "$TMP/invoke-t1.log")"
[ "$n_inst" = 2 ] \
  && ok "D5: an unchanged package still re-runs its installer every reconcile" \
  || bad "D5: re-run rule (installer ran $n_inst times, want 2)"

# Drop both tables and reconcile: deactivate runs, data survives, no orphans.
mkcfg "$F1DIR/cfg/airlock.toml"
out3="$(cd "$F1DIR/elsewhere" && orch "$F1DIR/cfg/airlock.toml" 2>&1)" && rc3=0 || rc3=$?
[ "$rc3" = 0 ] || bad "F1: removal run failed (rc=$rc3): $(tail -3 <<<"$out3")"
[ ! -e "$WEB/t1/marker" ] \
  && ok "F1: deactivate.sh removed the declared marker" \
  || bad "F1: marker still present after removal"
[ -f "$DATA/t1.data" ] \
  && ok "F1: app data survives deactivation (data is never torn down)" \
  || bad "F1: data file was deleted"
[ "$(ledger_field t1 x '"committed" in e or "intent" in e')" != True ] \
  && ok "F1: ledger entry dropped after removal" \
  || bad "F1: ledger entry survived removal"
grep -q -- "--http=18900 off" "$TMP/tailscale.log" \
  && ok "F1: serve mapping reclaimed on removal" \
  || bad "F1: serve mapping not reclaimed"

# Deactivate idempotence, against the script directly (after the record is
# gone a second reconcile correctly has nothing to do).
if (cd "$F1DIR/pkg" && AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$F1DIR/pkg" AIRLOCK_APP_ID=t1 \
      AIRLOCK_WEBROOT="$WEB" bash deactivate.sh && \
    AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$F1DIR/pkg" AIRLOCK_APP_ID=t1 \
      AIRLOCK_WEBROOT="$WEB" bash deactivate.sh); then
  ok "F1: deactivate.sh is idempotent (second direct invocation exits clean)"
else
  bad "F1: deactivate.sh second invocation failed"
fi

# =============================================================================
# F3(b) — shadowing a built-in resolves the override, never $ROOT/apps
# =============================================================================
reset_box
SH="$TMP/shadow"; mkdir -p "$SH/cfg"; mkpkg "$SH/pkg" notepad 1
# A shadowed built-in keeps its central schema in child 2 (the manifest reader
# is child 3), so the [apps.notepad] table stays key-free and the manifest
# declares no serve_ports.
manifest "$SH/pkg/airlock-app.toml" notepad <<'EOF'
[artifacts]
webroot = ["notepad/"]
EOF
mkcfg "$SH/cfg/airlock.toml" "[apps.notepad]" \
  "[packages.notepad]" "path = \"$SH/pkg\""
out="$(orch "$SH/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
# The real apps/notepad/install.sh dies without publish enabled, so a passing
# run by itself proves the override was used; the log line pins the path.
if [ "$rc" = 0 ] && grep -q "installing packaged app: notepad ($SH/pkg)" <<<"$out"; then
  ok "F3b: [packages.notepad] shadows the built-in (override path, run passes)"
else
  bad "F3b: shadowing (rc=$rc, log: $(grep -m1 notepad <<<"$out" || echo none))"
fi
[ "$(ledger_field notepad x 'e.get("committed",{}).get("path","")')" = "$SH/pkg" ] \
  && ok "F3b: ledger records the canonical override path" \
  || bad "F3b: ledger path"

# =============================================================================
# F7 — the deactivator-less package
# =============================================================================
reset_box
F7="$TMP/f7"; mkdir -p "$F7/cfg"; mkpkg "$F7/pkg" t2 0     # no deactivate.sh
mkcfg "$F7/cfg/airlock.toml" "[apps.t2]" "backend_port = 18902" \
  "[packages.t2]" "path = \"$F7/pkg\""
orch "$F7/cfg/airlock.toml" >/dev/null 2>&1 \
  || bad "F7: install of a deactivator-less package failed"
[ "$(ledger_field t2 x 'e.get("committed",{}).get("lifecycle",{}).get("deactivate")')" = False ] \
  && ok "F7: ledger records install/upgrade-only (no deactivator)" \
  || bad "F7: lifecycle capability recording"

# (a) dropping it from config is refused; nothing is touched. Path present:
mkcfg "$F7/cfg/airlock.toml"
out="$(orch "$F7/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && grep -q "airlock-teardown t2" <<<"$out" && [ -f "$WEB/t2/marker" ]; then
  ok "F7a: refusal names the app and the explicit teardown; artifacts untouched"
else
  bad "F7a: refusal (rc=$rc, marker=$([ -f "$WEB/t2/marker" ] && echo kept || echo GONE))"
fi
# Path gone: the refusal must hold regardless of path state (priority 1 first).
mv "$F7/pkg" "$F7/pkg-moved"
out="$(orch "$F7/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && grep -q "airlock-teardown t2" <<<"$out" && [ -f "$WEB/t2/marker" ]; then
  ok "F7a: refusal holds with the package path gone"
else
  bad "F7a: path-gone refusal (rc=$rc)"
fi
mv "$F7/pkg-moved" "$F7/pkg"

# (b) the explicit teardown removes every recorded artifact and drops the record.
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$F7/cfg/airlock.toml" bash "$ROOT/bin/airlock-teardown" t2 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ ! -e "$WEB/t2/marker" ] \
   && [ "$(ledger_field t2 x '"committed" in e')" != True ]; then
  ok "F7b: explicit teardown removes recorded artifacts and drops the record"
else
  bad "F7b: teardown (rc=$rc): $(tail -3 <<<"$out")"
fi
grep -q "platform-performed" <<<"$out" \
  && ok "F7b: teardown logs that the removal was platform-performed" \
  || bad "F7b: teardown log wording"

# A teardown of a still-enabled app is refused (reconcile owns desired state).
mkcfg "$F7/cfg/airlock.toml" "[apps.t2]" "backend_port = 18902" "[packages.t2]" "path = \"$F7/pkg\""
orch "$F7/cfg/airlock.toml" >/dev/null 2>&1 || true
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$F7/cfg/airlock.toml" bash "$ROOT/bin/airlock-teardown" t2 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && grep -q "still enabled" <<<"$out"; then
  ok "F7: teardown of a still-enabled app is refused"
else
  bad "F7: enabled-app teardown guard (rc=$rc)"
fi

# (c) upgrade: v2 stops claiming the webroot dir; the old-only artifact is
# gone once the run ends, with no deactivation step, and the new entry commits.
manifest "$F7/pkg/airlock-app.toml" t2 <<'EOF'
[artifacts]
serve_ports = ["backend_port"]
EOF
cat > "$F7/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_T2_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
printf 'v2\n' >> "$TMP/invoke-t2.log"
EOF
cat > "$F7/pkg/smoke.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
out="$(orch "$F7/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ ! -e "$WEB/t2/marker" ] \
   && [ "$(ledger_field t2 x '"committed" in e')" = True ]; then
  ok "F7c: no-deactivator upgrade removed the artifact v2 stopped claiming (record diff)"
else
  bad "F7c: upgrade record diff (rc=$rc, marker=$([ -e "$WEB/t2/marker" ] && echo present || echo gone))"
fi

# =============================================================================
# F8 — path gone / digest mismatch (packages WITH a deactivator)
# =============================================================================
reset_box
F8="$TMP/f8"; mkdir -p "$F8/cfg"; mkpkg "$F8/pkg" t3 1
mkcfg "$F8/cfg/airlock.toml" "[apps.t3]" "backend_port = 18903" "[packages.t3]" "path = \"$F8/pkg\""
orch "$F8/cfg/airlock.toml" >/dev/null 2>&1 || bad "F8: setup install failed"
rm -rf "$F8/pkg"
mkcfg "$F8/cfg/airlock.toml"
out="$(orch "$F8/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ ! -e "$WEB/t3/marker" ] \
   && [ "$(ledger_field t3 x '"committed" in e')" != True ]; then
  ok "F8: path gone — teardown proceeds from the recorded artifact list alone"
else
  bad "F8: path-gone teardown (rc=$rc)"
fi
grep -qi "deactivator did not run" <<<"$out" \
  && ok "F8: logs that the package's own deactivator did not run" \
  || bad "F8: missing did-not-run log"

# Digest mismatch variant: mutate one file's CONTENT, drop config, reconcile.
reset_box
mkdir -p "$F8/cfg"; mkpkg "$F8/pkg" t3 1
mkcfg "$F8/cfg/airlock.toml" "[apps.t3]" "backend_port = 18903" "[packages.t3]" "path = \"$F8/pkg\""
orch "$F8/cfg/airlock.toml" >/dev/null 2>&1 || bad "F8: setup install failed (variant)"
printf '# mutated\n' >> "$F8/pkg/install.sh"
mkcfg "$F8/cfg/airlock.toml"
out="$(orch "$F8/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ ! -e "$WEB/t3/marker" ] && grep -qi "deactivator did not run" <<<"$out"; then
  ok "F8: digest mismatch — recorded-list teardown, mutated deactivator never trusted"
else
  bad "F8: digest-mismatch teardown (rc=$rc)"
fi

# Digest sensitivity beyond content: a mode-only change and a symlink
# retarget must each flip the digest (D6 serializes type, mode, and symlink
# target — a tree that differs only there is still a different tree).
reset_box
mkdir -p "$F8/cfg"; mkpkg "$F8/pkg" t3 1
ln -s install.sh "$F8/pkg/link"
mkcfg "$F8/cfg/airlock.toml" "[apps.t3]" "backend_port = 18903" "[packages.t3]" "path = \"$F8/pkg\""
orch "$F8/cfg/airlock.toml" >/dev/null 2>&1 || bad "F8: setup install failed (mode variant)"
chmod 600 "$F8/pkg/smoke.sh"
out="$(orch "$F8/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
{ [ "$rc" = 0 ] && grep -qi "deactivator did not run" <<<"$out"; } \
  && ok "F8: a mode-only change flips the digest (stale-tree deactivator untrusted)" \
  || bad "F8: mode change invisible to the digest (rc=$rc)"
ln -sfn smoke.sh "$F8/pkg/link"
out="$(orch "$F8/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
{ [ "$rc" = 0 ] && grep -qi "deactivator did not run" <<<"$out"; } \
  && ok "F8: a symlink retarget flips the digest (stale-tree deactivator untrusted)" \
  || bad "F8: symlink retarget invisible to the digest (rc=$rc)"

# =============================================================================
# F9(b) — crash repair, both directions; (c) one writer
# =============================================================================
reset_box
F9="$TMP/f9"; mkdir -p "$F9/cfg"; mkpkg "$F9/pkg" t4 1
# install.sh writes its artifact, then dies before the run can commit.
cat > "$F9/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_T4_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
mkdir -p "\$AIRLOCK_WEBROOT/t4"; printf 'marker\n' > "\$AIRLOCK_WEBROOT/t4/marker"
exit 1
EOF
mkcfg "$F9/cfg/airlock.toml" "[apps.t4]" "backend_port = 18904" "[packages.t4]" "path = \"$F9/pkg\""
out="$(orch "$F9/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
[ "$rc" != 0 ] || bad "F9b: crashing installer should fail the run"
if [ "$(ledger_field t4 x '"intent" in e')" = True ] \
   && [ "$(ledger_field t4 x '"committed" in e')" != True ]; then
  ok "F9b: a run that dies after install leaves an intent entry, no commit"
else
  bad "F9b: intent state after crash (ledger: $(ledger_json | head -c 200))"
fi

# Still desired -> the next run repairs by reinstalling.
mkpkg "$F9/pkg" t4 1
out="$(orch "$F9/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$(ledger_field t4 x '"committed" in e')" = True ] \
   && [ "$(ledger_field t4 x '"intent" in e')" != True ]; then
  ok "F9b: intent whose app is still desired is repaired by reinstalling"
else
  bad "F9b: repair-by-reinstall (rc=$rc)"
fi

# First-install-crash-then-REMOVE: intent teardown from declared patterns +
# journaled serve value, even though the config lines are gone.
reset_box
mkdir -p "$F9/cfg"; mkpkg "$F9/pkg" t4 1
cat > "$F9/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_T4_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
mkdir -p "\$AIRLOCK_WEBROOT/t4"; printf 'marker\n' > "\$AIRLOCK_WEBROOT/t4/marker"
exit 1
EOF
mkcfg "$F9/cfg/airlock.toml" "[apps.t4]" "backend_port = 18904" "[packages.t4]" "path = \"$F9/pkg\""
orch "$F9/cfg/airlock.toml" >/dev/null 2>&1 || true
mkcfg "$F9/cfg/airlock.toml"
out="$(orch "$F9/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ ! -e "$WEB/t4/marker" ] \
   && [ "$(ledger_field t4 x '"intent" in e or "committed" in e')" != True ]; then
  ok "F9b: first-install-crash-then-remove ends clean (declared-pattern teardown)"
else
  bad "F9b: crash-then-remove (rc=$rc, marker=$([ -e "$WEB/t4/marker" ] && echo present || echo gone))"
fi
grep -q -- "--http=18904 off" "$TMP/tailscale.log" \
  && ok "F9b: journaled serve-port value reclaimed after the config lines are gone" \
  || bad "F9b: serve value not reclaimed from the intent record"

# (c) one writer, three pairings. A holder on the lock file makes every
# ledger-touching entry point fail fast before mutating.
reset_box
mkdir -p "$F9/cfg" "$STATE"; mkpkg "$F9/pkg" t4 1
mkcfg "$F9/cfg/airlock.toml" "[apps.t4]" "backend_port = 18904" "[packages.t4]" "path = \"$F9/pkg\""
exec 8>>"$STATE/app-ledger.lock"
if flock -n 8; then
  out="$(orch "$F9/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" != 0 ] && grep -q "ledger lock" <<<"$out"; then
    ok "F9c: orchestrator (configured package) fails fast under a held lock"
  else
    bad "F9c: configured-package lock (rc=$rc)"
  fi
  printf '{"version":1,"entries":{"zz":{"committed":{"path":"/x","digest":"0000000000000000000000000000000000000000000000000000000000000000","lifecycle":{"install":true,"smoke":true,"deactivate":true},"artifacts":{"units":[],"fragments":[],"webroot":[],"files":[],"serve_ports":[]}}}}}\n' > "$STATE/app-ledger.json"
  mkcfg "$F9/cfg/ledger-only.toml"   # hub only: the ledger file alone must trigger the lock
  out="$(orch "$F9/cfg/ledger-only.toml" 2>&1)" && rc=0 || rc=$?
  { [ "$rc" != 0 ] && grep -q "ledger lock" <<<"$out"; } \
    && ok "F9c: removal-only run (ledger file, no packages needed) also locks" \
    || bad "F9c: removal-only lock (rc=$rc)"
  out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$F9/cfg/airlock.toml" bash "$ROOT/bin/airlock-teardown" zz 2>&1)" && rc=0 || rc=$?
  { [ "$rc" != 0 ] && grep -q "ledger lock" <<<"$out"; } \
    && ok "F9c: airlock-teardown fails fast under a held lock" \
    || bad "F9c: teardown lock (rc=$rc)"
else
  bad "F9c: could not take the test's own lock"
fi
exec 8>&-
rm -f "$STATE/app-ledger.json"

# A restore caller that already owns the exact lock file may hand the open
# descriptor into the orchestrator. Before this contract the orchestrator
# opened fd 9 independently and failed against the caller's still-held lock;
# releasing first created the writer race this test is meant to prevent.
reset_box
mkdir -p "$F9/cfg" "$STATE"; mkpkg "$F9/pkg" t4 1
cat >>"$F9/pkg/install.sh" <<'EOF'
(sleep 5) </dev/null >/dev/null 2>&1 &
EOF
mkcfg "$F9/cfg/inherited.toml" "[apps.t4]" "backend_port = 18904" \
                               "[packages.t4]" "path = \"$F9/pkg\""
exec 8>>"$STATE/app-ledger.lock"
if flock -n 8; then
  out="$(orch "$F9/cfg/inherited.toml" AIRLOCK_LEDGER_LOCK_FD=8 2>&1)" && rc=0 || rc=$?
  if [ "$rc" = 0 ] && [ "$(ledger_field t4 x '"committed" in e')" = True ]; then
    ok "F9c: inherited exact lock fd closes the restore-to-installer handoff"
  else
    bad "F9c: inherited lock handoff failed (rc=$rc, out=${out:0:160})"
  fi
else
  bad "F9c: could not take the inherited-handoff test lock"
fi
exec 8>&-
exec 7>>"$STATE/app-ledger.lock"
if flock -n 7; then
  ok "F9c: inherited lock is still closed before lifecycle background children"
else
  bad "F9c: a lifecycle background child leaked the inherited lock"
fi
exec 7>&-

# =============================================================================
# Non-interference: no-packages runs and dry runs
# =============================================================================
# Child 4/P3: the built-in skip-and-log fallback ("apps/$app/install.sh not
# present yet — skipping") is retired — the nine built-ins are shipped
# packages now, so an [apps.X] that is neither hub nor a package (shipped or
# explicit) is fatal at validate.
# Child 4/P4 (F15 amendment): the ledger gate now ALSO opens for a box with
# no configured packages and no ledger file yet, as long as a known builtin
# exists on disk — true of any real checkout, since $ROOT/apps always ships
# the nine manifests (this test does not override AIRLOCK_SHIPPED_APPS_ROOT,
# deliberately: it is exercising the real tree the F15 sweep must reach on a
# genuinely hub-only box). So the lock/state DIRECTORY is now created here
# before validate rejects 'zed' — that is the gate doing its job, not a
# leak. What must still hold is the stronger, still-true guarantee: nothing
# is ever JOURNALED — no ledger FILE is written — on a run that dies at
# validate before any package resolves.
reset_box
NP="$TMP/np"; mkdir -p "$NP"
mkcfg "$NP/airlock.toml" "[apps.zed]"
out="$(orch "$NP/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && [ ! -e "$STATE/app-ledger.json" ]; then
  ok "fallback: an unknown app dies at validate before any ledger entry is journaled"
else
  bad "fallback: state leak (rc=$rc, ledger=$([ -e "$STATE/app-ledger.json" ] && echo written || echo none))"
fi
grep -q "unknown app \[apps.zed\]" <<<"$out" \
  && ok "fallback: the retired built-in skip-and-log fallback is gone — unmanifested 'zed' is fatal" \
  || bad "fallback: unknown-app fatal wording changed: $out"

# Dry run with a package: scripts NOT executed, state tree byte-identical.
reset_box
DR="$TMP/dr"; mkdir -p "$DR/cfg"; mkpkg "$DR/pkg" t5 1
mkcfg "$DR/cfg/airlock.toml" "[apps.t5]" "backend_port = 18905" "[packages.t5]" "path = \"$DR/pkg\""
out="$(orch "$DR/cfg/airlock.toml" AIRLOCK_DRY_RUN=1 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && grep -q "would install packaged app: t5" <<<"$out" \
   && [ ! -f "$TMP/invoke-t5.log" ]; then
  ok "dry-run: packaged scripts are not executed (plan is printed instead)"
else
  bad "dry-run: packaged execution (rc=$rc, invoked=$([ -f "$TMP/invoke-t5.log" ] && echo yes || echo no))"
fi
[ ! -e "$STATE" ] \
  && ok "dry-run: the whole state tree is untouched (no ledger, no lock)" \
  || bad "dry-run: state tree was touched"

# Standalone bin/airlock-smoke resolves the packaged dir under the ABI.
reset_box
SM="$TMP/sm"; mkdir -p "$SM/cfg"; mkpkg "$SM/pkg" t6 1
mkcfg "$SM/cfg/airlock.toml" "[apps.t6]" "backend_port = 18906" "[packages.t6]" "path = \"$SM/pkg\""
orch "$SM/cfg/airlock.toml" >/dev/null 2>&1 || bad "smoke: setup install failed"
rm -f "$TMP/invoke-t6.log"
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$SM/cfg/airlock.toml" bash "$ROOT/bin/airlock-smoke" 2>&1)" && rc=0 || rc=$?
inv="$(cat "$TMP/invoke-t6.log" 2>/dev/null || true)"
if [ "$rc" = 0 ] && grep -q "SMOKE ID=t6 CWD=$SM/pkg" <<<"$inv"; then
  ok "standalone airlock-smoke resolves the package dir under the ABI"
else
  bad "standalone smoke (rc=$rc, invoke: $inv)"
fi

# Serve-port teardown guard: a recorded port a DESIRED app still claims is
# never turned off (hand-seeded record for the collision — config validation
# would rightly refuse to create one).
reset_box
GD="$TMP/gd"; mkdir -p "$GD" "$STATE"
mkcfg "$GD/airlock.toml"    # hub only; hub's plaintext http_port default is 19901
printf '{"version":1,"entries":{"gone":{"committed":{"path":"/nowhere","digest":"0000000000000000000000000000000000000000000000000000000000000000","lifecycle":{"install":true,"smoke":true,"deactivate":false},"artifacts":{"units":[],"fragments":[],"webroot":[],"files":[],"serve_ports":[19901]}}}}}\n' > "$STATE/app-ledger.json"
: > "$TMP/tailscale.log"
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$GD/airlock.toml" bash "$ROOT/bin/airlock-teardown" gone 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && ! grep -q -- "--http=19901 off" "$TMP/tailscale.log"; then
  ok "guard: a recorded serve port claimed by a desired app is not turned off"
else
  bad "guard: serve-off guard (rc=$rc, log: $(grep 19901 "$TMP/tailscale.log" 2>/dev/null || echo none))"
fi

# Child 4/P3 review finding (Major): `validate` is fatal on an unknown/
# manifestless [apps.X], but bin/airlock-teardown used to consume the
# package-info/plaintext projections directly, without calling `validate`
# first — neither projection itself fails closed on an unrelated unknown
# app, so a typo elsewhere in airlock.toml sailed straight through the one
# operational path the flip didn't reach. teardown now validates before
# touching either projection.
#
# (b) baseline / regression guard: a config with NO typo (same "gone" setup
# above, hub only) must still teardown normally — this is the GD case
# immediately above, re-asserted here so the pairing with (a) is explicit
# and this fixture stays self-contained if (a) below is ever read alone.
reset_box
TD="$TMP/td"; mkdir -p "$TD" "$STATE"
mkcfg "$TD/airlock.toml"    # hub only, no typo
printf '{"version":1,"entries":{"gone3":{"committed":{"path":"/nowhere","digest":"0000000000000000000000000000000000000000000000000000000000000000","lifecycle":{"install":true,"smoke":true,"deactivate":false},"artifacts":{"units":[],"fragments":[],"webroot":[],"files":[],"serve_ports":[]}}}}}\n' > "$STATE/app-ledger.json"
out_clean="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$TD/airlock.toml" bash "$ROOT/bin/airlock-teardown" gone3 2>&1)" && rc_clean=0 || rc_clean=$?
if [ "$rc_clean" = 0 ] && grep -q "teardown complete: 'gone3'" <<<"$out_clean"; then
  ok "teardown: (b) a clean config (no typo) still tears down a recorded app normally (no regression)"
else
  bad "teardown: (b) clean-config teardown regressed (rc=$rc_clean): $out_clean"
fi

# (a) the actual fatal case: the SAME recorded app, but airlock.toml also
# carries an unrelated typo/manifestless [apps.typo] table (the exact shape
# the review reported: an http_port/redirect_port pair that would otherwise
# print a spurious `plaintext` row). teardown must die before ever calling
# package-info/plaintext — the recorded app named on the command line is
# never even reached.
reset_box
mkdir -p "$STATE"
mkcfg "$TD/airlock.toml" "[apps.typo]" "http_port = 19123" "redirect_port = 19124"
printf '{"version":1,"entries":{"gone3":{"committed":{"path":"/nowhere","digest":"0000000000000000000000000000000000000000000000000000000000000000","lifecycle":{"install":true,"smoke":true,"deactivate":false},"artifacts":{"units":[],"fragments":[],"webroot":[],"files":[],"serve_ports":[]}}}}}\n' > "$STATE/app-ledger.json"
out_typo="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$TD/airlock.toml" bash "$ROOT/bin/airlock-teardown" gone3 2>&1)" && rc_typo=0 || rc_typo=$?
if [ "$rc_typo" != 0 ] && grep -q "unknown app \[apps.typo\]" <<<"$out_typo" \
   && ! grep -q "teardown complete" <<<"$out_typo"; then
  ok "teardown: (a) an unrelated typo app elsewhere in config is fatal before package-info/plaintext are consumed"
else
  bad "teardown: (a) typo-app fatality not enforced (rc=$rc_typo): $out_typo"
fi

# Removal failure keeps the record: if an artifact refuses to go (here the
# serve-off), dropping the entry anyway would orphan it with no record
# naming it (D6) — the run must fail and the next run must converge.
reset_box
RF="$TMP/rf"; mkdir -p "$RF/cfg"; mkpkg "$RF/pkg" t7 1
mkcfg "$RF/cfg/airlock.toml" "[apps.t7]" "backend_port = 18907" "[packages.t7]" "path = \"$RF/pkg\""
orch "$RF/cfg/airlock.toml" >/dev/null 2>&1 || bad "retry: setup install failed"
mkcfg "$RF/cfg/airlock.toml"   # drop the app: the next run must remove it
: > "$TMP/serve-off-fails"
out="$(orch "$RF/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && [ "$(ledger_field t7 x '"committed" in e')" = True ]; then
  ok "retry: a failed serve-off keeps the ledger record and fails the run"
else
  bad "retry: record dropped or run passed despite the failure (rc=$rc)"
fi
rm -f "$TMP/serve-off-fails"
: > "$TMP/tailscale.log"   # so the grep below proves the RE-RUN retried the off
out="$(orch "$RF/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$(ledger_field t7 x '"committed" in e or "intent" in e')" != True ] \
   && grep -q -- "--http=18907 off" "$TMP/tailscale.log"; then
  ok "retry: the re-run finishes the removal and drops the record"
else
  bad "retry: re-run did not converge (rc=$rc)"
fi

# A projection that used to be consumed only after reconcile must fail while
# the old app is still active. A malformed prerequisites inventory is ideal
# for this oracle: ordinary config/package validation passes, but the complete
# candidate projection cannot be assembled. The installer intentionally pins
# its in-tree inventory, so the controlled bad inventory is passed to the
# read-only command directly; the ordering assertion below proves that exact
# command is fatal before the first ledger plan/removal in the orchestrator.
reset_box
PF="$TMP/install-preflight"; mkdir -p "$PF/cfg"; mkpkg "$PF/pkg" pf-old 1
mkcfg "$PF/cfg/airlock.toml" "[apps.pf-old]" "backend_port = 18917" \
  "[packages.pf-old]" "path = \"$PF/pkg\""
orch "$PF/cfg/airlock.toml" >/dev/null 2>&1 || bad "candidate preflight: setup install failed"
mkcfg "$PF/cfg/airlock.toml"  # dropping pf-old would normally deactivate it
printf 'malformed\tprerequisite\n' > "$PF/prerequisites.tsv"
out="$(AIRLOCK_PREREQUISITES="$PF/prerequisites.tsv" run "$PF/cfg/airlock.toml" install-preflight 2>&1)" \
  && rc=0 || rc=$?
if [ "$rc" != 0 ] \
   && grep -q "invalid declaration" <<<"$out" \
   && [ -f "$WEB/pf-old/marker" ] \
   && [ "$(ledger_field pf-old x '"committed" in e')" = True ]; then
  ok "candidate preflight: a late projection failure occurs before reconcile deactivates the old app"
else
  bad "candidate preflight: old app changed before candidate rejection (rc=$rc, marker=$([ -f "$WEB/pf-old/marker" ] && echo present || echo missing))"
fi
python3 - "$ROOT/install/airlock-install.sh" <<'PY' \
  && ok "candidate preflight: fatal projection resolution is wired before ledger reconcile" \
  || bad "candidate preflight: orchestrator ordering no longer protects reconcile"
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
first = source.index('_candidate_preflight="$(printf \'%s\' "$AIRLOCK_PKG_INFO"')
repeat = source.index('_candidate_preflight_now="$(printf \'%s\' "$AIRLOCK_PKG_INFO"')
plan = source.index('_plan="$(printf')
remove = source.index('"$ROOT/bin/airlock-ledger" remove "$_id"')
assert first < repeat < plan < remove
PY

# Actual orchestrator A/B race: A retains the installed app, while the first
# post-preflight mutation swaps the operator file to B (which drops it). The
# running installer must remain bound to A's AIRLOCK_PKG_INFO and app order;
# B is visible only to the next run. No remove/deactivate and no ledger loss.
reset_box
RACE="$TMP/config-race"; mkdir -p "$RACE/cfg"; mkpkg "$RACE/pkg" race-old 1
python3 - "$RACE/pkg/deactivate.sh" "$RACE/deactivate.log" <<'PY'
from pathlib import Path
import sys

path, log = map(Path, sys.argv[1:])
text = path.read_text(encoding="utf-8")
text = text.replace('set -euo pipefail\n', f'set -euo pipefail\nprintf "deactivate\\n" >> "{log}"\n', 1)
path.write_text(text, encoding="utf-8")
PY
mkcfg "$RACE/cfg/airlock.toml" "[apps.race-old]" "backend_port = 18927" \
  "[packages.race-old]" "path = \"$RACE/pkg\""
mkcfg "$RACE/cfg/drop.toml"
orch "$RACE/cfg/airlock.toml" >/dev/null 2>&1 \
  || bad "candidate snapshot race: setup install failed"
rm -f "$RACE/deactivate.log"
out="$(orch "$RACE/cfg/airlock.toml" \
  AIRLOCK_TEST_CONFIG_RACE_REPLACEMENT="$RACE/cfg/drop.toml" \
  AIRLOCK_TEST_CONFIG_RACE_DONE="$RACE/raced" 2>&1)" && rc=0 || rc=$?
deactivate_count="$([ -e "$RACE/deactivate.log" ] && wc -l < "$RACE/deactivate.log" || printf 0)"
if [ "$rc" = 0 ] \
   && [ -e "$RACE/raced" ] \
   && ! grep -q '\[apps.race-old\]' "$RACE/cfg/airlock.toml" \
   && [ "$deactivate_count" = 0 ] \
   && [ -f "$WEB/race-old/marker" ] \
   && [ "$(ledger_field race-old x '"committed" in e')" = True ]; then
  ok "candidate snapshot race: config B causes remove/deactivate calls=0; A marker and ledger stay intact"
else
  bad "candidate snapshot race: running install mixed config A/B (rc=$rc, deactivate_calls=$deactivate_count, marker=$([ -f "$WEB/race-old/marker" ] && echo present || echo missing))"
fi

# The private snapshot itself is owned by the installer uid, so freezing only
# its pathname is insufficient: that uid can still truncate/replace it after
# the final preflight.  Interpose python3 only for this run and rewrite the
# actual AIRLOCK_CONFIG_SNAPSHOT from A to B immediately after the second
# (final) install-preflight returns.  The next projection must reject B by its
# exact digest before the A ledger can plan a remove/deactivate.
rm -f "$RACE/deactivate.log" "$RACE/snapshot-raced" "$RACE/preflight-count"
mkcfg "$RACE/cfg/airlock.toml" "[apps.race-old]" "backend_port = 18927" \
  "[packages.race-old]" "path = \"$RACE/pkg\""
mkdir -p "$RACE/python-shim" "$RACE/snapshots"
REAL_PYTHON="$(command -v python3)"
cat >"$RACE/python-shim/python3" <<EOF
#!/usr/bin/env bash
"$REAL_PYTHON" "\$@"
rc=\$?
if [ "\$rc" = 0 ] \
   && [ "\${1:-}" = "$CFG" ] \
   && [ "\${2:-}" = install-preflight ]; then
  count_file="$RACE/preflight-count"
  count=0
  [ ! -f "\$count_file" ] || count="\$(cat "\$count_file")"
  count=\$((count + 1))
  printf '%s\n' "\$count" >"\$count_file"
  if [ "\$count" = 2 ]; then
    cp "$RACE/cfg/drop.toml" "\$AIRLOCK_CONFIG_SNAPSHOT"
    : >"$RACE/snapshot-raced"
  fi
fi
exit "\$rc"
EOF
chmod +x "$RACE/python-shim/python3"
out="$(orch "$RACE/cfg/airlock.toml" \
  PATH="$RACE/python-shim:$PATH" TMPDIR="$RACE/snapshots" 2>&1)" && rc=0 || rc=$?
deactivate_count="$([ -e "$RACE/deactivate.log" ] && wc -l < "$RACE/deactivate.log" || printf 0)"
if [ "$rc" != 0 ] \
   && [ -e "$RACE/snapshot-raced" ] \
   && grep -q 'snapshot digest changed' <<<"$out" \
   && [ "$deactivate_count" = 0 ] \
   && [ -f "$WEB/race-old/marker" ] \
   && [ "$(ledger_field race-old x '"committed" in e')" = True ]; then
  ok "candidate snapshot mutation: post-preflight A->B is rejected; deactivate calls=0 and A marker/ledger survive"
else
  bad "candidate snapshot mutation: mutable snapshot reached reconcile (rc=$rc, deactivate_calls=$deactivate_count, marker=$([ -f "$WEB/race-old/marker" ] && echo present || echo missing))"
fi

# No-deactivator upgrade: a failed record-diff teardown must keep the old
# committed record (and the intent) instead of committing — the new record
# would not name the artifact that refused to go. A second, healthy package
# rides along: its commit must land even though the run fails.
reset_box
RD="$TMP/rd"; mkdir -p "$RD/cfg"; mkpkg "$RD/pkg" t8 0; mkpkg "$RD/pkg2" ta 1
mkcfg "$RD/cfg/airlock.toml" "[apps.t8]" "backend_port = 18908" "[packages.t8]" "path = \"$RD/pkg\"" \
                             "[apps.ta]" "backend_port = 18910" "[packages.ta]" "path = \"$RD/pkg2\""
orch "$RD/cfg/airlock.toml" >/dev/null 2>&1 || bad "diff-retry: setup install failed"
old_digest="$(ledger_field t8 x 'e["committed"]["digest"]')"
# The upgrade stops declaring the serve port, so 18908 becomes old-only and
# the commit-time record diff must turn it off.
sed -i '/serve_ports = \["backend_port"\]/d' "$RD/pkg/airlock-app.toml"
: > "$TMP/serve-off-fails"
out="$(orch "$RD/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && [ "$(ledger_field t8 x '"intent" in e')" = True ] \
   && [ "$(ledger_field t8 x 'e.get("committed", {}).get("digest")')" = "$old_digest" ]; then
  ok "diff-retry: a failed record-diff keeps the OLD committed + intent and fails the run"
else
  bad "diff-retry: old committed lost or run passed despite the failure (rc=$rc)"
fi
[ "$(ledger_field ta x '"committed" in e and "intent" not in e')" = True ] \
  && ok "diff-retry: the healthy package's commit still lands in the failing run" \
  || bad "diff-retry: healthy package left uncommitted"
rm -f "$TMP/serve-off-fails"
: > "$TMP/tailscale.log"   # so the grep below proves the RE-RUN retried the off
out="$(orch "$RD/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$(ledger_field t8 x '"committed" in e and "intent" not in e')" = True ] \
   && [ "$(ledger_field t8 x 'e["committed"]["digest"]')" != "$old_digest" ] \
   && grep -q -- "--http=18908 off" "$TMP/tailscale.log"; then
  ok "diff-retry: the re-run completes the diff and commits the new record"
else
  bad "diff-retry: re-run did not converge (rc=$rc)"
fi

# A relative AIRLOCK_STATE_DIR is pinned to its kernel-resolved absolute path
# before any packaged script runs, so the value a package inherits names the
# directory the lock actually guards (packaged scripts run from their own cwd).
reset_box
RS="$TMP/rs"; mkdir -p "$RS/cfg" "$RS/cwd"; mkpkg "$RS/pkg" t9 1
cat >> "$RS/pkg/install.sh" <<EOF
printf '%s\n' "\$AIRLOCK_STATE_DIR" > "$TMP/t9-statedir"
EOF
mkcfg "$RS/cfg/airlock.toml" "[apps.t9]" "backend_port = 18911" "[packages.t9]" "path = \"$RS/pkg\""
out="$(cd "$RS/cwd" && env HOME="$FAKEHOME" AIRLOCK_CONFIG="$RS/cfg/airlock.toml" \
        AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" AIRLOCK_STATE_DIR="state-rel" \
        bash "$ROOT/install/airlock-install.sh" 2>&1)" && rc=0 || rc=$?
seen="$(cat "$TMP/t9-statedir" 2>/dev/null || true)"
if [ "$rc" = 0 ] && [ "$seen" = "$RS/cwd/state-rel" ] \
   && [ -f "$RS/cwd/state-rel/app-ledger.json" ] && [ -f "$RS/cwd/state-rel/app-ledger.lock" ]; then
  ok "state-dir: a relative value is pinned absolute before packaged scripts run"
else
  bad "state-dir: relative value not pinned (rc=$rc, seen=$seen)"
fi

# =============================================================================
# Platform self-protection and expansion soundness
# =============================================================================

# The ledger itself can never be an app artifact: validate refuses the claim...
reset_box
SC="$TMP/sc"; mkdir -p "$SC/cfg"; mkpkg "$SC/pkg" t10 1
manifest "$SC/pkg/airlock-app.toml" t10 <<EOF
[artifacts]
files = ["$STATE/app-ledger.json"]
EOF
mkcfg "$SC/cfg/airlock.toml" "[apps.t10]" "backend_port = 18912" "[packages.t10]" "path = \"$SC/pkg\""
msg="$(run "$SC/cfg/airlock.toml" validate 2>&1)" && bad "self-claim: validate accepted the ledger as an artifact" || {
  grep -q "state directory" <<<"$msg" \
    && ok "self-claim: validate refuses an artifact claim on the state directory" \
    || bad "self-claim: wrong message: $msg"; }

# ...and the teardown path refuses it even on a hand-made record.
reset_box
mkdir -p "$STATE"
Z="$(printf '0%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64)"
printf '{"version":1,"entries":{"zz":{"committed":{"path":"/nowhere","digest":"%s","lifecycle":{"install":true,"smoke":true,"deactivate":false},"artifacts":{"units":[],"fragments":[],"webroot":[],"files":["%s/app-ledger.json"],"serve_ports":[]}}}}}\n' "$Z" "$STATE" > "$STATE/app-ledger.json"
GDX="$TMP/gdx"; mkdir -p "$GDX"; mkcfg "$GDX/airlock.toml"
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$GDX/airlock.toml" bash "$ROOT/bin/airlock-teardown" zz 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && [ -f "$STATE/app-ledger.json" ] && grep -q "platform state directory" <<<"$out"; then
  ok "self-claim: teardown refuses to remove the ledger through a record"
else
  bad "self-claim: ledger was removable through a record (rc=$rc)"
fi

# A path that merely moves artifact class (webroot -> files) across an
# upgrade is still owned: the record diff must not tear it down.
reset_box
CM="$TMP/cm"; mkdir -p "$CM/cfg" "$CM/pkg"
manifest "$CM/pkg/airlock-app.toml" t11 <<EOF
[artifacts]
webroot = ["shared-x/"]
EOF
cat > "$CM/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_T11_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
mkdir -p "\$AIRLOCK_WEBROOT/shared-x"; printf 'f\n' > "\$AIRLOCK_WEBROOT/shared-x/f"
EOF
cat > "$CM/pkg/smoke.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$CM/pkg/install.sh" "$CM/pkg/smoke.sh"
mkcfg "$CM/cfg/airlock.toml" "[apps.t11]" "backend_port = 18913" "[packages.t11]" "path = \"$CM/pkg\""
orch "$CM/cfg/airlock.toml" >/dev/null 2>&1 || bad "class-move: setup install failed"
manifest "$CM/pkg/airlock-app.toml" t11 <<EOF
[artifacts]
files = ["$WEB/shared-x"]
EOF
out="$(orch "$CM/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ -f "$WEB/shared-x/f" ] \
   && [ "$(ledger_field t11 x '"'"$WEB"'/shared-x" in e["committed"]["artifacts"]["files"]')" = True ]; then
  ok "class-move: a path moving webroot->files survives the record diff"
else
  bad "class-move: owned path torn down or not re-recorded (rc=$rc)"
fi

# Glob characters in a platform root are literal directory names, not globs.
reset_box
GR="$TMP/gr"; mkdir -p "$GR/cfg" "$GR/w[12]" "$GR/w1/gx"; printf 'keep\n' > "$GR/w1/gx/f2"
mkpkg "$GR/pkg" t12 1
manifest "$GR/pkg/airlock-app.toml" t12 <<EOF
[artifacts]
webroot = ["gx/"]
EOF
cat > "$GR/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_T12_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
mkdir -p "\$AIRLOCK_WEBROOT/gx"; printf 'f\n' > "\$AIRLOCK_WEBROOT/gx/f"
EOF
cat > "$GR/pkg/smoke.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$GR/pkg/smoke.sh" # custom installer writes no mkpkg marker
mkcfg "$GR/cfg/airlock.toml" "[apps.t12]" "backend_port = 18914" "[packages.t12]" "path = \"$GR/pkg\""
orch "$GR/cfg/airlock.toml" AIRLOCK_WEBROOT="$GR/w[12]" >/dev/null 2>&1 || bad "glob-root: setup install failed"
rec_ok="$(ledger_field t12 x 'any("w[12]/gx" in str(p) for p in e["committed"]["artifacts"]["webroot"])')"
mkcfg "$GR/cfg/airlock.toml"
out="$(orch "$GR/cfg/airlock.toml" AIRLOCK_WEBROOT="$GR/w[12]" 2>&1)" && rc=0 || rc=$?
if [ "$rec_ok" = True ] && [ "$rc" = 0 ] && [ ! -e "$GR/w[12]/gx" ] && [ -f "$GR/w1/gx/f2" ]; then
  ok "glob-root: a root containing glob characters is treated literally"
else
  bad "glob-root: recorded=$rec_ok rc=$rc own=$([ -e "$GR/w[12]/gx" ] && echo kept || echo gone) sibling=$([ -f "$GR/w1/gx/f2" ] && echo kept || echo DELETED)"
fi

# Two roots aliasing one real directory collide in claim space: disjointness
# must not let two apps own the same real path through a symlink.
reset_box
AR="$TMP/ar"; mkdir -p "$AR/real"; ln -s "$AR/real" "$AR/alias"
mkpkg "$AR/p1" u1 1; mkpkg "$AR/p2" u2 1
manifest "$AR/p1/airlock-app.toml" u1 <<EOF
[artifacts]
webroot = ["x"]
EOF
manifest "$AR/p2/airlock-app.toml" u2 <<EOF
[artifacts]
fragments = ["x"]
EOF
mkcfg "$AR/airlock.toml" "[apps.u1]" "backend_port = 18918" "[packages.u1]" "path = \"$AR/p1\"" \
                         "[apps.u2]" "backend_port = 18919" "[packages.u2]" "path = \"$AR/p2\""
msg="$(env HOME="$FAKEHOME" AIRLOCK_WEBROOT="$AR/real" AIRLOCK_CONFD="$AR/alias" \
        AIRLOCK_CONFIG="$AR/airlock.toml" python3 "$CFG" validate 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && grep -q "overlapping artifacts" <<<"$msg"; then
  ok "alias-roots: symlinked roots collide in claim space (realpath canonicalisation)"
else
  bad "alias-roots: two apps own one real path through a symlink (rc=$rc)"
fi

# One path space for records and claims: an artifact recorded through a
# symlink alias must collide with a later claim on the real path.
reset_box
CS="$TMP/cs"; mkdir -p "$CS/real"; ln -s "$CS/real" "$CS/alias"
mkpkg "$CS/p1" v1 1
manifest "$CS/p1/airlock-app.toml" v1 <<EOF
[artifacts]
files = ["$CS/alias/shared"]
EOF
cat > "$CS/p1/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_V1_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
printf 's\n' > "$CS/real/shared"
EOF
cat > "$CS/p1/smoke.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$CS/p1/smoke.sh"
mkcfg "$CS/cfg1.toml" "[apps.v1]" "backend_port = 18920" "[packages.v1]" "path = \"$CS/p1\""
orch "$CS/cfg1.toml" >/dev/null 2>&1 || bad "canon: setup install failed"
mkpkg "$CS/p2" v2 1
manifest "$CS/p2/airlock-app.toml" v2 <<EOF
[artifacts]
files = ["$CS/real/shared"]
EOF
mkcfg "$CS/cfg2.toml" "[apps.v2]" "backend_port = 18921" "[packages.v2]" "path = \"$CS/p2\""
msg="$(run "$CS/cfg2.toml" validate 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && grep -q "recorded under id 'v1'" <<<"$msg"; then
  ok "canon: an alias-recorded artifact collides with a claim on the real path"
else
  bad "canon: alias record and real claim live in different spaces (rc=$rc)"
fi

# The canonical space covers PATTERN paths too: a symlink inside a rooted
# pattern collides with a claim on the real path at validate, before any
# installer runs.
reset_box
CP="$TMP/cp"; mkdir -p "$CP/root/realdir"; ln -s "$CP/root/realdir" "$CP/root/linkdir"
mkpkg "$CP/p1" w1 1; mkpkg "$CP/p2" w2 1
manifest "$CP/p1/airlock-app.toml" w1 <<EOF
[artifacts]
fragments = ["linkdir/x"]
EOF
manifest "$CP/p2/airlock-app.toml" w2 <<EOF
[artifacts]
files = ["$CP/root/realdir/x"]
EOF
mkcfg "$CP/airlock.toml" "[apps.w1]" "backend_port = 18922" "[packages.w1]" "path = \"$CP/p1\"" \
                         "[apps.w2]" "backend_port = 18923" "[packages.w2]" "path = \"$CP/p2\""
msg="$(env HOME="$FAKEHOME" AIRLOCK_CONFD="$CP/root" AIRLOCK_CONFIG="$CP/airlock.toml" python3 "$CFG" validate 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && grep -q "overlapping artifacts" <<<"$msg"; then
  ok "canon: a symlink inside a rooted pattern collides with the real path"
else
  bad "canon: rooted pattern claims escape the canonical space (rc=$rc)"
fi

# Glob characters live only in the FINAL segment: a wildcard directory
# cannot be checked for ownership before it exists.
reset_box
WG="$TMP/wg"; mkdir -p "$WG"; mkpkg "$WG/pkg" wg 1
manifest "$WG/pkg/airlock-app.toml" wg <<EOF
[artifacts]
webroot = ["l*/x"]
EOF
mkcfg "$WG/airlock.toml" "[apps.wg]" "backend_port = 18924" "[packages.wg]" "path = \"$WG/pkg\""
msg="$(run "$WG/airlock.toml" validate 2>&1)" && bad "glob-seg: wildcard directory accepted" || {
  grep -q "final segment" <<<"$msg" \
    && ok "glob-seg: a wildcard in a non-final segment is fatal at validate" \
    || bad "glob-seg: wrong message: $msg"; }

# Recursive globs never enter the contract (they descend through symlinked
# directories, escaping the claim space).
reset_box
RG="$TMP/rg"; mkdir -p "$RG"; mkpkg "$RG/pkg" rg 1
manifest "$RG/pkg/airlock-app.toml" rg <<EOF
[artifacts]
webroot = ["safe/**"]
EOF
mkcfg "$RG/airlock.toml" "[apps.rg]" "backend_port = 18926" "[packages.rg]" "path = \"$RG/pkg\""
msg="$(run "$RG/airlock.toml" validate 2>&1)" && bad "glob-rec: recursive glob accepted" || {
  grep -q "recursive globs" <<<"$msg" \
    && ok "glob-rec: a recursive glob is fatal at validate" \
    || bad "glob-rec: wrong message: $msg"; }

# A DESIRED app's crash repair with a changed declaration tears the stale
# intent's expansion down before the new intent replaces it — the old
# partial artifacts must not lose their only record.
reset_box
DI="$TMP/di"; mkdir -p "$DI/cfg"; mkpkg "$DI/pkg" di 1
cat > "$DI/pkg/smoke.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$DI/pkg/smoke.sh" # the custom installers below write no mkpkg marker
manifest "$DI/pkg/airlock-app.toml" di <<EOF
[artifacts]
webroot = ["di-old/"]
EOF
cat > "$DI/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_DI_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
mkdir -p "\$AIRLOCK_WEBROOT/di-old"; printf 'p\n' > "\$AIRLOCK_WEBROOT/di-old/partial"
exit 1
EOF
mkcfg "$DI/cfg/airlock.toml" "[apps.di]" "backend_port = 18927" "[packages.di]" "path = \"$DI/pkg\""
orch "$DI/cfg/airlock.toml" >/dev/null 2>&1 && bad "stale-intent: crashing install passed"
manifest "$DI/pkg/airlock-app.toml" di <<EOF
[artifacts]
webroot = ["di-new/"]
EOF
cat > "$DI/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_DI_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
mkdir -p "\$AIRLOCK_WEBROOT/di-new"; printf 'n\n' > "\$AIRLOCK_WEBROOT/di-new/f"
EOF
out="$(orch "$DI/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ ! -e "$WEB/di-old" ] && [ -f "$WEB/di-new/f" ] \
   && [ "$(ledger_field di x '"committed" in e and "intent" not in e')" = True ]; then
  ok "stale-intent: a redeclared repair cleans the old intent's partials first"
else
  bad "stale-intent: old partials orphaned or repair failed (rc=$rc)"
fi

# Stale-intent cleanup is scoped: what the SAME id's committed record (or
# the new declaration) still owns survives — a redeclared repair must not
# eat the live v1 install while v3 is still failing.
reset_box
SV="$TMP/sv"; mkdir -p "$SV/cfg"; mkpkg "$SV/pkg" sv 0
cat > "$SV/pkg/smoke.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$SV/pkg/smoke.sh"
manifest "$SV/pkg/airlock-app.toml" sv <<EOF
[artifacts]
webroot = ["sv-a/"]
EOF
cat > "$SV/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_SV_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
mkdir -p "\$AIRLOCK_WEBROOT/sv-a"; printf 'a\n' > "\$AIRLOCK_WEBROOT/sv-a/f"
EOF
mkcfg "$SV/cfg/airlock.toml" "[apps.sv]" "backend_port = 18929" "[packages.sv]" "path = \"$SV/pkg\""
orch "$SV/cfg/airlock.toml" >/dev/null 2>&1 || bad "scoped-stale: v1 install failed"
manifest "$SV/pkg/airlock-app.toml" sv <<EOF
[artifacts]
webroot = ["sv-b/"]
EOF
cat > "$SV/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_SV_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
mkdir -p "\$AIRLOCK_WEBROOT/sv-b"; printf 'b\n' > "\$AIRLOCK_WEBROOT/sv-b/partial"
exit 1
EOF
orch "$SV/cfg/airlock.toml" >/dev/null 2>&1 && bad "scoped-stale: v2 crash passed"
manifest "$SV/pkg/airlock-app.toml" sv <<EOF
[artifacts]
webroot = ["sv-c/"]
EOF
cat > "$SV/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_SV_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
exit 1
EOF
out="$(orch "$SV/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && [ -f "$WEB/sv-a/f" ] && [ ! -e "$WEB/sv-b" ] \
   && [ "$(ledger_field sv x '"committed" in e')" = True ]; then
  ok "scoped-stale: cleanup spares what the committed record still owns"
else
  bad "scoped-stale: live v1 assets eaten or v2 partials kept (rc=$rc, a=$([ -f "$WEB/sv-a/f" ] && echo kept || echo GONE))"
fi

# Containment is ownership: an upgrade that turns a directory claim into a
# claim on its contents (or back) must not tear down what it just claimed —
# user data the installer does not recreate survives both directions.
reset_box
CV="$TMP/cv"; mkdir -p "$CV/cfg"; mkpkg "$CV/pkg" cv 0
cat > "$CV/pkg/smoke.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$CV/pkg/smoke.sh"
manifest "$CV/pkg/airlock-app.toml" cv <<EOF
[artifacts]
webroot = ["cv"]
EOF
cat > "$CV/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_CV_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
mkdir -p "\$AIRLOCK_WEBROOT/cv"
printf 'app\n' > "\$AIRLOCK_WEBROOT/cv/app.js"
[ -f "\$AIRLOCK_WEBROOT/cv/db.sqlite" ] || printf 'data\n' > "\$AIRLOCK_WEBROOT/cv/db.sqlite"
EOF
mkcfg "$CV/cfg/airlock.toml" "[apps.cv]" "backend_port = 18932" "[packages.cv]" "path = \"$CV/pkg\""
orch "$CV/cfg/airlock.toml" >/dev/null 2>&1 || bad "containment: v1 install failed"
manifest "$CV/pkg/airlock-app.toml" cv <<EOF
[artifacts]
webroot = ["cv/*"]
EOF
out="$(orch "$CV/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
mid_ok=0
[ "$rc" = 0 ] && [ -f "$WEB/cv/db.sqlite" ] \
  && [ "$(ledger_field cv x 'any(p.endswith("db.sqlite") for p in e["committed"]["artifacts"]["webroot"])')" = True ] && mid_ok=1
manifest "$CV/pkg/airlock-app.toml" cv <<EOF
[artifacts]
webroot = ["cv"]
EOF
out="$(orch "$CV/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$mid_ok" = 1 ] && [ "$rc" = 0 ] && [ -f "$WEB/cv/db.sqlite" ]; then
  ok "containment: dir<->contents upgrades never eat the claimed tree"
else
  bad "containment: claimed tree torn down across the upgrade (mid=$mid_ok rc=$rc, db=$([ -f "$WEB/cv/db.sqlite" ] && echo kept || echo GONE))"
fi

# A dotfile written under a * claim is recorded (and therefore reclaimed) —
# a stray .env must never survive with no record naming it.
reset_box
DV="$TMP/dv"; mkdir -p "$DV/cfg"; mkpkg "$DV/pkg" dv 1
cat > "$DV/pkg/smoke.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$DV/pkg/smoke.sh"
manifest "$DV/pkg/airlock-app.toml" dv <<EOF
[artifacts]
webroot = ["dv/*"]
EOF
cat > "$DV/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_DV_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
mkdir -p "\$AIRLOCK_WEBROOT/dv"
printf 'i\n' > "\$AIRLOCK_WEBROOT/dv/index.html"
printf 'SECRET=x\n' > "\$AIRLOCK_WEBROOT/dv/.env"
EOF
mkcfg "$DV/cfg/airlock.toml" "[apps.dv]" "backend_port = 18933" "[packages.dv]" "path = \"$DV/pkg\""
orch "$DV/cfg/airlock.toml" >/dev/null 2>&1 || bad "dotfile: setup install failed"
rec_ok="$(ledger_field dv x 'any(p.endswith("/.env") for p in e["committed"]["artifacts"]["webroot"])')"
mkcfg "$DV/cfg/airlock.toml"
out="$(orch "$DV/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rec_ok" = True ] && [ "$rc" = 0 ] && [ ! -e "$WEB/dv/.env" ]; then
  ok "dotfile: a hidden file under a * claim is recorded and reclaimed"
else
  bad "dotfile: .env unrecorded or orphaned (rec=$rec_ok rc=$rc, env=$([ -e "$WEB/dv/.env" ] && echo ORPHANED || echo gone))"
fi

# A trailing-slash files declaration is the same object as its slashless
# form: it must collide with another id's recorded ownership of the link.
reset_box
TSL="$TMP/tsl"; mkdir -p "$TSL/x/real" "$STATE"; ln -s "$TSL/x/real" "$TSL/x/link"
printf '{"version":1,"entries":{"zb":{"committed":{"path":"/nowhere","digest":"%s","lifecycle":{"install":true,"smoke":false,"deactivate":false},"artifacts":{"units":[],"fragments":[],"webroot":[],"files":["%s/x/link"],"serve_ports":[]}}}}}\n' "$Z" "$TSL" > "$STATE/app-ledger.json"
mkpkg "$TSL/pkg" ts 1
manifest "$TSL/pkg/airlock-app.toml" ts <<EOF
[artifacts]
files = ["$TSL/x/link/"]
EOF
mkcfg "$TSL/airlock.toml" "[apps.ts]" "backend_port = 18930" "[packages.ts]" "path = \"$TSL/pkg\""
msg="$(run "$TSL/airlock.toml" validate 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && grep -q "recorded under id 'zb'" <<<"$msg"; then
  ok "canon: a trailing-slash declaration collides with the slashless record"
else
  bad "canon: trailing slash made a second object of one link (rc=$rc)"
fi

# Serve keys that do not end in _port join the same port-uniqueness pool,
# and 443 (the platform TLS entrypoint) is never an app's serve port.
reset_box
PU="$TMP/pu"; mkdir -p "$PU"; mkpkg "$PU/pkg" pu 1
manifest "$PU/pkg/airlock-app.toml" pu port <<EOF
[artifacts]
webroot = ["pu/"]
serve_ports = ["port"]
EOF
mkcfg "$PU/airlock.toml" "[apps.pu]" "port = 443" "[packages.pu]" "path = \"$PU/pkg\""
msg="$(run "$PU/airlock.toml" validate 2>&1)" && bad "ports: serve key 'port' = 443 accepted" || {
  grep -Eq "TLS entrypoint|port 443 is used twice" <<<"$msg" \
    && ok "ports: 443 is reserved — never an app's serve port" \
    || bad "ports: wrong message: $msg"; }
# "other" is a second package (child 4/P3: a bare unpackaged [apps.X] is
# fatal now — see the unknown-app fixtures elsewhere) whose own PLAIN _port
# config key (no [artifacts] claim at all — mkpkg's template would declare
# it as serve_ports and trip the STRONGER cross-app claim-exclusivity check
# instead) collides with pu's non-_port serve key; only the generic per-app
# uniqueness sweep is under test.
mkdir -p "$PU/other-pkg"
cat >"$PU/other-pkg/airlock-app.toml" <<EOF
contract = 1
id = "other"
[config.defaults]
backend_port = 18900
EOF
printf '#!/usr/bin/env bash\nport="${AIRLOCK_OTHER_BACKEND_PORT:?}"\ntest "$port" -gt 0\n' >"$PU/other-pkg/install.sh"
cp "$PU/other-pkg/install.sh" "$PU/other-pkg/smoke.sh"
mkcfg "$PU/airlock.toml" "[apps.other]" "backend_port = 18940" "[packages.other]" "path = \"$PU/other-pkg\"" \
      "[apps.pu]" "port = 18940" "[packages.pu]" "path = \"$PU/pkg\""
msg="$(run "$PU/airlock.toml" validate 2>&1)" && bad "ports: non-_port serve key dodged the sweep" || {
  grep -q "used twice" <<<"$msg" \
    && ok "ports: a serve key without the _port suffix still hits the uniqueness sweep" \
    || bad "ports: wrong message: $msg"; }

# Since child 3 (F6) a package without install.sh cannot even VALIDATE, so a
# mapping can never precede a record — the failure is loud, not a silent skip.
reset_box
NI="$TMP/ni"; mkdir -p "$NI"; mkpkg "$NI/pkg" ni 1
rm -f "$NI/pkg/install.sh"
mkcfg "$NI/airlock.toml" "[apps.ni]" "backend_port = 18941" "[packages.ni]" "path = \"$NI/pkg\""
rows_rc=0
rows="$(run "$NI/airlock.toml" plaintext 2>&1)" || rows_rc=$?
if [ "$rows_rc" -ne 0 ] && grep -q "has no install.sh" <<<"$rows"; then
  ok "plaintext: an install-less package is fatal before any mapping (F6)"
else
  bad "plaintext: install-less package rc=$rows_rc: $rows"
fi

# A claim that contains a platform root (or is its ancestor) is fatal.
reset_box
RA="$TMP/ra"; mkdir -p "$RA"; mkpkg "$RA/pkg" ra 1
manifest "$RA/pkg/airlock-app.toml" ra <<EOF
[artifacts]
files = ["$TMP/web"]
EOF
mkcfg "$RA/airlock.toml" "[apps.ra]" "backend_port = 18942" "[packages.ra]" "path = \"$RA/pkg\""
msg="$(run "$RA/airlock.toml" validate 2>&1)" && bad "root-claim: webroot root claim accepted" || {
  grep -q "platform" <<<"$msg" \
    && ok "root-claim: claiming a platform root is fatal at validate" \
    || bad "root-claim: wrong message: $msg"; }
manifest "$RA/pkg/airlock-app.toml" ra <<EOF
[artifacts]
files = ["$TMP"]
EOF
msg="$(run "$RA/airlock.toml" validate 2>&1)" && bad "root-claim: root ancestor claim accepted" || {
  grep -q "platform" <<<"$msg" \
    && ok "root-claim: claiming a root's ancestor is fatal at validate" \
    || bad "root-claim: ancestor — wrong message: $msg"; }

# A third-party install.sh that drains stdin must not eat the app list.
reset_box
SD="$TMP/sd"; mkdir -p "$SD/cfg"; mkpkg "$SD/pkg1" sd1 1; mkpkg "$SD/pkg2" sd2 1
for d in "$SD/pkg1" "$SD/pkg2"; do
  cat >> "$d/install.sh" <<'EOF'
cat >/dev/null   # a stdin-draining third-party installer
EOF
done
mkcfg "$SD/cfg/airlock.toml" "[apps.sd1]" "backend_port = 18943" "[packages.sd1]" "path = \"$SD/pkg1\"" \
                             "[apps.sd2]" "backend_port = 18944" "[packages.sd2]" "path = \"$SD/pkg2\""
out="$(orch "$SD/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ -f "$TMP/invoke-sd1.log" ] && [ -f "$TMP/invoke-sd2.log" ]; then
  ok "stdin: a stdin-draining installer cannot eat the remaining app list"
else
  bad "stdin: app list swallowed (rc=$rc, sd2=$([ -f "$TMP/invoke-sd2.log" ] && echo ran || echo SKIPPED))"
fi

# Grammar edges: recursive glob in units, and the whole home as an artifact.
reset_box
GE="$TMP/ge"; mkdir -p "$GE"; mkpkg "$GE/pkg" ge 1
manifest "$GE/pkg/airlock-app.toml" ge <<EOF
[artifacts]
units = ["**.service"]
EOF
mkcfg "$GE/airlock.toml" "[apps.ge]" "backend_port = 18931" "[packages.ge]" "path = \"$GE/pkg\""
run "$GE/airlock.toml" validate >/dev/null 2>&1 && bad "grammar: units ** accepted" \
  || ok "grammar: a recursive glob in units is fatal at validate"
manifest "$GE/pkg/airlock-app.toml" ge <<EOF
[artifacts]
files = ["~/"]
EOF
run "$GE/airlock.toml" validate >/dev/null 2>&1 && bad "grammar: whole-home files claim accepted" \
  || ok "grammar: claiming the whole home is fatal at validate"
manifest "$GE/pkg/airlock-app.toml" ge <<EOF
[artifacts]
files = ["~/."]
EOF
run "$GE/airlock.toml" validate >/dev/null 2>&1 && bad "grammar: ~/. (home via dot) accepted" \
  || ok "grammar: a '.' segment cannot alias the whole home"

# An intent remembers HOME too: a ~-declared file torn down after a crash
# goes to the recorded home, not whoever runs the repair.
reset_box
HH="$TMP/hh"; mkdir -p "$HH/cfg" "$TMP/otherhome"; mkpkg "$HH/pkg" hh 1
manifest "$HH/pkg/airlock-app.toml" hh <<EOF
[artifacts]
files = ["~/hh-file"]
EOF
cat > "$HH/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_HH_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
printf 'h\n' > "\$HOME/hh-file"
exit 1
EOF
mkcfg "$HH/cfg/airlock.toml" "[apps.hh]" "backend_port = 18928" "[packages.hh]" "path = \"$HH/pkg\""
orch "$HH/cfg/airlock.toml" >/dev/null 2>&1 && bad "home-snap: crashing install passed"
mkcfg "$HH/cfg/airlock.toml"   # dropped: repair must remove ~/hh-file
out="$(env HOME="$TMP/otherhome" AIRLOCK_CONFIG="$HH/cfg/airlock.toml" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" bash "$ROOT/install/airlock-install.sh" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ ! -e "$FAKEHOME/hh-file" ] && [ ! -e "$TMP/otherhome/hh-file" ]; then
  ok "home-snap: repair removes the ~-file under the RECORDED home"
else
  bad "home-snap: recorded home ignored (rc=$rc, fake=$([ -e "$FAKEHOME/hh-file" ] && echo kept || echo gone))"
fi

# The ledger never persists a store it would refuse to re-read: an intent
# built from inconsistent package-info dies at the write, not the next run.
reset_box
mkdir -p "$STATE"; WB="$TMP/wb"; mkpkg "$WB/pkg" wb 1
out="$(printf '{"config_path":"%s","packages":{"wb":{"dir":"%s","artifacts":{"units":[],"fragments":[],"webroot":[],"files":[],"serve_ports":["backend_port"]},"lifecycle":{"install":true,"smoke":true,"deactivate":true},"serve_port_values":{},"capabilities":[]}}}' "$TMP/none.toml" "$WB/pkg" \
        | env HOME="$FAKEHOME" python3 "$ROOT/bin/airlock-ledger" intent wb 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && grep -q "serve_port_values keys" <<<"$out" && [ ! -s "$STATE/app-ledger.json" ]; then
  ok "write-gate: an inconsistent intent dies at the write, nothing persisted"
else
  bad "write-gate: inconsistent store persisted or wrong error (rc=$rc)"
fi

# An intent remembers its roots: repair after a crash expands against the
# roots the installer actually wrote under, even if the env has moved.
reset_box
IR="$TMP/ir"; mkdir -p "$IR/cfg" "$TMP/mvroot"; mkpkg "$IR/pkg" ir 1
manifest "$IR/pkg/airlock-app.toml" ir <<EOF
[artifacts]
units = ["ir.service"]
EOF
cat > "$IR/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_IR_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
printf '[Unit]\n' > "$UU/ir.service"
exit 1
EOF
mkcfg "$IR/cfg/airlock.toml" "[apps.ir]" "backend_port = 18925" "[packages.ir]" "path = \"$IR/pkg\""
orch "$IR/cfg/airlock.toml" >/dev/null 2>&1 && bad "intent-roots: crashing install passed"
mkcfg "$IR/cfg/airlock.toml"   # package dropped: repair must tear the intent down
out="$(orch "$IR/cfg/airlock.toml" AIRLOCK_UNIT_DIR_USER="$TMP/mvroot" 2>&1)" && rc=0 || rc=$?
moved_ok=0
[ "$rc" != 0 ] && [ -f "$UU/ir.service" ] && [ "$(ledger_field ir x '"intent" in e')" = True ] && moved_ok=1
out="$(orch "$IR/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$moved_ok" = 1 ] && [ "$rc" = 0 ] && [ ! -e "$UU/ir.service" ] \
   && [ "$(ledger_field ir x '"intent" in e')" != True ]; then
  ok "intent-roots: a moved root env fails loudly; the true env converges"
else
  bad "intent-roots: crash repair lost the recorded root (moved_ok=$moved_ok rc=$rc)"
fi

# An intent's serve VALUE map must be exactly its declared key set — an
# undeclared value would make its port a teardown target nothing declared.
reset_box
mkdir -p "$STATE"
printf '{"version":1,"entries":{"zs":{"intent":{"path":"/nowhere","digest":"%s","artifacts_declared":{"units":[],"fragments":[],"webroot":[],"files":[],"serve_ports":[]},"serve_port_values":{"bad":18999},"lifecycle":{"install":true,"smoke":false,"deactivate":false},"roots":{"unit_user":"%s","unit_system":"%s","confd":"%s","webroot":"%s","home":"%s"}}}}}\n' "$Z" "$UU" "$US" "$CONFD" "$WEB" "$FAKEHOME" > "$STATE/app-ledger.json"
msg="$(run "$CFGDIR/ok.toml" validate 2>&1)" && bad "intent-serve: undeclared serve value accepted" || {
  grep -q "serve_port_values keys" <<<"$msg" \
    && ok "intent-serve: an undeclared serve value fails validate" \
    || bad "intent-serve: wrong message: $msg"; }
rm -f "$STATE/app-ledger.json"

# An outside-roots recorded unit fails loudly even when the file is absent —
# a quiet success would drop a record whose pending reload this run cannot see.
reset_box
mkdir -p "$STATE"
printf '{"version":1,"entries":{"zg":{"committed":{"path":"/nowhere","digest":"%s","lifecycle":{"install":true,"smoke":false,"deactivate":false},"artifacts":{"units":["%s/gone/g.service"],"fragments":[],"webroot":[],"files":[],"serve_ports":[]}}}}}\n' "$Z" "$TMP" > "$STATE/app-ledger.json"
ZG="$TMP/zg"; mkdir -p "$ZG"; mkcfg "$ZG/airlock.toml"
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$ZG/airlock.toml" bash "$ROOT/bin/airlock-teardown" zg 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && [ "$(ledger_field zg x '"committed" in e')" = True ]; then
  ok "units: an absent outside-roots unit still fails loudly, record kept"
else
  bad "units: absent outside-roots unit dropped quietly (rc=$rc)"
fi

# A hand-made intent cannot smuggle what the manifest grammar refuses.
reset_box
mkdir -p "$STATE"
printf '{"version":1,"entries":{"zi":{"intent":{"path":"/nowhere","digest":"%s","artifacts_declared":{"units":[],"fragments":[],"webroot":[],"files":["victim"],"serve_ports":[]},"serve_port_values":{},"lifecycle":{"install":true,"smoke":false,"deactivate":false},"roots":{"unit_user":"%s","unit_system":"%s","confd":"%s","webroot":"%s","home":"%s"}}}}}\n' "$Z" "$UU" "$US" "$CONFD" "$WEB" "$FAKEHOME" > "$STATE/app-ledger.json"
msg="$(run "$CFGDIR/ok.toml" validate 2>&1)" && bad "intent-grammar: relative files pattern accepted" || {
  grep -q "absolute or ~-prefixed" <<<"$msg" \
    && ok "intent-grammar: a hand-made intent with a relative files pattern fails validate" \
    || bad "intent-grammar: wrong message: $msg"; }
rm -f "$STATE/app-ledger.json"

# A recorded unit whose parent is no longer EXACTLY a unit root is foreign —
# a root env moved to an ancestor must not disable a same-named current unit.
reset_box
mkdir -p "$STATE" "$TMP/old"; printf 'unit\n' > "$TMP/old/mv.service"
printf '{"version":1,"entries":{"zm":{"committed":{"path":"/nowhere","digest":"%s","lifecycle":{"install":true,"smoke":false,"deactivate":false},"artifacts":{"units":["%s/old/mv.service"],"fragments":[],"webroot":[],"files":[],"serve_ports":[]}}}}}\n' "$Z" "$TMP" > "$STATE/app-ledger.json"
MV="$TMP/mv"; mkdir -p "$MV"; mkcfg "$MV/airlock.toml"
out="$(env HOME="$FAKEHOME" AIRLOCK_UNIT_DIR_USER="$TMP" AIRLOCK_CONFIG="$MV/airlock.toml" bash "$ROOT/bin/airlock-teardown" zm 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && [ -f "$TMP/old/mv.service" ] && ! grep -q "disable --now mv.service" "$TMP/systemctl.log"; then
  ok "units: a moved unit root never disables a same-named foreign unit"
else
  bad "units: root move misclassified a recorded unit (rc=$rc)"
fi

# Teardown touches recorded artifacts only: an emptied parent directory stays.
reset_box
mkdir -p "$STATE" "$TMP/pp/sub"; printf 'x\n' > "$TMP/pp/sub/f"
printf '{"version":1,"entries":{"zp":{"committed":{"path":"/nowhere","digest":"%s","lifecycle":{"install":true,"smoke":false,"deactivate":false},"artifacts":{"units":[],"fragments":[],"webroot":[],"files":["%s/pp/sub/f"],"serve_ports":[]}}}}}\n' "$Z" "$TMP" > "$STATE/app-ledger.json"
PP="$TMP/ppc"; mkdir -p "$PP"; mkcfg "$PP/airlock.toml"
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$PP/airlock.toml" bash "$ROOT/bin/airlock-teardown" zp 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ ! -e "$TMP/pp/sub/f" ] && [ -d "$TMP/pp/sub" ]; then
  ok "teardown: recorded artifacts only — the emptied parent directory stays"
else
  bad "teardown: unrecorded parent removed or teardown failed (rc=$rc)"
fi

# A dangling ledger symlink is corrupt, not empty (F9a).
reset_box
mkdir -p "$STATE"; ln -s "$STATE/missing" "$STATE/app-ledger.json"
msg="$(run "$CFGDIR/ok.toml" validate 2>&1)" && bad "F9a: dangling symlink treated as empty" || {
  grep -q "dangling symlink" <<<"$msg" \
    && ok "F9a: a dangling ledger symlink fails validate closed" \
    || bad "F9a: dangling symlink — wrong message: $msg"; }
rm -f "$STATE/app-ledger.json"

# A packaged app's plaintext surface is its DECLARED serve ports only — the
# generic http_port/public_port sweep must skip it (an undeclared mapping
# would be recorded nowhere and unreclaimable).
reset_box
PX="$TMP/px"; mkdir -p "$PX"; mkpkg "$PX/pkg" tp 1
manifest "$PX/pkg/airlock-app.toml" tp public_port redirect_port <<EOF
[artifacts]
webroot = ["tp/"]
EOF
mkcfg "$PX/airlock.toml" "[apps.tp]" "public_port = 18950" "redirect_port = 18951" "[packages.tp]" "path = \"$PX/pkg\""
rows="$(run "$PX/airlock.toml" plaintext 2>/dev/null)"
if ! grep -q "^tp	" <<<"$rows"; then
  ok "plaintext: undeclared packaged ports are not swept into the mapping"
else
  bad "plaintext: generic sweep mapped an undeclared packaged port: $(grep "^tp" <<<"$rows")"
fi
known="$(run "$PX/airlock.toml" plaintext-known 2>/dev/null)"
if ! grep -qx "18950" <<<"$known"; then
  ok "plaintext-known: an undeclared packaged port is not sweepable as stale"
else
  bad "plaintext-known: undeclared packaged port 18950 claimed as ours"
fi

# A packaged serve value colliding with a built-in plaintext listen port is
# fatal at validate (the later direct mapping would replace the built-in's).
reset_box
PC="$TMP/pc"; mkdir -p "$PC"; mkpkg "$PC/pkg" tc 1
manifest "$PC/pkg/airlock-app.toml" tc listen <<EOF
[artifacts]
webroot = ["tc/"]
serve_ports = ["listen"]
EOF
mkcfg "$PC/airlock.toml" "[apps.tc]" "listen = 19901" "[packages.tc]" "path = \"$PC/pkg\""
msg="$(run "$PC/airlock.toml" validate 2>&1)" && bad "collision: packaged serve value over hub's 19901 accepted" || {
  grep -q "built-in" <<<"$msg" \
    && ok "collision: packaged serve value colliding with a built-in plaintext port is fatal" \
    || bad "collision: wrong message: $msg"; }

# Option-like unit names never enter the contract.
reset_box
HU="$TMP/hu"; mkdir -p "$HU"; mkpkg "$HU/pkg" th 1
manifest "$HU/pkg/airlock-app.toml" th <<EOF
[artifacts]
units = ["--evil.service"]
EOF
mkcfg "$HU/airlock.toml" "[apps.th]" "backend_port = 18915" "[packages.th]" "path = \"$HU/pkg\""
msg="$(run "$HU/airlock.toml" validate 2>&1)" && bad "hyphen-unit: option-like unit name accepted" || {
  grep -q "option-like" <<<"$msg" \
    && ok "hyphen-unit: an option-like unit name is fatal at validate" \
    || bad "hyphen-unit: wrong message: $msg"; }

# A recorded unit outside the current unit roots is never unlinked blind —
# there is no systemctl name to stop it by (env changed?), so fail loudly.
reset_box
mkdir -p "$STATE" "$TMP/outside"; printf 'unit\n' > "$TMP/outside/x.service"
printf '{"version":1,"entries":{"zu":{"committed":{"path":"/nowhere","digest":"%s","lifecycle":{"install":true,"smoke":false,"deactivate":false},"artifacts":{"units":["%s/outside/x.service"],"fragments":[],"webroot":[],"files":[],"serve_ports":[]}}}}}\n' "$Z" "$TMP" > "$STATE/app-ledger.json"
OU="$TMP/ou"; mkdir -p "$OU"; mkcfg "$OU/airlock.toml"
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$OU/airlock.toml" bash "$ROOT/bin/airlock-teardown" zu 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && [ -f "$TMP/outside/x.service" ] && [ "$(ledger_field zu x '"committed" in e')" = True ]; then
  ok "units: a recorded unit outside the roots fails loudly, file and record kept"
else
  bad "units: outside-roots unit handled blind (rc=$rc)"
fi

# daemon-reload is retryable: its failure keeps the record even after the
# unit file is gone, and the next teardown runs the reload again.
reset_box
mkdir -p "$STATE" "$UU"; printf 'unit\n' > "$UU/tr.service"
printf '{"version":1,"entries":{"tr":{"committed":{"path":"/nowhere","digest":"%s","lifecycle":{"install":true,"smoke":false,"deactivate":false},"artifacts":{"units":["%s/tr.service"],"fragments":[],"webroot":[],"files":[],"serve_ports":[]}}}}}\n' "$Z" "$UU" > "$STATE/app-ledger.json"
RL="$TMP/rl"; mkdir -p "$RL"; mkcfg "$RL/airlock.toml"
: > "$TMP/reload-fails"
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$RL/airlock.toml" bash "$ROOT/bin/airlock-teardown" tr 2>&1)" && rc=0 || rc=$?
first_ok=0
[ "$rc" != 0 ] && [ ! -e "$UU/tr.service" ] && [ "$(ledger_field tr x '"committed" in e')" = True ] && first_ok=1
rm -f "$TMP/reload-fails"; : > "$TMP/systemctl.log"
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$RL/airlock.toml" bash "$ROOT/bin/airlock-teardown" tr 2>&1)" && rc=0 || rc=$?
if [ "$first_ok" = 1 ] && [ "$rc" = 0 ] && grep -q -- "--user daemon-reload" "$TMP/systemctl.log" \
   && [ "$(ledger_field tr x '"committed" in e')" != True ]; then
  ok "units: a failed daemon-reload keeps the record and the re-run reloads again"
else
  bad "units: reload failure not retryable (first_ok=$first_ok rc=$rc)"
fi

# Lifecycle children must not inherit the lock fd: a background process an
# installer leaves behind would otherwise hold the flock after the run ends.
reset_box
FD="$TMP/fdt"; mkdir -p "$FD/cfg"; mkpkg "$FD/pkg" t13 1
cat >> "$FD/pkg/install.sh" <<'EOF'
sleep 15 >/dev/null 2>&1 &
EOF
mkcfg "$FD/cfg/airlock.toml" "[apps.t13]" "backend_port = 18916" "[packages.t13]" "path = \"$FD/pkg\""
orch "$FD/cfg/airlock.toml" >/dev/null 2>&1 || bad "lock-fd: setup install failed"
out="$(orch "$FD/cfg/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ]; then
  ok "lock-fd: a background lifecycle child does not hold the ledger lock"
else
  bad "lock-fd: re-run blocked by an inherited lock fd (rc=$rc)"
fi

# Standalone smoke pins a relative state dir too (packaged smoke scripts run
# from the package cwd).
reset_box
SS="$TMP/ss"; mkdir -p "$SS/cfg" "$SS/cwd/srel"; mkpkg "$SS/pkg" t14 1
cat >> "$SS/pkg/smoke.sh" <<EOF
printf '%s\n' "\$AIRLOCK_STATE_DIR" > "$TMP/t14-statedir"
EOF
mkcfg "$SS/cfg/airlock.toml" "[apps.t14]" "backend_port = 18917" "[packages.t14]" "path = \"$SS/pkg\""
orch "$SS/cfg/airlock.toml" >/dev/null 2>&1 || bad "smoke-pin: setup install failed"
out="$(cd "$SS/cwd" && env HOME="$FAKEHOME" AIRLOCK_CONFIG="$SS/cfg/airlock.toml" AIRLOCK_STATE_DIR="srel" bash "$ROOT/bin/airlock-smoke" 2>&1)" && rc=0 || rc=$?
seen="$(cat "$TMP/t14-statedir" 2>/dev/null || true)"
if [ "$rc" = 0 ] && [ "$seen" = "$SS/cwd/srel" ]; then
  ok "smoke-pin: standalone smoke pins a relative state dir before package cwd"
else
  bad "smoke-pin: not pinned (rc=$rc, seen=$seen)"
fi

# =============================================================================
# F16 — container intent, collision, and runtime-proven removal
# =============================================================================
# A stateful Docker fake keeps this fixture runnable in CI, but deliberately
# implements only the API surface the platform and this package are allowed to
# use.  It rejects name filters, short-id/name removals, mutable image refs,
# pulls/builds, and named volumes/networks at the command boundary.  Every
# runtime result is persisted independently of the ledger so the assertions can
# prove that a record disappears only after Docker itself answered ABSENT.
F16="$TMP/f16"
F16_DOCKER_STATE="$F16/docker-state.json"
F16_DOCKER_CONTROL="$F16/docker-control.json"
F16_DOCKER_LOG="$F16/docker.log"
F16_DOCKER_AUDIT="$F16/docker-audit.log"
F16_IMAGE="registry.invalid/airlock-t16@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
export F16_DOCKER_STATE F16_DOCKER_CONTROL F16_DOCKER_LOG F16_DOCKER_AUDIT F16_IMAGE
mkdir -p "$F16"
: > "$F16_DOCKER_AUDIT"

cat > "$SHIM/docker" <<'PY'
#!/usr/bin/env python3
import json
import os
import re
import sys
from pathlib import Path

STATE = Path(os.environ["F16_DOCKER_STATE"])
CONTROL = Path(os.environ["F16_DOCKER_CONTROL"])
LOG = Path(os.environ["F16_DOCKER_LOG"])
AUDIT = Path(os.environ["F16_DOCKER_AUDIT"])
LEDGER = Path(os.environ["AIRLOCK_STATE_DIR"]) / "app-ledger.json"
PACKAGE_LABEL = "io.airlock.package"
NONCE_LABEL = "io.airlock.install-nonce"
FULL_ID = re.compile(r"[0-9a-f]{64}")


def read_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def write_json(path, value):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def ledger_fact():
    raw = read_json(LEDGER, {"entries": {}})
    entry = (raw.get("entries") or {}).get("t16") or {}
    kinds = [kind for kind in ("committed", "intent") if kind in entry]
    intent = entry.get("intent") or {}
    runtime = intent.get("container_runtime") or {}
    return {"ledger_kind": "+".join(kinds) or "none",
            "ledger_nonce": runtime.get("install_nonce")}


def log(event, **extra):
    row = {"event": event, "argv": sys.argv[1:], **ledger_fact(), **extra}
    line = json.dumps(row, sort_keys=True) + "\n"
    for path in (LOG, AUDIT):
        with path.open("a", encoding="utf-8") as stream:
            stream.write(line)


def die(message, rc=64):
    log("rejected", reason=message)
    print(message, file=sys.stderr)
    raise SystemExit(rc)


def labels_from_filters(args):
    labels = {}
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--filter":
            if index + 1 >= len(args):
                die("--filter requires a value")
            value = args[index + 1]
            index += 2
        elif arg.startswith("--filter="):
            value = arg.split("=", 1)[1]
            index += 1
        else:
            index += 1
            continue
        if value.startswith("name="):
            die("name filters are forbidden: candidates come from exact labels")
        if not value.startswith("label=") or "=" not in value[6:]:
            die(f"unsupported filter {value!r}")
        key, val = value[6:].split("=", 1)
        labels[key] = val
    return labels


state = read_json(STATE, {"next_id": 1, "objects": {}, "rm_calls": 0,
                          "images": [os.environ["F16_IMAGE"]],
                          "volumes": [], "networks": ["bridge", "host", "none"]})
control = read_json(CONTROL, {})
args = sys.argv[1:]
log("call")
if not args:
    die("missing docker command")

if args == ["info"]:
    log("info-ok")
    raise SystemExit(0)
if args == ["info", "--format", "{{.ID}}"]:
    identity = control.get("daemon_identity", "t16-fixture-daemon")
    log("daemon-identity", identity=identity)
    print(identity)
    raise SystemExit(0)

if args[0] in {"pull", "build"} or args[:2] in (["volume", "create"], ["network", "create"]):
    die("pull/build/named volume/network creation is forbidden")

if args[0] == "ps":
    if not all(arg in {"ps", "-aq", "--no-trunc", "--filter"}
               or arg.startswith(("--filter=", "label=")) for arg in args):
        die(f"unsupported ps arguments: {args!r}")
    filters = labels_from_filters(args)
    ids = []
    for object_id, obj in state["objects"].items():
        if all(obj["labels"].get(k) == v for k, v in filters.items()):
            ids.append(object_id)
    ids.sort()
    exact_pair = PACKAGE_LABEL in filters and NONCE_LABEL in filters
    if (exact_pair and not ids and control.get("spawn_on_filtered_empty")
            and not control.get("spawned")
            and state.get("rm_calls", 0) >= control.get("spawn_after_rm", 0)):
        object_id = f'{state["next_id"]:064x}'
        state["next_id"] += 1
        state["objects"][object_id] = {
            "name": control.get("spawn_name", "airlock-t16-race"),
            "labels": {PACKAGE_LABEL: filters[PACKAGE_LABEL],
                       NONCE_LABEL: filters[NONCE_LABEL]},
        }
        control["spawned"] = True
        write_json(STATE, state)
        write_json(CONTROL, control)
        ids = [object_id]
        log("race-spawn", object_id=object_id, filters=filters)
    log("ps-result", ids=ids, filters=filters)
    if ids:
        print("\n".join(ids))
    raise SystemExit(0)

if args[0] == "inspect" and len(args) == 2:
    query = args[1]
    object_id = query if query in state["objects"] else next(
        (oid for oid, obj in state["objects"].items() if obj["name"] == query), None)
    def absence_reply(target):
        # Docker has shipped more than one wording for "no such object" and
        # changes the casing between releases, so the fixture can speak either
        # dialect. The platform must not depend on which one it hears.
        if control.get("absence_message") == "lowercase":
            return f"error: no such object: {target}"
        if control.get("absence_message") == "daemon":
            return f"Error response from daemon: No such container: {target}"
        return f"Error: No such object: {target}"
    if object_id is None:
        log("inspect-result", query=query, state="ABSENT")
        print(absence_reply(query), file=sys.stderr)
        raise SystemExit(1)
    if object_id in control.get("inspect_absent_liar", []):
        # Present, but the query claims absence. Nothing may conclude the
        # object is gone from that claim alone.
        log("inspect-result", query=query, object_id=object_id, state="LIAR")
        print(absence_reply(query), file=sys.stderr)
        raise SystemExit(1)
    if object_id in control.get("inspect_unknown", []):
        log("inspect-result", query=query, object_id=object_id, state="UNKNOWN")
        print("fixture daemon query failed", file=sys.stderr)
        raise SystemExit(2)
    obj = state["objects"][object_id]
    returned_id = (control.get("inspect_id_mismatch") or {}).get(object_id, object_id)
    log("inspect-result", query=query, object_id=object_id,
        returned_id=returned_id, state="PRESENT")
    print(json.dumps([{"Id": returned_id, "Name": "/" + obj["name"],
                       "Config": {"Labels": obj["labels"]}}], sort_keys=True))
    raise SystemExit(0)

if args[0] == "run":
    if args[-1] != os.environ["F16_IMAGE"] or args[-1] not in state["images"]:
        die("docker run must use the preseeded immutable image digest")
    if "--pull=never" not in args:
        die("docker run must use --pull=never")
    if any(arg in {"-v", "--volume"} or arg.startswith("--volume=") for arg in args):
        die("named/short volume syntax is forbidden")
    if "--network=bridge" not in args:
        die("only the built-in bridge network is allowed by this fixture")
    if "--tmpfs" not in args:
        die("the fixture requires an explicit tmpfs")
    mounts = [args[i + 1] for i, arg in enumerate(args[:-1]) if arg == "--mount"]
    if not mounts or any(not value.startswith("type=bind,") for value in mounts):
        die("only explicit bind mounts are allowed")
    name = None
    labels = {}
    index = 1
    while index < len(args) - 1:
        arg = args[index]
        if arg == "--name":
            name = args[index + 1]
            index += 2
        elif arg == "--label":
            key, value = args[index + 1].split("=", 1)
            labels[key] = value
            index += 2
        elif arg in {"--tmpfs", "--mount"}:
            index += 2
        else:
            index += 1
    if not name or any(obj["name"] == name for obj in state["objects"].values()):
        die("container name is missing or already exists")
    if set(labels) != {PACKAGE_LABEL, NONCE_LABEL} or labels[PACKAGE_LABEL] != "t16":
        die("create requires exactly the package and install-nonce labels")
    entry = (read_json(LEDGER, {"entries": {}}).get("entries") or {}).get("t16") or {}
    intent_runtime = (entry.get("intent") or {}).get("container_runtime") or {}
    if intent_runtime.get("install_nonce") != labels[NONCE_LABEL]:
        die("container create happened before its durable matching intent")
    object_id = f'{state["next_id"]:064x}'
    state["next_id"] += 1
    state["objects"][object_id] = {"name": name, "labels": labels}
    write_json(STATE, state)
    log("authorized-create", object_id=object_id, name=name,
        install_nonce=labels[NONCE_LABEL], policy_ok=True)
    print(object_id)
    raise SystemExit(0)

if args[0] == "rm" and len(args) == 3 and args[1] == "-f":
    object_id = args[2]
    if not FULL_ID.fullmatch(object_id):
        die("rm requires one full immutable 64-hex id")
    state["rm_calls"] = state.get("rm_calls", 0) + 1
    if object_id in control.get("rm_zero_keep", []):
        write_json(STATE, state)
        log("rm-result", object_id=object_id, rc=0, removed=False)
        raise SystemExit(0)
    if object_id in control.get("rm_nonzero_delete", []):
        state["objects"].pop(object_id, None)
        write_json(STATE, state)
        log("rm-result", object_id=object_id, rc=1, removed=True)
        print("fixture rm failed after deleting", file=sys.stderr)
        raise SystemExit(1)
    state["objects"].pop(object_id, None)
    write_json(STATE, state)
    log("rm-result", object_id=object_id, rc=0, removed=True)
    raise SystemExit(0)

die(f"unsupported docker invocation: {args!r}")
PY
chmod +x "$SHIM/docker"

f16_runtime_reset() {
  mkdir -p "$F16"
  printf '{"images":["%s"],"networks":["bridge","host","none"],"next_id":1,"objects":{},"rm_calls":0,"volumes":[]}\n' \
    "$F16_IMAGE" > "$F16_DOCKER_STATE"
  printf '{}\n' > "$F16_DOCKER_CONTROL"
  : > "$F16_DOCKER_LOG"
}

f16_control() {
  printf '%s\n' "$1" > "$F16_DOCKER_CONTROL"
}

f16_state_eval() {
  python3 - "$F16_DOCKER_STATE" "$1" <<'PY'
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
print(eval(sys.argv[2], {"s": s}))
PY
}

f16_log_eval() {
  python3 - "$F16_DOCKER_LOG" "$1" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
print(eval(sys.argv[2], {"rows": rows}))
PY
}

f16_audit_eval() {
  python3 - "$F16_DOCKER_AUDIT" "$1" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
print(eval(sys.argv[2], {"rows": rows, "len": len, "all": all, "any": any}))
PY
}

f16_seed() { # f16_seed <name> <package-label|-> <nonce-label|->
  python3 - "$F16_DOCKER_STATE" "$1" "$2" "$3" <<'PY'
import json, os, sys
path, name, package, nonce = sys.argv[1:]
s = json.load(open(path, encoding="utf-8"))
object_id = f'{s["next_id"]:064x}'
s["next_id"] += 1
labels = {}
if package != "-": labels["io.airlock.package"] = package
if nonce != "-": labels["io.airlock.install-nonce"] = nonce
s["objects"][object_id] = {"name": name, "labels": labels}
tmp = path + ".tmp"
open(tmp, "w", encoding="utf-8").write(json.dumps(s, sort_keys=True) + "\n")
os.replace(tmp, path)
print(object_id)
PY
}

f16_ids() {
  ledger_field t16 x '" ".join(o["id"] for o in e.get("committed",{}).get("container_runtime",{}).get("objects",[]))'
}

f16_nonce() {
  ledger_field t16 x 'e.get("committed",{}).get("container_runtime",{}).get("install_nonce","")'
}

f16_intent_nonce() {
  ledger_field t16 x 'e.get("intent",{}).get("container_runtime",{}).get("install_nonce","")'
}

f16_object_absent() {
  local object_id="$1" out rc
  out="$(docker inspect "$object_id" 2>&1)" && rc=0 || rc=$?
  [ "$rc" != 0 ] && grep -qx "Error: No such object: $object_id" <<<"$out"
}

f16_mkpkg() {
  local dir="$1"
  mkdir -p "$dir" "$F16/data"
  cat > "$dir/airlock-app.toml" <<'EOF'
contract = 1
id = "t16"
[artifacts]
containers = ["airlock-t16-*"]
EOF
  cat > "$dir/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load t16
[ -n "\${AIRLOCK_INSTALL_NONCE:-}" ] || die "missing journaled container nonce"
mapfile -t ids < <(docker ps -aq --no-trunc \
  --filter "label=io.airlock.package=t16" \
  --filter "label=io.airlock.install-nonce=\$AIRLOCK_INSTALL_NONCE")
if [ "\${#ids[@]}" -eq 2 ]; then
  exit 0
fi
[ "\${#ids[@]}" -eq 0 ] || die "active nonce has an unexpected object count"
create() {
  docker run --detach --pull=never --network=bridge \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    --mount "type=bind,src=$F16/data,dst=/data,ro" \
    --name "\$1" \
    --label io.airlock.package=t16 \
    --label "io.airlock.install-nonce=\$AIRLOCK_INSTALL_NONCE" \
    "$F16_IMAGE" >/dev/null
}
create airlock-t16-one
if [ "\$(cat "$F16/mode" 2>/dev/null || true)" = crash-after-one ]; then
  exit 16
fi
create airlock-t16-two
if [ "\$(cat "$F16/mode" 2>/dev/null || true)" = outside-name ]; then
  create t16-outside-declaration
fi
EOF
  cat > "$dir/smoke.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# Real container-backed apps load their platform env from smoke.sh too, and
# that happens after install.sh created the objects but before the ledger
# commit. Opt-in so the other F16 cases keep the no-op smoke they assert on.
[ -f "$F16/smoke-load" ] || exit 0
. "\$AIRLOCK_ROOT/install/lib.sh"
if [ -f "$F16/smoke-foreign" ]; then
  # Inject one name-colliding object the way f16_seed does, so the smoke-phase
  # gate still has a genuine namespace collision to refuse. It wears this
  # package's own label under a DIFFERENT nonce on purpose: that is the variant
  # that binds the assertion to the nonce half of the admitted pair. An
  # unlabelled object would only re-prove that the empty pair is rejected --
  # the install-time collision matrix already covers that, and mixing the two
  # here would let the unlabelled one refuse first and mask this case.
  python3 - "\$F16_DOCKER_STATE" <<'PY'
import json, os, sys
path = sys.argv[1]
s = json.load(open(path, encoding="utf-8"))
object_id = f'{s["next_id"]:064x}'
s["next_id"] += 1
s["objects"][object_id] = {
    "name": "airlock-t16-othernonce",
    "labels": {"io.airlock.package": "t16",
               "io.airlock.install-nonce":
                   "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"}}
tmp = path + ".tmp"
open(tmp, "w", encoding="utf-8").write(json.dumps(s, sort_keys=True) + "\\n")
os.replace(tmp, path)
PY
fi
airlock_load t16
[ -n "\${AIRLOCK_INSTALL_NONCE:-}" ] || die "smoke lost the journaled container nonce"
[ "\${AIRLOCK_CONTAINER_RECONCILE_MODE:-}" = fresh ] \
  || die "smoke saw reconcile mode '\${AIRLOCK_CONTAINER_RECONCILE_MODE:-}'"
EOF
  cat > "$dir/deactivate.sh" <<'EOF'
#!/usr/bin/env bash
# Intentionally no-op: F16 proves the platform's generic full-id teardown.
set -euo pipefail
exit 0
EOF
  chmod +x "$dir"/*.sh
}

f16_new_fixture() {
  reset_box
  f16_runtime_reset
  rm -f "$F16/mode" "$F16/smoke-load" "$F16/smoke-foreign"
  rm -rf "$F16/pkg" "$F16/pkg-gone"
  f16_mkpkg "$F16/pkg"
  mkcfg "$F16/airlock.toml" '[apps.t16]' '[packages.t16]' "path = \"$F16/pkg\""
}

f16_removal_proven_before_drop() { # ids...
  local object_id
  for object_id in "$@"; do
    [ "$(f16_log_eval "any(r.get('event') == 'inspect-result' and r.get('query') == '$object_id' and r.get('state') == 'ABSENT' and 'committed' in r.get('ledger_kind','') for r in rows)")" = True ] \
      || return 1
  done
  [ "$(f16_log_eval "any(r.get('event') == 'ps-result' and not r.get('ids') and 'committed' in r.get('ledger_kind','') and r.get('filters',{}).get('io.airlock.package') == 't16' for r in rows)")" = True ]
}

# Positive path: intent precedes create, commit captures two immutable objects,
# and a same-digest reconcile admits exactly that set without a new create.
f16_new_fixture
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
read -r f16_id1 f16_id2 <<<"$(f16_ids)"
f16_nonce1="$(f16_nonce)"
if [ "$rc" = 0 ] && [ -n "$f16_nonce1" ] \
   && [ "$(f16_log_eval "len([r for r in rows if r.get('event') == 'authorized-create' and r.get('ledger_kind') == 'intent' and r.get('ledger_nonce') == r.get('install_nonce')])")" = 2 ]; then
  ok "F16: durable matching intent exists before each first-install container create"
else
  bad "F16: create preceded intent or initial install failed (rc=$rc): $(tail -5 <<<"$out")"
fi
if [[ "$f16_id1" =~ ^[0-9a-f]{64}$ && "$f16_id2" =~ ^[0-9a-f]{64}$ ]] \
   && [ "$f16_id1" != "$f16_id2" ] \
   && [ "$(ledger_field t16 x 'len(e.get("committed",{}).get("container_runtime",{}).get("objects",[]))')" = 2 ]; then
  ok "F16: commit records the intent nonce and two distinct full immutable ids"
else
  bad "F16: committed container identity set is incomplete"
fi
f16_create_before="$(f16_log_eval "len([r for r in rows if r.get('event') == 'authorized-create'])")"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$(f16_nonce)" = "$f16_nonce1" ] \
   && [ "$(f16_ids)" = "$f16_id1 $f16_id2" ] \
   && [ "$(f16_log_eval "len([r for r in rows if r.get('event') == 'authorized-create'])")" = "$f16_create_before" ]; then
  ok "F16: same-digest reconcile reuses the nonce and exact committed ids without mutation"
else
  bad "F16: same-digest reconcile changed nonce/id set or created an object"
fi

# Normal configured removal: exact-id ABSENT and exact-label empty are observed
# by the fake while the committed entry is still present, then the entry drops.
mkcfg "$F16/airlock.toml"
: > "$F16_DOCKER_LOG"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && f16_removal_proven_before_drop "$f16_id1" "$f16_id2" \
   && f16_object_absent "$f16_id1" && f16_object_absent "$f16_id2"; then
  ok "F16: normal removal proves exact ids and two-label set ABSENT before ledger drop"
else
  bad "F16: normal removal lacked runtime-proven pre-drop absence (rc=$rc)"
fi
[ "$(ledger_field t16 x '"intent" in e or "committed" in e')" != True ] \
  && ok "F16: normal removal drops the ledger entry only after runtime absence" \
  || bad "F16: normal removal retained the entry after proven absence"

# Path-gone and digest-mismatch each force recorded/generic teardown and must
# retain the same proof ordering as the ordinary deactivator path.
mkcfg "$F16/airlock.toml" '[apps.t16]' '[packages.t16]' "path = \"$F16/pkg\""
orch "$F16/airlock.toml" >/dev/null 2>&1 || bad "F16: path-gone setup install failed"
read -r f16_pg1 f16_pg2 <<<"$(f16_ids)"
mv "$F16/pkg" "$F16/pkg-gone"
mkcfg "$F16/airlock.toml"
: > "$F16_DOCKER_LOG"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && f16_removal_proven_before_drop "$f16_pg1" "$f16_pg2" \
   && f16_object_absent "$f16_pg1" && f16_object_absent "$f16_pg2" \
   && [ "$(ledger_field t16 x '"intent" in e or "committed" in e')" != True ]; then
  ok "F16: path-gone removal proves runtime absence before dropping the record"
else
  bad "F16: path-gone removal did not converge with proof (rc=$rc)"
fi
mv "$F16/pkg-gone" "$F16/pkg"

mkcfg "$F16/airlock.toml" '[apps.t16]' '[packages.t16]' "path = \"$F16/pkg\""
orch "$F16/airlock.toml" >/dev/null 2>&1 || bad "F16: digest-mismatch setup install failed"
read -r f16_dm1 f16_dm2 <<<"$(f16_ids)"
printf '# digest mutation\n' >> "$F16/pkg/install.sh"
mkcfg "$F16/airlock.toml"
: > "$F16_DOCKER_LOG"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && f16_removal_proven_before_drop "$f16_dm1" "$f16_dm2" \
   && f16_object_absent "$f16_dm1" && f16_object_absent "$f16_dm2" \
   && [ "$(ledger_field t16 x '"intent" in e or "committed" in e')" != True ]; then
  ok "F16: digest-mismatch removal proves runtime absence before dropping the record"
else
  bad "F16: digest-mismatch removal did not converge with proof (rc=$rc)"
fi

# Intent-only crash after one create: retry tears down by the old recorded
# nonce before replacing the journal with a fresh nonce and committing two.
f16_new_fixture
printf 'crash-after-one\n' > "$F16/mode"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
f16_crash_nonce="$(f16_intent_nonce)"
f16_crash_id="$(f16_state_eval "next(iter(s['objects'])) if len(s['objects']) == 1 else ''")"
if [ "$rc" != 0 ] && [ -n "$f16_crash_nonce" ] && [[ "$f16_crash_id" =~ ^[0-9a-f]{64}$ ]] \
   && [ "$(ledger_field t16 x '"intent" in e and "committed" not in e')" = True ]; then
  ok "F16: crash after first create leaves one object and an intent-only nonce"
else
  bad "F16: crash fixture did not preserve its intent-only recovery record"
fi
rm -f "$F16/mode"
: > "$F16_DOCKER_LOG"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
f16_retry_nonce="$(f16_nonce)"
if [ "$rc" = 0 ] && [ "$f16_retry_nonce" != "$f16_crash_nonce" ] \
   && f16_object_absent "$f16_crash_id" \
   && [ "$(f16_log_eval "any(r.get('event') == 'inspect-result' and r.get('query') == '$f16_crash_id' and r.get('state') == 'ABSENT' and r.get('ledger_kind') == 'intent' for r in rows)")" = True ] \
   && [ "$(ledger_field t16 x 'len(e.get("committed",{}).get("container_runtime",{}).get("objects",[]))')" = 2 ]; then
  ok "F16: intent-crash retry proves old absence, journals a fresh nonce, and commits two"
else
  bad "F16: intent-crash retry reused/orphaned the old nonce set (rc=$rc)"
fi

# Foreign namespace matrix: every incomplete/wrong ownership pair blocks an
# install and is untouched.  Once inserted beside a legitimate committed set,
# the same objects are diagnostic-only during removal; a substring lookalike
# never enters the candidate/diagnostic namespace at all.
f16_new_fixture
f16_other_nonce="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
f16_foreign_ids="$(f16_seed airlock-t16-no-label - -)"
f16_foreign_ids="$f16_foreign_ids $(f16_seed airlock-t16-package-only t16 -)"
f16_foreign_ids="$f16_foreign_ids $(f16_seed airlock-t16-nonce-only - "$f16_other_nonce")"
f16_foreign_ids="$f16_foreign_ids $(f16_seed airlock-t16-both-other other "$f16_other_nonce")"
f16_foreign_ids="$f16_foreign_ids $(f16_seed airlock-t16-other-nonce t16 "$f16_other_nonce")"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
f16_foreign_present=1
for f16_id in $f16_foreign_ids; do
  [ "$(f16_state_eval "'$f16_id' in s['objects']")" = True ] || f16_foreign_present=0
done
if [ "$rc" != 0 ] && [ "$f16_foreign_present" = 1 ] \
   && grep -q "container namespace collision" <<<"$out" \
   && [ "$(f16_log_eval "len([r for r in rows if r.get('event') == 'authorized-create'])")" = 0 ]; then
  ok "F16: every foreign label variant blocks install and remains untouched"
else
  bad "F16: foreign collision matrix was mutated or admitted (rc=$rc)"
fi

f16_new_fixture
orch "$F16/airlock.toml" >/dev/null 2>&1 || bad "F16: foreign-removal setup install failed"
read -r f16_owned1 f16_owned2 <<<"$(f16_ids)"
f16_other_nonce="CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
f16_foreign_ids="$(f16_seed airlock-t16-no-label - -)"
f16_foreign_ids="$f16_foreign_ids $(f16_seed airlock-t16-package-only t16 -)"
f16_foreign_ids="$f16_foreign_ids $(f16_seed airlock-t16-nonce-only - "$f16_other_nonce")"
f16_foreign_ids="$f16_foreign_ids $(f16_seed airlock-t16-both-other other "$f16_other_nonce")"
f16_foreign_ids="$f16_foreign_ids $(f16_seed airlock-t16-other-nonce t16 "$f16_other_nonce")"
f16_lookalike="$(f16_seed xairlock-t16-substring - -)"
mkcfg "$F16/airlock.toml"
: > "$F16_DOCKER_LOG"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
f16_foreign_present=1
for f16_id in $f16_foreign_ids "$f16_lookalike"; do
  [ "$(f16_state_eval "'$f16_id' in s['objects']")" = True ] || f16_foreign_present=0
done
if [ "$rc" = 0 ] && [ "$f16_foreign_present" = 1 ] \
   && f16_object_absent "$f16_owned1" && f16_object_absent "$f16_owned2" \
   && [ "$(ledger_field t16 x '"intent" in e or "committed" in e')" != True ]; then
  ok "F16: removal deletes owned ids but leaves every foreign collision untouched"
else
  bad "F16: removal crossed the foreign ownership boundary (rc=$rc)"
fi
if [ "$(grep -c "foreign container collision left untouched" <<<"$out")" = 5 ] \
   && ! grep -q "xairlock-t16-substring" <<<"$out" \
   && [ "$(f16_log_eval "any(any(str(a).startswith('name=') for a in r.get('argv',[])) for r in rows)")" = False ]; then
  ok "F16: foreign matches are diagnostic-only and substring lookalikes/name filters are excluded"
else
  bad "F16: foreign diagnostics or substring/name-filter candidate selection drifted"
fi

# One committed snapshot drives the four independent failure controls.  A
# fixture restore is test setup only; every exercised command still consumes a
# validated v6 record and a separately modelled live runtime.
f16_new_fixture
orch "$F16/airlock.toml" >/dev/null 2>&1 || bad "F16: failure-control setup install failed"
read -r f16_fault1 f16_fault2 <<<"$(f16_ids)"
mkcfg "$F16/airlock.toml"
cp "$STATE/app-ledger.json" "$F16/ledger.snapshot"
cp "$F16_DOCKER_STATE" "$F16/docker.snapshot"
f16_restore_fault() {
  cp "$F16/ledger.snapshot" "$STATE/app-ledger.json"
  cp "$F16/docker.snapshot" "$F16_DOCKER_STATE"
  f16_control '{}'
  : > "$F16_DOCKER_LOG"
}

f16_restore_fault
f16_control "{\"inspect_unknown\":[\"$f16_fault1\"]}"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && [ "$(ledger_field t16 x '"committed" in e')" = True ] \
   && [ "$(f16_state_eval "'$f16_fault1' in s['objects'] and '$f16_fault2' in s['objects']")" = True ]; then
  ok "F16: UNKNOWN runtime query fails closed with record and objects retained"
else
  bad "F16: UNKNOWN runtime query lost evidence or passed (rc=$rc)"
fi

f16_restore_fault
f16_control "{\"rm_zero_keep\":[\"$f16_fault1\"]}"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && [ "$(ledger_field t16 x '"committed" in e')" = True ] \
   && [ "$(f16_state_eval "'$f16_fault1' in s['objects']")" = True ]; then
  ok "F16: rm zero with object still PRESENT fails and retains the record"
else
  bad "F16: rm-zero/PRESENT was mistaken for removal (rc=$rc)"
fi

f16_restore_fault
f16_control "{\"rm_nonzero_delete\":[\"$f16_fault1\"]}"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
f16_nonzero_first=0
if [ "$rc" != 0 ] && f16_object_absent "$f16_fault1" \
   && [ "$(ledger_field t16 x '"committed" in e')" = True ]; then
  f16_nonzero_first=1
fi
f16_control '{}'
: > "$F16_DOCKER_LOG"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$f16_nonzero_first" = 1 ] && [ "$rc" = 0 ] \
   && [ "$(f16_log_eval "len([r for r in rows if r.get('event') == 'rm-result'])")" = 0 ] \
   && [ "$(ledger_field t16 x '"intent" in e or "committed" in e')" != True ]; then
  ok "F16: non-zero rm followed by ABSENT retains once, then retry drops without another rm"
else
  bad "F16: nonzero-rm/ABSENT retry semantics drifted (first=$f16_nonzero_first rc=$rc)"
fi

f16_restore_fault
f16_replacement="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
f16_control "{\"inspect_id_mismatch\":{\"$f16_fault1\":\"$f16_replacement\"}}"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && [ "$(ledger_field t16 x '"committed" in e')" = True ] \
   && [ "$(f16_log_eval "len([r for r in rows if r.get('event') == 'rm-result'])")" = 0 ]; then
  ok "F16: immutable-id replacement fails preflight with the record retained"
else
  bad "F16: immutable-id replacement reached removal or dropped evidence (rc=$rc)"
fi

f16_restore_fault
f16_control '{"daemon_identity":"t16-other-daemon"}'
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] && grep -q "Docker daemon identity changed" <<<"$out" \
   && [ "$(ledger_field t16 x '"committed" in e')" = True ] \
   && [ "$(f16_state_eval "'$f16_fault1' in s['objects'] and '$f16_fault2' in s['objects']")" = True ] \
   && [ "$(f16_log_eval "len([r for r in rows if r.get('event') == 'rm-result'])")" = 0 ]; then
  ok "F16: Docker daemon identity change fails before mutation with record and objects retained"
else
  bad "F16: daemon identity change crossed the mutation boundary (rc=$rc)"
fi
f16_control '{}'

# An exact active label pair outside the declaration is invalid at commit, but
# teardown authority comes from the nonce and therefore still includes it.
f16_new_fixture
printf 'outside-name\n' > "$F16/mode"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
f16_outside_id="$(f16_state_eval "next((oid for oid,o in s['objects'].items() if o['name'] == 't16-outside-declaration'),'')")"
if [ "$rc" != 0 ] && [[ "$f16_outside_id" =~ ^[0-9a-f]{64}$ ]] \
   && [ "$(ledger_field t16 x '"intent" in e and "committed" not in e')" = True ] \
   && grep -q "outside the declaration" <<<"$out"; then
  ok "F16: exact-label object outside the namespace blocks commit and keeps intent"
else
  bad "F16: outside-namespace exact-label object reached commit (rc=$rc)"
fi
mkcfg "$F16/airlock.toml"
rm -f "$F16/mode"
: > "$F16_DOCKER_LOG"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && f16_object_absent "$f16_outside_id" \
   && [ "$(ledger_field t16 x '"intent" in e or "committed" in e')" != True ]; then
  ok "F16: nonce-driven teardown removes the exact-label object outside the declaration"
else
  bad "F16: nonce teardown orphaned the outside-namespace object (rc=$rc)"
fi

# A same-nonce object born after all planned ids were removed is caught by the
# final label-set oracle.  On retry it is owned (not foreign), becomes a union
# candidate, and is removed before the record can drop.
f16_new_fixture
orch "$F16/airlock.toml" >/dev/null 2>&1 || bad "F16: final-oracle setup install failed"
mkcfg "$F16/airlock.toml"
f16_control '{"spawn_after_rm":2,"spawn_name":"airlock-t16-race","spawn_on_filtered_empty":true}'
: > "$F16_DOCKER_LOG"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
f16_race_id="$(f16_state_eval "next((oid for oid,o in s['objects'].items() if o['name'] == 'airlock-t16-race'),'')")"
if [ "$rc" != 0 ] && [[ "$f16_race_id" =~ ^[0-9a-f]{64}$ ]] \
   && [ "$(ledger_field t16 x '"committed" in e')" = True ] \
   && grep -q "final container label-set is not empty" <<<"$out"; then
  ok "F16: final label-set oracle catches a new same-nonce id and retains the record"
else
  bad "F16: final-oracle race escaped or lost its record (rc=$rc)"
fi
f16_control '{}'
: > "$F16_DOCKER_LOG"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && f16_object_absent "$f16_race_id" \
   && [ "$(ledger_field t16 x '"intent" in e or "committed" in e')" != True ] \
   && ! grep -q "foreign container collision" <<<"$out"; then
  ok "F16: retry removes the race id as unexpected owned, not foreign"
else
  bad "F16: final-oracle retry did not converge as owned (rc=$rc)"
fi

# The load gate runs again inside smoke.sh, and smoke runs after install.sh
# created this run's objects but before the ledger commit. A fresh intent must
# therefore admit the objects carrying its own nonce -- refusing them deadlocks
# the lifecycle permanently, because the commit that would end "fresh" is
# exactly what the refusal prevents.
f16_new_fixture
: > "$F16/smoke-load"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] \
   && [ "$(ledger_field t16 x '"committed" in e')" = True ] \
   && [ "$(f16_state_eval "len([o for o in s['objects'].values() if o['labels'].get('io.airlock.package') == 't16']) == 2")" = True ] \
   && ! grep -q "exact-label object" <<<"$out"; then
  ok "F16: smoke-phase load on a fresh intent admits this run's own objects"
else
  bad "F16: the fresh-intent load gate deadlocked its own lifecycle (rc=$rc)"
fi

# Negative control for the same gate: admitting our own nonce must not admit
# anyone else's. A name-colliding object owned by nobody, inserted between the
# create and the smoke-phase load, still has to stop the run -- and stop it for
# that reason, not for the self-collision the case above removed.
f16_new_fixture
: > "$F16/smoke-load"
: > "$F16/smoke-foreign"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" != 0 ] \
   && grep -q "container namespace collision" <<<"$out" \
   `# bind the refusal to the LOAD gate: only airlock-config's admission call` \
   `# emits this prefix. Without it the commit-time capture refuses the same` \
   `# object with the same collision wording, and the case would pass even if` \
   `# the smoke-phase gate had admitted a foreign nonce.` \
   && grep -q "container runtime admission failed for app 't16'" <<<"$out" \
   && [ "$(ledger_field t16 x '"committed" in e')" != True ] \
   && [ "$(f16_state_eval "any(o['name'] == 'airlock-t16-othernonce' for o in s['objects'].values())")" = True ] \
   && [ "$(f16_log_eval "len([r for r in rows if r.get('event') == 'rm-result'])")" = 0 ]; then
  ok "F16: smoke-phase load still refuses a foreign namespace collision"
else
  bad "F16: smoke-phase load lost the foreign namespace guard (rc=$rc)"
fi

# Absence is a fact about the daemon's object list, not about the wording of an
# error string. The runtime ships more than one phrasing and changes the casing
# between releases, so a removal that actually completed must still converge.
f16_new_fixture
orch "$F16/airlock.toml" >/dev/null 2>&1 || bad "F16: absence-dialect setup install failed"
read -r f16_dialect1 f16_dialect2 <<<"$(f16_ids)"
f16_control '{"absence_message":"lowercase"}'
mkcfg "$F16/airlock.toml"
: > "$F16_DOCKER_LOG"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ] \
   && [ "$(f16_state_eval "'$f16_dialect1' not in s['objects'] and '$f16_dialect2' not in s['objects']")" = True ] \
   && [ "$(ledger_field t16 x '"intent" in e or "committed" in e')" != True ] \
   && ! grep -q "not proven ABSENT" <<<"$out"; then
  ok "F16: removal proves absence by re-query, not by the daemon's error wording"
else
  bad "F16: a reworded absence reply blocked a completed removal (rc=$rc)"
fi
f16_control '{}'

# Negative control for that proof: the guard exists to catch "said it removed
# it, did not". An object that is still listed must never be retired on the
# strength of an absence reply, no matter how well phrased.
f16_new_fixture
orch "$F16/airlock.toml" >/dev/null 2>&1 || bad "F16: forged-absence setup install failed"
read -r f16_liar1 f16_liar2 <<<"$(f16_ids)"
f16_control "{\"inspect_absent_liar\":[\"$f16_liar1\"]}"
mkcfg "$F16/airlock.toml"
: > "$F16_DOCKER_LOG"
out="$(orch "$F16/airlock.toml" 2>&1)" && rc=0 || rc=$?
f16_liar_reason="$(grep -c "is UNKNOWN (exit 1); the daemon still lists the object" <<<"$out")"
f16_liar_refusal="$(grep -c "could not establish $f16_liar1" <<<"$out")"
f16_liar_objects="$(f16_state_eval "'$f16_liar1' in s['objects'] and '$f16_liar2' in s['objects']")"
f16_liar_record="$(ledger_field t16 x '"committed" in e')"
f16_liar_rms="$(f16_log_eval "len([r for r in rows if r.get('event') == 'rm-result'])")"
if [ "$rc" != 0 ] && [ "$f16_liar_reason" != 0 ] && [ "$f16_liar_refusal" != 0 ] \
   && [ "$f16_liar_objects" = True ] && [ "$f16_liar_record" = True ] \
   && [ "$f16_liar_rms" = 0 ]; then
  ok "F16: a forged absence reply cannot retire a container the daemon still lists"
else
  bad "F16: absence proof accepted a claim the daemon's own list contradicts (rc=$rc reason=$f16_liar_reason refusal=$f16_liar_refusal objects=$f16_liar_objects record=$f16_liar_record rms=$f16_liar_rms)"
fi
f16_control '{}'

# Package/runtime obligations: the fake rejected violations inline; this audit
# pins the positive arguments too.  The Notes acceptance supplies the separate
# real-Docker before/after image/volume/network inventory required by D9/F16.
if [ "$(f16_audit_eval "all(len(r.get('object_id','')) == 64 for r in rows if r.get('event') == 'rm-result')")" = True ] \
   && [ "$(f16_audit_eval "all(r.get('policy_ok') is True for r in rows if r.get('event') == 'authorized-create')")" = True ]; then
  ok "F16: fake runtime enforces immutable image, pull-never, bind/tmpfs, built-in network, and full-id rm"
else
  bad "F16: runtime argument policy or full-id removal was not proved"
fi
if [ "$(f16_audit_eval "any(r.get('argv',[None])[0] in ('pull','build') or r.get('argv',[])[:2] in (['volume','create'],['network','create']) for r in rows if r.get('argv'))")" = False ] \
   && [ "$(f16_state_eval "s['images'] == ['$F16_IMAGE'] and s['volumes'] == [] and s['networks'] == ['bridge','host','none']")" = True ]; then
  ok "F16: fixture creates no image, named volume, or named network"
else
  bad "F16: forbidden Docker resource inventory changed"
fi

# =============================================================================
# F17 — 폭발 반경: 한 패키지의 deactivate 실패가 다른 패키지를 끌어내리지 않는다
#
# 재조정은 바뀐 패키지를 **전부** 먼저 비활성화한 뒤 설치한다(옛 설치가 쥔
# 포트를 새 것이 잡기 전에 놓게 하려고). 그래서 중간에 죽으면 이미 내려간
# 패키지들이 되살아날 길 없이 남는다 — 2026-08-26 실기기에서 두 번 났고,
# 한 번은 무관한 앱 넷이 down 인 채 남았다.
#
# 원장은 **기록된 경로**의 deactivator 를 지문까지 맞춰 보고 부르므로, 여기서도
# 그 모양 그대로 만든다: a1 에서 설치해 a1 이 기록되게 하고, 설정을 a2 로 옮겨
# `upgrade-deactivate` 를 유발한다. a1 은 손대지 않으므로 그 deactivator 가 실제로
# 돈다. 실패는 패키지 트리 밖의 플래그 파일로 만든다 — 스크립트를 고치면 지문이
# 달라져 아예 안 불리기 때문이다.
# =============================================================================
reset_box
BR="$TMP/blast"; mkdir -p "$BR/cfg"
mkpkg "$BR/a1" ba 1
mkpkg "$BR/b1" bb 1
# a 의 deactivator: 플래그가 있으면 실패한다 (트리 밖 조건이라 지문은 안정)
cat >"$BR/a1/deactivate.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ -e "$TMP/blast-fail" ] && exit 1
rm -f "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID/marker"
exit 0
EOF
chmod +x "$BR/a1/deactivate.sh"
blast_cfg() { # blast_cfg <a-dir> <b-dir>
  mkcfg "$BR/cfg/airlock.toml" \
    '[apps.ba]' 'backend_port = 18901' '[packages.ba]' "path = \"$1\"" \
    '[apps.bb]' 'backend_port = 18902' '[packages.bb]' "path = \"$2\""
}
blast_cfg "$BR/a1" "$BR/b1"
orch "$BR/cfg/airlock.toml" >/dev/null 2>&1 || bad "F17: first install failed"

# 둘 다 '바뀜'으로 계획되게 새 디렉터리로 옮긴다. a1·b1 은 그대로 두므로
# 기록된 deactivator 는 여전히 지문이 맞아 실제로 실행된다.
mkpkg "$BR/a2" ba 1
mkpkg "$BR/b2" bb 1
: > "$TMP/blast-fail"
blast_cfg "$BR/a2" "$BR/b2"
n_bb_before="$(grep -c '^ROOT=' "$TMP/invoke-bb.log" 2>/dev/null || echo 0)"
out_blast="$(orch "$BR/cfg/airlock.toml" 2>&1)" && rc_blast=0 || rc_blast=$?

[ "$rc_blast" != 0 ] \
  && ok "F17: 비활성화 실패가 실행을 실패로 끝낸다 (조용히 넘어가지 않는다)" \
  || bad "F17: run exited 0 despite a failed deactivation"
grep -q "reconcile FAILED: could not deactivate 'ba'" <<<"$out_blast" \
  && ok "F17: 실패한 패키지를 이름으로 말한다" \
  || bad "F17: failure was not named (out: $(tail -3 <<<"$out_blast"))"
grep -q "skipping install of 'ba'" <<<"$out_blast" \
  && ok "F17: 내리지 못한 패키지는 그 위에 설치하지 않는다" \
  || bad "F17: the failed package was installed over its stale artifacts"
n_bb_after="$(grep -c '^ROOT=' "$TMP/invoke-bb.log" 2>/dev/null || echo 0)"
[ "$n_bb_after" -gt "$n_bb_before" ] \
  && ok "F17: 무관한 패키지는 그대로 재설치된다 (끌려 내려가지 않는다)" \
  || bad "F17: bb was not reinstalled (before=$n_bb_before after=$n_bb_after)"
[ -f "$WEB/bb/marker" ] \
  && ok "F17: 무관한 패키지가 실제로 다시 서 있다" \
  || bad "F17: bb marker missing after the run"
[ "$(ledger_field ba x '"committed" in e')" = True ] \
  && ok "F17: 실패한 패키지의 기록은 남아 다음 실행이 재시도한다" \
  || bad "F17: ba ledger record was dropped despite the failed teardown"

# =============================================================================
# F18 — disable 이 유닛 파일을 먼저 지워도 회수는 성공이어야 한다
#
# _teardown_unit 의 부재 검사는 `disable` **앞**에만 있다. 그런데 유닛이
# 심링크면 `systemctl --user disable` 이 그 파일을 스스로 지우고, 그 뒤의
# unlink 는 반드시 ENOENT 로 죽는다. 그것을 실패로 세면 기록이 안 지워지고,
# 다음 실행이 같은 회수를 다시 계획해 같은 자리에서 또 죽는다 — 교착이다.
# system 쪽은 `sudo rm -f` 라 원래 멀쩡했다. user 쪽만 그랬다.
# =============================================================================
reset_box
DG="$TMP/dgone"; mkdir -p "$DG/cfg"; mkpkg "$DG/pkg" dg 1
manifest "$DG/pkg/airlock-app.toml" dg <<EOF
[artifacts]
units = ["dg.service"]
EOF
cat > "$DG/pkg/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_DG_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
printf '[Unit]\n' > "$UU/dg.service"
EOF
cat > "$DG/pkg/smoke.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# 이 deactivator 는 유닛에 손대지 않는다 — 실제 systemd 처럼 disable 이 지운다.
cat > "$DG/pkg/deactivate.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$DG/pkg"/*.sh
mkcfg "$DG/cfg/airlock.toml" "[apps.dg]" "backend_port = 18926" "[packages.dg]" "path = \"$DG/pkg\""
orch "$DG/cfg/airlock.toml" >/dev/null 2>&1 || bad "F18: 첫 설치 실패"
[ -f "$UU/dg.service" ] || bad "F18: 유닛이 설치되지 않았다"
: > "$TMP/disable-removes-unit"
mkcfg "$DG/cfg/airlock.toml"          # 패키지를 뺀다 -> 재조정이 회수한다
out_dg="$(orch "$DG/cfg/airlock.toml" 2>&1)" && rc_dg=0 || rc_dg=$?
rm -f "$TMP/disable-removes-unit"

[ "$rc_dg" = 0 ] \
  && ok "F18: disable 이 먼저 지운 유닛도 회수가 성공으로 끝난다" \
  || bad "F18: teardown failed (rc=$rc_dg): $(tail -3 <<<"$out_dg")"
[ ! -e "$UU/dg.service" ] \
  && ok "F18: 유닛이 실제로 사라져 있다 (후조건이 성립한다)" \
  || bad "F18: unit file survived"
[ "$(ledger_field dg x '"committed" in e or "intent" in e')" != True ] \
  && ok "F18: 기록이 지워져 교착에 빠지지 않는다" \
  || bad "F18: ledger record kept — the deadlock is still there"

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
