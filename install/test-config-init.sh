#!/usr/bin/env bash
# Tests `airlock-config init` — the generator that replaces hand-editing a TOML.
#
# Why this exists: the macOS launcher's picker is mechanically "generate the smallest
# config that validates" (docs/tasks/active/macos-app-launcher.md, Phase 1b). That claim
# was measured once, by hand, when the task was written. This file turns it into a
# regression, because the claim is load-bearing: if the generated file stops validating,
# or a defaulted port stops resolving, the GUI's install fails at a screen the user
# cannot read, and the only evidence would be a transcript nobody kept.
#
# The end-to-end oracle is the real one — generate, then run the REAL validator over the
# result and read the REAL resolved ports back out. Asserting the text of the file would
# only pin this generator against itself.
#
# Offline: no network, no machine, no file written outside a scratch dir (init writes to
# stdout by design, so there is nothing to clobber).
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1

airlock_test_counters_init

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
CFG="$ROOT/bin/airlock-config"
# The validator needs a deployment FQDN it would normally get from the installer.
export AIRLOCK_TS_FQDN=test.example.ts.net

# 1. init runs with NO config in existence — it is the command that creates one.
#    Same positive control as catalog: prove the environment really has no config,
#    or "init worked" says nothing about whether it needed one.
ctl="$( (cd "$scratch" && env -u AIRLOCK_CONFIG "$CFG" validate) 2>&1 )"
ctl_rc=$?
if [ "$ctl_rc" -eq 0 ]; then
  bad "positive control broken: validate succeeded with no config"
elif ! printf '%s' "$ctl" | grep -q "no airlock.toml found"; then
  bad "positive control inconclusive: validate failed for another reason: $(printf '%s' "$ctl" | head -1)"
elif (cd "$scratch" && env -u AIRLOCK_CONFIG "$CFG" init --owner owner@fixture.dev) > "$scratch/bare.toml" 2>/dev/null; then
  ok "init succeeds where validate fails for want of a config"
else
  bad "init failed with no config present"
fi

# 2. THE claim: what it generates validates, and the ports nobody typed resolve.
#    These three values are the ones docs/tasks/active/macos-app-launcher.md cites as
#    evidence that the 186-line example is a bluff.
# shellcheck disable=SC2088  # literal on purpose: airlock-config expands ~ itself
"$CFG" init --owner owner@fixture.dev --site-name Test \
       --apps devterm,fileview,paseo > "$scratch/full.toml" 2>/dev/null
if AIRLOCK_CONFIG="$scratch/full.toml" "$CFG" validate >/dev/null 2>&1; then
  ok "a generated config passes the real validator"
else
  bad "generated config failed validate: $(AIRLOCK_CONFIG="$scratch/full.toml" "$CFG" validate 2>&1 | head -1)"
fi
ports_ok=1
while read -r key expected; do
  got="$(AIRLOCK_CONFIG="$scratch/full.toml" "$CFG" get "$key" 2>/dev/null)"
  [ "$got" = "$expected" ] || { bad "defaulted port $key resolved to '$got', expected $expected"; ports_ok=0; }
done <<'PORTS'
apps.hub.nginx_port 19902
apps.devterm.ttyd_port 19912
apps.paseo.backend_port 19952
PORTS
[ "$ports_ok" = 1 ] && ok "ports nobody typed resolve to the manifest defaults"

# 3. Nothing but the two real inputs and one table per app. The point of the generator
#    is that the operator does not choose ports, so a port appearing in the OUTPUT would
#    mean the generator started making decisions that belong to the manifests.
if python3 - "$scratch/full.toml" <<'PYPORT'
import sys, tomllib
# Parse it, do not grep it. A regex over lines answers "is there an unindented
# lowercase key ending in port", which is not the question — a quoted, indented,
# hyphenated or differently-spelled port decision would sail past. Walk the
# parsed document and assert the generator wrote NOTHING but the tables and the
# three operator values.
doc = tomllib.load(open(sys.argv[1], "rb"))
allowed = {("airlock", "config_version"), ("site", "name"),
           ("auth", "provider"), ("auth", "owner")}
