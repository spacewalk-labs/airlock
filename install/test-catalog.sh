#!/usr/bin/env bash
# Tests `airlock-config catalog` — the one subcommand that must answer with NO
# airlock.toml in existence.
#
# Why this exists: a picker has to show what is installable BEFORE the operator has
# chosen anything, and every other subcommand runs after load() (bin/airlock-config,
# main). The macOS launcher (docs/tasks/active/macos-app-launcher.md, Phase 1a) is the
# first caller. Two properties carry that use and neither is self-evident from reading
# the code:
#
#   1. It really is config-free. A test that just runs the command proves nothing if
#      the box it runs on happens to have an airlock.toml somewhere up the tree — so
#      this file carries a POSITIVE CONTROL: in the same scratch directory, `validate`
#      must FAIL for want of a config while `catalog` succeeds. Without that control,
#      "catalog worked" is not evidence that it worked without a config.
#   2. Its output is a pure function of the tree, not of the host or the operator. The
#      run with a config present must be byte-identical to the run without one, and two
#      runs from different directories must agree. That is what lets the launcher cache
#      it, and what lets `arch` be reported rather than applied.
#
# Offline: reads the repo's own manifests. No network, no machine, no config written.
set -uo pipefail
# install/test-render-parity.sh gates that every suite whose text mentions an app
# installer pins the RAM the paseo installer takes its memory share from. The gate is a
# deliberately coarse text scan — it does not reason about WHICH app a path resolves to
# — so suites that never install paseo carry the pin anyway and it sits inert. Cheaper
# than a gate that tries to be clever about which mention counts.
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
CFG="$ROOT/bin/airlock-config"

# 1. POSITIVE CONTROL + the claim. In a directory with no airlock.toml anywhere above
#    it, `validate` must fail (the control: this environment genuinely has no config)
#    and `catalog` must still succeed (the claim).
ctl="$( (cd "$scratch" && env -u AIRLOCK_CONFIG "$CFG" validate) 2>&1 )"
ctl_rc=$?
if [ "$ctl_rc" -eq 0 ]; then
  bad "positive control broken: 'validate' succeeded with no config, so a passing 'catalog' proves nothing"
elif ! printf '%s' "$ctl" | grep -q "no airlock.toml found"; then
  # A nonzero exit alone is not the control. If a repo-root airlock.toml existed
  # but were malformed, validate would also fail — and "no config" would be
  # indistinguishable from "bad config", leaving the scratch dir unproven.
  bad "positive control inconclusive: validate failed for a reason other than a missing config: $(printf '%s' "$ctl" | head -1)"
else
  if (cd "$scratch" && env -u AIRLOCK_CONFIG "$CFG" catalog) > "$scratch/out.json" 2>"$scratch/err"; then
    ok "catalog succeeds where validate fails for want of a config"
  else
    bad "catalog failed with no config present: $(head -1 "$scratch/err")"
  fi
fi

# 2. Valid JSON with the documented shape.
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d["apps"], list) and d["apps"]' "$scratch/out.json" 2>/dev/null; then
  ok "catalog emits JSON with a non-empty apps array"
else
  bad "catalog output is not JSON with a non-empty apps array"
fi

# 3. Exactly the shipped app ids — computed from the tree, so silently dropping an app
#    fails here rather than showing up as a missing checkbox on someone's Mac. `hub` is
#    excluded by contract (RESERVED_PACKAGE_IDS: always installed, never a choice).
expected="$(cd "$ROOT/apps" && for d in */airlock-app.toml; do dirname "$d"; done | sort | tr '\n' ' ')"
actual="$(python3 -c 'import json,sys; print(" ".join(sorted(a["id"] for a in json.load(open(sys.argv[1]))["apps"]))+" ")' "$scratch/out.json")"
if [ "$expected" = "$actual" ]; then
  ok "catalog lists exactly the shipped manifests ($actual)"
