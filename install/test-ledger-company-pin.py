#!/usr/bin/env python3
"""Pin each real Company fetch to its own SHA across an interleaved caller."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("AIRLOCK_PIN_TEST_SOURCE", ROOT / "bin/airlock-ledger")).resolve()
SCRATCH = Path(os.environ.get("AIRLOCK_COMPANY_PIN_TEST_SCRATCH", tempfile.gettempdir())).resolve()


class CompanyPinTests(unittest.TestCase):
    def setUp(self):
        SCRATCH.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix="company-pin-", dir=SCRATCH)
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        env = {key: value for key, value in os.environ.items()
               if (not key.startswith(("AIRLOCK_", "GIT_"))
                   or key.startswith("AIRLOCK_TEST_GUARD"))
               and key not in {"PYTHONPATH", "PYTHONHOME"}}
        for name in ("home", "state", "data"):
            (self.base / name).mkdir()
        env.update(HOME=str(self.base / "home"),
                   AIRLOCK_STATE_DIR=str(self.base / "state"),
                   AIRLOCK_DATA_DIR=str(self.base / "data"),
                   AIRLOCK_FIXTURE_ROOT=str(self.base),
                   GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
        environment = patch.dict(os.environ, env, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        loader = importlib.machinery.SourceFileLoader("_company_pin_test_ledger", str(SOURCE))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.engine = importlib.util.module_from_spec(spec)
        modules = patch.dict(sys.modules, {loader.name: self.engine})
        modules.start()
        self.addCleanup(modules.stop)
        loader.exec_module(self.engine)

    def git(self, directory, *args):
        return subprocess.run(["git", "-C", str(directory), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def repository(self, name, marker=None):
        directory = self.base / name
        directory.mkdir()
        self.git(directory, "init", "--quiet", "-b", "main")
        if marker is None:
            (directory / "README").write_text(name + "\n")
        else:
            target = directory / "apps/same/marker"
            target.parent.mkdir(parents=True)
            target.write_text(marker)
        self.commit(directory, name)
        return directory

    def commit(self, directory, message):
        self.git(directory, "add", ".")
        self.git(directory, "-c", "user.name=Fixture",
                 "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", message)
        return self.git(directory, "rev-parse", "HEAD")

    def info(self, directory):
        return {"company_repo": directory.as_uri()}

    def interleave(self, action):
        """Run one actual nested pin immediately before the outer SHA read."""
        original = self.engine._git
        calls = []

        def wrapped(args, description):
            if ("rev-parse" in args and not calls
                    and any(arg.endswith("^{commit}") for arg in args)):
                calls.append(True)  # arm before the nested call to prevent recursion
                action()
            return original(args, description)

        wrapper = patch.object(self.engine, "_git", wrapped)
        wrapper.start()
        self.addCleanup(wrapper.stop)
        return calls

    def assert_no_refs(self):
        refs = self.git(self.engine.company_mirror_path(), "for-each-ref", "--format=%(refname)")
        self.assertEqual(refs, "", "a temporary fetch ref survived pin_main")

    def test_different_sources_keep_their_sha_and_app_membership(self):
        a = self.repository("A")
        b = self.repository("B", "B-marker")
        expected_a = self.git(a, "rev-parse", "HEAD")
        expected_b = self.git(b, "rev-parse", "HEAD")
        nested = []
        calls = self.interleave(lambda: nested.append(self.engine.pin_main(self.info(b))))
        pinned_a = self.engine.pin_main(self.info(a))
        self.assertEqual(len(calls), 1)
        self.assertEqual(nested, [expected_b])
        self.assertEqual(pinned_a, expected_a)
        mirror = self.engine.company_mirror_path()
        self.assertFalse(self.engine._mirror_has_app(mirror, pinned_a, "same"))
        self.assertTrue(self.engine._mirror_has_app(mirror, nested[0], "same"))
        self.assertEqual(self.git(mirror, "show", f"{nested[0]}:apps/same/marker"), "B-marker")
        self.assert_no_refs()

    def test_moving_main_keeps_each_calls_fetched_commit_and_marker(self):
        repo = self.repository("moving", "before")
        before = self.git(repo, "rev-parse", "HEAD")
        advanced, nested = [], []

        def advance_and_pin():
            (repo / "apps/same/marker").write_text("after")
            advanced.append(self.commit(repo, "advance main"))
            nested.append(self.engine.pin_main(self.info(repo)))

        calls = self.interleave(advance_and_pin)
        first = self.engine.pin_main(self.info(repo))
        self.assertEqual(len(calls), 1)
        self.assertNotEqual(before, advanced[0])
        self.assertEqual(first, before)
        self.assertEqual(nested, advanced)
        mirror = self.engine.company_mirror_path()
        self.assertEqual(self.git(mirror, "show", f"{first}:apps/same/marker"), "before")
        self.assertEqual(self.git(mirror, "show", f"{nested[0]}:apps/same/marker"), "after")
        self.assert_no_refs()

    def test_failed_fetch_is_an_ordinary_error_and_leaves_no_refs(self):
        missing = self.base / "missing.git"
        with self.assertRaisesRegex(self.engine.LedgerError, "cannot fetch Company main"):
            self.engine.pin_main(self.info(missing))
        self.assert_no_refs()


if __name__ == "__main__":
    unittest.main(verbosity=2)
