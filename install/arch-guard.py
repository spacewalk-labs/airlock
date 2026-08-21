#!/usr/bin/env python3
"""Describe an installer's `case "$(uname -m)"` guard as a decidable shape.

Used by install/test-catalog.sh to tie ARCH_LIMITS in bin/airlock-config back to
the guard it transcribes (apps/orca/install.sh).

Two weaker designs were tried and rejected, both by counterexample:

  * `grep x86_64` — stays green when the guard grows an `arm64)` arm, because the
    string is still in the file.
  * "an arm rejects if its body mentions `die`" — reports the guard
    `x86_64) ;; *) log "..." ;;` as rejecting everything else, when it accepts
    everything else. Whether a shell fragment exits is not decidable by reading
    it, so the oracle must not try.

So this reports SHAPE, not meaning: which patterns have an empty body, and the
first word of each non-empty body. The caller asserts the exact expected string.
Any edit to the guard — a new arm, a changed action, a rewrite this parser cannot
read — changes the output and fails the caller's comparison, which is the point:
the guard is small and rarely touched, so "someone changed it, come look" is the
correct alarm.

Prints `accepted=<patterns with empty bodies>|rejected=<pattern:first-word>...`,
each list comma-separated and sorted, or `NO-GUARD` when the file has no such
case statement.
"""
import re
import sys

if len(sys.argv) != 2:
    print("usage: arch-guard.py <installer.sh>", file=sys.stderr)
    raise SystemExit(2)
try:
    src = open(sys.argv[1], encoding="utf-8").read()
except OSError as e:
    # Fail closed and legibly. A traceback would also fail the caller's string
    # comparison, but it would report a Python error where the real answer is
    # "the installer being pinned is gone".
    print(f"UNREADABLE: {e}", file=sys.stderr)
    raise SystemExit(2)

GUARD = re.compile(r'case\s+"\$\(uname -m\)"\s+in(.*?)\besac\b', re.S)
found = GUARD.findall(src)
if not found:
    print("NO-GUARD")
    raise SystemExit(0)
if len(found) > 1:
    # Reading the FIRST match is only sound while there is exactly one. A second
    # block — inside a heredoc, a dead function, a comment sample — would let the
    # parser describe a decoy while the guard that actually runs says something
    # else. Counting is decidable; deciding which block executes is not.
    print(f"MULTIPLE-GUARDS:{len(found)}")
    raise SystemExit(0)
body = found[0]

ARM = re.compile(r'\A\s*\(?\s*(?P<pat>[^)]*?)\s*\)(?P<body>.*)\Z', re.S)
accepted, rejected = [], []
for chunk in body.split(";;"):
    if not chunk.strip():
        continue
    arm = ARM.match(chunk)
    if arm is None:
        # Unparseable arm: say so rather than dropping it. A silently swallowed
        # arm is how `arm64 ) ;;` slipped past an earlier version of this parser.
        accepted.append("UNPARSEABLE-ARM")
        continue
    pat, body = arm.group("pat"), arm.group("body").split()
    if body:
        rejected.append(f"{pat}:{body[0]}")
    else:
        accepted.append(pat)
print("accepted=" + ",".join(sorted(accepted))
      + "|rejected=" + ",".join(sorted(rejected)))
