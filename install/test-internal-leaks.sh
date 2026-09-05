#!/usr/bin/env bash
# install/test-internal-leaks.sh — controls for install/check-internal-leaks.sh.
#
# The scan is the last thing standing between this repository and a public mirror,
# and until now nothing asserted that it works — it was a shell fragment inside a
# workflow, and the only evidence it functioned was that it had never fired. It has
# fired since (2026-08-07, an internal repository slug in a task document), which is
# reassuring about one branch of the pattern and says nothing about the other
# fourteen. An alternation is exactly the shape where a dead branch hides behind a
# live one, so each branch gets its own fixture.
#
# Every case runs in --dir mode against a scratch tree; none can touch the real one.
#
# 🔴 The probe strings are stored SPLIT and joined at runtime, and that is not
# decoration. A test file containing the very strings the scan forbids would make
# the scan fail on itself, and the fix for that would be an exclusion — which is how
# a guard starts having holes. Every line in the PROBES block below is inert as
# written: the split always falls inside the token the pattern matches. Verified by
# the last case in this file, which scans this very tree and must come back clean.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/check-internal-leaks.sh"
pass=0; fail=0
ok()  { echo "ok   internal-leaks: $1"; pass=$((pass+1)); }
bad() { echo "FAIL internal-leaks: $1"; fail=$((fail+1)); }

FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT

# Every allowlisted string, seeded into each fixture. The stale-entry check demands
# that each one still appears somewhere in the scanned tree, so a fixture without
# them would fail for the wrong reason — and that check is itself worth exercising,
# which the stale case does by removing one.
allow_all() {   # allow_all <dir>
  mkdir -p "$1"
  bash "$GUARD" --print-allow | tr '|' '\n' | sed 's/\\//g' > "$1/allowlisted-strings.txt"
}

# ---- negative control: a tree with nothing internal in it ----
clean="$FIX/clean"; allow_all "$clean"
printf 'hello, this file mentions airlock and example.com and nothing else\n' > "$clean/readme.md"
out="$(bash "$GUARD" --dir "$clean" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "a clean tree passes (and the allowlisted strings are not themselves reported)"
else
  bad "a clean tree was reported as leaking (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# ---- positive control: one fixture per branch of the pattern ----
i=0
while IFS='	' read -r head tail; do
  [ -n "$head$tail" ] || continue
  probe="$head$tail"
  i=$((i+1))
  d="$FIX/leak$i"; allow_all "$d"
  printf 'a line that says %s in the middle of it\n' "$probe" > "$d/leaky.md"
  out="$(bash "$GUARD" --dir "$d" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'Internal/site-specific string found'; then
    ok "caught: $probe"
  else
    bad "NOT caught: $probe (rc=$rc) — this branch of the pattern is dead"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
done <<'PROBES'
s	pacewalk
s	parrow-spectrum
qwertybox-d	ev
qwertybox-m	gmt
Team	SPWK
s	wk-infra
s	wk:something
s	wk_thing
s	wk.thing
macmini	-42
someone@s	pacewalk.tech
doc.s	pacewalk.dev
PROBES
[ "$i" -eq 12 ] || bad "expected 12 pattern branches, drove $i — the probe list and the pattern have drifted apart"

# Case must not be an escape hatch. The readable pattern is mostly lowercase,
# while document titles and licences may capitalise the same identifier.
upper="$FIX/upper"; allow_all "$upper"
printf 'a line that says %s in the middle of it\n' "S""PACEWALK" > "$upper/leaky.md"
out="$(bash "$GUARD" --dir "$upper" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'Internal/site-specific string found'; then
  ok "the scan is case-insensitive"
else
  bad "uppercase changed a forbidden identifier into a false green (rc=$rc)"
fi