extra = []
for section, table in doc.items():
    if section == "apps":
        extra += [f"apps.{a}.{k}" for a, body in table.items() for k in body]
        continue
    extra += [f"{section}.{k}" for k in table if (section, k) not in allowed]
if extra:
    print("generator wrote keys it has no business deciding: " + ", ".join(extra),
          file=sys.stderr)
    raise SystemExit(1)
PYPORT
then
  ok "generated config carries only the operator's own values — no port, no app key"
else
  bad "the generator wrote a key that belongs to the manifests"
fi

# 4. hub is written unconditionally. cmd_validate requires it ("the entrance") and it is
#    a RESERVED_PACKAGE_ID that `catalog` never offers — so if init did not write it, no
#    picker selection could ever produce a valid config.
if grep -q '^\[apps\.hub\]' "$scratch/bare.toml" && AIRLOCK_CONFIG="$scratch/bare.toml" "$CFG" validate >/dev/null 2>&1; then
  ok "hub is written even when no app was selected, and that alone validates"
else
  bad "a selection of no apps did not produce a valid hub-only config"
fi

# 5. Dependencies are closed, and the addition is announced. notepad without publish dies
#    in app_order, so a picker that passed exactly what was ticked would emit a config
#    that fails at validate. Adding it silently would be the other failure: an app the
#    operator never chose, appearing with no explanation.
dep_err="$("$CFG" init --owner owner@fixture.dev --apps notepad 2>&1 >"$scratch/dep.toml")"
if ! AIRLOCK_CONFIG="$scratch/dep.toml" "$CFG" validate >/dev/null 2>&1; then
  bad "notepad alone produced a config that does not validate — the dependency was not closed"
elif ! printf '%s' "$dep_err" | grep -q "added as dependencies: publish"; then
  bad "publish was added silently — the operator gets an app they did not choose, unannounced"
else
  ok "a dependency is added to close the set, and the addition is announced"
fi
if python3 -c 'import sys,tomllib; apps=list(tomllib.load(open(sys.argv[1],"rb"))["apps"]); assert apps.index("publish") < apps.index("notepad")' "$scratch/dep.toml"; then
  ok "a dependency is written before the app that needs it"
else
  bad "notepad was written before publish"
fi

# 6. Refusals. Each of these reaching validate instead of init means a GUI fails several
#    screens after the mistake was made, with a message aimed at a terminal reader.
refuse() {
  local why="$1"; shift
  "$CFG" init "$@" >/dev/null 2>"$scratch/err"
  local rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "init refuses $why at the picker, not at validate"
  else
    bad "init accepted $why (rc=$rc)"
  fi
}
refuse "a flag with no value"                --owner
refuse "an unknown flag"                     --owner owner@fixture.dev --nope x
"$CFG" init >/dev/null 2>&1
noowner_rc=$?
if [ "$noowner_rc" -eq 2 ]; then
  ok "init refuses to run with no --owner at all"
else
  bad "init ran without --owner (rc=$noowner_rc)"
fi

# 7. The output is a function of the inputs alone — same inputs, same bytes, whatever
#    order the picker's checkboxes happened to be read in. A launcher re-runs this to add
#    an app; an unstable generator would rewrite the operator's file every time.
one="$("$CFG" init --owner owner@fixture.dev --apps paseo,devterm 2>/dev/null)"
two="$("$CFG" init --owner owner@fixture.dev --apps devterm,paseo 2>/dev/null)"
three="$("$CFG" init --owner owner@fixture.dev --apps paseo,devterm 2>/dev/null)"
if [ "$one" = "$two" ] && [ "$one" = "$three" ]; then
  ok "output is byte-identical across repeats and input orderings"
else
  bad "generator output is not a function of its inputs alone"
fi

# 8. It writes to stdout and touches nothing. There is no --force to get wrong because
#    there is no path to clobber; this asserts that stays true.
# The claim is "it writes nothing", so watch a whole directory rather than one
# canary file: init never reads AIRLOCK_CONFIG, so a canary AT that path proves
# only that an unread variable was unread. Compare a full listing before and after.
watched="$scratch/watched"
mkdir -p "$watched"
printf 'DO NOT OVERWRITE\n' > "$watched/airlock.toml"
find "$watched" -type f -exec sha256sum {} + | sort > "$scratch/before.sums"
(cd "$watched" && AIRLOCK_CONFIG="$watched/airlock.toml" "$CFG" init \
    --owner owner@fixture.dev --apps fileview) >/dev/null 2>&1