else
  bad "catalog id set drifted from apps/: expected [$expected] got [$actual]"
fi
case " $actual " in
  *" hub "*) bad "catalog offers 'hub', which is reserved platform core and not a choice" ;;
  *)         ok "catalog does not offer reserved 'hub'" ;;
esac

# 4. The three manifest facts a picker needs actually survive the projection. Each is a
#    different shape, and each has a real consumer: a dependency the UI must enforce, a
#    tileless backend the UI must render nothing for, and the label it draws.
python3 - "$scratch/out.json" > "$scratch/facts" 2>&1 <<'PY'
import json, sys
apps = {a["id"]: a for a in json.load(open(sys.argv[1]))["apps"]}
def check(name, cond, detail=""):
    print(("ok " if cond else "BAD ") + name + ((" — " + detail) if not cond and detail else ""))
check("dependencies survive (notepad requires publish)",
      apps.get("notepad", {}).get("requires") == ["publish"],
      repr(apps.get("notepad", {}).get("requires")))
check("a tileless backend stays in the catalog with tile=null (feedback)",
      "feedback" in apps and apps["feedback"]["tile"] is None,
      repr(apps.get("feedback", {}).get("tile")))
tiled = [a for a in apps.values() if a["tile"] is not None]
check("every tile carries label+sub+cat",
      bool(tiled) and all(t["tile"].get("label") and t["tile"].get("sub") and t["tile"].get("cat") for t in tiled),
      "one or more tiles missing a field")
# The whole key set, not just the three that are always populated. This pins
# CATALOG's own output shape, which is what a picker codes against — it is NOT a
# parity test against cmd_webjson's separate tile projection, and deleting a key
# there would leave this green. The two projections differ on purpose (webjson
# drops null optionals and rewrites icons to staged URLs), so parity between them
# would have to normalize both sides and is deliberately not claimed here.
TILE_KEYS = {"label", "sub", "cat", "path", "icon", "glyph"}
bad_shape = [x["id"] for x in tiled if set(x["tile"]) != TILE_KEYS]
check("every tile has exactly the documented key set",
      not bad_shape,
      "tiles with an unexpected key set: " + ", ".join(bad_shape))
check("audience, when present, carries supported+default",
      all(set(a["audience"]) == {"supported", "default"}
          for a in apps.values() if a["audience"] is not None),
      "an audience block has an unexpected shape")
check("prerequisites survive with their fix strings",
      all(isinstance(a["prerequisites"], list) for a in apps.values())
      and any(p.get("fix") for a in apps.values() for p in a["prerequisites"]),
      "no prerequisite carried a fix")
PY
while read -r line; do
  case "$line" in
    "ok "*)  ok "${line#ok }" ;;
    "BAD "*) bad "${line#BAD }" ;;
    *)       bad "projection check crashed: $line" ;;
  esac
done < "$scratch/facts"

