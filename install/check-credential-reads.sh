#!/usr/bin/env bash
# install/check-credential-reads.sh — apps do not open box credential files.
#
# This gate is P3's standing ownership boundary: packages consume provider state
# through platform CLIs handed in by the D5 ABI, rather than opening account files.
# There are no package allowances: even the read-only generation used to keep Codex
# usage caches account-correct comes from the platform CLI. The platform owns every
# credential read and write, including re-login backup and restore.
#
# Apps own surfaces; the platform owns the account pool and the reading of live
# provider credentials. A package that opens one of these files has silently
# recreated the cross-package contract that bin/airlock-accounts is meant to
# replace:
#
#   ~/.claude-accounts               .claude/.credentials.json
#   .claude.json                     .codex/auth.json
#   .grok/auth.json                  opencode/auth.json
#
# Usage:
#   bash install/check-credential-reads.sh            scan $ROOT/apps
#   bash install/check-credential-reads.sh --dir DIR  scan an arbitrary package tree
#                                                    (fixtures or the apps repository)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

SCAN="$ROOT/apps"
SCAN_IS_DEFAULT=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) [ "$#" -ge 2 ] || { echo "--dir requires a path" >&2; exit 2; }
           SCAN="$2"; SCAN_IS_DEFAULT=0; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$SCAN" ] || { echo "not a directory: $SCAN" >&2; exit 2; }

# Python is intentional here. check-app-abi.sh is shell-only because the D5 ABI
# is consumed by installers, but both credential readers this gate was created
# for are Python. Parsing Python also lets the scan ignore comments/docstrings
# without pretending that `#` inside a string starts a comment, and lets it see
# the real dev-monitor spelling: os.path.join(base, '.credentials.json') where
# `base` was assembled from '.claude' on the preceding line.
python3 - "$SCAN" "$SCAN_IS_DEFAULT" <<'PY'
import ast
import itertools
import os
import posixpath
import re
import sys

scan = os.path.abspath(sys.argv[1])
scan_is_default = sys.argv[2] == "1"

FORBIDDEN = (
    ".claude-accounts",
    ".claude/.credentials.json",
    ".claude.json",
    ".codex/auth.json",
    ".grok/auth.json",
    "opencode/auth.json",
)

SKIP_DIRS = {".git", "__pycache__", "node_modules", "patches", "web-bundle"}
# Both direct interpreters (`#!/bin/bash`) and env dispatch
# (`#!/usr/bin/env bash`) ship in apps/. The separator immediately before the
# shell name can therefore be a slash OR whitespace.
SHELL_FIRST = re.compile(r"^#!.*(?:/|\s)(?:ba|da|k|z)?sh(?:\s|$)")
SHELL_HIT = re.compile(
    r"\.claude-accounts|\.claude/\.credentials\.json|\.claude\.json|"
    r"\.codex/auth\.json|\.grok/auth\.json|opencode/auth\.json"
)


def source_kind(path):
    if path.endswith(".py"):
        return "python"
    if path.endswith(".sh"):
        return "shell"
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as src:
            first = src.readline()
    except OSError:
        return None
    if first.startswith("#!") and "python" in first:
        return "python"
    if SHELL_FIRST.search(first):
        return "shell"
    return None


def forbidden_in(value):
    # A leading ~/ or /home/name/ is immaterial: every forbidden spelling is a
    # stable suffix/subpath and is therefore matched inside an absolute path too.
    value = posixpath.normpath(value.replace("\\", "/"))
    return [shape for shape in FORBIDDEN if shape in value]


def combine(parts, sep):
    if not parts or any(not p for p in parts):
        return set()
    out = set()
    for values in itertools.product(*parts):
        candidate = values[0]
        for value in values[1:]:
            if sep == "/":
                candidate = candidate.rstrip("/") + "/" + value.lstrip("/")
            else:
                candidate += value
        out.add(candidate)
        # Static alternatives are deliberately capped. Credential paths have at
        # most a handful; an accidental combinatorial expression should not turn
        # a repository gate into an unbounded evaluator.
        if len(out) >= 64:
            break
    return out


def values(node, env):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return {node.value}
    if isinstance(node, ast.Name):
        # Keep an opaque prefix instead of dropping an unknown runtime value.
        # `$HOME/.claude/...` is still the forbidden path when HOME itself is
        # unknowable statically; only the stable credential suffix matters.
        return env.get(node.id, {"<runtime>"})
    if isinstance(node, ast.IfExp):
        return values(node.body, env) | values(node.orelse, env)
    if isinstance(node, ast.BoolOp):
        out = set()
        for item in node.values:
            out |= values(item, env)
        return out
    if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Add, ast.Div)):
        sep = "/" if isinstance(node.op, ast.Div) else ""
        return combine([values(node.left, env), values(node.right, env)], sep)
    if isinstance(node, (ast.Tuple, ast.List, ast.Set)):
        out = set()
        for item in node.elts:
            out |= values(item, env)
        return out
    if isinstance(node, ast.Call):
        name = ""
        if isinstance(node.func, ast.Name):
            name = node.func.id
        elif isinstance(node.func, ast.Attribute):
            name = node.func.attr
        if name in {"join", "joinpath"}:
            return combine([values(arg, env) for arg in node.args], "/")
        if name == "Path" and node.args:
            # pathlib accepts several components: Path(home, ".codex",
            # "auth.json") is the same direct reference as home / ... .
            return combine([values(arg, env) for arg in node.args], "/")
        if name in {"expanduser", "str"} and node.args:
            return values(node.args[0], env)
        return {"<runtime>"}
    return set()


