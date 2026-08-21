#!/usr/bin/env bash
# install/check-internal-leaks.sh — the internal/site-specific string scan.
#
# This repository is mirrored to a public one. Anything naming an internal host,
# tailnet, domain, org or repository has to be gone before it leaves. The scan
# itself has lived in .github/workflows/ci.yml since the beginning and is unchanged
# here; what moved is WHERE it lives, and that move has a reason:
#
#   2026-08-07 — a task document naming an internal repository six times was
#   committed after a local leak scan reported clean. The local scan was the
#   publish-sync one, which reads `git archive origin/main`, so a file that was
#   written but not yet on main was invisible to it. CI caught it. That is the
#   right order of events for a gate, but the wrong order for a person: the check
#   that could have been run before the commit was not the same check.
#
# So there is now exactly one implementation, and both callers use it:
#
#   bash install/check-internal-leaks.sh            the working tree, tracked and
#                                                   untracked (what CI runs, and
#                                                   what to run before committing)
#   bash install/check-internal-leaks.sh --dir DIR  a plain exported tree, for the
#                                                   publish-sync path
#   bash install/check-internal-leaks.sh --print-pattern
#   bash install/check-internal-leaks.sh --print-allow
#
# `--untracked` matters and is not a convenience: in CI nothing is untracked, so it
# changes nothing there, and locally it is the entire difference between scanning
# what you are about to commit and scanning what you committed last time.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# The internal prefix is matched as a prefix, and the box names by SHAPE, not as
# the list of hostnames that happened to carry it. An enumeration only catches the
# leaks someone already thought of: three comments naming an internal unit name
# walked through the enumerated version of this pattern and were caught by a human
# instead, and the `-mgmt` boxes were never in the list at all.
#
# The enumeration was also its own leak. This file is mirrored to the public
# repository, so every name spelled out here is published by the guard that exists
# to stop exactly that — and it already happened: the inline copy this pattern
# lived in before 2026-08-07 named four internal repositories, and 15 of the
# public mirror's 24 commits still carry that line. Public history does not come
# back. So do not add a name here. A name no shape can express belongs in the
# publish-sync scan, which is never mirrored.
#
# The separator is a class, not a hyphen: `swk:airlock-btn-pos-v1` was a
# published localStorage key that the hyphen-only version of this pattern did
# not see, so the prefix scan missed a name it existed to catch.
PATTERN='spacewalk|sparrow-spectrum|\b[a-z0-9]+-(dev|mgmt)\b|TeamSPWK|swk[-:_.]|\bmacmini-[0-9]+\b|@spacewalk\.tech|doc\.spacewalk\.dev'

# The allowlist holds two kinds of string, and they leave for different reasons.
#
# (a) Four frontend identifiers that carry the prefix and are already in the
#     public mirror. The rename landed (owner decision, 2026-08-06): the widget
#     emits the `airlock-` spellings and these survive only as INPUT it still
#     accepts. That overlap ends on 2026-09-07 (owner decision, 2026-08-07 —
#     "one release" pointed at nothing, this repo has no tags). Deleting the
#     legacy branches in hub/assets/airlock-return.js and
#     apps/devterm/web/panel.html makes all four stale, and the check below
#     fails on a stale entry, so the cleanup cannot be half-done.
# (b) Two strings this project deliberately publishes: the public org slug and
#     the security contact in SECURITY.md. They are not leaks, they are the
#     repository's own public identity — the pattern catches them only because
#     the company name and the public org share a word. These do not expire.
#
# (c) One name of ours the SHAPE pattern cannot tell from a box: `airlock-dev`,
#     this project's own app name. It is not a host. `airlock-devterm` needs no
#     entry — `\bdev\b` does not fire inside it.
#
# Do not grow either group casually: (a) is closed, and (b) needs an owner
# decision, because it is the one place a real internal string could hide.
ALLOW='swk-airlock-return|swk-airlock-slot|swk-panel-close|swk:airlock-btn-pos-v1|spacewalk-labs|cho@spacewalk\.tech|airlock-dev'
ALLOW_LIST=(swk-airlock-return swk-airlock-slot swk-panel-close swk:airlock-btn-pos-v1
            spacewalk-labs cho@spacewalk.tech airlock-dev)

# This file necessarily names every pattern, so it excludes itself — the same
# carve-out ci.yml used to need for holding them.
SELF='install/check-internal-leaks.sh'

# The upstream bundle we do not write. Its minified strings coin tokens like
# `1.104.0-dev` and `--save-dev`, which no shape can tell from a host name. An
# ALLOW entry would be worse than an exclusion here: those strings are tied to a
# build hash, so the next rebuild would make the entry stale and turn the
# stale-allowlist check red for a reason nobody could act on. The publish-sync
# scan already skips this path, so skipping it here keeps one rule with one
# implementation.
VENDOR='apps/orca/web-bundle/'

mode=tree
dir=""
case "${1:-}" in
  --print-pattern) printf '%s\n' "$PATTERN"; exit 0 ;;
  --print-allow)   printf '%s\n' "$ALLOW";   exit 0 ;;
  --dir) mode=dir; dir="${2:?--dir needs a path}" ;;
  "") ;;
  *) echo "usage: $0 [--dir DIR | --print-pattern | --print-allow]" >&2; exit 2 ;;
esac

scan() {   # emit matching "path:line:text" for the whole scanned tree
  if [ "$mode" = dir ]; then
    grep -rnEI "$PATTERN" "$dir" 2>/dev/null | grep -vE "/($SELF:|$VENDOR)"
  else
    git -C "$ROOT" grep --untracked -nEI "$PATTERN" -- . ":(exclude)$SELF" ":(exclude)$VENDOR*"
  fi
}
contains() {   # is this exact string present anywhere in the scanned tree?
  if [ "$mode" = dir ]; then
    grep -rqF -- "$1" "$dir" 2>/dev/null
  else
    git -C "$ROOT" grep --untracked -qF -- "$1" -- . ":(exclude)$SELF"
  fi
}

# Strip the permitted tokens and re-match, rather than dropping whole lines:
# a line is excused for the token it carries, not for anything sharing it.
hits=$(scan | sed -E "s/($ALLOW)//g" | grep -E "$PATTERN" || true)
if [ -n "$hits" ]; then
  printf '%s\n' "$hits"
  echo "::error::Internal/site-specific string found — scrub before commit."
  exit 1
fi

# An exception that outlives the string it excuses is a hole nobody is watching.
for s in "${ALLOW_LIST[@]}"; do
  contains "$s" \
    || { echo "::error::stale allowlist entry: $s no longer appears — remove it"; exit 1; }
done

echo "clean: no internal identifiers found"
