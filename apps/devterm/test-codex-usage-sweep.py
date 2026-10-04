#!/usr/bin/env python3
"""Codex fleet compatibility stays synchronous after account-state retirement."""

import ast
from pathlib import Path


GATE = Path(__file__).with_name("backend") / "devterm-gate.py"
source = GATE.read_text(encoding="utf-8")
tree = ast.parse(source, filename=str(GATE))
handler = next(
    node for node in tree.body
    if isinstance(node, ast.AsyncFunctionDef) and node.name == "_serve_codex_usage"
)

assert "_codex_usage_sweeper" not in source
assert "_codex_usage_cache" not in source
assert "create_task" not in ast.unparse(handler)
calls = [node for node in ast.walk(handler) if isinstance(node, ast.Call)]
# One synchronous probe per request: _run_probe(cw, [...]) or _run_probe_result([...])
# (the latter when the handler adds the `stale` flag the fleet collector requires).
probe_calls = [
    call for call in calls
    if isinstance(call.func, ast.Name)
    and call.func.id in ("_run_probe", "_run_probe_result")
    and call.args and isinstance(call.args[-1], ast.List)
    and [elt.value for elt in call.args[-1].elts] == ["--codex-usage"]
]
assert len(probe_calls) == 1
print("PASS codex fleet read uses one synchronous probe and owns no cache/sweeper")

# The fleet collector refuses a /codex-usage answer without `stale` (2026-09-15..25 every
# Codex cell froze). The handler adds it from observedAt with the account API's TTL.
assert "_codex_value_stale" in ast.unparse(handler)
import datetime as _dt
import importlib.machinery as _mach
import importlib.util as _util
_loader = _mach.SourceFileLoader("devterm_gate_under_test", str(GATE))
_mod = _util.module_from_spec(_util.spec_from_loader(_loader.name, _loader))
_loader.exec_module(_mod)
_now = _dt.datetime.now(_dt.timezone.utc)
_iso = lambda sec: (_now - _dt.timedelta(seconds=sec)).strftime("%Y-%m-%dT%H:%M:%SZ")
assert _mod._codex_value_stale(_iso(10)) is False
assert _mod._codex_value_stale(_iso(_mod.CODEX_USAGE_TTL + 60)) is True
assert _mod._codex_value_stale(None) is True and _mod._codex_value_stale("x") is True
print("PASS codex fleet read carries the stale flag the collector requires")
