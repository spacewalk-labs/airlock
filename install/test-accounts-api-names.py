#!/usr/bin/env python3
"""Every name bin/airlock-accounts-api loads is defined in it.

🔴 Why this exists as its own check. This surface is built by porting functions out of
`apps/devterm/backend/devterm-gate.py`, and a ported function keeps referring to whatever
the gate called things. `python -m py_compile` accepts that happily — an undefined global
is only an error when the line runs — so five of them shipped past compilation and past
the route tests, and were found by an HTTP request that killed the worker thread mid-reply
(curl reported "empty reply from server", which says nothing about the cause).

A NameError in a handler is not a small bug here: the thread dies with the response
half-written, so the caller sees a transport failure rather than an error it can act on.

Deliberately a whole-module scan rather than a lint rule with a suppression list: the
defect is "a name from somewhere else survived the move", and any list of allowed
exceptions would eventually be where the next one hides.
"""
import ast
import builtins
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(ROOT, "bin", "airlock-accounts-api")

tree = ast.parse(open(TARGET, encoding="utf-8").read(), filename=TARGET)
defined = set(dir(builtins))
for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        defined.add(node.name)
    elif isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store):
        defined.add(node.id)
    elif isinstance(node, ast.arg):
        defined.add(node.arg)
    elif isinstance(node, ast.Import):
        for alias in node.names:
            defined.add((alias.asname or alias.name).split(".")[0])
    elif isinstance(node, ast.ImportFrom):
        for alias in node.names:
            defined.add(alias.asname or alias.name)
    elif isinstance(node, ast.ExceptHandler) and node.name:
        defined.add(node.name)

loads = {}
for node in ast.walk(tree):
    if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
        loads.setdefault(node.id, node.lineno)

# Positive control: a scan that stopped resolving anything would report a clean module
# while looking at nothing.
if len(loads) < 50:
    print(f"FAIL only {len(loads)} loaded names found — the scan is broken, not the file")
    sys.exit(1)

missing = sorted((name, line) for name, line in loads.items() if name not in defined)
for name, line in missing:
    print(f"FAIL {os.path.relpath(TARGET, ROOT)}:{line}: undefined name {name!r} "
          f"— a ported function still refers to what devterm's gate called it")
if missing:
    print(f"\n{len(missing)} undefined name(s)")
    sys.exit(1)
print(f"ok   all {len(loads)} loaded names are defined in the module")
