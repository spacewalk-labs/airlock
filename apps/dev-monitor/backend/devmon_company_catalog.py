"""Read and stage a pinned private package catalog using the box's Git credentials.

The catalog repository is optional configuration. A box that cannot fetch it exposes an
empty company list; it never turns authentication failure into backend failure. Installing
one selected row is stricter: the pinned commit is copied to an immutable stage directory
and the platform ledger's tree digest must match before the path can reach the config writer.
"""
from __future__ import annotations

import hashlib
import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib
import urllib.parse
from pathlib import Path, PurePosixPath
from typing import Any


APP_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}\Z")
SHA = re.compile(r"^[0-9a-f]{40}\Z")
DIGEST = re.compile(r"^[0-9a-f]{64}\Z")
REPO_SLUG = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
SCP_REPOSITORY = re.compile(
    r"^[A-Za-z0-9_.-]+@[A-Za-z0-9.-]+:[A-Za-z0-9_./-]+(?:\.git)?\Z")
ROW_KEYS = {
    "id", "repo", "commit", "tree_digest", "label", "sub", "installable", "reason",
}
NON_INSTALLABLE_REASONS = {"build_artifact", "source_tree_digest_mismatch"}


class CatalogError(RuntimeError):
    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(detail or code)
        self.code = code
        self.detail = detail


def _safe_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or any(ch in value for ch in "\0\r\n"):
        raise CatalogError("catalog_invalid", f"{label} must be a non-empty single line")
    return value


def _safe_sub(value: Any) -> str:
    value = _safe_text(value, "sub")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or not path.parts or "." in path.parts:
        raise CatalogError("catalog_invalid", "sub must be a safe repository-relative path")
    return value


def _validate_row(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict) or set(raw) != ROW_KEYS:
        raise CatalogError("catalog_invalid", "catalog row has an unknown shape")
    app_id = raw.get("id")
    commit = raw.get("commit")
    digest = raw.get("tree_digest")
    if not isinstance(app_id, str) or APP_ID.fullmatch(app_id) is None:
        raise CatalogError("catalog_invalid", "catalog row has an invalid id")
    if not isinstance(commit, str) or SHA.fullmatch(commit) is None:
        raise CatalogError("catalog_invalid", f"{app_id}: commit must be full lowercase SHA-1")
    if not isinstance(digest, str) or DIGEST.fullmatch(digest) is None:
        raise CatalogError("catalog_invalid", f"{app_id}: tree_digest must be lowercase SHA-256")
    installable = raw.get("installable")
    reason = raw.get("reason")
    if not isinstance(installable, bool):
        raise CatalogError("catalog_invalid", f"{app_id}: installable must be boolean")
    if installable and reason is not None:
        raise CatalogError("catalog_invalid", f"{app_id}: installable row cannot have a reason")
    if not installable and reason not in NON_INSTALLABLE_REASONS:
        raise CatalogError("catalog_invalid", f"{app_id}: non-installable reason is invalid")
    return {
        "id": app_id,
        "repo": _safe_text(raw.get("repo"), "repo"),
        "commit": commit,
        "tree_digest": digest,
        "label": _safe_text(raw.get("label"), "label"),
        "sub": _safe_sub(raw.get("sub")),
        "installable": installable,
        "reason": reason,
    }


def _decode_catalog(raw: bytes) -> list[dict[str, Any]]:
    try:
        document = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CatalogError("catalog_invalid", str(exc)) from exc
    if not isinstance(document, dict) or set(document) != {"schema_version", "apps"} \
            or document.get("schema_version") != 1 or not isinstance(document.get("apps"), list):
        raise CatalogError("catalog_invalid", "catalog document has an unknown shape")
    rows = [_validate_row(row) for row in document["apps"]]
    ids = [row["id"] for row in rows]
    if ids != sorted(ids) or len(ids) != len(set(ids)):
        raise CatalogError("catalog_invalid", "catalog ids must be unique and sorted")
    return rows


