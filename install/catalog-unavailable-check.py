#!/usr/bin/env python3
"""Exit 0 iff a catalog on stdin lists exactly `publish` and names the ids in argv
as unavailable.

The scratch trees install/test-catalog.sh builds each have one good app and one
that must not be offered. Both halves matter: the bad app must appear in
`unavailable` (it is not silently gone) AND must not appear in `apps` (it is not
offered as installable).
"""
import json
import sys

try:
    d = json.load(sys.stdin)
except ValueError as e:
    print(f"not JSON: {e}", file=sys.stderr)
    raise SystemExit(2)
expected = sorted(sys.argv[1:])
ok = (d.get("unavailable") == expected
      and [a["id"] for a in d.get("apps", [])] == ["publish"])
if not ok:
    print(f"apps={[a['id'] for a in d.get('apps', [])]} "
          f"unavailable={d.get('unavailable')} expected={expected}", file=sys.stderr)
raise SystemExit(0 if ok else 1)
