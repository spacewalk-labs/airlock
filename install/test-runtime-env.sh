#!/usr/bin/env bash
# install/test-runtime-env.sh — [config].runtime_env, and the strict scan.
#
# The problem it solves: one install printed 90 warning lines of the shape
# "references AIRLOCK_PUBLISH_GATED_DIR, but 'gated_dir' is not a declared config
# key (the export will not exist)". The wording implies a bug in eighteen places.
# It was not: seventeen of the eighteen are names the INSTALLER WRITES into units,
# secrets or test seams, and one is an operator knob read as a raw string. Nothing
# was reading a key that did not exist — the scan simply had no way to say
# "written, not read", so it said the only thing it could.
#
# Declaring them as config keys would have been worse than the warnings. They would
# merge into resolved config (bin/airlock-config's resolved()) and be exported, and
# for two of them that CHANGES BEHAVIOUR: AIRLOCK_PASEO_ALLOW_UNBACKED_MEM is
# compared against the literal `1`, so a bool declaration exports "true" and stops
# matching; AIRLOCK_DEV_MONITOR_CORS_HOSTS is measured by the installer from the
# box's FQDN, so a declaration creates a knob that does nothing.
#
# So: a declaration space that is explicitly NOT config. The cases below are mostly
# about the ways that space could become an escape hatch, because a way to silence
# the scan without fixing anything is strictly worse than the warnings were.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CFG="$ROOT/bin/airlock-config"
pass=0; fail=0
ok()  { echo "ok   runtime-env: $1"; pass=$((pass+1)); }
bad() { echo "FAIL runtime-env: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Strict certification is immutable production bundle policy.  The focused
# scratch-root cases below need a shipped principal without adding a production
# override, so a PATH-scoped test interpreter patches only the imported process.
PYSHIM="$TMP/python-shim"; mkdir -p "$PYSHIM"
cat >"$PYSHIM/python3" <<'PY'
#!/usr/bin/python3
import importlib.util
import os
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

tool = os.environ.get("AIRLOCK_TEST_CONFIG_TOOL", "")
root_value = os.environ.get("AIRLOCK_TEST_BUNDLE_ROOT", "")
if len(sys.argv) > 1 and tool and root_value \
        and os.path.realpath(sys.argv[1]) == os.path.realpath(tool):
    sys.argv.pop(1)
    loader = SourceFileLoader("_airlock_runtime_env_test", tool)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    root = Path(root_value)
    fixture_ids = sorted(
        entry.name for entry in root.iterdir()
        if entry.is_dir() and not entry.is_symlink()
        and (entry / "airlock-app.toml").is_file()
        and not (entry / "airlock-app.toml").is_symlink()
        and module.PACKAGE_ID_RE.fullmatch(entry.name) is not None
        and entry.name not in module.RESERVED_PACKAGE_IDS
    )
    module.BUNDLE_ENTITLEMENTS = {package_id: () for package_id in fixture_ids}
    module.BUNDLE_ROOT = root
    raise SystemExit(module.main(sys.argv[1:]))
os.execv("/usr/bin/python3", ["/usr/bin/python3", *sys.argv[1:]])
PY
chmod +x "$PYSHIM/python3"
export AIRLOCK_TEST_CONFIG_TOOL="$CFG"
PATH="$PYSHIM:$PATH"; export PATH

# A minimal external package, so every case below is about the manifest and not
# about the shipped tree.
mkpkg() {   # mkpkg <dir> <manifest-config-body> [file-contents]
  local d="$1" body="$2" content="${3:-}"
  mkdir -p "$d"
  { printf 'contract = 1\nid = "probe"\n\n'
    printf '%s\n' "$body"
    printf '\n[[prerequisites]]\ncommand = "sh"\npredicate = "present"\nexpected = "-"\n'
    printf 'fix = "it is already there"\nnote = "shell"\n'
  } > "$d/airlock-app.toml"
  printf '#!/usr/bin/env bash\n%s\n' "$content" > "$d/install.sh"
  printf '#!/usr/bin/env bash\n' > "$d/smoke.sh"
}

mkcfg() {   # mkcfg <dir>  -> echoes a config path enabling the probe package
  local d="$1" c="$TMP/cfg-$RANDOM.toml"
  { printf '[site]\nname = "P"\n\n[auth]\nprovider = "tailscale"\nowner = "o@example.com"\n\n'
    printf '[apps.hub]\n[apps.probe]\n\n[packages.probe]\npath = "%s"\n' "$d"
  } > "$c"
  printf '%s\n' "$c"
}

run() {   # run <cfgpath> [env...] -> sets OUT/RC
  local c="$1"; shift
  OUT="$(env AIRLOCK_CONFIG="$c" "$@" python3 "$CFG" validate 2>&1)"; RC=$?
}

# ---- it silences the finding it is for, and only that one ----
d="$TMP/p1"; mkpkg "$d" '[config]
runtime_env = ["AIRLOCK_PROBE_WRITTEN"]

[config.defaults]
port = 1234' 'echo "$AIRLOCK_PROBE_WRITTEN" > /dev/null; echo "$AIRLOCK_PROBE_PORT"'
run "$(mkcfg "$d")"
printf '%s' "$OUT" | grep -q 'AIRLOCK_PROBE_WRITTEN' \
  && bad "a declared runtime_env name was still reported as an undeclared read" \
  || ok "a declared runtime_env name stops being reported"

d="$TMP/p2"; mkpkg "$d" '[config]
runtime_env = ["AIRLOCK_PROBE_WRITTEN"]

[config.defaults]
port = 1234' 'echo "$AIRLOCK_PROBE_WRITTEN"; echo "$AIRLOCK_PROBE_SOMETHINGELSE"'
run "$(mkcfg "$d")"
printf '%s' "$OUT" | grep -q 'AIRLOCK_PROBE_SOMETHINGELSE' \
  && ok "declaring one name does not excuse the next one" \
  || bad "an undeclared sibling name went unreported"

# ---- it is not an escape hatch ----
# The whole risk of this field. Each of these must be refused at manifest-validate
# time, not merely warned about.
d="$TMP/p3"; mkpkg "$d" '[config]
runtime_env = ["AIRLOCK_OTHERAPP_THING"]

[config.defaults]
port = 1234'
run "$(mkcfg "$d")"
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "own prefix" \
  && ok "a package cannot declare another package's variable" \
  || bad "a foreign-prefixed runtime_env entry was accepted: $OUT"

d="$TMP/p4"; mkpkg "$d" '[config]
runtime_env = ["AIRLOCK_PROBE_PORT"]

[config.defaults]
port = 1234'
run "$(mkcfg "$d")"
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "collides" \
  && ok "a name cannot be both a config key and a runtime variable" \
  || bad "a runtime_env entry colliding with a declared config key was accepted: $OUT"

d="$TMP/p5"; mkpkg "$d" '[config]
runtime_env = ["AIRLOCK_PROBE_A", "AIRLOCK_PROBE_A"]

[config.defaults]
port = 1234'
run "$(mkcfg "$d")"
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "twice" \
  && ok "a duplicate entry is refused" \
  || bad "a duplicated runtime_env entry was accepted: $OUT"

d="$TMP/p6"; mkpkg "$d" '[config]
runtime_env = ["AIRLOCK_PROBE_lowercase"]

[config.defaults]
port = 1234'
run "$(mkcfg "$d")"
[ "$RC" != 0 ] && ok "a name that is not a valid env var is refused" \
  || bad "a malformed runtime_env entry was accepted: $OUT"

d="$TMP/p7"; mkpkg "$d" '[config]
runtime_env = "AIRLOCK_PROBE_A"

[config.defaults]
port = 1234'
run "$(mkcfg "$d")"
[ "$RC" != 0 ] && ok "runtime_env must be an array, not a bare string" \
  || bad "a scalar runtime_env was accepted: $OUT"

# The most important one: runtime_env must NOT excuse a literal
# `airlock_config get apps.probe.<key>`. That really is a config read and really
# does fail at runtime, whatever the manifest says about the env-var name.
d="$TMP/p8"; mkpkg "$d" '[config]
runtime_env = ["AIRLOCK_PROBE_GHOST"]

[config.defaults]
port = 1234' 'airlock_config get apps.probe.ghost'
run "$(mkcfg "$d")"
printf '%s' "$OUT" | grep -q 'reads apps.probe.ghost' \
  && ok "runtime_env does NOT excuse a literal 'airlock_config get' of the same name" \
  || bad "declaring a runtime_env name silenced a real config read: $OUT"

# ---- strict mode ----
d="$TMP/p9"; mkpkg "$d" '[config.defaults]
port = 1234' 'echo "$AIRLOCK_PROBE_UNDECLARED"'
run "$(mkcfg "$d")"
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'AIRLOCK_PROBE_UNDECLARED' \
  && ok "an EXTERNAL package with an undeclared reference warns and passes" \
  || bad "an external package was blocked: rc=$RC $OUT"
run "$(mkcfg "$d")" AIRLOCK_STRICT_CONFIG_SCAN=1
[ "$RC" = 0 ] \
  && ok "strict mode still does not block an external package — it is not ours to gate" \
  || bad "strict mode blocked an external package: $OUT"

# Shipped packages are where it bites. Build a fake shipped root so the case does
# not depend on breaking a real app.
SHIP="$TMP/ship"; mkdir -p "$SHIP"
mkpkg "$SHIP/probe" '[config.defaults]
port = 1234' 'echo "$AIRLOCK_PROBE_UNDECLARED"'
sed -i 's/^id = "probe"/id = "probe"/' "$SHIP/probe/airlock-app.toml"
shipcfg="$TMP/shipcfg.toml"
printf '[site]\nname = "P"\n\n[auth]\nprovider = "tailscale"\nowner = "o@example.com"\n\n[apps.hub]\n[apps.probe]\n' > "$shipcfg"
OUT="$(AIRLOCK_CONFIG="$shipcfg" AIRLOCK_SHIPPED_APPS_ROOT="$SHIP" AIRLOCK_TEST_BUNDLE_ROOT="$SHIP" python3 "$CFG" validate 2>&1)"; RC=$?
[ "$RC" = 0 ] \
  && ok "a shipped package with an undeclared reference passes when strict is OFF (today's behaviour)" \
  || bad "the default behaviour changed: $OUT"
OUT="$(AIRLOCK_CONFIG="$shipcfg" AIRLOCK_SHIPPED_APPS_ROOT="$SHIP" AIRLOCK_TEST_BUNDLE_ROOT="$SHIP" AIRLOCK_STRICT_CONFIG_SCAN=1 python3 "$CFG" validate 2>&1)"; RC=$?
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'strict scan' \
  && ok "strict mode FAILS a shipped package with a literal undeclared reference" \
  || bad "strict mode did not block a shipped package: rc=$RC $OUT"
# And the fix works: declaring it turns the same tree green under strict.
python3 - "$SHIP/probe/airlock-app.toml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("[config.defaults]",
                       '[config]\nruntime_env = ["AIRLOCK_PROBE_UNDECLARED"]\n\n[config.defaults]'))