def _settings(config: Path) -> dict[str, Any]:
    try:
        document = tomllib.loads(Path(config).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise CatalogError("config_unavailable", str(exc)) from exc
    apps = document.get("apps") if isinstance(document, dict) else None
    block = apps.get("dev-monitor") if isinstance(apps, dict) else None
    block = block if isinstance(block, dict) else {}
    repository = os.environ.get(
        "AIRLOCK_DEV_MONITOR_COMPANY_CATALOG_REPOSITORY",
        block.get("company_catalog_repository", ""),
    )
    if repository == "":
        return {"repository": "", "ref": "main", "stage": _default_stage()}
    repository = _repository_url(repository, code="config_unavailable")
    ref = _safe_text(
        os.environ.get("AIRLOCK_DEV_MONITOR_COMPANY_CATALOG_REF",
                       block.get("company_catalog_ref", "main")),
        "company_catalog_ref",
    )
    if ref.startswith("-"):
        raise CatalogError("config_unavailable", "catalog ref cannot start with '-'")
    stage_value = os.environ.get(
        "AIRLOCK_DEV_MONITOR_COMPANY_CATALOG_STAGE",
        block.get("company_catalog_stage", ""),
    )
    stage = _default_stage() if stage_value == "" else Path(
        os.path.expandvars(os.path.expanduser(_safe_text(stage_value, "company_catalog_stage"))))
    if not stage.is_absolute():
        raise CatalogError("config_unavailable", "company catalog stage must be absolute")
    return {"repository": repository, "ref": ref, "stage": stage}


def _default_stage() -> Path:
    state = os.environ.get("AIRLOCK_STATE_DIR", "").strip()
    base = Path(os.path.expanduser(state)) if state else Path.home() / ".local/state/airlock"
    return base / "company-catalog"


def _git(args: list[str], *, cwd: Path | None = None, timeout: int = 90) -> bytes:
    env = os.environ.copy()
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GCM_INTERACTIVE"] = "never"
    try:
        result = subprocess.run(
            ["git", *args], cwd=str(cwd) if cwd is not None else None, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CatalogError("catalog_unavailable", str(exc)) from exc
    if result.returncode:
        raise CatalogError("catalog_unavailable", result.stderr.decode(errors="replace").strip())
    return result.stdout


def list_catalog(config: Path) -> list[dict[str, Any]]:
    settings = _settings(config)
    if not settings["repository"]:
        return []
    with tempfile.TemporaryDirectory(prefix="airlock-company-catalog-") as temporary:
        checkout = Path(temporary) / "catalog"
        try:
            _git(["clone", "--quiet", "--depth=1", "--branch", settings["ref"], "--",
                  settings["repository"], str(checkout)])
            raw = (checkout / "catalog.json").read_bytes()
        except (CatalogError, OSError):
            # Absence of usable Git credentials is a normal capability difference between
            # boxes. Do not leak transport diagnostics or turn the tab into an error page.
            return []
    return _decode_catalog(raw)


def _repository_url(value: str, *, code: str = "catalog_invalid") -> str:
    value = _safe_text(value, "repo")
    if REPO_SLUG.fullmatch(value):
        return f"git@github.com:{value}.git"
    if SCP_REPOSITORY.fullmatch(value):
        return value
    if os.path.isabs(value):
        return value
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme in {"https", "ssh"} and parsed.netloc and not parsed.username == "-":
        return value
    if parsed.scheme == "file" and parsed.path.startswith("/"):
        return value
    # In particular reject Git's ext::<command> transport: a catalog is data, not
    # authority to execute a remote helper before its tree digest can be checked.
    raise CatalogError(code, "repository must be a slug or an https/ssh/file Git URL")


def _ensure_real_directory(path: Path, mode: int) -> None:
    try:
        path.mkdir(parents=True, mode=mode, exist_ok=True)
    except OSError as exc:
        raise CatalogError("stage_unavailable", str(exc)) from exc
    if path.is_symlink() or not path.is_dir():
        raise CatalogError("stage_unavailable", f"stage directory is not a real directory: {path}")


def _load_digest(root: Path, package: Path) -> str:
    ledger = Path(root) / "bin" / "airlock-ledger"
    if not ledger.is_file() or ledger.is_symlink():
        raise CatalogError("stage_unavailable", "platform ledger is unavailable")
    name = "airlock_company_catalog_ledger_" + hashlib.sha256(
        os.fspath(ledger).encode()).hexdigest()[:12]
    loader = importlib.machinery.SourceFileLoader(name, str(ledger))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise CatalogError("stage_unavailable", "platform ledger cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    old = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        loader.exec_module(module)
        value = module.digest_tree(str(package))
    except Exception as exc:  # preserve the platform runtime's refusal as a closed error
        raise CatalogError("stage_unavailable", str(exc)) from exc
    finally:
        sys.dont_write_bytecode = old
    if not isinstance(value, str) or DIGEST.fullmatch(value) is None:
        raise CatalogError("stage_unavailable", "platform ledger returned an invalid digest")
    return value


def _normalise_checkout_modes(root: Path) -> None:
    """Reproduce the composite lock's portable checkout modes.

    Git stores only regular/executable file mode. The composite package lock uses 0644/0755
    files and group-traversable 0775 directories, independent of the checkout umask.
    """
    for path in root.rglob("*"):
        if path.is_symlink():
            continue
        mode = path.stat().st_mode
        if stat.S_ISDIR(mode):
            path.chmod(0o775)
        elif stat.S_ISREG(mode):
            path.chmod(0o755 if mode & 0o111 else 0o644)


def stage_entry(root: Path, config: Path, raw: dict[str, Any]) -> Path:
    entry = _validate_row(raw)
    if not entry["installable"]:
        raise CatalogError("catalog_not_installable", entry["reason"])
    settings = _settings(config)
    if not settings["repository"]:
        raise CatalogError("catalog_unavailable", "company catalog is not configured")
    stage = Path(settings["stage"])
    destination = (stage / "packages" / entry["id"] /
                   f"{entry['commit']}-{entry['tree_digest']}")
    if destination.is_dir() and not destination.is_symlink():
        observed = _load_digest(root, destination)
        if observed == entry["tree_digest"]:
            return destination
        raise CatalogError("digest_mismatch", "existing immutable stage differs")

    packages_root = stage / "packages"
    packages = destination.parent
    try:
        _ensure_real_directory(stage, 0o700)
        _ensure_real_directory(packages_root, 0o700)
        _ensure_real_directory(packages, 0o700)
        temporary = Path(tempfile.mkdtemp(prefix=f".{entry['id']}.", dir=packages))
    except OSError as exc:
        raise CatalogError("stage_unavailable", str(exc)) from exc
    try:
        checkout = temporary / "repo"
        _git(["clone", "--quiet", "--no-checkout", "--", _repository_url(entry["repo"]),
              str(checkout)])
        _git(["fetch", "--quiet", "--depth=1", "origin", entry["commit"]], cwd=checkout)
        _git(["checkout", "--quiet", "--detach", entry["commit"]], cwd=checkout)
        resolved = _git(["rev-parse", "HEAD"], cwd=checkout).decode().strip()
        if resolved != entry["commit"]:
            raise CatalogError("catalog_invalid", "fetched commit differs from catalog pin")
        source = checkout.joinpath(*PurePosixPath(entry["sub"]).parts)
        if not source.is_dir() or source.is_symlink():
            raise CatalogError("catalog_invalid", "pinned source subdirectory is absent")
        candidate = temporary / "package"
        shutil.copytree(source, candidate, symlinks=True)
        _normalise_checkout_modes(candidate)
        observed = _load_digest(root, candidate)
        if observed != entry["tree_digest"]:
            raise CatalogError(
                "digest_mismatch",
                f"staged package digest differs: expected {entry['tree_digest']}, got {observed}",
            )
        try:
            os.replace(candidate, destination)
        except FileExistsError:
            if not destination.is_dir() or destination.is_symlink() \
                    or _load_digest(root, destination) != entry["tree_digest"]:
                raise CatalogError("digest_mismatch", "concurrent immutable stage differs")
        return destination
    except CatalogError:
        raise
    except OSError as exc:
        raise CatalogError("stage_unavailable", str(exc)) from exc
    finally:
        shutil.rmtree(temporary, ignore_errors=True)