# 5. `arch` is reported, and the table it comes from still matches its source. ARCH_LIMITS
#    lives in bin/airlock-config because airlock-app.toml has no grammar for it; the guard
#    it transcribes lives in apps/orca/install.sh. Tie them together here or they drift:
#    an orca that gained an arm64 build would otherwise stay greyed out forever, and an
#    app that newly lost one would silently be offered on a machine that cannot run it.
orca_arch="$(python3 -c 'import json,sys; a={x["id"]:x for x in json.load(open(sys.argv[1]))["apps"]}; print(",".join(a.get("orca",{}).get("arch",[])))' "$scratch/out.json")"
if [ "$orca_arch" = "x86_64" ]; then
  # Not `grep x86_64`: that string survives in a comment, a download URL, or a
  # case arm that has quietly grown an `arm64)` sibling — all of which would leave
  # ARCH_LIMITS wrong while the grep stayed green. Parse the guard instead and
  # assert the set of architectures it ACCEPTS is exactly {x86_64}.
  guard="$(python3 "$HERE/arch-guard.py" "$ROOT/apps/orca/install.sh")"
  if [ "$guard" = "accepted=x86_64|rejected=*:die" ]; then
    ok "orca reports arch=[x86_64] and its installer guard still has exactly that shape"
  else
    bad "ARCH_LIMITS says orca is x86_64-only, but its installer guard now reads [$guard] — update ARCH_LIMITS or this test deliberately"
  fi
  # A second guard block anywhere in the file (heredoc, dead function, comment
  # sample) must not be read as if it were the only one — the parser takes the
  # first match, so a decoy above the real guard would describe the wrong thing.
  # shellcheck disable=SC2016  # the fixture must contain a LITERAL $(uname -m)
  printf 'case "$(uname -m)" in\n  x86_64) ;;\n  *) die x ;;\nesac\ncase "$(uname -m)" in\n  *) log ok ;;\nesac\n' > "$scratch/decoy.sh"
  decoy="$(python3 "$HERE/arch-guard.py" "$scratch/decoy.sh")"
  if [ "$decoy" = "accepted=x86_64|rejected=*:die" ]; then
    bad "arch-guard read the first of two guards as authoritative — a decoy block gives a false green"
  else
    ok "arch-guard refuses to choose between multiple guard blocks (got: $decoy)"
  fi

  # The oracle itself, against the two guards that fooled its predecessors: an arm
  # that accepts everything else without dying, and an extra arm written `arm64 )`.
  # Both used to report the accepted value; both must now differ from it.
  for probe in "  *) log \"does not die\" ;;|A: default arm that does not reject" \
               "  arm64 ) ;;\n  *) die x ;;|B: extra accepted arm written with a space"; do
    frag="${probe%%|*}"; label="${probe##*|}"
    # shellcheck disable=SC2059
    printf "case \"\$(uname -m)\" in\n  x86_64) ;;\n$frag\nesac\n" > "$scratch/guard.sh"
    got="$(python3 "$HERE/arch-guard.py" "$scratch/guard.sh")"
    if [ "$got" = "accepted=x86_64|rejected=*:die" ]; then
      bad "arch-guard oracle is blind to $label — it reported the expected value for a guard that is not equivalent"
    else
      ok "arch-guard oracle distinguishes $label"
    fi
  done
else
  bad "orca should report arch=[x86_64]; got [$orca_arch]"
fi
if python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["apps"]; sys.exit(0 if all("arch" not in x for x in a if x["id"]!="orca") else 1)' "$scratch/out.json"; then
  ok "no other app claims an arch limit (absent = runs anywhere)"
else
  bad "an app other than orca carries an arch limit — add it to this test deliberately"
fi

# 6. Pure function of the tree: the operator's config must not change the answer, and
#    neither must the directory it is run from. This is what makes `arch` safe to report
#    rather than apply, and what lets the launcher run it on either side of the boundary.
cat > "$scratch/min.toml" <<'TOML'
[airlock]
config_version = 2
[site]
name = "Test"
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[paths]
[apps.hub]
[apps.devterm]
TOML
AIRLOCK_CONFIG="$scratch/min.toml" AIRLOCK_TS_FQDN=test.example.ts.net "$CFG" catalog > "$scratch/with-config.json" 2>/dev/null
wc_rc=$?
if [ "$wc_rc" -ne 0 ]; then
  bad "catalog failed (rc=$wc_rc) with a config present — comparing its output would prove nothing"
elif cmp -s "$scratch/out.json" "$scratch/with-config.json"; then
  ok "catalog output is identical with and without an airlock.toml"
else
  bad "catalog output changed when a config was present — it is reading the operator's choices"
fi
(cd / && env -u AIRLOCK_CONFIG "$CFG" catalog) > "$scratch/from-root.json" 2>/dev/null
fr_rc=$?
if [ "$fr_rc" -ne 0 ]; then
  bad "catalog failed (rc=$fr_rc) when run from another directory"