PY
OUT="$(AIRLOCK_CONFIG="$shipcfg" AIRLOCK_SHIPPED_APPS_ROOT="$SHIP" AIRLOCK_TEST_BUNDLE_ROOT="$SHIP" AIRLOCK_STRICT_CONFIG_SCAN=1 python3 "$CFG" validate 2>&1)"; RC=$?
[ "$RC" = 0 ] \
  && ok "declaring the name turns the same shipped tree green under strict" \
  || bad "the documented fix does not satisfy strict mode: $OUT"

# A dynamically-built key stays a warning under strict. The scan's own docstring
# records eleven rounds of trying to become a shell parser; promoting a finding it
# cannot decide would be that mistake with a fatal exit attached.
mkpkg "$SHIP/probe" '[config.defaults]
port = 1234' 'k=port; airlock_config get "apps.probe.$k"'
OUT="$(AIRLOCK_CONFIG="$shipcfg" AIRLOCK_SHIPPED_APPS_ROOT="$SHIP" AIRLOCK_TEST_BUNDLE_ROOT="$SHIP" AIRLOCK_STRICT_CONFIG_SCAN=1 python3 "$CFG" validate 2>&1)"; RC=$?
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'at runtime' \
  && ok "a runtime-built key stays a warning even under strict" \
  || bad "strict mode promoted a finding the scan cannot decide: rc=$RC $OUT"

