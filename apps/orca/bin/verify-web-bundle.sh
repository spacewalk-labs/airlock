#!/usr/bin/env bash
# Verify the vendored Orca web client (apps/orca/web-bundle/dist) against its provenance
# pin (web-bundle/VERSION).
#
# Why this exists: dist/ is a 22MB build of ~385 files. A partial copy, a truncated clone
# or a stray edit produces a client that serves 200s and then renders a blank page — the
# worst failure shape, because everything looks installed. install.sh runs this before it
# serves the bundle, so that becomes a loud install failure instead.
#
# What it does NOT do: rebuild. Re-deriving the client needs the upstream source and its
# toolchain, which this repo deliberately does not vendor (see web-bundle/README.md). This
# checks that what is here is what VERSION says is here.
#
#   verify-web-bundle.sh [--quiet]      exit 0 = matches the pin, 1 = does not
set -euo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
say() { [ "$QUIET" = 1 ] || printf '[orca-bundle] %s\n' "$*" >&2; }
fail() { printf '[orca-bundle] MISMATCH: %s\n' "$*" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "$HERE/.." && pwd)/web-bundle"
DIST="$BUNDLE/dist"
PIN="$BUNDLE/VERSION"

[ -f "$PIN" ]  || fail "no VERSION pin at $PIN"
[ -d "$DIST" ] || fail "no dist/ at $DIST"

pin() { sed -n "s/^$1: *//p" "$PIN" | head -1; }
want_idx="$(pin web-index-asset)"
want_n="$(pin dist-file-count)"
want_sha="$(pin dist-tree-sha256)"
[ -n "$want_idx" ] && [ -n "$want_n" ] && [ -n "$want_sha" ] || fail "VERSION is missing fields"

[ -f "$DIST/web-index.html" ] || fail "dist/web-index.html absent"
# The entry asset is the one file whose absence turns into a blank page rather than a 404
# the operator would notice.
[ -f "$DIST/$want_idx" ] || fail "entry asset $want_idx absent (stale pin, or a partial copy)"
grep -q "$want_idx" "$DIST/web-index.html" || fail "web-index.html does not reference $want_idx"

got_n="$(find "$DIST" -type f | wc -l | tr -d ' ')"
[ "$got_n" = "$want_n" ] || fail "file count $got_n != $want_n (pinned)"

# Hash the tree, not the files individually: this catches a changed file, a missing file
# and an extra file with one number. Sorted under LC_ALL=C so it is platform-stable.
got_sha="$(cd "$DIST" && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)"
[ "$got_sha" = "$want_sha" ] || fail "tree sha256 $got_sha != $want_sha (pinned)"

say "dist matches VERSION ($want_n files, entry $want_idx)"