elif cmp -s "$scratch/out.json" "$scratch/from-root.json"; then
  ok "catalog output does not depend on the working directory"
else
  bad "catalog output changed with the working directory"
fi

# 7. An empty catalog is a failure, not an answer. AIRLOCK_SHIPPED_APPS_ROOT selects
#    the tree; pointed at nothing it used to print {"apps": []} and exit 0, which a
#    picker would render as "this Airlock ships no apps" with no error anywhere.
empty_out="$(AIRLOCK_SHIPPED_APPS_ROOT=/nonexistent-airlock-root "$CFG" catalog 2>&1)"
empty_rc=$?
if [ "$empty_rc" -eq 0 ]; then
  bad "catalog exited 0 with an empty shipped root — an empty picker is not a real answer"
elif printf '%s' "$empty_out" | grep -q "no app manifests under"; then
  ok "catalog fails loudly when the shipped root holds no manifests"
else
  bad "catalog failed on an empty shipped root but without saying why: $(printf '%s' "$empty_out" | head -1)"
fi

# 8. A manifest that will not parse must be NAMED, not dropped. known_builtin_specs
#    swallows the parse failure by contract (one broken app must not wedge a
#    diagnostic scan); for a picker that silence means an app vanishes from the list
#    with no explanation, so `unreadable` has to carry it.
fake="$scratch/apps"
mkdir -p "$fake"
cp -r "$ROOT/apps/publish" "$fake/publish"
cp -r "$ROOT/apps/notepad" "$fake/notepad"
printf 'this is not toml =\n' > "$fake/notepad/airlock-app.toml"
broken="$(AIRLOCK_SHIPPED_APPS_ROOT="$fake" "$CFG" catalog 2>/dev/null)"
if printf '%s' "$broken" | python3 "$HERE/catalog-unavailable-check.py" notepad; then
  ok "a manifest that will not parse is named in 'unavailable', not silently dropped"
else
  bad "a broken manifest did not surface in 'unavailable' — it vanished from the catalog silently"
fi

# 8a. The harder half of the same rule. _shipped_dirs filters through _regular_file,
#     which turns every OSError into False — so a manifest that cannot even be
#     stat'd was excluded BEFORE the report was computed and went missing from both
#     lists. Corrupting readable TOML (check 8) cannot reach that path; making the
#     app directory unsearchable can.
noread="$scratch/apps-noread"
mkdir -p "$noread"
cp -r "$ROOT/apps/publish" "$noread/publish"
mkdir -p "$noread/notepad" && : > "$noread/notepad/airlock-app.toml"
chmod 000 "$noread/notepad"
hidden="$(AIRLOCK_SHIPPED_APPS_ROOT="$noread" "$CFG" catalog 2>/dev/null)"
chmod 755 "$noread/notepad"
if printf '%s' "$hidden" | python3 "$HERE/catalog-unavailable-check.py" notepad; then
  ok "a manifest that cannot be read is named in 'unavailable' too"
else
  bad "an unreadable manifest went missing from BOTH apps and unavailable — silent loss"
fi

# 8b. The same "empty is not an answer" rule one step later. A root that HOLDS
#     entries but yields no installable app slips past the check above — `dirs` is
#     non-empty, so only the apps list ends up empty. Found by probing rather than
#     by review: the first fix guarded the root and left this hole behind it.
allbroken="$scratch/allbroken/a"
mkdir -p "$allbroken"
printf 'not toml =\n' > "$allbroken/airlock-app.toml"
ab_out="$(AIRLOCK_SHIPPED_APPS_ROOT="$scratch/allbroken" "$CFG" catalog 2>&1)"
ab_rc=$?
if [ "$ab_rc" -eq 0 ]; then
  bad "catalog exited 0 with entries present but no installable app — the empty-picker hole is back"
elif printf '%s' "$ab_out" | grep -q "no installable app under"; then
  ok "catalog fails loudly when entries exist but none yields an installable app"
