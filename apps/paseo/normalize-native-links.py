"""Materialize esbuild's closed native/shim hardlink pair for rollback archives.

Paseo runtime files are immutable installation inputs. Keep checkpoint hardlink
rejection intact; npm's storage optimization must not make the runtime unbackupable.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile


def normalize(server: Path) -> int:
    if server.is_symlink():
        raise ValueError("Paseo server root must not be a symlink")
    root = server.resolve(strict=True)
    shim = root / "node_modules/esbuild/bin/esbuild"
    if not os.path.lexists(shim):
        return 0

    def inspect(path: Path) -> os.stat_result:
        for parent in [path, *path.parents]:
            if parent == root:
                break
            if parent.is_symlink():
                raise ValueError("native binary path is redirected")
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise ValueError("native binary is not an owned regular file")
        return info

    original = inspect(shim)
    if original.st_nlink == 1:
        return 0
    candidates = list((root / "node_modules/@esbuild").glob("*/bin/esbuild"))
    pair = []
    for path in candidates:
        info = inspect(path)
        if (info.st_dev, info.st_ino) == (original.st_dev, original.st_ino):
            pair.append(path)
    if len(pair) != 1 or original.st_nlink != 2:
        raise ValueError("native binary has aliases outside its closed esbuild pair")
    native = pair[0]
    descriptor, temporary = tempfile.mkstemp(prefix=".airlock-native-", dir=shim.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            with os.fdopen(os.open(shim, os.O_RDONLY | os.O_NOFOLLOW), "rb") as source:
                opened = os.fstat(source.fileno())
                if (opened.st_dev, opened.st_ino, opened.st_nlink) != (original.st_dev, original.st_ino, 2):
                    raise ValueError("native binary changed before materialization")
                shutil.copyfileobj(source, output)
            os.fchown(output.fileno(), original.st_uid, original.st_gid)
            os.fchmod(output.fileno(), stat.S_IMODE(original.st_mode))
            output.flush()
            os.fsync(output.fileno())
        os.utime(temporary, ns=(original.st_atime_ns, original.st_mtime_ns))
        for path in [native, shim]:
            current = inspect(path)
            if (current.st_dev, current.st_ino, current.st_nlink) != (original.st_dev, original.st_ino, 2):
                raise ValueError("native binary changed during materialization")
        os.replace(temporary, shim)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)
    return 1


if __name__ == "__main__":
    try:
        count = normalize(Path(sys.argv[1]))
    except (OSError, ValueError) as exc:
        print(f"Paseo native link normalization failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
    if count:
        print("Paseo esbuild native binary materialized for rollback checkpoints")
