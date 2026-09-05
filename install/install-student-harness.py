#!/usr/bin/env python3
"""Install the pinned external student harness into one user's home.

The repository carries plain projected inputs so the public leak gate can inspect
them. This installer validates those bytes, prepares every replacement off to the
side, completes one backup batch, then publishes the replacements. It never follows
a destination-parent symlink out of the selected home.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_HARNESS = ROOT / "docker" / "student-harness"
DEFAULT_STARTER = ROOT / "docker" / "project-starter"
DEFAULT_PROVENANCE = ROOT / "docker" / "student-harness-provenance.json"
FALLBACK_FQDN = "<이 박스의 tailnet 호스트>.ts.net"
FQDN_RE = re.compile(
    r"(?=.{1,253}\Z)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    r"(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\.ts\.net\Z"
)
PINNED_HARNESS_SOURCE = {
    "source_revision": "8e91faac6928ab0d4e9acd8f52d3452428c1644a",
    "source_archive_sha256": "a83d6e8c67fa13c0762a60c1c503f19781219ee2f273d5099cd293a7dafbbb34",
    "source_archive_bytes": 332773,
}
PINNED_STARTER_SOURCE = {
    "source_revision": "b9df44b1a9131a005fe782419461c0f72445a069",
}
PINNED_HARNESS_EXECUTABLES = (
    "hooks/secret-guard.sh",
    "hooks/session-close-reminder.sh",
    "hooks/session-start-restore.sh",
    "skills/cad-read/scripts/cadread.py",
    "skills/crawling-scraping/scripts/yt-transcript.py",
    "skills/excel-io/scripts/xlsx.py",
    "skills/session-close/scripts/retire-worktree.sh",
    "skills/share-docs/scripts/css-collision-lint.py",
    "skills/share-docs/scripts/doc-contract-lint.py",
    "skills/worktree/scripts/create-worktree.sh",
)
PINNED_STARTER_EXECUTABLES = (
    ".claude/hooks/secret-scan.sh",
    ".claude/hooks/typecheck.sh",
    ".claude/hooks/verify-turn.sh",
    "setup.sh",
)

TARGETS = (
    Path(".claude/CLAUDE.md"),
    Path(".claude/settings.json"),
    Path(".claude/skills"),
    Path(".claude/hooks"),
    Path(".codex/AGENTS.md"),
    Path(".agents/skills"),
    Path("workspace/templates"),
)
PARENT_ROOTS = (
    Path(".claude"), Path(".codex"), Path(".agents"), Path("workspace"),
    Path(".local"), Path(".local/state"), Path(".local/state/airlock"),
    Path(".local/state/airlock/harness-backups"),
)


class InstallError(RuntimeError):
    pass


def lexists(path: Path) -> bool:
    return os.path.lexists(path)


def is_generated_cache(path: Path) -> bool:
    return "__pycache__" in path.parts


def tree_digest(root: Path) -> str:
    """Hash file paths, executable bits, symlink targets and bytes."""
    digest = hashlib.sha256()
    paths = sorted(
        (path for path in root.rglob("*") if not is_generated_cache(path.relative_to(root))),
        key=lambda p: p.relative_to(root).as_posix(),
    )
    for path in paths:
        rel = path.relative_to(root).as_posix().encode()
        if path.is_symlink():
            digest.update(b"L\0" + rel + b"\0" + os.readlink(path).encode() + b"\0")
        elif path.is_file():
            data = path.read_bytes()
            executable = b"1" if path.stat().st_mode & stat.S_IXUSR else b"0"
            digest.update(
                b"F\0" + rel + b"\0" + executable + b"\0"
                + str(len(data)).encode() + b"\0" + data
            )
    return digest.hexdigest()


def projected_path_count(root: Path) -> int:
    return sum(
        1 for p in root.rglob("*")
        if not is_generated_cache(p.relative_to(root)) and (p.is_file() or p.is_symlink())
    )


def validated_executable_paths(meta: dict, root: Path, label: str) -> tuple[Path, ...]:
    raw = meta.get("executable_paths")
    if not isinstance(raw, list) or raw != sorted(set(raw)):
        raise InstallError(f"{label} executable path list is missing, duplicated or unsorted")
    paths = []
    for value in raw:
        if not isinstance(value, str):
            raise InstallError(f"{label} executable path is not text")
        relative = Path(value)
        if relative.is_absolute() or ".." in relative.parts or str(relative) != value:
            raise InstallError(f"unsafe {label} executable path: {value}")
        source = root / relative
        if not source.is_file() or source.is_symlink():
            raise InstallError(f"{label} executable path is not a regular file: {value}")
        paths.append(relative)
    return tuple(paths)


def load_and_validate_inputs(harness: Path, starter: Path, provenance_path: Path) -> dict:
    for label, path in (("harness", harness), ("starter", starter)):
        if not path.is_dir() or path.is_symlink():
            raise InstallError(f"{label} projection is missing or unsafe: {path}")
    try:
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        settings = json.loads((harness / "settings.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, KeyError) as exc:
        raise InstallError(f"harness metadata is unreadable: {exc}") from exc
    if provenance.get("schema") != "airlock.student-harness-provenance/v1":
        raise InstallError("unknown student harness provenance schema")

    harness_meta = provenance.get("harness") or {}
    starter_meta = provenance.get("starter") or {}
    for key, expected in PINNED_HARNESS_SOURCE.items():
        if harness_meta.get(key) != expected:
            raise InstallError(f"harness source pin drifted at {key}")
    for key, expected in PINNED_STARTER_SOURCE.items():
        if starter_meta.get(key) != expected:
            raise InstallError(f"starter source pin drifted at {key}")
    skills = sum(
        1 for p in (harness / "skills").iterdir()
        if p.is_dir() and not p.is_symlink() and (p / "SKILL.md").is_file()
    )
    hooks = sum(1 for p in (harness / "hooks").iterdir() if p.is_file() and not p.is_symlink())
    actual = {
        "files": projected_path_count(harness),
        "skills": skills,
        "hooks": hooks,
        "deny_rules": len(settings["permissions"]["deny"]),
        "ask_rules": len(settings["permissions"]["ask"]),
        "projection_sha256": tree_digest(harness),
    }
    for key, value in actual.items():
        if harness_meta.get(key) != value:
            raise InstallError(
                f"harness projection drifted at {key}: got {value}, expected {harness_meta.get(key)}"
            )
    starter_actual = {
        "files": projected_path_count(starter),
        "projection_sha256": tree_digest(starter),
    }
    for key, value in starter_actual.items():
        if starter_meta.get(key) != value:
            raise InstallError(
                f"starter projection drifted at {key}: got {value}, expected {starter_meta.get(key)}"
            )
    harness_executables = validated_executable_paths(harness_meta, harness, "harness")
    starter_executables = validated_executable_paths(starter_meta, starter, "starter")
    if tuple(str(path) for path in harness_executables) != PINNED_HARNESS_EXECUTABLES:
        raise InstallError("harness executable path contract drifted")
    if tuple(str(path) for path in starter_executables) != PINNED_STARTER_EXECUTABLES:
        raise InstallError("starter executable path contract drifted")
    projected_agents = harness / "AGENTS.md"
    if projected_agents.is_symlink() or not projected_agents.is_file() \
            or projected_agents.read_bytes() != (harness / "CLAUDE.md").read_bytes():
        raise InstallError("projected AGENTS.md is not the download archive's CLAUDE.md copy")
    for path in harness.rglob("*"):
        if path.is_symlink():
            raise InstallError(f"unexpected symlink in harness projection: {path.relative_to(harness)}")
    if any(path.is_symlink() for path in starter.rglob("*")):
        raise InstallError("starter projection contains a symlink")
    return provenance


def detect_fqdn(explicit: str | None) -> str:
    candidate = (explicit or "").strip().rstrip(".")
    if explicit is None:
        try:
            result = subprocess.run(
                ["tailscale", "status", "--json"], check=True,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10,
            )
            data = json.loads(result.stdout)
            candidate = str((data.get("Self") or {}).get("DNSName") or "").strip().rstrip(".")
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
            candidate = ""
    return candidate if FQDN_RE.fullmatch(candidate) else FALLBACK_FQDN


def copy_path(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        destination.symlink_to(os.readlink(source))
    elif source.is_dir():
        shutil.copytree(source, destination, symlinks=True)
    else:
        shutil.copy2(source, destination, follow_symlinks=False)


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def ensure_safe_parents(home: Path) -> None:
    if home == Path("/") or not home.is_dir() or home.is_symlink():
        raise InstallError(f"selected home is missing or unsafe: {home}")
    for relative in PARENT_ROOTS:
        current = home / relative
        if current.is_symlink():
            raise InstallError(f"destination parent is a symlink: {current}")
        if lexists(current) and not current.is_dir():
            # The backup root gets a dedicated actionable error below; every other
            # non-directory parent is equally unsafe to traverse.
            if relative != Path(".local/state/airlock/harness-backups"):
                raise InstallError(f"destination parent is not a directory: {current}")


def merge_personal_entries(existing: Path, staged: Path) -> None:
    if not existing.is_dir() or existing.is_symlink():
        return
    for source in existing.iterdir():
        destination = staged / source.name
        if not lexists(destination):
            copy_path(source, destination)


def prepare_stage(
    home: Path, harness: Path, starter: Path, provenance: dict, fqdn: str,
) -> Path:
    stage = Path(tempfile.mkdtemp(prefix=".airlock-harness-stage-", dir=home))
    try:
        claude = stage / ".claude"
        codex = stage / ".codex"
        agents = stage / ".agents"
        workspace = stage / "workspace"
        for path in (claude, codex, agents, workspace):
            path.mkdir(parents=True, exist_ok=True)

        source_rules = (harness / "CLAUDE.md").read_text(encoding="utf-8")
        preamble = (
            "# 외부 접속 개발서버\n\n"
            f"이 박스는 외부 접속 개발서버입니다. 문서·개발서버·링크는 `{fqdn}` 주소로 전달합니다.\n\n"
        )
        (claude / "CLAUDE.md").write_text(preamble + source_rules, encoding="utf-8")
        shutil.copy2(harness / "settings.json", claude / "settings.json")
        shutil.copytree(
            harness / "skills", claude / "skills", symlinks=True,
            ignore=shutil.ignore_patterns("__pycache__"),
        )
        shutil.copytree(harness / "hooks", claude / "hooks", symlinks=True)
        merge_personal_entries(home / ".claude/skills", claude / "skills")
        merge_personal_entries(home / ".claude/hooks", claude / "hooks")
        for relative in validated_executable_paths(
            provenance["harness"], harness, "harness"
        ):
            (claude / relative).chmod(0o755)
        (codex / "AGENTS.md").symlink_to("../.claude/CLAUDE.md")
        (agents / "skills").symlink_to("../.claude/skills")

        template_seed = stage / ".project-starter-seed"
        template = workspace / "templates"
        shutil.copytree(starter, template_seed, symlinks=False)
        for relative in validated_executable_paths(
            provenance["starter"], starter, "starter"
        ):
            (template_seed / relative).chmod(0o755)
        marker = {
            "schema": "airlock.project-starter-source/v1",
            "source_revision": provenance["starter"]["source_revision"],
            "projection_sha256": provenance["starter"]["projection_sha256"],
        }
        (template_seed / ".airlock-source.json").write_text(
            json.dumps(marker, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        env = os.environ.copy()
        env.update({
            "GIT_AUTHOR_NAME": "Airlock Installer",
            "GIT_AUTHOR_EMAIL": "installer@example.invalid",
            "GIT_COMMITTER_NAME": "Airlock Installer",
            "GIT_COMMITTER_EMAIL": "installer@example.invalid",
            "GIT_AUTHOR_DATE": "2026-01-01T00:00:00+00:00",
            "GIT_COMMITTER_DATE": "2026-01-01T00:00:00+00:00",
        })
        subprocess.run(["git", "init", "-q", "-b", "main", str(template_seed)], check=True, env=env)
        subprocess.run(["git", "-C", str(template_seed), "add", "."], check=True, env=env)
        subprocess.run(
            ["git", "-C", str(template_seed), "-c", "core.hooksPath=/dev/null",
             "commit", "-q", "-m", "Pinned Airlock project starter"],
            check=True, env=env,
        )
        subprocess.run(
            ["git", "clone", "-q", "--no-hardlinks", str(template_seed), str(template)],
            check=True, env=env,
        )
        subprocess.run(
            ["git", "-C", str(template), "remote", "remove", "origin"], check=True, env=env
        )
        shutil.rmtree(template_seed)
        return stage
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def make_backup(home: Path) -> tuple[Path, set[Path]]:
    backup_root = home / ".local/state/airlock/harness-backups"
    backup_root.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    pending = backup_root / f".{stamp}.{os.getpid()}.pending"
    final = backup_root / stamp
    pending.mkdir(mode=0o700)
    existed: set[Path] = set()
    try:
        for relative in TARGETS:
            source = home / relative
            if lexists(source):
                copy_path(source, pending / relative)
                existed.add(relative)
        (pending / "backup-manifest.json").write_text(
            json.dumps({"paths": [str(p) for p in sorted(existed)]}, indent=2) + "\n",
            encoding="utf-8",
        )
        os.replace(pending, final)
        return final, existed
    except Exception:
        shutil.rmtree(pending, ignore_errors=True)
        raise


def publish(home: Path, stage: Path, backup: Path, existed: set[Path]) -> None:
    changed: list[Path] = []
    try:
        for relative in TARGETS:
            source = stage / relative
            destination = home / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if lexists(destination):
                remove_path(destination)
            # Once the old destination is gone it belongs to the rollback set,
            # even if the following atomic publish itself fails. Appending only
            # after os.replace() loses exactly the destination that failed.
            changed.append(relative)
            os.replace(source, destination)
    except Exception as exc:
        rollback_errors = []
        for relative in reversed(changed):
            destination = home / relative
            try:
                if lexists(destination):
                    remove_path(destination)
                if relative in existed:
                    copy_path(backup / relative, destination)
            except Exception as rollback_exc:  # pragma: no cover - catastrophic disk failure
                rollback_errors.append(f"{relative}: {rollback_exc}")
        detail = f"publish failed and live destinations were rolled back: {exc}"
        if rollback_errors:
            detail += "; rollback errors: " + "; ".join(rollback_errors)
        raise InstallError(detail) from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--home", default=str(Path.home()))
    parser.add_argument("--fqdn", default=None)
    parser.add_argument("--harness", default=str(DEFAULT_HARNESS))
    parser.add_argument("--starter", default=str(DEFAULT_STARTER))
    parser.add_argument("--provenance", default=str(DEFAULT_PROVENANCE))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    home = Path(args.home).expanduser().absolute()
    harness = Path(args.harness).expanduser().absolute()
    starter = Path(args.starter).expanduser().absolute()
    provenance_path = Path(args.provenance).expanduser().absolute()
    try:
        provenance = load_and_validate_inputs(harness, starter, provenance_path)
        if args.check:
            print("student harness inputs: ok")
            return 0
        ensure_safe_parents(home)
        fqdn = detect_fqdn(args.fqdn)
        stage = prepare_stage(home, harness, starter, provenance, fqdn)
        try:
            backup, existed = make_backup(home)
            publish(home, stage, backup, existed)
        finally:
            shutil.rmtree(stage, ignore_errors=True)
    except (InstallError, OSError, subprocess.SubprocessError, KeyError, ValueError) as exc:
        print(f"student harness: {exc}", file=sys.stderr)
        return 1
    print(f"student harness installed for {home.name}; backup: {backup}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