else
  bad "catalog failed on an all-broken root but without saying why: $(printf '%s' "$ab_out" | head -1)"
fi

# 8c. An unreadable root must produce a message, not a Python traceback. A GUI shells
#     out to this command and shows what it prints; a traceback is not a message.
noperm="$scratch/noperm"
mkdir -p "$noperm/app" && : > "$noperm/app/airlock-app.toml"
chmod 000 "$noperm"
np_out="$(AIRLOCK_SHIPPED_APPS_ROOT="$noperm" "$CFG" catalog 2>&1)"
np_rc=$?
chmod 755 "$noperm"
if [ "$np_rc" -eq 0 ]; then
  bad "catalog succeeded on an unreadable shipped root"
elif printf '%s' "$np_out" | grep -q "Traceback"; then
  bad "catalog raised a raw traceback on an unreadable shipped root instead of a message"
elif printf '%s' "$np_out" | grep -q "cannot read the shipped app root"; then
  ok "catalog reports an unreadable shipped root as a message, not a traceback"
else
  bad "catalog failed on an unreadable root with an unrecognised message: $(printf '%s' "$np_out" | head -1)"
fi

# 8d. The drift helper itself must fail closed. The test compares its stdout against an
#     expected string, so a crash would still fail the check — but it would report a
#     Python error where the answer is "the installer being pinned is gone".
if python3 "$HERE/arch-guard.py" "$scratch/definitely-not-here.sh" >/dev/null 2>&1; then
  bad "arch-guard.py exited 0 on a missing installer"
elif python3 "$HERE/arch-guard.py" >/dev/null 2>&1; then
  bad "arch-guard.py exited 0 with no argument"
elif printf '' | python3 "$HERE/catalog-unavailable-check.py" x >/dev/null 2>&1; then
  bad "catalog-unavailable-check.py exited 0 on empty stdin"
else
  ok "both helpers fail closed on missing input"
fi

# 9. A global flag that cannot apply must be refused, not accepted and ignored.
(cd "$scratch" && env -u AIRLOCK_CONFIG "$CFG" --dangerously-admit-unverified=orca catalog) >/dev/null 2>&1
flag_rc=$?
if [ "$flag_rc" -eq 2 ]; then
  ok "catalog refuses --dangerously-admit-unverified instead of ignoring it"
else
  bad "catalog accepted --dangerously-admit-unverified (rc=$flag_rc) — a flag with no effect reported as success"
fi

# 10. Argument handling: a typo must not be silently ignored.
(cd "$scratch" && env -u AIRLOCK_CONFIG "$CFG" catalog extra) >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "catalog rejects a stray argument with exit 2"
else
  bad "catalog should exit 2 on a stray argument; got $rc"
fi

# 11. The fixture the Swift half decodes must be what this command actually emits.
#     mac/Sources/AirlockLauncherChecks decodes mac/Fixtures/catalog.json and asserts
#     the picker's invariants against it. That is the only place the contract between
#     the two languages is written down.
#
#     Only THIS half runs in CI. There is no macOS runner, so nothing automated ever
#     executes the Swift checks — they are run by hand on a Mac. Which makes this check
#     the more important of the two, not the less: it is the only one that fires when
#     the schema moves, and without it the Swift side would keep passing on someone's
#     laptop against output this command no longer produces.
FIXTURE="$ROOT/mac/Fixtures/catalog.json"
if [ ! -f "$FIXTURE" ]; then
  bad "mac/Fixtures/catalog.json is missing — the Swift half has nothing real to decode"
elif diff -q <("$CFG" catalog) "$FIXTURE" >/dev/null 2>&1; then
  ok "the macOS launcher's catalog fixture matches what catalog emits"
else
  bad "mac/Fixtures/catalog.json has drifted from 'airlock-config catalog' — regenerate it: bin/airlock-config catalog > mac/Fixtures/catalog.json"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
