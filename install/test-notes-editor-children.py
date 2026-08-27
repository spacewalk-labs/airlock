#!/usr/bin/env python3
"""Regression test for the Notes editor-child hardening check.

`apps/notes/smoke.sh` live() reads every SilverBullet child of the editor
supervisor out of /proc and asserts each one carries `SB_SHELL_BACKEND=off`,
`SB_RUNTIME_API=0`, and exactly one `SB_URL_PREFIX` per writable vault. That is
the only place the sandbox hardening is checked against the *running* process
rather than against the supervisor's source text — standalone smoke can only
grep `bin/editor-supervisor.py` for the string.

It never ran. The block split a NUL-separated **bytes** buffer with a `str`
separator:

    env=dict(item.split("=",1) for item in ...read_bytes().split(b"\\0") ...)

so every live invocation raised `TypeError: a bytes-like object is required,
not 'str'` inside the generator expression, before the first child was
evaluated. rc was non-zero, the smoke reported `notes smoke: live FAILED`, and
the failure looked like an app fault rather than a check fault. A hardening
check that always crashes and a hardening check that always passes are equally
worthless; this one had been the first kind, which is at least loud, but it was
loud about the wrong thing.

This test extracts that block from smoke.sh **verbatim** and runs it exactly
the way smoke.sh does (`python3 - <pid> <plan.json>` with the body on stdin),
pointed at a fabricated /proc tree via `AIRLOCK_PROC_ROOT`. Extracting rather
than copying is the repo convention (see
`apps/dev-monitor/backend/test_devmon.py::TestSmokeLaneCheckAgainstBackend` and
`install/test-systemd-ordering.sh`): a copy would drift silently, and a check
that drifts is back to proving nothing.

Run: python3 install/test-notes-editor-children.py
"""
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SMOKE = ROOT / "apps" / "notes" / "smoke.sh"
BEGIN = "# EDITOR_CHILDREN_CHECK"
END = "# :EDITOR_CHILDREN_CHECK"

pass_count = 0
fail_count = 0


def ok(name):
    global pass_count
    print(f"ok   {name}")
    pass_count += 1


def bad(name, detail=""):
    global fail_count
    print(f"FAIL {name}{(': ' + detail) if detail else ''}")
    fail_count += 1


def extract_check():
    """Slice the heredoc body out of smoke.sh, between the markers."""
    lines = SMOKE.read_text(encoding="utf-8").splitlines()
    # The begin marker carries a trailing note for whoever reads smoke.sh, so
    # match its prefix; the end marker is exact and cannot collide with it.
    begins = [i for i, line in enumerate(lines) if line.strip().startswith(BEGIN)]
    ends = [i for i, line in enumerate(lines) if line.strip() == END]
    if len(begins) != 1 or len(ends) != 1 or ends[0] < begins[0]:
        sys.exit(
            f"{SMOKE}: expected exactly one {BEGIN} ... {END} pair, "
            f"found {len(begins)} begin / {len(ends)} end. The marker moved or was "
            "dropped — fix the marker rather than deleting this test, which would "
            "otherwise silently check an empty string."
        )
    body = lines[begins[0] + 1:ends[0]]
    starts = [i for i, line in enumerate(body) if "<<'PY'" in line]
    stops = [i for i, line in enumerate(body) if line.strip() == "PY"]
    if not starts or not stops:
        sys.exit(f"{SMOKE}: no python heredoc between the markers")
    source = "\n".join(body[starts[0] + 1:stops[0]]) + "\n"
    # Positive control on the extraction itself. If the slice is empty or the
    # wrong fragment, every assertion below would pass vacuously.
    for token in ("SB_SHELL_BACKEND", "SB_RUNTIME_API", "SB_URL_PREFIX",
                  "AIRLOCK_PROC_ROOT", "read_bytes"):
        if token not in source:
            sys.exit(f"{SMOKE}: extracted block is missing {token!r} — extraction is wrong")
    return source


