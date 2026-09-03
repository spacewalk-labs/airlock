#!/usr/bin/env python3
"""Headless contract tests for the Ubuntu installer window's trusted data seam."""

from __future__ import annotations

import hashlib
import io
import json
import os
import pathlib
import tarfile
import tempfile
import unittest

from gui_installer_core import (
    ContractError,
    failure_copy,
    load_inputs,
    make_request,
    parse_event,
    picker_apps,
    reconcile_exit,
)
from gui_selection import validate as validate_selection


HERE = pathlib.Path(__file__).resolve().parent


class InstallerCoreTest(unittest.TestCase):
    def setUp(self) -> None:
        # The contract deliberately rejects every group/world-writable path
        # component.  tempfile's system default is commonly /tmp (01777), so
        # keep the fixture below the current user's trusted home instead.
        self.tmp = tempfile.TemporaryDirectory(
            prefix=".airlock-gui-test-",
            dir=pathlib.Path.home(),
        )
        root = pathlib.Path(self.tmp.name)
        self.bundle = root / "bundle.tgz"
        self.config = root / "installer.json"
        self.helper = root / "helper"
        self.helper.write_text("#!/bin/sh\n", encoding="utf-8")
        self.helper.chmod(0o755)

        self.profile = {
            "schema": "airlock.gui-default-profile/v1",
            "always": ["hub"],
            "required": ["devterm", "fileview", "publish"],
            "default": ["paseo"],
            "install": ["devterm", "fileview", "publish", "paseo"],
        }
        self.catalog = {
            "apps": [
                {"id": app, "tile": {"label": app}, "arch": []}
                for app in ("devterm", "fileview", "publish", "paseo", "notes")
            ] + [{"id": "armapp", "tile": {"label": "armapp"}, "arch": ["arm64"]}],
            "unavailable": [],
        }
        self._write_bundle()
        self._write_config()
        self.extracted = root / "extracted"
        self.extracted.mkdir()
        with tarfile.open(self.bundle, "r:gz") as tf:
            tf.extractall(self.extracted, filter="data")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    @staticmethod
    def _raw(value) -> bytes:
        return (json.dumps(value, sort_keys=True) + "\n").encode()

    def _write_bundle(self) -> None:
        profile = self._raw(self.profile)
        catalog = self._raw(self.catalog)
        manifest = self._raw(
            {
                "schema": "airlock.gui-provisioner-bundle/v1",
                "source_sha": "a" * 40,
                "source_epoch": 1,
                "profile_path": "docker/gui-default-profile.json",
                "profile_sha256": hashlib.sha256(profile).hexdigest(),
                "catalog_path": "docker/gui-catalog.json",
                "catalog_sha256": hashlib.sha256(catalog).hexdigest(),
            }
        )
        with tarfile.open(self.bundle, "w:gz") as tf:
            for name, data in (
                ("airlock/gui-provisioner-manifest.json", manifest),
                ("airlock/docker/gui-default-profile.json", profile),
                ("airlock/docker/gui-catalog.json", catalog),
            ):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o644
                tf.addfile(info, io.BytesIO(data))
        self.bundle.chmod(0o644)

    def _write_config(self) -> None:
        self.config.write_text(
            json.dumps(
                {
                    "schema": "airlock.gui-installer-config/v1",
                    "bundle": str(self.bundle),
                    "bundle_sha256": hashlib.sha256(self.bundle.read_bytes()).hexdigest(),
                    "helper": str(self.helper),
                    "expected_tailnet": "example.ts.net",
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self.config.chmod(0o644)

    def load(self):
        return load_inputs(
            self.config,
            trusted_uid=os.getuid(),
            expected_helper=self.helper,
        )

    def test_default_request_carries_only_paseo_as_optional(self) -> None:
        inputs = self.load()
        request = json.loads(
            make_request(
                "airlock-box",
                ["devterm", "fileview", "publish", "paseo"],
                inputs,
            )
        )
        self.assertEqual(request["schema"], "airlock.gui-install-request/v1")
        self.assertEqual(request["selected_optional_apps"], ["paseo"])

    def test_picker_synthesizes_locked_hub_and_approved_defaults(self) -> None:
        rows = picker_apps(self.load())
        by_id = {row.app_id: row for row in rows}
        self.assertEqual(len(rows), 7)
        self.assertTrue(by_id["hub"].locked and by_id["hub"].checked)
        for app_id in ("devterm", "fileview", "publish"):
            self.assertTrue(by_id[app_id].locked and by_id[app_id].checked)
        self.assertFalse(by_id["paseo"].locked)
        self.assertTrue(by_id["paseo"].checked)
        self.assertFalse(by_id["notes"].locked or by_id["notes"].checked)
        self.assertTrue(by_id["armapp"].locked)
        self.assertFalse(by_id["armapp"].checked)

    def test_explicit_empty_is_distinct_from_default(self) -> None:
        inputs = self.load()
        request = json.loads(make_request("airlock-box", [], inputs))
        self.assertEqual(request["selected_optional_apps"], [])

    def test_optional_app_is_preserved_and_required_is_not_user_input(self) -> None:
        inputs = self.load()
        request = json.loads(make_request("airlock-box", ["notes", "publish"], inputs))
        self.assertEqual(request["selected_optional_apps"], ["notes"])

    def test_unknown_duplicate_and_bad_hostname_are_refused(self) -> None:
        inputs = self.load()
        for hostname, apps in (
            ("Bad Name", []),
            ("airlock", ["missing"]),
            ("airlock", ["notes", "notes"]),
            ("airlock", ["armapp"]),
        ):
            with self.subTest(hostname=hostname, apps=apps), self.assertRaises(ContractError):
                make_request(hostname, apps, inputs)

    def test_config_binds_bundle_digest(self) -> None:
        self.bundle.write_bytes(self.bundle.read_bytes() + b"tampered")
        with self.assertRaisesRegex(ContractError, "digest"):
            self.load()

    def test_trusted_inputs_reject_symlinks_writable_parents_and_other_helpers(self) -> None:
        link = pathlib.Path(self.tmp.name).parent / (pathlib.Path(self.tmp.name).name + "-link")
        link.symlink_to(self.config)
        try:
            with self.assertRaisesRegex(ContractError, "symlink"):
                load_inputs(link, trusted_uid=os.getuid(), expected_helper=self.helper)
        finally:
            link.unlink()

        root = pathlib.Path(self.tmp.name)
        root.chmod(0o775)
        try:
            with self.assertRaisesRegex(ContractError, "writable"):
                self.load()
        finally:
            root.chmod(0o700)

        other = root / "other-helper"
        other.write_text("#!/bin/sh\n", encoding="utf-8")
        other.chmod(0o755)
        cfg = json.loads(self.config.read_text(encoding="utf-8"))
        cfg["helper"] = str(other)
        self.config.write_text(json.dumps(cfg) + "\n", encoding="utf-8")
        self.config.chmod(0o644)
        with self.assertRaisesRegex(ContractError, "unexpected privileged helper"):
            self.load()

    def test_profile_and_catalog_are_manifest_bound(self) -> None:
        self.catalog["apps"].append({"id": "surprise", "tile": None})
        self._write_bundle()
        # Config still has the old whole-bundle digest, so refresh only that outer pin.
        self._write_config()
        inputs = self.load()
        self.assertIn("surprise", {app["id"] for app in inputs.catalog["apps"]})

    def test_event_and_failure_fallback_are_total(self) -> None:
        self.assertIsNone(parse_event("not json"))
        event = parse_event('{"event":"failed","code":"x","message":"m","remedy":"r"}')
        self.assertIsNotNone(event)
        self.assertEqual(failure_copy(event), ("x", "m", "r"))
        self.assertEqual(failure_copy({})[0], "unexpected")

    def test_exit_reconciliation_never_turns_a_mismatch_into_success(self) -> None:
        self.assertEqual(reconcile_exit(0, "finished", "https://box.example.ts.net/")[0], "success")
        self.assertEqual(reconcile_exit(1, "finished", "https://box.example.ts.net/")[1], "finished-exit-mismatch")
        self.assertEqual(reconcile_exit(0, "", "")[1], "missing-terminal-event")
        self.assertEqual(reconcile_exit(126, "", "")[1], "privilege-cancelled")
        self.assertEqual(reconcile_exit(3, "needs-auth", "https://login.tailscale.com/")[0], "reported")

    def test_root_validator_distinguishes_default_empty_and_extra(self) -> None:
        base = self.extracted / "airlock"
        paths = (
            base / "gui-provisioner-manifest.json",
            base / "docker/gui-default-profile.json",
            base / "docker/gui-catalog.json",
        )
        self.assertEqual(validate_selection(*paths, None, "x86_64")[1], ["devterm", "fileview", "paseo", "publish"])
        selection = pathlib.Path(self.tmp.name) / "selection.json"
        selection.write_text(
            '{"schema":"airlock.gui-selection/v1","selected_optional_apps":[]}\n',
            encoding="utf-8",
        )
        self.assertEqual(validate_selection(*paths, selection, "x86_64")[1], ["devterm", "fileview", "publish"])
        selection.write_text(
            '{"schema":"airlock.gui-selection/v1","selected_optional_apps":["notes"]}\n',
            encoding="utf-8",
        )
        self.assertEqual(validate_selection(*paths, selection, "x86_64")[1], ["devterm", "fileview", "notes", "publish"])

    def test_root_validator_refuses_locked_unknown_and_unsupported(self) -> None:
        base = self.extracted / "airlock"
        paths = (
            base / "gui-provisioner-manifest.json",
            base / "docker/gui-default-profile.json",
            base / "docker/gui-catalog.json",
        )
        selection = pathlib.Path(self.tmp.name) / "selection.json"
        for apps, message in (
            (["publish"], "locked"),
            (["missing"], "unknown"),
            (["armapp"], "unsupported"),
        ):
            selection.write_text(
                json.dumps({"schema": "airlock.gui-selection/v1", "selected_optional_apps": apps}) + "\n",
                encoding="utf-8",
            )
            with self.subTest(apps=apps), self.assertRaisesRegex(ValueError, message):
                validate_selection(*paths, selection, "x86_64")


if __name__ == "__main__":
    unittest.main()
