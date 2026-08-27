"""Locate a user-installed CLI (codex / claude / paseo) from a non-interactive context.

Why this exists: a systemd --user unit and a remote `su - <user> -c` both get a PATH
that has none of the places node CLIs actually land (npm prefix dirs, fnm, nvm, ...),
so `shutil.which()` alone reports "not installed" for a tool that is installed and
working. Probing exactly one hardcoded path is worse: it names an innocent path as
the cause. In the field that produced
`[Errno 2] No such file or directory: '<home>/.npm-global/bin/codex'` on a machine whose
codex lived under fnm.

The candidate order, the trust rules and the not-found contract are fixed by
`bin-discovery-cases.json`, which is vendored next to this file and pinned by a
sha256 assertion in the test suite. Change the behaviour there first.

Self-contained on purpose: stdlib only, no package imports, small enough to inline
into a snippet that is shipped to a box over stdin.
"""

import os
import re
import shutil
import stat
from glob import glob

# Ordered candidate directories. `~` is expanded against the caller's home.
# Ordering rule: operator intent first (override, PATH, shim dir), then
# version-independent aliases, then version dirs newest-first, then system dirs.
_CANDIDATES = (
    ("local_bin", "dir", "~/.local/bin", None),
    ("npm_global", "dir", "~/.npm-global/bin", None),
    ("fnm_alias", "glob", "~/.local/share/fnm/aliases/*/bin", None),
    ("fnm_versions", "glob", "~/.local/share/fnm/node-versions/*/installation/bin", None),
    ("nvm_versions", "glob", "~/.nvm/versions/node/*/bin", None),
    ("volta", "dir", "~/.volta/bin", None),
    ("mise", "dir", "~/.local/share/mise/shims", None),
    ("asdf", "dir", "~/.asdf/shims", None),
    ("bun", "dir", "~/.bun/bin", None),
    ("pnpm", "dir", "~/.local/share/pnpm", None),
    ("claude_versions", "glob_exe", "~/.local/share/claude/versions/*", ("claude",)),
    ("system_local", "dir", "/usr/local/bin", None),
    ("system_usr", "dir", "/usr/bin", None),
    ("snap", "dir", "/snap/bin", None),
)

# [0-9] rather than \d: in a str pattern \d is every Unicode decimal digit, and a
# version directory is ASCII by construction.
_SEMVER = re.compile(r"([0-9]+)(?:\.([0-9]+))?(?:\.([0-9]+))?")


def _semver_key(path):
    """Sort key for a version path. The version segment is not always the last one
    (`~/.nvm/versions/node/v22.9.0/bin`, `.../node-versions/v24.15.0/installation/bin`),
    so take the last version-looking run in the whole path. Non-numeric names sort last."""
    found = _SEMVER.findall(path.rstrip("/"))
    if not found:
        return (0, 0, 0, path)
    major, minor, patch = found[-1]
    return (int(major), int(minor or 0), int(patch or 0), path)


def _trusted(path):
    """Is this real file safe to execute on the caller's behalf?

    Returns (ok, reason). A candidate that fails is dropped *with a reason* — a
    silently skipped candidate is indistinguishable from one that was never there.
    """
    try:
        st = os.stat(path)
        dst = os.stat(os.path.dirname(path) or "/")
    except OSError as e:
        return False, "stat failed: %s" % e.strerror
    if not stat.S_ISREG(st.st_mode):
        return False, "not a regular file"
    if not os.access(path, os.X_OK):
        return False, "not executable"
    uid, gids = os.getuid(), set(os.getgroups()) | {os.getgid()}
    for label, s in (("file", st), ("dir", dst)):
        if s.st_uid not in (uid, 0):
            return False, "%s owned by uid %d" % (label, s.st_uid)
        if s.st_mode & stat.S_IWOTH:
            return False, "%s is world-writable" % label
        # Group-writable is normal here: npm creates its prefix dirs 0775 and the
        # group is the user's own. It is only a hazard when the writing group is
        # somebody else's.
        if s.st_mode & stat.S_IWGRP and s.st_gid not in gids and s.st_gid != 0:
            return False, "%s writable by gid %d" % (label, s.st_gid)
    return True, ""


def _accept(path, rejects):
    """Resolve symlinks and apply the trust rules. Returns the *candidate* path
    (not the resolved one) so the caller keeps the stable name it was found under."""
    if not path:
        return None
    real = os.path.realpath(path)
    ok, reason = _trusted(real)
    if ok:
        return path
    rejects.append("%s (%s)" % (path, reason))
    return None


def find_bin(cmd, home=None, env=None):
    """Return (path_or_None, diagnostics).

    diagnostics = {"searched": <int>, "path": <effective PATH>, "rejected": [str]}
    Never returns a path that was not verified to exist — the caller may exec the
    result directly.
    """
    env = os.environ if env is None else env
    home = home or os.path.expanduser("~")
    rejects = []

    def expand(p):
        return p.replace("~", home, 1) if p.startswith("~") else p

    override = env.get("%s_BIN" % cmd.upper())
    if override:
        # An override that points at nothing is a configuration error, not a cue to
        # go looking elsewhere: silently ignoring it would hide the misconfiguration.
        got = _accept(expand(override), rejects)
        return got, {"searched": 1, "path": env.get("PATH", ""), "rejected": rejects}

    searched = 1
    found = _accept(shutil.which(cmd, path=env.get("PATH")), rejects)
    if found:
        return found, {"searched": searched, "path": env.get("PATH", ""), "rejected": rejects}

    extra = [d for d in (env.get("%s_EXTRA_BIN_DIRS" % cmd.upper()) or "").split(":") if d]
    # extra dirs go LAST: a misconfigured entry must not shadow every standard path.
    for name, kind, spec, only_for in _CANDIDATES + tuple(
            ("extra:%s" % d, "dir", d, None) for d in extra):
        if only_for and cmd not in only_for:
            continue
        spec = expand(spec)
        if kind == "dir":
            hits = [os.path.join(spec, cmd)]
        else:
            matches = sorted(glob(spec), key=_semver_key, reverse=True)
            hits = matches if kind == "glob_exe" else [os.path.join(m, cmd) for m in matches]
        for h in hits:
            searched += 1
            got = _accept(h, rejects)
            if got:
                return got, {"searched": searched, "path": env.get("PATH", ""), "rejected": rejects}
    return None, {"searched": searched, "path": env.get("PATH", ""), "rejected": rejects}


def not_found_message(cmd, diag):
    """The message a user sees. It names what was looked for and where — never a
    single internal path presented as if it were the cause."""
    msg = ("%s not found (not installed, or installed outside the known locations).\n"
           "  searched: PATH(%s) + %d candidate location(s)\n"
           "  fix: install %s on the box, or symlink it into ~/.local/bin/%s"
           % (cmd, diag.get("path") or "<empty>", diag.get("searched", 0), cmd, cmd))
    if diag.get("rejected"):
        msg += "\n  rejected: " + "; ".join(diag["rejected"][:3])
    return msg
