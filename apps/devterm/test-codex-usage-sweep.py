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
assert any(
    isinstance(call.func, ast.Name)
    and call.func.id == "_run_probe"
    and len(call.args) == 2
    and isinstance(call.args[1], ast.List)
    and [elt.value for elt in call.args[1].elts] == ["--codex-usage"]
    for call in calls
)
print("PASS codex fleet read uses one synchronous probe and owns no cache/sweeper")