def write_environ(path, prefix, backend="off", runtime="0"):
    """Write /proc/<pid>/environ the way the kernel does: NUL-separated bytes.

    The trailing `LS_COLORS` entry carries '=' inside its *value* on purpose, so
    a regression that drops the maxsplit argument fails here too.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = [
        f"SB_SHELL_BACKEND={backend}".encode(),
        f"SB_RUNTIME_API={runtime}".encode(),
        f"SB_URL_PREFIX={prefix}".encode(),
        b"LS_COLORS=di=1;34:ln=36",
        b"",  # kernel leaves a trailing NUL; the parser must skip the empty tail
    ]
    path.write_bytes(b"\0".join(fields))


def build_proc(root, children):
    """children: {pid: (prefix, backend, runtime)}"""
    task = root / "100" / "task" / "100"
    task.mkdir(parents=True, exist_ok=True)
    (task / "children").write_text(" ".join(children) + "\n" if children else "\n")
    for pid, (prefix, backend, runtime) in children.items():
        write_environ(root / pid / "environ", prefix, backend, runtime)


def build_plan(path, writable=("/notes/editor/main/", "/notes/editor/work/")):
    vaults = [{"id": f"v{i}", "writable": True, "editor_path": p}
              for i, p in enumerate(writable)]
    # A read-only vault must NOT be expected to have a child.
    vaults.append({"id": "ro", "writable": False, "editor_path": "/notes/editor/ro/"})
    path.write_text(json.dumps({"vaults": vaults}), encoding="utf-8")


def run_check(source, proc_root, plan):
    return subprocess.run(
        [sys.executable, "-", "100", str(plan)],
        input=source, capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "AIRLOCK_PROC_ROOT": str(proc_root)},
    )


def main():
    source = extract_check()
    ok("extracted the check from smoke.sh (markers and tokens present)")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        plan = tmp / "plan.json"
        build_plan(plan)
        healthy = {
            "201": ("/notes/editor/main", "off", "0"),
            "202": ("/notes/editor/work", "off", "0"),
        }

        # --- green -------------------------------------------------------
        proc = tmp / "proc-ok"
        build_proc(proc, healthy)
        r = run_check(source, proc, plan)
        if r.returncode == 0:
            ok("hardened children accepted (rc=0)")
        else:
            bad("hardened children accepted", f"rc={r.returncode} stderr={r.stderr.strip()!r}")

        # This is the specific regression. Before the fix the run above exited
        # non-zero with a TypeError, so assert the *reason* is gone, not just rc.
        if "TypeError" in r.stderr or "bytes-like object" in r.stderr:
            bad("no bytes/str TypeError", r.stderr.strip())
        else:
            ok("no bytes/str TypeError on a well-formed environ")

        # --- red, three ways. Each asserts the reason, not just rc, because a
        # check that dies for the wrong reason also exits non-zero. -------
        cases = [
            (
                "shell backend left on",
                {**healthy, "201": ("/notes/editor/main", "on", "0")},
                "SB_SHELL_BACKEND='on' want 'off'",
            ),
            (
                "runtime API re-enabled",
                {**healthy, "202": ("/notes/editor/work", "off", "1")},
                "SB_RUNTIME_API='1' want '0'",
            ),
            (
                "a writable vault has no editor child",
                {"201": ("/notes/editor/main", "off", "0")},
                "!= writable vaults ['/notes/editor/main', '/notes/editor/work']",
            ),
        ]
        for name, children, want in cases:
            proc = tmp / ("proc-" + name.replace(" ", "-"))
            build_proc(proc, children)
            r = run_check(source, proc, plan)
            if r.returncode == 0:
                bad(f"rejects {name}", "check passed a child it must reject")
            elif "TypeError" in r.stderr:
                bad(f"rejects {name}", f"failed for the wrong reason: {r.stderr.strip()!r}")
            elif want not in r.stderr:
                bad(f"rejects {name}", f"reason {want!r} not in {r.stderr.strip()!r}")
            else:
                ok(f"rejects {name} — and names it")

        # --- the read-only vault must not be demanded a child -------------
        proc = tmp / "proc-ro"
        build_proc(proc, healthy)
        r = run_check(source, proc, plan)
        if r.returncode == 0 and "/notes/editor/ro" not in r.stderr:
            ok("read-only vault is not expected to have an editor child")
        else:
            bad("read-only vault ignored", r.stderr.strip())

    print(f"\n{pass_count} passed, {fail_count} failed")
    return 1 if fail_count else 0


if __name__ == "__main__":
    sys.exit(main())