find "$watched" -type f -exec sha256sum {} + | sort > "$scratch/after.sums"
if cmp -s "$scratch/before.sums" "$scratch/after.sums"; then
  ok "init creates and modifies no file, even run inside a directory holding a config"
else
  bad "init touched the filesystem: $(diff "$scratch/before.sums" "$scratch/after.sums" | head -1)"
fi

# 9. Every app the catalog offers can actually be generated and validated. A picker can
#    tick any of them, so a per-app hole would surface as one broken checkbox — the kind
#    of thing a hand-written test with three example apps never reaches. orca is skipped
#    for a reason the catalog itself states: it is x86_64-only.
every_ok=1
seen_apps=0
while read -r app; do
  seen_apps=$((seen_apps+1))
  [ "$app" = orca ] && continue
  # shellcheck disable=SC2088  # literal on purpose, as above
  "$CFG" init --owner owner@fixture.dev --apps "$app" > "$scratch/one.toml" 2>/dev/null
  AIRLOCK_CONFIG="$scratch/one.toml" "$CFG" validate >/dev/null 2>&1 || {
    bad "selecting '$app' alone produced a config that does not validate"; every_ok=0; }
done < <("$CFG" catalog | python3 -c 'import json,sys; [print(a["id"]) for a in json.load(sys.stdin)["apps"]]')
if [ "$seen_apps" -lt 2 ]; then
  # Without this the loop reports success when the producer yields nothing —
  # "every app validated" is trivially true of an empty list, and a broken
  # `catalog` would read as a pass.
  bad "the catalog produced $seen_apps app(s) to check — this check verified nothing"
elif [ "$every_ok" = 1 ]; then
  ok "every app the catalog offers ($seen_apps of them) generates a config that validates"
fi

# 10. Values the operator types must survive into a file a TOML parser can read.
#     This is not hypothetical: the generator first used json.dumps, whose default
#     ensure_ascii spells a non-BMP character as a UTF-16 surrogate pair
#     (\ud83d\ude00) — and TOML forbids escaped surrogates outright. Naming your
#     box with an emoji produced a config no parser would read, and the operator
#     met that as a validate error several screens later. Each value below is
#     round-tripped through the real TOML parser and compared to what was passed.
esc_ok=1
while IFS= read -r value; do
  "$CFG" init --owner owner@fixture.dev --site-name "$value" > "$scratch/esc.toml" 2>/dev/null
  python3 - "$scratch/esc.toml" "$value" <<'PYESC' || esc_ok=0
import sys, tomllib
path, expected = sys.argv[1], sys.argv[2]
try:
    got = tomllib.load(open(path, "rb"))["site"]["name"]
except Exception as e:
    print(f"    {expected!r}: generated file is not valid TOML: {e}", file=sys.stderr)
    raise SystemExit(1)
if got != expected:
    print(f"    {expected!r}: round-tripped as {got!r}", file=sys.stderr)
    raise SystemExit(1)
PYESC
done <<VALUES
$(printf '\xf0\x9f\x98\x80 home')
우리집
a"b
a\\b
$(printf 'a\tb')
$(printf 'a\nb')
$(printf 'a\001b')
VALUES
if [ "$esc_ok" = 1 ]; then
  ok "operator-supplied text round-trips through the real TOML parser (emoji, quotes, controls)"
else
  bad "a value the operator could type does not survive into readable TOML"
fi

# 11. A value cannot escape its string and invent a table. The generator writes three
#     operator-supplied values into TOML; if quoting were wrong, --site-name would be an
#     arbitrary-config-injection point, and the app it silently enabled would be installed.
"$CFG" init --owner owner@fixture.dev --site-name 'x"
[apps.orca]
y = "z' > "$scratch/inj.toml" 2>/dev/null
if python3 -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); sys.exit(0 if list(d["apps"])==["hub"] else 1)' "$scratch/inj.toml"; then
  ok "a crafted value cannot close its string and enable an app"
