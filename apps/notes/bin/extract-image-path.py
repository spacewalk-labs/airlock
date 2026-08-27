#!/usr/bin/env python3
"""Materialize one directory from a docker-save archive without creating a container."""

from __future__ import annotations

import argparse
import io
import json
import os
import shutil
import tarfile
from pathlib import Path, PurePosixPath


PREFIX = PurePosixPath("var/www/perlite")


def relative_member(name: str) -> PurePosixPath | None:
    path = PurePosixPath(name.removeprefix("./"))
    if path == PREFIX:
        return PurePosixPath(".")
    try:
        return path.relative_to(PREFIX)
    except ValueError:
        return None


def destination(root: Path, relative: PurePosixPath) -> Path:
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"unsafe layer path: {relative}")
    return root.joinpath(*relative.parts)


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.is_dir():
        shutil.rmtree(path)


def apply_layer(layer_bytes: bytes, root: Path) -> None:
    with tarfile.open(fileobj=io.BytesIO(layer_bytes), mode="r:*") as layer:
        members = layer.getmembers()
        for member in members:
            relative = relative_member(member.name)
            if relative is None or relative == PurePosixPath("."):
                continue
            basename = relative.name
            if not basename.startswith(".wh."):
                continue
            parent = destination(root, relative.parent)
            if basename == ".wh..wh..opq":
                if parent.is_dir():
                    for child in parent.iterdir():
                        remove_path(child)
            else:
                remove_path(parent / basename.removeprefix(".wh."))
        for member in members:
            relative = relative_member(member.name)
            if relative is None or relative == PurePosixPath("."):
                continue
            if relative.name.startswith(".wh."):
                continue
            target = destination(root, relative)
            target.parent.mkdir(parents=True, exist_ok=True)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                os.chmod(target, member.mode & 0o777)
            elif member.isfile():
                source = layer.extractfile(member)
                if source is None:
                    raise ValueError(f"missing layer payload: {member.name}")
                remove_path(target)
                with target.open("wb") as handle:
                    shutil.copyfileobj(source, handle)
                os.chmod(target, member.mode & 0o777)
            elif member.issym():
                link = PurePosixPath(member.linkname)
                if link.is_absolute() or ".." in link.parts:
                    raise ValueError(f"unsafe symlink in image: {member.name}")
                remove_path(target)
                target.symlink_to(member.linkname)
            elif member.islnk():
                source_relative = relative_member(member.linkname)
                if source_relative is None:
                    raise ValueError(f"hardlink leaves extracted root: {member.name}")
                source_path = destination(root, source_relative)
                remove_path(target)
                os.link(source_path, target)
            else:
                raise ValueError(f"unsupported layer member type: {member.name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=False)
    with tarfile.open(args.archive, mode="r:*") as archive:
        manifest_member = archive.getmember("manifest.json")
        manifest_file = archive.extractfile(manifest_member)
        if manifest_file is None:
            raise ValueError("docker archive has no manifest payload")
        manifest = json.load(manifest_file)
        if not isinstance(manifest, list) or len(manifest) != 1:
            raise ValueError("docker archive must contain exactly one image")
        for layer_name in manifest[0].get("Layers", []):
            layer_member = archive.getmember(layer_name)
            layer_file = archive.extractfile(layer_member)
            if layer_file is None:
                raise ValueError(f"docker archive layer missing: {layer_name}")
            apply_layer(layer_file.read(), args.destination)
    if not (args.destination / "index.php").is_file():
        raise ValueError("extracted Perlite root has no index.php")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