def first_python_hit(path):
    try:
        with open(path, "r", encoding="utf-8") as src:
            tree = ast.parse(src.read(), filename=path)
    except (OSError, UnicodeError, SyntaxError) as exc:
        raise RuntimeError("cannot parse %s: %s" % (path, exc))

    hits = []

    def inspect_expr(node, env):
        found = set()
        for value in values(node, env):
            found.update(forbidden_in(value))
        if found:
            hits.append((getattr(node, "lineno", 1), sorted(found)))

    def block(statements, inherited=None):
        env = dict(inherited or {})
        for index, stmt in enumerate(statements):
            # A docstring describes a path; it does not read one. Comments are
            # absent from the AST already. Only the leading string expression in
            # a module/class/function is a docstring.
            if (index == 0 and isinstance(stmt, ast.Expr)
                    and isinstance(stmt.value, ast.Constant)
                    and isinstance(stmt.value.value, str)):
                continue
            if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
                for default in list(stmt.args.defaults) + [d for d in stmt.args.kw_defaults if d]:
                    inspect_expr(default, env)
                # Module/class constants are lexical inputs to a function too.
                # Dropping them here lets `CLAUDE_DIR = ".claude"` plus a leaf
                # inside the function evade a path assembled in one scope.
                block(stmt.body, env)
                continue
            if isinstance(stmt, ast.ClassDef):
                block(stmt.body, env)
                continue
            if isinstance(stmt, (ast.Assign, ast.AnnAssign, ast.NamedExpr)):
                value_node = stmt.value
                inspect_expr(value_node, env)
                resolved = values(value_node, env)
                targets = stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
                for target in targets:
                    if isinstance(target, ast.Name):
                        env[target.id] = resolved
                continue
            if isinstance(stmt, (ast.If, ast.For, ast.AsyncFor, ast.While,
                                 ast.With, ast.AsyncWith, ast.Try)):
                # Inspect condition/iterator/context expressions with the current
                # bindings, then follow every block. This is a scan, not execution:
                # a dormant branch can still become the credential reader later.
                for field in ("test", "iter"):
                    expr = getattr(stmt, field, None)
                    if expr is not None:
                        inspect_expr(expr, env)
                for item in getattr(stmt, "items", []):
                    inspect_expr(item.context_expr, env)
                for child in (getattr(stmt, "body", []), getattr(stmt, "orelse", []),
                              getattr(stmt, "finalbody", [])):
                    block(child, env)
                for handler in getattr(stmt, "handlers", []):
                    block(handler.body, env)
                continue
            for node in ast.walk(stmt):
                if isinstance(node, ast.expr):
                    inspect_expr(node, env)

    block(tree.body)
    return min(hits, default=None, key=lambda hit: hit[0])


def first_shell_hit(path):
    logical = ""
    start = 0
    with open(path, "r", encoding="utf-8", errors="replace") as src:
        for lineno, raw in enumerate(src, 1):
            if not logical and re.match(r"^\s*#", raw):
                continue
            if not logical:
                start = lineno
            logical += raw.rstrip("\n")
            if logical.endswith("\\"):
                logical = logical[:-1]
                continue
            normalized = logical.replace('"', "").replace("'", "")
            normalized = re.sub(r"/+", "/", normalized).replace("/./", "/")
            match = SHELL_HIT.search(normalized)
            if match:
                return start, forbidden_in(match.group(0))
            logical = ""
    if logical:
        normalized = logical.replace('"', "").replace("'", "")
        normalized = re.sub(r"/+", "/", normalized).replace("/./", "/")
        match = SHELL_HIT.search(normalized)
        if match:
            return start, forbidden_in(match.group(0))
    return None


files = []
for base, dirs, names in os.walk(scan):
    dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
    for name in sorted(names):
        path = os.path.join(base, name)
        kind = source_kind(path)
        if kind:
            files.append((path, kind))

if not files:
    print("no shell or Python files under %s" % scan, file=sys.stderr)
    sys.exit(2)

violations = []
try:
    for path, kind in files:
        rel = os.path.relpath(path, scan).replace(os.sep, "/")
        hit = first_python_hit(path) if kind == "python" else first_shell_hit(path)
        if hit:
            violations.append((rel, hit[0], hit[1]))
except RuntimeError as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(2)

for rel, lineno, shapes in violations:
    print(
        "::error::apps/%s:%d: reads a credential file path directly (%s). "
        "Call the platform account CLI handed in through the D5 ABI instead; "
        "an app must not open provider credential files." %
        (rel, lineno, ", ".join(shapes)),
        file=sys.stderr,
    )

if violations:
    print("FAIL check-credential-reads: %d violation file(s) in %s" %
          (len(violations), scan), file=sys.stderr)
    sys.exit(1)

print("ok check-credential-reads: %d shell/Python file(s) under %s do not read credential paths" %
      (len(files), scan))
PY
