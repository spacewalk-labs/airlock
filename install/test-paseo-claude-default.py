#!/usr/bin/env python3
"""Regression tests for apps/paseo/configure-claude-default.py."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parent.parent / "apps/paseo/configure-claude-default.py"


def run(home: Path, model: str) -> int:
    return subprocess.run(
        ["python3", str(SCRIPT), "--paseo-home", str(home), "--model", model],
        capture_output=True,
        text=True,
    ).returncode


class ClaudeDefaultTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.config = self.home / "config.json"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def read(self) -> dict:
        return json.loads(self.config.read_text(encoding="utf-8"))

    def test_sets_default_and_keeps_other_fields(self) -> None:
        self.config.write_text(json.dumps({
            "daemon": {"listen": "127.0.0.1:6767"},
            "agents": {"providers": {"claude": {"env": {"TMPDIR": "/x"}}}},
        }))
        self.assertEqual(run(self.home, "claude-opus-5-5"), 2)
        claude = self.read()["agents"]["providers"]["claude"]
        self.assertEqual(claude["env"], {"TMPDIR": "/x"})
        self.assertEqual(claude["additionalModels"], [{"id": "claude-opus-5-5", "label": "Opus 5.5", "isDefault": True}])
        self.assertEqual(self.read()["daemon"], {"listen": "127.0.0.1:6767"})

    def test_second_run_is_byte_identical(self) -> None:
        self.assertEqual(run(self.home, "claude-opus-5-5"), 2)
        before = self.config.read_bytes()
        self.assertEqual(run(self.home, "claude-opus-5-5"), 0)
        self.assertEqual(self.config.read_bytes(), before)

    def test_moves_flag_without_dropping_operator_entries(self) -> None:
        self.config.write_text(json.dumps({"agents": {"providers": {"claude": {"additionalModels": [
            {"id": "claude-opus-5", "label": "Opus 5", "isDefault": True},
            {"id": "my-proxy-model", "label": "Proxy"},
        ]}}}}))
        self.assertEqual(run(self.home, "claude-opus-5-5"), 2)
        self.assertEqual(self.read()["agents"]["providers"]["claude"]["additionalModels"], [
            {"id": "claude-opus-5", "label": "Opus 5"},
            {"id": "my-proxy-model", "label": "Proxy"},
            {"id": "claude-opus-5-5", "label": "Opus 5.5", "isDefault": True},
        ])

    def test_empty_model_clears_flag(self) -> None:
        self.assertEqual(run(self.home, "claude-opus-5-5"), 2)
        self.assertEqual(run(self.home, ""), 2)
        models = self.read()["agents"]["providers"]["claude"]["additionalModels"]
        self.assertFalse(any(m.get("isDefault") for m in models))

    def test_every_entry_has_the_label_paseo_requires(self) -> None:
        for model, want in (("claude-opus-5-5", "Opus 5.5"), ("claude-fable-5-1", "Fable 5.1"), ("claude-sonnet-5", "Sonnet 5")):
            self.assertEqual(run(self.home, model), 2)
            labels = {m["id"]: m.get("label") for m in self.read()["agents"]["providers"]["claude"]["additionalModels"]}
            self.assertEqual(labels[model], want)

    def test_empty_model_on_fresh_home_writes_nothing(self) -> None:
        self.assertEqual(run(self.home, ""), 0)
        self.assertFalse(self.config.exists())


if __name__ == "__main__":
    unittest.main()
