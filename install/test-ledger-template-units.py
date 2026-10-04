#!/usr/bin/env python3
"""Template-unit teardown regressions.

These tests do not put a fake ``systemctl`` executable on PATH. They hold the
subprocess boundary to an exact command transcript and feed the parser real-format
``systemctl list-units --no-legend --plain`` output fixtures. Any attempt to
invoke the bare ``@.service`` template raises immediately.
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader(
    "ledger_template_test",
    os.environ.get("LEDGER_TEST_TOOL", str(ROOT / "bin/airlock-ledger")))
spec = importlib.util.spec_from_loader(loader.name, loader)
ledger = importlib.util.module_from_spec(spec)
loader.exec_module(ledger)

TEMPLATE = "airlock-code-server@.service"
INSTANCES = ("airlock-code-server@1.service", "airlock-code-server@3.service")


class SystemctlTranscript:
    def __init__(self, fixture: Path, *, instances: bool):
        self.fixture = fixture
        self.calls = []
        self.units = ({
            INSTANCES[0]: {"active": True, "enabled": True, "pid": "42"},
            INSTANCES[1]: {"active": False, "enabled": False, "pid": "0"},
        } if instances else {})

    def __call__(self, command, **_kwargs):
        command = list(command)
        self.calls.append(command)
        if command[:2] != ["systemctl", "--user"]:
            raise AssertionError(f"unexpected command: {command!r}")
        args = command[2:]
        action = args[0]
        if action == "list-units":
            expected = ["list-units", "--all", "--full", "--plain",
                        "--no-legend", "--no-pager", "airlock-code-server@*.service"]
            if args != expected:
                raise AssertionError(f"unexpected list-units invocation: {args!r}")
            return subprocess.CompletedProcess(command, 0, self.fixture.read_text(), "")
        name = args[1] if action == "show" else args[-1]
        if name == TEMPLATE:
            raise AssertionError(f"bare template was invoked: {command!r}")
        if action == "daemon-reload":
            return subprocess.CompletedProcess(command, 0, "", "")
        if name not in self.units:
            raise AssertionError(f"unknown instance was invoked: {command!r}")
        unit = self.units[name]
        if action == "is-active":
            rc = 0 if unit["active"] else 3
            return subprocess.CompletedProcess(command, rc, "", "")
        if action == "is-enabled":
            rc = 0 if unit["enabled"] else 1
            return subprocess.CompletedProcess(command, rc, "", "")
        if action == "show":
            stdout = ("LoadState=loaded\n"
                      f"ActiveState={'active' if unit['active'] else 'inactive'}\n"
                      f"MainPID={unit['pid']}\nControlPID=0\n")
            return subprocess.CompletedProcess(command, 0, stdout, "")
        if action == "stop":
            unit.update(active=False, pid="0")
            return subprocess.CompletedProcess(command, 0, "", "")
        if action == "start":
            unit.update(active=True, pid="42")
            return subprocess.CompletedProcess(command, 0, "", "")
        if action == "disable":
            unit["enabled"] = False
            return subprocess.CompletedProcess(command, 0, "", "")
        if action == "enable":
            unit["enabled"] = True
            return subprocess.CompletedProcess(command, 0, "", "")
        raise AssertionError(f"unexpected systemctl action: {command!r}")

    def names_for(self, action: str) -> set[str]:
        return {command[-1] for command in self.calls
                if len(command) > 2 and command[2] == action}

    def count_for(self, action: str) -> int:
        return sum(len(command) > 2 and command[2] == action for command in self.calls)


class TemplateUnitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ledger-template-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.roots = {name: str(self.root / name) for name in
                      ("unit_user", "unit_system", "confd", "webroot", "home")}
        for directory in self.roots.values():
            Path(directory).mkdir()
        self.template = Path(self.roots["unit_user"]) / TEMPLATE
        self.template.write_text("[Unit]\nDescription=Airlock Code Server slot %i\n")
        self.store = {"probe": {"repo": str(self.root / "missing-package"),
                                "commit": "", "artifacts": [str(self.template)]}}
        env = {
            "AIRLOCK_STATE_DIR": str(self.root / "state"),
            "AIRLOCK_UNIT_DIR_USER": self.roots["unit_user"],
            "AIRLOCK_UNIT_DIR_SYSTEM": self.roots["unit_system"],
            "AIRLOCK_CONFD": self.roots["confd"],
            "AIRLOCK_WEBROOT": self.roots["webroot"],
            "HOME": self.roots["home"], "AIRLOCK_DRY_RUN": "0",
            "AIRLOCK_CONFIG_SNAPSHOT_SHA256": "a" * 64,
            "AIRLOCK_INSTALL_PKG_INFO_SHA256": "b" * 64,
        }
        self.env = patch.dict(os.environ, env)
        self.env.start()
        self.addCleanup(self.env.stop)
        ledger.write_installed(self.store)

    def transcript(self, *, instances: bool) -> SystemctlTranscript:
        name = ("list-units-template-instances.txt" if instances
                else "list-units-template-none.txt")
        return SystemctlTranscript(ROOT / "install/fixtures/systemctl" / name,
                                   instances=instances)

    def teardown(self, transcript: SystemctlTranscript) -> int:
        with patch.object(ledger.subprocess, "run", side_effect=transcript), \
                patch.object(ledger, "project"), \
                contextlib.redirect_stderr(io.StringIO()):
            return ledger.command_remove("probe")

    def test_teardown_stops_and_disables_each_concrete_instance(self):
        transcript = self.transcript(instances=True)
        self.assertEqual(self.teardown(transcript), 0)
        self.assertFalse(self.template.exists())
        self.assertEqual(transcript.count_for("list-units"), 1)
        self.assertEqual(transcript.names_for("stop"), set(INSTANCES))
        self.assertEqual(transcript.names_for("disable"), set(INSTANCES))

    def test_teardown_with_no_instances_skips_unit_commands(self):
        transcript = self.transcript(instances=False)
        self.assertEqual(self.teardown(transcript), 0)
        self.assertFalse(self.template.exists())
        self.assertEqual(transcript.count_for("list-units"), 1)
        for action in ("show", "stop", "disable"):
            self.assertEqual(transcript.names_for(action), set())


if __name__ == "__main__":
    unittest.main(verbosity=2)
