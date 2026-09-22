import os
from pathlib import Path
import runpy
import stat
import tempfile
import tarfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
normalize = runpy.run_path(str(ROOT / "apps/paseo/normalize-native-links.py"))["normalize"]
ledger = runpy.run_path(str(ROOT / "bin/airlock-ledger"))


class NativeLinksTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.server = self.base / "server"
        self.native = self.server / "node_modules/@esbuild/linux-x64/bin/esbuild"
        self.shim = self.server / "node_modules/esbuild/bin/esbuild"
        self.native.parent.mkdir(parents=True)
        self.shim.parent.mkdir(parents=True)
        self.native.write_bytes(b"native executable bytes")
        self.native.chmod(0o755)
        os.link(self.native, self.shim)
        os.utime(self.native, ns=(1234567890000000000, 1234567890000000000))

    def test_pair_becomes_independent_with_identical_bytes_and_metadata(self):
        before = self.native.stat()
        self.assertEqual(normalize(self.server), 1)
        for path in [self.native, self.shim]:
            self.assertEqual(path.read_bytes(), b"native executable bytes")
            after = path.stat()
            self.assertEqual(after.st_nlink, 1)
            self.assertEqual((stat.S_IMODE(after.st_mode), after.st_uid, after.st_gid, after.st_mtime_ns),
                             (stat.S_IMODE(before.st_mode), before.st_uid, before.st_gid, before.st_mtime_ns))
        self.assertEqual(normalize(self.server), 0)

    def test_outside_alias_is_rejected_without_mutation(self):
        outside = self.base / "outside"
        os.link(self.native, outside)
        with self.assertRaisesRegex(ValueError, "aliases outside"):
            normalize(self.server)
        self.assertEqual(self.native.stat().st_ino, self.shim.stat().st_ino)
        self.assertEqual(outside.stat().st_nlink, 3)

    def test_real_checkpoint_accepts_materialized_runtime(self):
        archive = self.base / "checkpoint.tar"
        with tarfile.open(archive, "w", dereference=False) as bundle:
            with self.assertRaisesRegex(ledger["LedgerError"], "hard-linked") as refused:
                ledger["_capture_checkpoint_tree"](bundle, str(self.server), privileged=False)
        # The refusal names the exact one-time recovery, and that command is what makes the retry pass.
        self.assertIn(f"normalize-native-links.py {self.server}", str(refused.exception))
        normalize(self.server)
        with tarfile.open(archive, "w", dereference=False) as bundle:
            self.assertEqual(ledger["_capture_checkpoint_tree"](bundle, str(self.server), privileged=False), [])
        with tarfile.open(archive) as bundle:
            files = [member for member in bundle.getmembers() if member.isfile()]
            self.assertEqual(len(files), 2)
            for member in files:
                self.assertEqual(bundle.extractfile(member).read(), b"native executable bytes")

    def test_refusal_outside_esbuild_gives_the_generic_recovery(self):
        other = self.base / "tree"
        other.mkdir()
        (other / "a").write_bytes(b"x")
        os.link(other / "a", other / "b")
        with tarfile.open(self.base / "other.tar", "w", dereference=False) as bundle:
            with self.assertRaisesRegex(ledger["LedgerError"], "hard-linked") as refused:
                ledger["_capture_checkpoint_tree"](bundle, str(other), privileged=False)
        self.assertIn("-samefile", str(refused.exception))
        self.assertNotIn("normalize-native-links.py", str(refused.exception))

    def _pair(self, root: Path) -> tuple[Path, Path]:
        native = root / "node_modules/@esbuild/linux-arm64/bin/esbuild"
        shim = root / "node_modules/esbuild/bin/esbuild"
        native.parent.mkdir(parents=True)
        shim.parent.mkdir(parents=True)
        native.write_bytes(b"n")
        os.link(native, shim)
        return native, shim

    def test_refusal_recognizes_only_the_exact_closed_esbuild_pair(self):
        refuse = ledger["_hard_link_refusal"]
        for path in (self.native, self.shim):
            self.assertIn(f"normalize-native-links.py {self.server}", refuse(str(path)))
        # the last node_modules decides: a nested package tree names its own directory
        nested = self.server / "node_modules/vite"
        native, shim = self._pair(nested)
        self.assertIn(f"normalize-native-links.py {nested}", refuse(str(shim)))
        for other in (f"{self.shim}/extra", str(self.native.parent / "other"),
                      str(self.server / "node_modules/@esbuild/bin/esbuild")):
            self.assertNotIn("normalize-native-links.py", refuse(other))

    def test_native_linked_outside_with_independent_shim_gets_generic_advice(self):
        # Review (Sol): the normalizer would be a no-op here, so its command must not be offered.
        self.shim.unlink()
        self.shim.write_bytes(b"shim")
        os.link(self.native, self.base / "outside")
        advice = ledger["_hard_link_refusal"](str(self.native))
        self.assertNotIn("normalize-native-links.py", advice)
        self.assertIn("-samefile", advice)

    def test_refusal_quotes_paths_it_asks_the_operator_to_run(self):
        hostile = self.base / "a b;$(touch pwned)"
        native, shim = self._pair(hostile)
        self.assertIn(f"'{hostile}'", ledger["_hard_link_refusal"](str(shim)))
        self.assertIn("-samefile '/srv/a b;$(x)/f'", ledger["_hard_link_refusal"]("/srv/a b;$(x)/f"))
        self.assertFalse((Path.cwd() / "pwned").exists())

    def test_redirected_parent_is_rejected(self):
        directory = self.shim.parent
        renamed = directory.with_name("saved")
        directory.rename(renamed)
        directory.symlink_to(renamed, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "redirected"):
            normalize(self.server)

    def test_install_wires_normalization_after_resolving_server(self):
        source = (ROOT / "apps/paseo/install.sh").read_text()
        self.assertIn('"$PY" "$HERE/normalize-native-links.py" "$PASEO_SERVER_DIR"', source)
        self.assertLess(source.index('PASEO_SERVER_DIR="$(paseo_server_dir)"'),
                        source.index('"$PY" "$HERE/normalize-native-links.py"'))


if __name__ == "__main__":
    unittest.main()