else
  bad "a crafted --site-name injected a table into the generated config"
fi

# 12. A list flag must accumulate. `--apps a --apps b` dropping the first silently is how
#     a caller that builds its selection in pieces ends up with a box missing an app, with
#     nothing anywhere saying so.
"$CFG" init --owner owner@fixture.dev --apps devterm --apps paseo > "$scratch/acc.toml" 2>/dev/null
if python3 -c 'import sys,tomllib; assert {"devterm","paseo"} <= tomllib.load(open(sys.argv[1],"rb"))["apps"].keys()' "$scratch/acc.toml"; then
  ok "a repeated --apps accumulates instead of silently replacing"
else
  bad "a repeated --apps dropped an earlier selection silently"
fi
"$CFG" init --owner owner@fixture.dev --apps ' devterm , paseo ' > "$scratch/ws.toml" 2>/dev/null
if python3 -c 'import sys,tomllib; assert {"devterm","paseo"} <= tomllib.load(open(sys.argv[1],"rb"))["apps"].keys()' "$scratch/ws.toml"; then
  ok "spaces around a comma-separated list are tolerated"
else
  bad "a list with spaces after the commas was rejected"
fi

# 13. A dependency cycle in the manifest tree must not hang init. The fixture is built
#     here because no shipped manifest has a cycle.
fixture() {  # <root> <id> <deps-toml>
  mkdir -p "$1/$2"; : > "$1/$2/install.sh"; : > "$1/$2/smoke.sh"
  printf 'contract = 1\nid = "%s"\n\n[dependencies]\napps = [%s]\n' "$2" "$3" \
    > "$1/$2/airlock-app.toml"
}
cyc="$scratch/cyc"; fixture "$cyc" aa '"bb"'; fixture "$cyc" bb '"aa"'
# A real timeout, because the failure mode being tested is a hang: `a -> b -> a`
# spun the ordering loop forever, and a GUI would simply have sat there. `placed`
# stopped an app being emitted twice, never being visited again.
AIRLOCK_SHIPPED_APPS_ROOT="$cyc" timeout 10 "$CFG" init --owner owner@fixture.dev --apps aa \
  > "$scratch/cyc.toml" 2>/dev/null
cyc_rc=$?
if [ "$cyc_rc" -eq 124 ]; then
  bad "a dependency cycle hangs init — the ordering loop has no cycle guard"
elif [ "$cyc_rc" -eq 0 ] && python3 -c 'import sys,tomllib; assert {"aa","bb"} <= tomllib.load(open(sys.argv[1],"rb"))["apps"].keys()' "$scratch/cyc.toml"; then
  ok "a dependency cycle terminates and writes both apps instead of hanging"
else
  bad "a dependency cycle produced rc=$cyc_rc"
fi

# 14. `--code-root` is gone with the key it wrote. It used to be REQUIRED as soon as
#     fileview was selected; fileview now serves the filesystem and has no root to
#     choose, so the flag must be rejected as unknown rather than quietly ignored —
#     a silently-accepted flag would let a caller believe it had set a boundary.
"$CFG" init --owner owner@fixture.dev --apps fileview --code-root /srv/code >"$scratch/cr.toml" 2>/dev/null
cr_rc=$?
if [ "$cr_rc" -ne 2 ]; then
  bad "init accepted the retired --code-root flag (rc=$cr_rc)"
elif [ -s "$scratch/cr.toml" ]; then
  bad "init refused --code-root but had already written to stdout"
else
  ok "init refuses the retired --code-root flag before writing anything"
fi

# ...and fileview alone, with no path flag at all, produces a config that validates.
"$CFG" init --owner owner@fixture.dev --apps fileview >"$scratch/mw.toml" 2>/dev/null
if AIRLOCK_CONFIG="$scratch/mw.toml" "$CFG" validate >/dev/null 2>&1; then
  ok "init fileview needs no path flag"
else
  bad "init fileview needs no path flag"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
