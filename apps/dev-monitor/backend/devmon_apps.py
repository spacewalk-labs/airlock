"""Owner app-store projections and the single ``airlock.toml`` writer.

The writer deliberately does not serialize TOML.  Re-serializing the operator's
file would discard its comments and ordering. It adds app registration intent and,
when disabling, removes both its ``[apps.<id>]`` subtree and any explicit
``[packages.<id>]`` registration. It validates a sibling candidate with the platform's
canonical parser, keeps one previous copy, and only then swaps the candidate into place.
"""
from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
import tomllib
from pathlib import Path
from typing import Any


APP_ID = re.compile(r"\A[a-z0-9][a-z0-9-]{0,31}\Z")
_WRITE_LOCK = threading.Lock()


class AppsError(RuntimeError):
    """A stable error code plus a diagnostic suitable for the server log."""

    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(detail or code)
        self.code = code
        self.detail = detail


def default_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _checked_id(app_id: str) -> str:
    if not isinstance(app_id, str) or APP_ID.fullmatch(app_id) is None:
        raise AppsError("bad_app_id")
    return app_id


def _command(root: Path, args: list[str], *, config: Path | None = None,
             json_output: bool = False) -> Any:
    env = os.environ.copy()
    # Snapshot authority belongs to an installer process.  It must never leak into a
    # later owner request and make airlock-config authenticate the wrong pathname.
    for name in ("AIRLOCK_CONFIG_SNAPSHOT", "AIRLOCK_CONFIG_SNAPSHOT_SHA256",
                 "AIRLOCK_INSTALL_PKG_INFO_SHA256"):
        env.pop(name, None)
    if config is not None:
        env["AIRLOCK_CONFIG"] = str(config)
    argv = [sys.executable, str(root / "bin" / "airlock-config"), *args]
    try:
        result = subprocess.run(argv, cwd=str(root), env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise AppsError("config_unavailable", str(exc)) from exc
    if result.returncode:
        raise AppsError("config_invalid", result.stderr.strip())
    if not json_output:
        return result.stdout
    try:
        value = json.loads(result.stdout)
    except ValueError as exc:
        raise AppsError("config_unavailable", "airlock-config returned non-JSON") from exc
    if not isinstance(value, dict):
        raise AppsError("config_unavailable", "airlock-config returned an unknown shape")
    return value


def config_path(root: Path) -> Path:
    # The installed unit passes the exact config used by the installer.  Prefer that
    # authority directly: package-info is deliberately lock-strict, so asking it to
    # rediscover the same path makes the one operation that repairs a digest mismatch
    # impossible.  The fallback keeps source-tree/test launches without the installed
    # unit environment working as before.
    configured = os.environ.get("AIRLOCK_CONFIG")
    if configured:
        path = Path(configured).expanduser()
        if not path.is_absolute():
            raise AppsError(
                "config_unavailable", "AIRLOCK_CONFIG must be an absolute path")
        return path.resolve()
    try:
        info = _command(root, ["package-info"], json_output=True)
    except AppsError as exc:
        # package-info is deliberately lock-strict, but its answer about where the
        # operator config lives is still needed by the one action that repairs that
        # lock. Match airlock-config's no-environment discovery from cwd=root, and do
        # so only for its exact package-lock refusal. Every other discovery failure
        # remains closed.
        if (exc.code != "config_invalid"
                or "package lock digest mismatch" not in exc.detail):
            raise
        for base in [root, *root.parents]:
            candidate = base / "airlock.toml"
            if candidate.exists():
                return candidate.resolve()
        raise
    value = info.get("config_path")
    if not isinstance(value, str) or not value:
        raise AppsError("config_unavailable", "package-info omitted config_path")
    return Path(value)


def package_preview(root: Path, path: str) -> dict[str, Any]:
    """Return the canonical read-only preview for one local package path."""
    if not isinstance(path, str) or not path.strip():
        raise AppsError("bad_package_path")
    return _command(Path(root).resolve(), ["package-preview", path], json_output=True)


def _update_map(updates: Any) -> dict[str, dict[str, Any]]:
    rows = updates.get("apps") if isinstance(updates, dict) else None
    if not isinstance(rows, list):
        return {}
    return {row["id"]: row for row in rows
            if isinstance(row, dict) and isinstance(row.get("id"), str)}


def _lock_mismatch_projection(error: AppsError, updates: Any) -> dict[str, Any] | None:
    """Keep the review surface reachable when the strict config reader refuses a lock.

    ``airlock-config json`` intentionally fails closed after an explicit package's
    bytes move. Its own diagnostic is the authority for the degraded row, so the app
    sheet stays reachable before the daily update collector has produced a snapshot.
    Never calculate another digest or turn a different config error into a partial
    inventory.
    """
    if error.code != "config_invalid" or "package lock digest mismatch" not in error.detail:
        return None
    rows = [row for row in _update_map(updates).values()
            if row.get("action") == "lock-mismatch"
            and APP_ID.fullmatch(row["id"]) is not None]
    match = re.search(
        r"package '([a-z0-9][a-z0-9-]{0,31})': package lock digest mismatch",
        error.detail)
    if match is not None and all(row["id"] != match.group(1) for row in rows):
        rows.append({"id": match.group(1), "action": "lock-mismatch",
                     "sourceClass": "explicit"})
    if not rows:
        return None
    rows.sort(key=lambda value: value["id"])
    update_doc = dict(updates) if isinstance(updates, dict) else {}
    existing = update_doc.get("apps")
    existing = existing if isinstance(existing, list) else []
    mismatch_ids = {row["id"] for row in rows}
    update_doc["apps"] = [row for row in existing
                          if not (isinstance(row, dict)
                                  and row.get("id") in mismatch_ids)] + rows
    installed = [{
        "id": row["id"],
        "config": {},
        "tile": None,
        "source": "explicit",
        "digest": None,
        "capabilities": [],
        "canRemove": False,
        "update": row,
    } for row in rows]
    return {"apps": {}, "installed": installed, "public": [],
            "updates": update_doc,
            "degraded": "lock-mismatch"}


def list_apps(root: Path, updates: Any) -> dict[str, Any]:
    """Return installed apps, uninstalled shipped apps, and the update snapshot.

    Installed values come from ``airlock-config json`` rather than a second TOML
    reader.  The public set is exactly ``known-builtins - installed``.  ``catalog``
    contributes presentation metadata only; it cannot add an id to that set.
    """
    root = Path(root).resolve()
    try:
        resolved = _command(root, ["json"], json_output=True)
    except AppsError as exc:
        degraded = _lock_mismatch_projection(exc, updates)
        if degraded is not None:
            return degraded
        raise
    apps = resolved.get("apps")
    if not isinstance(apps, dict):
        raise AppsError("config_unavailable", "airlock-config json omitted apps")
    package_info = _command(root, ["package-info"], json_output=True)
    packages = package_info.get("packages")
    packages = packages if isinstance(packages, dict) else {}
    known = {line.strip() for line in _command(root, ["known-builtins"]).splitlines()
             if line.strip()}
    catalog_doc = _command(root, ["catalog"], json_output=True)
    catalog_rows = catalog_doc.get("apps")
    catalog = {row["id"]: row for row in catalog_rows or []
               if isinstance(row, dict) and isinstance(row.get("id"), str)}
    by_update = _update_map(updates)

    installed = []
    for app_id, config in apps.items():
        # The sheet renders one explicit Airlock platform row in hub's place. Keeping
        # hub here as well would show ten rows for a nine-entry config.
        if app_id == "hub":
            continue
        package = packages.get(app_id)
        package = package if isinstance(package, dict) else {}
        installed.append({
            "id": app_id,
            "config": config,
            "tile": package.get("tile"),
            "source": package.get("source_class", "platform"),
            "digest": package.get("digest"),
            "capabilities": package.get("effective_capabilities") or [],
            "canRemove": bool((package.get("lifecycle") or {}).get("deactivate")),
            "update": by_update.get(app_id),
        })

    public = []
    for app_id in sorted(known - set(apps)):
        meta = catalog.get(app_id, {})
        public.append({
            "id": app_id,
            "tile": meta.get("tile"),
            "source": "builtin",
            "digest": None,
            "capabilities": [],
            "canRemove": (root / "apps" / app_id / "deactivate.sh").is_file(),
            "update": by_update.get(app_id),
        })
    return {"apps": apps, "installed": installed, "public": public,
            "updates": updates if isinstance(updates, dict) else {"apps": []}}


def _read_config(path: Path) -> tuple[bytes, dict[str, Any]]:
    try:
        data = path.read_bytes()
        value = tomllib.loads(data.decode("utf-8"))
    except (OSError, ValueError) as exc:
        raise AppsError("config_unavailable", str(exc)) from exc
    if not isinstance(value, dict):
        raise AppsError("config_unavailable", "config is not a TOML document")
    return data, value


def _load(path: Path) -> dict[str, Any]:
    return _read_config(path)[1]


def registered_package_path(config: Path, app_id: str) -> Path:
    """Return one configured explicit package path, resolved like airlock-config."""
    app_id = _checked_id(app_id)
    config = Path(config).resolve()
    document = _load(config)
    table = (document.get("packages") or {}).get(app_id)
    raw = table.get("path") if isinstance(table, dict) else None
    if not isinstance(raw, str) or not raw.strip():
        raise AppsError("package_not_registered")
    path = Path(raw.strip()).expanduser()
    if not path.is_absolute():
        path = config.parent / path
    return path.resolve()


def _owned_header(line: str, namespace: str, app_id: str) -> bool:
    atom = r'(?:%s|"%s"|\'%s\')' % tuple(re.escape(app_id) for _ in range(3))
    # Match the owned table and any array/table nested below it. A similarly prefixed
    # id (notes-old) does not match because only dot or closing bracket may follow.
    return re.match(  # noqa: regex-anchor - table/id atoms are built at runtime
                    r"^\s*\[\[?\s*" + re.escape(namespace) + r"\s*\.\s*" +
                    atom + r"\s*(?:\.|\]\]?)", line) is not None


def _drop_app_tables(text: str, app_id: str) -> str:
    lines = text.splitlines(keepends=True)
    output: list[str] = []
    dropping = False
    for line in lines:
        if re.match(r"^\s*\[\[?", line):
            # An explicit package table is registration intent, not reusable catalog
            # state. Leaving it behind shadows a shipped id and, more importantly,
            # makes a later enable/disable cycle fail validation as an orphan package.
            dropping = (_owned_header(line, "apps", app_id) or
                        _owned_header(line, "packages", app_id))
        if not dropping:
            output.append(line)
    return "".join(output)


def _append_tables(text: str, app_id: str,
                   package: dict[str, Any] | None) -> str:
    suffix = "" if not text or text.endswith("\n") else "\n"
    if package is not None:
        path = package.get("path")
        grants = package.get("grant") or []
        suffix += "[packages.%s]\npath = %s\n" % (
            app_id, json.dumps(path, ensure_ascii=False))
        if grants:
            suffix += "grant = %s\n" % json.dumps(
                grants, ensure_ascii=False, separators=(",", ":"))
        suffix += "\n"
    suffix += "[apps.%s]\n" % app_id
    return text + suffix


def _checked_package(package: dict[str, Any] | None) -> dict[str, Any] | None:
    if package is None:
        return None
    if not isinstance(package, dict) or set(package) - {"path", "grant"}:
        raise AppsError("bad_package_registration")
    path = package.get("path")
    grants = package.get("grant", [])
    if not isinstance(path, str) or not path.strip():
        raise AppsError("bad_package_path")
    if (not isinstance(grants, list)
            or any(not isinstance(value, str) for value in grants)
            or len(grants) != len(set(grants))):
        raise AppsError("bad_package_grants")
    return {"path": path, "grant": list(grants)}


def _write_candidate(config: Path, candidate_text: str) -> Path:
    try:
        original_mode = stat.S_IMODE(config.stat().st_mode)
        descriptor, temporary = tempfile.mkstemp(prefix=".%s.candidate." % config.name,
                                                  dir=str(config.parent))
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            os.fchmod(handle.fileno(), original_mode)
            handle.write(candidate_text)
            handle.flush()
            os.fsync(handle.fileno())
        return Path(temporary)
    except OSError as exc:
        raise AppsError("config_unwritable", str(exc)) from exc


def _replace_validated(config: Path, candidate_text: str, expected: bytes,
                       approved_package: tuple[str, str] | None = None) -> None:
    root = default_root()
    candidate = _write_candidate(config, candidate_text)
    backup_tmp: Path | None = None
    try:
        validation = (["validate"] if approved_package is None else
                      ["package-register-validate", *approved_package])
        _command(root, validation, config=candidate)
        try:
            current = config.read_bytes()
        except OSError as exc:
            raise AppsError("config_unavailable", str(exc)) from exc
        if current != expected:
            raise AppsError("config_conflict", "airlock.toml changed during validation")
        descriptor, temporary = tempfile.mkstemp(prefix=".%s.backup." % config.name,
                                                  dir=str(config.parent))
        backup_tmp = Path(temporary)
        with os.fdopen(descriptor, "wb") as handle:
            os.fchmod(handle.fileno(), stat.S_IMODE(config.stat().st_mode))
            handle.write(expected)
            handle.flush()
            os.fsync(handle.fileno())
        # Keep the old .bak too when an external editor won the race while the
        # candidate or its backup was being prepared.
        if config.read_bytes() != expected:
            raise AppsError("config_conflict", "airlock.toml changed before replacement")
        os.replace(backup_tmp, Path(str(config) + ".bak"))
        backup_tmp = None
        os.replace(candidate, config)
    except AppsError:
        raise
    except OSError as exc:
        raise AppsError("config_unwritable", str(exc)) from exc
    finally:
        try:
            candidate.unlink()
        except FileNotFoundError:
            pass
        if backup_tmp is not None:
            try:
                backup_tmp.unlink()
            except FileNotFoundError:
                pass


def mutate_enabled(config: Path, app_id: str, enabled: bool) -> dict[str, Any]:
    """Add or remove one app registration through validate -> backup -> replace."""
    app_id = _checked_id(app_id)
    config = Path(config).resolve()
    with _WRITE_LOCK:
        original, document = _read_config(config)
        present = app_id in (document.get("apps") or {})
        if bool(enabled) == present:
            return {"id": app_id, "enabled": present, "changed": False}
        text = original.decode("utf-8")
        candidate = (_append_tables(text, app_id, None) if enabled
                     else _drop_app_tables(text, app_id))
        if not enabled:
            try:
                projected = tomllib.loads(candidate)
            except ValueError as exc:
                raise AppsError("config_unsupported", str(exc)) from exc
            if app_id in (projected.get("apps") or {}) \
                    or app_id in (projected.get("packages") or {}):
                raise AppsError(
                    "config_unsupported",
                    "app/package registration is not expressed as a removable table")
        _replace_validated(config, candidate, original)
    return {"id": app_id, "enabled": bool(enabled), "changed": True}


def register(config: Path, app_id: str,
             package: dict[str, Any] | None = None, *,
             approved_digest: str | None = None) -> dict[str, Any]:
    """Register an app, optionally with an explicit package path, via the same writer."""
    app_id = _checked_id(app_id)
    package = _checked_package(package)
    if approved_digest is not None:
        if package is None or re.fullmatch(r"[0-9a-f]{64}", approved_digest) is None:
            raise AppsError("bad_package_approval")
    config = Path(config).resolve()
    with _WRITE_LOCK:
        original, document = _read_config(config)
        apps = document.get("apps") or {}
        packages = document.get("packages") or {}
        if app_id in apps:
            if package is not None and app_id not in packages:
                raise AppsError("app_already_registered")
            return {"id": app_id, "enabled": True, "changed": False}
        if package is not None and app_id in packages:
            raise AppsError("package_already_registered")
        text = _append_tables(original.decode("utf-8"), app_id, package)
        approval = ((app_id, approved_digest)
                    if approved_digest is not None else None)
        _replace_validated(config, text, original, approval)
    return {"id": app_id, "enabled": True, "changed": True}
