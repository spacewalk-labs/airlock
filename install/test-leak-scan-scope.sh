#!/usr/bin/env bash
# install/test-leak-scan-scope.sh — the two modes of the name scan must agree.
#
# They have now drifted apart twice in one day, both times silently, both times found by
# something other than a test:
#
#   - --dir walked .git/, which the tree mode cannot see. The post-release check pointed
#     it at a clone and reported six leaks that were never published.
#   - --dir ignored the public/private boundary the tree mode had just learned. The
#     pre-push hook caught it, minutes after the tree half shipped.
#
# CI only ever ran the tree mode, so neither was going to be caught here. This file runs
# both, over the same tree, and asserts they say the same thing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$ROOT/install/check-internal-leaks.sh"
MANIFEST="$ROOT/install/public-manifest.sh"
pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

export_tree() { local d; d=$(mktemp -d); git -C "$ROOT" archive HEAD | tar -x -C "$d"; printf '%s' "$d"; }

# Assembled at run time, never written out whole. A control that plants a real internal
# string has to hold one, and this file is public — spelling it here would make the suite
# the leak it is testing for. `swk` alone matches nothing; the separator is what arms it.
sep='-'
PROBE="swk${sep}planted"


# A public path to plant strings in, and a private one, both taken from the manifest so
# this cannot drift from the boundary it is checking.
PUB=$(bash "$MANIFEST" --print-public  | grep -m1 '/$')
PRIV=$(bash "$MANIFEST" --print-private | grep -m1 '/$')

d=$(export_tree)
if bash "$SCAN" --dir "$d" >/dev/null 2>&1; then
  ok "--dir is clean on an untouched export, like the tree mode"
else
  bad "--dir reports leaks on a clean export:"; bash "$SCAN" --dir "$d" 2>&1 | sed 's/^/    /' | head -5
fi

# Positive control. Without this the two assertions below pass on a scan that finds
# nothing ever.
mkdir -p "$d/$PUB"; printf '%s\n' "$PROBE" > "$d/${PUB}planted.md"
if ! bash "$SCAN" --dir "$d" >/dev/null 2>&1; then
  ok "--dir still catches an internal string on a public path"
else
  bad "--dir missed a planted internal string under $PUB — the scan is not measuring anything"
fi
rm -f "$d/${PUB}planted.md"

# The boundary. A private path may hold an internal name; that is the whole point of it
# being private, and forcing redaction there is what the rescope was meant to end.
mkdir -p "$d/$PRIV"; printf '%s\n' "$PROBE" > "$d/${PRIV}planted.md"
if bash "$SCAN" --dir "$d" >/dev/null 2>&1; then
  ok "--dir ignores an internal string on a private path"
else
  bad "--dir flagged $PRIV, which never publishes"; bash "$SCAN" --dir "$d" 2>&1 | sed 's/^/    /' | head -3
fi
rm -rf "$d"

# .git/ is not the tree. A clone carries hooks this box installed; they are not shipped.
d=$(export_tree); git -C "$d" init -q
mkdir -p "$d/.git/hooks"; printf '# %s shim\n' "$PROBE" > "$d/.git/hooks/pre-commit"
if bash "$SCAN" --dir "$d" >/dev/null 2>&1; then
  ok "--dir does not read .git/, which the tree mode cannot see either"
else
  bad "--dir read .git/ and called it a leak"
fi
rm -rf "$d"

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
