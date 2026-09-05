#!/usr/bin/env python3
"""devterm hands fileview only what fileview can open.

Clicking a path in the terminal asks the gate to turn it into a /fileview/?path=
URL. fileview serves the home directory of the account it runs as and nothing above
it (filebrowser --root %h, 2026-09-04), so a path the terminal can perfectly well
name — /etc/nginx/nginx.conf, another account's home, a worktree elsewhere on the
disk — is not openable. The gate has to refuse those, and refuse them as
"outside_home" rather than "not found": the path is right, it is simply not in the
tree, and sending somebody to hunt for a typo is the wrong answer.

Run: python3 apps/devterm/test-fileview-scope.py
"""
import asyncio, importlib.util, os, sys, tempfile

os.environ.setdefault("AIRLOCK_OWNER", "owner@example.com")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))

TMP = tempfile.mkdtemp(prefix="devterm-fileview-scope-")
HOME = os.path.join(TMP, "home")
os.makedirs(os.path.join(HOME, "repo"))
INSIDE = os.path.join(HOME, "repo", "notes.md")
open(INSIDE, "w").write("inside\n")
OUTSIDE = os.path.join(TMP, "outside.md")
open(OUTSIDE, "w").write("outside\n")
os.makedirs(os.path.join(TMP, "otherhome", "repo"))
SIBLING = os.path.join(TMP, "otherhome", "repo", "notes.md")
open(SIBLING, "w").write("sibling\n")
# A symlink INSIDE home that points out of it. The path a user clicks may be the
# link; what decides is where it lands.
LINK = os.path.join(HOME, "link.md")
os.symlink(OUTSIDE, LINK)

# HOME has to be the fixture home before the module is imported: the gate resolves
# fileview's scope once, at import, the same way the service resolves it once at
# start. DEVTERM_FILEVIEW enables the feature the resolver serves.
os.environ["HOME"] = HOME
os.environ["DEVTERM_FILEVIEW"] = "true"
spec = importlib.util.spec_from_file_location(
    "gate", os.path.join(ROOT, "apps/devterm/backend/devterm-gate.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

def resolve(path):
    return asyncio.run(g._resolve_to_fileview(path, ""))


fails, checks = [], 0


def check(name, cond):
    global checks
    checks += 1
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


check("the gate resolved fileview's scope to this home",
      g.FILEVIEW_HOME == os.path.realpath(HOME))

# --- positive control: the ordinary case still resolves ---------------------
r = resolve(INSIDE)
check("control: a file inside home resolves to a fileview URL",
      r.get("ok") and r.get("rel") == INSIDE and r.get("url", "").startswith("/fileview/?path="))
check("control: the URL carries the absolute path, encoded",
      "%2F" in r.get("url", "") or "%2f" in r.get("url", ""))

# --- the refusals -----------------------------------------------------------
for label, path in [
    ("a file above home", OUTSIDE),
    ("another account's home", SIBLING),
    ("a system file", "/etc/hostname"),
]:
    r = resolve(path)
    check("refused: " + label, not r.get("ok"))
    check("refused as outside_home, not notfound: " + label,
          r.get("reason") == "outside_home" and r.get("home") == os.path.realpath(HOME))

# A symlink inside home that leaves it is judged by where it lands — the server
# refuses it too (--followExternalSymlinks=false), so a link would be a dead end.
r = resolve(LINK)
check("refused: a symlink inside home pointing out of it", not r.get("ok"))

# _map_to_viewer is the funnel the search fallback uses as well, so it is asserted
# directly: everything above home maps to nothing.
check("_map_to_viewer: inside home maps to itself", g._map_to_viewer(INSIDE) == INSIDE)
check("_map_to_viewer: above home maps to None", g._map_to_viewer(OUTSIDE) is None)
check("_map_to_viewer: /etc/hostname maps to None", g._map_to_viewer("/etc/hostname") is None)
check("_map_to_viewer: a directory maps to None", g._map_to_viewer(HOME) is None)

# --- control: the check can go red -----------------------------------------
# Point the scope one level up and the same refusals must turn into successes.
saved = g.FILEVIEW_HOME
g.FILEVIEW_HOME = os.path.realpath(TMP)
check("control: with the scope one level up, the outside file DOES map",
      g._map_to_viewer(OUTSIDE) == OUTSIDE)
g.FILEVIEW_HOME = saved
check("control: the scope is back", g._map_to_viewer(OUTSIDE) is None)

print("---")
print("checks=%d failed=%d" % (checks, len(fails)))
sys.exit(1 if fails else 0)