# A component subset cannot contain every repository-wide allow entry. Subset mode
# keeps the same pattern and allow stripping, while deliberately omitting only the
# stale-entry assertion whose domain is the complete published repository.
subset="$FIX/subset"; mkdir -p "$subset"
printf 'plain external component\n' > "$subset/readme.md"
if bash "$GUARD" --subset "$subset" >/dev/null 2>&1; then
  ok "a clean component subset passes without repository-wide allow fixtures"
else
  bad "a clean component subset failed"
fi
printf '%s\n' "s""wk-planted" > "$subset/leaky.md"
if ! bash "$GUARD" --subset "$subset" >/dev/null 2>&1; then
  ok "subset mode still catches a planted internal identifier"
else
  bad "subset mode skipped a planted internal identifier"
fi

# ---- an allowlisted token excuses itself and nothing else ----
# The scan strips permitted tokens and re-matches, rather than dropping the whole
# line. So a line carrying both a permitted string and a real leak must still fail.
mixed="$FIX/mixed"; allow_all "$mixed"
printf '%s is public, but %s is not\n' "spacewalk-labs" "s""wk-infra" > "$mixed/mixed.md"
out="$(bash "$GUARD" --dir "$mixed" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then
  ok "a line carrying both an allowlisted token and a real leak still fails"
else
  bad "an allowlisted token excused the whole line it was on (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# ---- the stale-allowlist check ----
# An exception that outlives the string it excuses is a hole nobody is watching.
stale="$FIX/stale"; allow_all "$stale"
gone="s""wk-panel-close"
sed -i "/$gone/d" "$stale/allowlisted-strings.txt"
out="$(bash "$GUARD" --dir "$stale" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q "stale allowlist entry: $gone"; then
  ok "an allowlist entry whose string is gone is reported as stale"
else
  bad "a stale allowlist entry was not reported (rc=$rc)"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# ---- the working-tree mode is the one CI runs, and it is green ----
# This is also what proves the paragraph at the top of this file: if any probe above
# were stored whole, this case would fail on this file.
out="$(bash "$GUARD" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "the working tree (tracked and untracked) is clean"
else
  bad "the working tree is not clean"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# ---- CI calls the script, not a copy of it ----
if grep -q 'install/check-internal-leaks.sh' "$ROOT/.github/workflows/ci.yml" \
   && ! grep -q "^ *PATTERN='" "$ROOT/.github/workflows/ci.yml"; then
  ok "ci.yml calls the script and no longer carries its own copy of the pattern"
else
  bad "ci.yml either does not call the script or still holds a second copy of the pattern"
fi

# ---- the pattern spells out no box name ----
# This is the rule the shape rewrite exists to hold, and it is the one rule the
# guard cannot check about itself: SELF excludes this file from the scan, so a
# name added back to PATTERN would be published by the very check meant to stop
# it, silently and forever. That is not hypothetical — the inline copy that
# preceded this script named four internal repositories and is still in the
# public mirror's history. Enumerating a box here is therefore not a shortcut
# with a cost, it is the leak.
#
# The assertion is on the SHAPE of what PATTERN may contain: a `-dev`/`-mgmt`
# branch must be anchored to a character class, never to a literal name. Reading
# PATTERN through --print-pattern rather than grepping the file keeps this honest
# if the definition ever moves.
# The first check is -F on purpose: as an ERE, `[a-z0-9]+` would match any name a
# literal branch could carry, so a regex form of it would pass on the very
# enumeration it exists to reject. Written in the same spirit as the rule below —
# a comment here is published too, so it argues by shape and names nothing.
pat="$(bash "$GUARD" --print-pattern)"
if printf '%s' "$pat" | grep -qF '\b[a-z0-9]+-(dev|mgmt)\b' \
   && ! printf '%s' "$pat" | grep -qE '\\b[a-z0-9]+-(dev|mgmt)\\b'; then
  ok "the pattern matches box names by shape and spells none of them out"
else
  bad "the pattern names a box literally (or lost its shape branch) — a name here is published to the public mirror and cannot be withdrawn"
  printf '    %s\n' "$pat"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
