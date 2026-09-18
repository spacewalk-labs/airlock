#!/usr/bin/env python3
"""Offline Git and digest checks for the optional company catalog."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import devmon_company_catalog as CATALOG


ROOT = Path(__file__).resolve().parents[3]


def git(repo: Path, *args: str) -> str:
    env = os.environ.copy()
    env.update({"GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.test",
                "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.test"})
    return subprocess.run(["git", *args], cwd=repo, env=env, check=True,
                          stdout=subprocess.PIPE, text=True).stdout.strip()


def digest(path: Path) -> str:
    loader = importlib.machinery.SourceFileLoader("fixture_ledger", str(ROOT / "bin/airlock-ledger"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module.digest_tree(str(path))


class CompanyCatalogTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.source = self.base / "source"
        self.source.mkdir()
        git(self.source, "init", "-q", "-b", "main")
        package = self.source / "packages/widget"
        (package / "payload").mkdir(parents=True)
        (package / "airlock-app.toml").write_text('contract = 1\nid = "widget"\n')
        (package / "payload/data.txt").write_text("pinned bytes\n")
        CATALOG._normalise_checkout_modes(package)
        self.expected = digest(package)
        git(self.source, "add", ".")
        git(self.source, "commit", "-qm", "fixture package")
        self.commit = git(self.source, "rev-parse", "HEAD")

        self.catalog = self.base / "catalog"
        self.catalog.mkdir()
        git(self.catalog, "init", "-q", "-b", "main")
        self.row = {"id": "widget", "repo": str(self.source), "commit": self.commit,
                    "tree_digest": self.expected, "label": "Widget", "sub": "packages/widget",
                    "installable": True, "reason": None}
        (self.catalog / "catalog.json").write_text(json.dumps(
            {"schema_version": 1, "apps": [self.row]}, sort_keys=True) + "\n")
        git(self.catalog, "add", ".")
        git(self.catalog, "commit", "-qm", "fixture catalog")
        self.config = self.base / "airlock.toml"
        self.config.write_text(
            '[apps.dev-monitor]\ncompany_catalog_repository = '
            + json.dumps(str(self.catalog))
            + '\ncompany_catalog_ref = "main"\ncompany_catalog_stage = '
            + json.dumps(str(self.base / "stage")) + "\n")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_existing_git_access_lists_and_stages_the_pinned_tree(self) -> None:
        self.assertEqual(CATALOG.list_catalog(self.config), [self.row])
        staged = CATALOG.stage_entry(ROOT, self.config, self.row)
        self.assertEqual(digest(staged), self.expected)
        self.assertEqual(staged.readlink() if staged.is_symlink() else None, None)
        self.assertEqual(CATALOG.stage_entry(ROOT, self.config, self.row), staged)

    def test_unavailable_catalog_is_an_empty_list(self) -> None:
        self.config.write_text(
            '[apps.dev-monitor]\ncompany_catalog_repository = '
            + json.dumps(str(self.base / "missing")) + "\n")
        self.assertEqual(CATALOG.list_catalog(self.config), [])

    def test_pinned_stage_marks_only_already_approved_company_packages(self) -> None:
        """This local provenance check never fetches or exposes a catalog row."""
        pinned = (self.base / "stage" / "packages" / "widget" /
                  f"{self.commit}-{self.expected}")
        personal = self.base / "personal" / "widget"
        self.config.write_text(self.config.read_text() + (
            "[apps.widget]\n[packages.widget]\npath = " + json.dumps(str(pinned)) + "\n"
            "[apps.personal]\n[packages.personal]\npath = " + json.dumps(str(personal)) + "\n"
            "[apps.wrong-id]\n[packages.wrong-id]\npath = "
            + json.dumps(str(self.base / "stage" / "packages" / "widget" /
                             f"{self.commit}-{self.expected}")) + "\n"))
        original_git = CATALOG._git
        CATALOG._git = lambda *args, **kwargs: (_ for _ in ()).throw(
            AssertionError("provenance must not fetch the catalog"))
        try:
            self.assertEqual(CATALOG.installed_company_ids(self.config), {"widget"})
        finally:
            CATALOG._git = original_git

    def test_digest_mismatch_leaves_no_package_stage(self) -> None:
        row = dict(self.row, tree_digest="0" * 64)
        with self.assertRaisesRegex(CATALOG.CatalogError, "digest differs") as raised:
            CATALOG.stage_entry(ROOT, self.config, row)
        self.assertEqual(raised.exception.code, "digest_mismatch")
        self.assertFalse(any((self.base / "stage/packages/widget").glob("*")))

    def test_non_installable_row_is_refused_before_git_or_stage(self) -> None:
        row = dict(self.row, installable=False, reason="build_artifact")
        with self.assertRaisesRegex(CATALOG.CatalogError, "build_artifact") as raised:
            CATALOG.stage_entry(ROOT, self.config, row)
        self.assertEqual(raised.exception.code, "catalog_not_installable")
        self.assertFalse((self.base / "stage").exists())

    def test_catalog_shape_is_closed(self) -> None:
        bad = dict(self.row, unexpected=True)
        with self.assertRaisesRegex(CATALOG.CatalogError, "unknown shape"):
            CATALOG._decode_catalog(json.dumps(
                {"schema_version": 1, "apps": [bad]}).encode())

        bad_reason = dict(self.row, installable=False, reason=None)
        with self.assertRaisesRegex(CATALOG.CatalogError, "reason is invalid"):
            CATALOG._decode_catalog(json.dumps(
                {"schema_version": 1, "apps": [bad_reason]}).encode())

    def test_catalog_cannot_select_an_executable_git_transport(self) -> None:
        row = dict(self.row, repo="ext::sh -c ignored")
        with self.assertRaisesRegex(CATALOG.CatalogError, "slug or an https/ssh/file"):
            CATALOG.stage_entry(ROOT, self.config, row)


if __name__ == "__main__":
    unittest.main()
