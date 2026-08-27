#!/usr/bin/env python3
"""Conformance test for bin_discovery.find_bin against the shared case corpus.

Vendored verbatim alongside `bin_discovery.py` and `bin-discovery-cases.json`.
The sha256 assertion is the anti-drift device: three repos carry three copies of
the implementation, so if one of them edits the corpus to match a local change,
the other two turn red instead of quietly diverging.

Run: python3 test_bin_discovery.py
"""

import hashlib
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bin_discovery  # noqa: E402

CORPUS = os.path.join(HERE, "bin-discovery-cases.json")

# Pin of bin-discovery-cases.json. Changing the contract means changing this in
# every repo that vendors it, in the same change. That is the point.
CORPUS_SHA256 = "07ddd840ce912a6b5e842740f56bb756b512c36ea4faedf3786e58007cdcd06b"


def _mkdirs(path, home):
    """makedirs, but pin every directory we create to 0755 — the fixture must not
    inherit the runner's umask, or the trust rules fire on the fixture itself."""
    os.makedirs(path, exist_ok=True)
    p = path
    while len(p) > len(home):
        os.chmod(p, 0o755)
        p = os.path.dirname(p)


def _mk(tree_path, kind, home):
    path = tree_path.replace("~", home, 1)
    _mkdirs(os.path.dirname(path.rstrip("/")) or "/", home)
    if kind.startswith("dir"):
        _mkdirs(path, home)
        if ":" in kind:
            os.chmod(path, int(kind.split(":")[1], 8))
        return
    if kind.startswith("symlink:"):
        target = kind.split(":", 1)[1].replace("~", home, 1)
        if os.path.lexists(path):
            os.remove(path)
        os.symlink(target, path)
        return
    with open(path, "w") as f:
        f.write("#!/bin/sh\nexit 0\n")
    if kind.startswith("exe"):
        os.chmod(path, int(kind.split(":")[1], 8) if ":" in kind else 0o755)
    else:
        os.chmod(path, 0o644)


def run_case(case):
    with tempfile.TemporaryDirectory() as home:
        # symlinks must be created after their targets exist
        items = sorted(case.get("tree", {}).items(),
                       key=lambda kv: kv[1].startswith("symlink:"))
        for p, kind in items:
            _mk(p, kind, home)
        env = {"PATH": ":".join(d.replace("~", home, 1) for d in case.get("path_dirs", []))}
        for k, v in (case.get("env") or {}).items():
            env[k] = v.replace("~", home, 1)
        if case.get("extra_dirs"):
            env["%s_EXTRA_BIN_DIRS" % case["cmd"].upper()] = ":".join(
                d.replace("~", home, 1) for d in case["extra_dirs"])
        got, diag = bin_discovery.find_bin(case["cmd"], home=home, env=env)
        want = case["expect"]
        want = want.replace("~", home, 1) if want else None
        if got != want:
            return "want %r, got %r (searched=%s rejected=%s)" % (
                want, got, diag["searched"], diag["rejected"])
        if want is None:
            msg = bin_discovery.not_found_message(case["cmd"], diag)
            for must in (case["cmd"], "searched", "PATH("):
                if must not in msg:
                    return "not-found message missing %r: %s" % (must, msg)
        return None


def check_candidate_order(corpus):
    """The cases alone do not pin the candidate list: an implementation can delete
    every manager it has no case for and still go green. So compare the declared
    order in the corpus against what the implementation actually walks."""
    special = {"env", "which", "env_pathlist"}   # not part of the walked table
    want = [(c["id"], c["kind"], c.get("spec"), tuple(c.get("only_for") or ()) or None)
            for c in corpus["candidate_order"] if c["kind"] not in special]
    got = [(n, k, s, o) for n, k, s, o in bin_discovery._CANDIDATES]
    if got == want:
        return None
    extra = [c for c in got if c not in want]
    missing = [c for c in want if c not in got]
    if not extra and not missing:
        return "candidate order differs: declared %r, implemented %r" % (
            [c[0] for c in want], [c[0] for c in got])
    return "candidate table drifted — missing %r, unexpected %r" % (
        [c[0] for c in missing], [c[0] for c in extra])


def main():
    raw = open(CORPUS, "rb").read()
    digest = hashlib.sha256(raw).hexdigest()
    corpus = json.loads(raw)
    failures = []
    err = check_candidate_order(corpus)
    print("%s %-34s %s" % ("ok  " if err is None else "FAIL", "candidate-order-matches-corpus",
                           err or "the walked table is exactly what the contract declares"))
    if err:
        failures.append("candidate-order: %s" % err)
    if CORPUS_SHA256 != "REPLACE_ME" and digest != CORPUS_SHA256:
        failures.append("corpus sha256 %s != pinned %s — the shared contract moved; "
                        "sync every repo that vendors it" % (digest, CORPUS_SHA256))
    for case in corpus["cases"]:
        err = run_case(case)
        status = "ok  " if err is None else "FAIL"
        print("%s %-34s %s" % (status, case["id"], err or case["why"]))
        if err:
            failures.append("%s: %s" % (case["id"], err))
    print("\ncorpus sha256: %s" % digest)
    print("%d case(s), %d failure(s)" % (len(corpus["cases"]), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
