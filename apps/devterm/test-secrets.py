#!/usr/bin/env python3
"""Offline contract checks for the devterm secret drop — no HTTP, no box, no network.

Run: python3 apps/devterm/test-secrets.py   (exit 0 = pass)

The whole point of a secret drop is that the value stays put and then goes away, so what
is pinned here is exactly that: where the file lands, what mode it lands with, that a
symlink in the way is refused rather than followed, that the TTL sweep really deletes,
and that the request-facing guards (name shape, cross-origin write) hold.
"""
import importlib.util
import os
import stat
import sys
import tempfile
import time

os.environ.setdefault("AIRLOCK_OWNER", "owner@example.com")
os.environ["DEVTERM_SECRET_TTL"] = "4"          # short, so the sweep is testable
spec = importlib.util.spec_from_file_location("gate", "apps/devterm/backend/devterm-gate.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

fails = []
def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)

tmp = tempfile.mkdtemp(prefix="airlock-secret-test-")
g.SECRETS = os.path.join(tmp, "secrets")

# ---- name shape: this is what keeps a name out of the filesystem ----
ok_names = ["GH_TOKEN", "a", "x.y-z_1", "A" * 48]
# "GH_TOKEN\n" is here because Python's `$` also matches before a trailing newline, so a
# `^...$` pattern accepts one character its character class forbids and lets a {1,N} cap be
# exceeded by one. The app itself never accepted these — every call site is fullmatch — so
# this pair passes either way; the assertion further down tests the pattern, which does not.
bad_names = ["", ".hidden", "../escape", "a/b", "with space", "A" * 49, "naïve", "a\x00b",
             "GH_TOKEN\n", "A" * 48 + "\n"]
check("valid names accepted", all(g._RE_SECRET_NAME.fullmatch(n) for n in ok_names))
check("path escape / dotfile / oversize rejected",
      not any(g._RE_SECRET_NAME.fullmatch(n) for n in bad_names))

# The upload name is the one pattern here that a query string reaches directly.
ok_uploads = ["image001-20260801-120000.jpg"]
bad_uploads = ["image001-20260801-120000.jpg\n", "image1-20260801-120000.jpg", "note.jpg"]
check("upload names accepted", all(g._RE_UPLOAD.match(n) for n in ok_uploads))
check("upload names with a trailing newline rejected",
      not any(g._RE_UPLOAD.match(n) for n in bad_uploads))

# Every _RE_SECRET_NAME call site is fullmatch, so the case above passes with or without
# the anchor — it cannot detect a regression on its own. This asserts the property the
# anchor actually provides: the pattern is safe by itself, not only where someone
# remembered fullmatch. It fails the moment the pattern ends at `$` again.
check("_RE_SECRET_NAME is anchored at end-of-string, not before a trailing newline",
      g._RE_SECRET_NAME.match("GH_TOKEN\n") is None)

# ---- storage: fresh inode, tight modes ----
ok, reason = g._store_secret("GH_TOKEN", b"value\n")
check("store succeeds", ok and reason is None)
f = os.path.join(g.SECRETS, "GH_TOKEN.txt")
check("file lands where the token points", os.path.isfile(f))
check("file is 0600", stat.S_IMODE(os.stat(f).st_mode) == 0o600)
check("directory is 0700", stat.S_IMODE(os.stat(g.SECRETS).st_mode) == 0o700)
check("content is exactly what was written", open(f, "rb").read() == b"value\n")
check("no temp file left behind",
      not any(n.endswith(".tmp") for n in os.listdir(g.SECRETS)))

# rewriting must not widen the mode of an existing file
os.chmod(f, 0o600)
ok, _ = g._store_secret("GH_TOKEN", b"second\n")
check("rewrite keeps 0600", ok and stat.S_IMODE(os.stat(f).st_mode) == 0o600)
check("rewrite replaced the content", open(f, "rb").read() == b"second\n")

# ---- a symlink in the way is refused, never followed ----
victim = os.path.join(tmp, "victim.txt")
open(victim, "w").write("do not touch\n")
link_dir = os.path.join(tmp, "linked-secrets")
os.symlink(tmp, link_dir)
saved = g.SECRETS
g.SECRETS = link_dir
ok, reason = g._store_secret("X", b"v\n")
check("symlinked secret dir refused", (ok, reason) == (False, "io"))
g._sweep_secrets()                                    # must not walk into it either
check("victim outside the store untouched", open(victim).read() == "do not touch\n")
g.SECRETS = saved

# ---- the file limit ----
saved_max = g.SECRET_MAX_FILES
g.SECRET_MAX_FILES = 2
g._store_secret("one", b"1\n"); g._store_secret("two", b"2\n")
ok, reason = g._store_secret("three", b"3\n")
check("limit refuses a NEW secret", (ok, reason) == (False, "limit"))
ok, _ = g._store_secret("one", b"1b\n")
check("limit still allows overwriting an existing one", ok)
g.SECRET_MAX_FILES = saved_max

# ---- the TTL is the safety property: it must actually delete ----
check("remaining time is reported", 0 < g._secret_remain("one") <= g.SECRET_TTL_SEC)
time.sleep(g.SECRET_TTL_SEC + 1)
g._sweep_secrets()
check("expired secrets are gone", os.listdir(g.SECRETS) == [])
g._store_secret("fresh", b"f\n")
g._sweep_secrets()
check("a fresh secret survives the sweep", os.path.isfile(os.path.join(g.SECRETS, "fresh.txt")))

# a stray temp file is swept regardless of age (it was never a live secret)
stray = os.path.join(g.SECRETS, ".stray.123.tmp")
open(stray, "w").write("x")
g._sweep_secrets()
check("stray temp file swept", not os.path.exists(stray))

# an unparseable name is left alone rather than deleted blindly
foreign = os.path.join(g.SECRETS, "not a secret.txt")
open(foreign, "w").write("x")
os.utime(foreign, (0, 0))
g._sweep_secrets()
check("files that are not ours are not deleted", os.path.exists(foreign))

# a missing directory is not an error
g.SECRETS = os.path.join(tmp, "nope")
g._sweep_secrets()
check("absent store sweeps quietly", not os.path.exists(g.SECRETS))
g.SECRETS = saved

# ---- cross-origin WRITE guard (these endpoints mutate; the alert only reads) ----
H = lambda **kw: {k.encode(): v for k, v in kw.items()}
check("no Origin (curl / the terminal) allowed", g._secret_origin_ok({}))
check("same origin allowed",
      g._secret_origin_ok(H(origin=b"https://box.example.ts.net:8443", host=b"box.example.ts.net:8443")))
check("another origin refused",
      not g._secret_origin_ok(H(origin=b"https://evil.example", host=b"box.example.ts.net:8443")))
check("same host, different port refused (a write is not a read)",
      not g._secret_origin_ok(H(origin=b"https://box.example.ts.net:8447", host=b"box.example.ts.net:8443")))
check("garbage origin refused", not g._secret_origin_ok(H(origin=b"::::", host=b"h")))
check("missing Host refused", not g._secret_origin_ok(H(origin=b"https://h", host=b"")))

print(("\nFAILED: " + ", ".join(fails)) if fails else "\nall secret-drop contract checks passed")
sys.exit(1 if fails else 0)