# ---- the shipped tree ----
allcfg="$TMP/all.toml"
{ printf '[site]\nname = "S"\n\n[auth]\nprovider = "tailscale"\nowner = "o@example.com"\n\n'
  printf '[apps.hub]\n'
  for a in "$ROOT"/apps/*/; do printf '[apps.%s]\n' "$(basename "$a")"; done
} > "$allcfg"
OUT="$(AIRLOCK_CONFIG="$allcfg" AIRLOCK_STRICT_CONFIG_SCAN=1 python3 "$CFG" validate 2>&1)"; RC=$?
[ "$RC" = 0 ] \
  && ok "every shipped app passes the strict scan" \
  || { bad "a shipped app fails the strict scan"; printf '%s\n' "$OUT" | tail -6 | sed 's/^/    /'; }
n="$(AIRLOCK_CONFIG="$allcfg" python3 "$CFG" validate 2>&1 | grep -c 'the export will not exist')"
[ "$n" = 0 ] \
  && ok "the 18 'the export will not exist' warnings are gone (was 18 distinct names, 90 lines per install)" \
  || bad "$n such warnings remain"

# CI has to run it under strict, or the gate is a variable nobody sets.
grep -q 'AIRLOCK_STRICT_CONFIG_SCAN' "$ROOT/.github/workflows/ci.yml" \
  && ok "ci.yml sets AIRLOCK_STRICT_CONFIG_SCAN" \
  || bad "ci.yml never turns strict mode on — the gate would never run"

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
