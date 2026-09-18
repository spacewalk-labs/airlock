#!/usr/bin/env python3
"""Regression tests for the installed OpenCode defaults."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "configure-opencode.py"
spec = importlib.util.spec_from_file_location("configure_opencode", SCRIPT)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


class OpenCodeDefaultsTest(unittest.TestCase):
    def run_installer(self, home: Path) -> None:
        subprocess.run(
            ["python3", str(SCRIPT), "--home", str(home)],
            check=True,
            capture_output=True,
            text=True,
        )

    def load(self, home: Path) -> dict:
        path = home / ".config/opencode/opencode.jsonc"
        return json.loads(path.read_text(encoding="utf-8"))

    def test_clean_home_gets_exact_standard_roster(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            self.run_installer(home)
            config = self.load(home)
            self.assertEqual(config["model"], module.MODEL)
            self.assertEqual(config["agent"], module.AGENTS)
            self.assertEqual(set(config["agent"]), {
                "muse-spark-1.3-contributor",
                "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "grok-4.6",
                "gemini-3.7-flash", "gemini-3.5-flash-lite",
            })
            self.assertNotIn("variant", config["agent"]["gemini-3.5-flash-lite"])
            self.assertEqual(config["agent"]["grok-4.6"]["variant"], "high")
            muse = config["agent"]["muse-spark-1.3-contributor"]
            self.assertEqual(muse["model"], "opencode-go/muse-spark-1.3-contributor")
            self.assertEqual(muse["variant"], "xhigh")
            # Live provider set: opencode-go enabled, anthropic absent.
            self.assertEqual(config["enabled_providers"], module.ENABLED_PROVIDERS)
            self.assertEqual(
                config["provider"]["opencode-go"]["whitelist"],
                ["muse-spark-1.3-contributor"],
            )
            self.assertEqual(
                config["provider"]["xai"]["whitelist"], module.XAI_WHITELIST
            )
            self.assertEqual(
                config["provider"]["google"]["whitelist"], module.GOOGLE_WHITELIST
            )
            self.assertEqual(
                config["provider"]["openai"]["whitelist"], module.OPENAI_WHITELIST
            )
            self.assertEqual(
                config["provider"]["xai"]["models"]["grok-4.6"]["limit"]["context"],
                module.GROK_CONTEXT["grok-4.6"],
            )
            self.assertEqual(
                config["provider"]["xai"]["models"]["grok-build-0.1"]["limit"]["context"],
                module.GROK_CONTEXT["grok-build-0.1"],
            )
            for model_id in module.OPENAI_WHITELIST:
                limit = config["provider"]["openai"]["models"][model_id]["limit"]
                self.assertEqual(limit["context"], module.OPENAI_CONTEXT[model_id])
                self.assertEqual(limit["output"], module.OPENAI_OUTPUT[model_id])
            # Muse never uses `max` (OpenCode Go rejects it) and the free
            # Muse tier is never registered. (Other families keep their own
            # live variants — e.g. Luna stays `max`.)
            self.assertEqual(muse["variant"], "xhigh")
            dumped = json.dumps(config)
            self.assertNotIn("muse-spark-1.3-contributor-free", dumped)
            self.assertNotIn("free", dumped)

    def test_jsonc_top_level_keys_survive_and_second_run_is_identical(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            path = home / ".config/opencode/opencode.jsonc"
            path.parent.mkdir(parents=True)
            path.write_text(
                '''{
  // values owned by the user stay intact
  "$schema": "custom-schema",
  "permission": {"bash": "ask"},
  "instructions": ["one", "two",],
  "provider": {"xai": {"whitelist": ["grok-4.6"]}},
  "experimental": {"url": "https://example.invalid/a//b,}"}, /* block */
  "model": "old/model",
  "agent": {"old-alias": {"model": "old/model"}},
}
''',
                encoding="utf-8",
            )
            path.chmod(0o640)
            self.run_installer(home)
            first = path.read_bytes()
            config = self.load(home)
            self.assertEqual(config["$schema"], "custom-schema")
            self.assertEqual(config["permission"], {"bash": "ask"})
            self.assertEqual(config["instructions"], ["one", "two"])
            self.assertEqual(config["provider"]["xai"]["whitelist"], ["grok-4.6"])
            self.assertEqual(
                config["provider"]["xai"]["models"]["grok-4.6"]["limit"]["context"],
                module.GROK_CONTEXT["grok-4.6"],
            )
            self.assertEqual(
                config["provider"]["xai"]["models"]["grok-build-0.1"]["limit"]["context"],
                module.GROK_CONTEXT["grok-build-0.1"],
            )
            self.assertEqual(config["experimental"], {"url": "https://example.invalid/a//b,}"})
            self.assertEqual(config["model"], module.MODEL)
            self.assertEqual(config["agent"], module.AGENTS)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
            self.run_installer(home)
            self.assertEqual(path.read_bytes(), first)

    def test_existing_grok_output_survives_context_update(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            path = home / ".config/opencode/opencode.jsonc"
            path.parent.mkdir(parents=True)
            path.write_text(
                '{"provider":{"xai":{"models":{"grok-4.6":{"limit":{"context":1,"output":999}}}}}}',
                encoding="utf-8",
            )
            self.run_installer(home)
            config = self.load(home)
            self.assertEqual(config["provider"]["xai"]["models"]["grok-4.6"]["limit"]["context"], 230000)
            self.assertEqual(config["provider"]["xai"]["models"]["grok-4.6"]["limit"]["output"], 999)
            self.assertEqual(
                config["provider"]["xai"]["models"]["grok-build-0.1"]["limit"]["output"],
                module.GROK_OUTPUT["grok-build-0.1"],
            )

    def test_output_at_or_above_context_is_reset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            path = home / ".config/opencode/opencode.jsonc"
            path.parent.mkdir(parents=True)
            path.write_text(
                '{"provider":{"xai":{"models":{"grok-4.6":{"limit":{"context":400000,"output":500000}}}}}}',
                encoding="utf-8",
            )
            self.run_installer(home)
            limit = self.load(home)["provider"]["xai"]["models"]["grok-4.6"]["limit"]
            self.assertEqual(limit, {"context": 230000, "output": 30000})
            self.assertEqual(limit["context"] - limit["output"], 200000)

    def test_enabled_providers_adds_missing_and_removes_anthropic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            path = home / ".config/opencode/opencode.jsonc"
            path.parent.mkdir(parents=True)
            path.write_text(
                '{"enabled_providers": ["xai", "anthropic", "my-custom"]}',
                encoding="utf-8",
            )
            self.run_installer(home)
            enabled = self.load(home)["enabled_providers"]
            self.assertNotIn("anthropic", enabled)
            for required in module.ENABLED_PROVIDERS:
                self.assertIn(required, enabled)
            self.assertIn("my-custom", enabled)
            # Idempotent: second run keeps the merged list as-is.
            first = path.read_bytes()
            self.run_installer(home)
            self.assertEqual(path.read_bytes(), first)

    def test_opencode_go_whitelist_ensures_muse_removes_free(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            path = home / ".config/opencode/opencode.jsonc"
            path.parent.mkdir(parents=True)
            path.write_text(
                '{"provider":{"opencode-go":{"whitelist":['
                '"muse-spark-1.3-contributor-free",'
                '"opencode/muse-spark-1.3-contributor-free"]}}}',
                encoding="utf-8",
            )
            self.run_installer(home)
            whitelist = self.load(home)["provider"]["opencode-go"]["whitelist"]
            self.assertIn("muse-spark-1.3-contributor", whitelist)
            self.assertNotIn("muse-spark-1.3-contributor-free", whitelist)
            self.assertNotIn(
                "opencode/muse-spark-1.3-contributor-free", whitelist
            )

    def test_member_google_openai_whitelists_survive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            path = home / ".config/opencode/opencode.jsonc"
            path.parent.mkdir(parents=True)
            path.write_text(
                '{"provider":{"google":{"whitelist":["gemini-3.5-flash-lite"]},'
                '"openai":{"whitelist":["gpt-5.6-sol"]}}}',
                encoding="utf-8",
            )
            self.run_installer(home)
            config = self.load(home)
            self.assertEqual(
                config["provider"]["google"]["whitelist"],
                ["gemini-3.5-flash-lite"],
            )
            self.assertEqual(
                config["provider"]["openai"]["whitelist"], ["gpt-5.6-sol"]
            )

    def test_missing_opencode_key_does_not_break_other_providers(self) -> None:
        # Boxes without an `opencode-go` key in auth.json.
        # The config writer never reads auth.json, so other providers stay
        # configured and the default seat stays xai/grok-4.6.
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            self.assertFalse(
                (home / ".local/share/opencode/auth.json").exists()
            )
            self.run_installer(home)
            config = self.load(home)
            self.assertEqual(config["model"], "xai/grok-4.6")
            for provider_id in ("opencode-go", "xai", "google", "openai"):
                self.assertIn(provider_id, config["provider"])
                self.assertIn("whitelist", config["provider"][provider_id])

    def test_existing_openai_output_survives_context_update(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            path = home / ".config/opencode/opencode.jsonc"
            path.parent.mkdir(parents=True)
            path.write_text(
                '{"provider":{"openai":{"models":{"gpt-5.6-sol":'
                '{"limit":{"context":1,"output":999}}}}}}',
                encoding="utf-8",
            )
            self.run_installer(home)
            limit = self.load(home)["provider"]["openai"]["models"]["gpt-5.6-sol"][
                "limit"
            ]
            self.assertEqual(limit["context"], 350000)
            self.assertEqual(limit["output"], 999)

    def test_invalid_existing_file_is_not_replaced(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            path = home / ".config/opencode/opencode.jsonc"
            path.parent.mkdir(parents=True)
            original = b'{"permission": /* unfinished'
            path.write_bytes(original)
            result = subprocess.run(
                ["python3", str(SCRIPT), "--home", str(home)],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
