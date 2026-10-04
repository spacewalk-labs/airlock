"""Owner app-store projections, package preview and personal link input."""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
from pathlib import Path
from typing import Any


APP_ID = re.compile(r"\A[a-z0-9][a-z0-9-]{0,31}\Z")


class AppsError(RuntimeError):
    """A stable error code plus a diagnostic suitable for the server log."""

    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(detail or code)
        self.code = code
        self.detail = detail


def _command(root: Path, args: list[str], *, config: Path | None = None,
             json_output: bool = False) -> Any:
    env = os.environ.copy()
    env["AIRLOCK_ROOT"] = str(Path(root).resolve())
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


def installed_ids(root: Path) -> list[str]:
    """③ — every app id the install record says is installed on this box.

    One adapter over `bin/airlock-ledger list`, and the only place in the server
    that answers "is this installed". Every row a caller can install but this box
    has not installed reads as not installed, which is the point: a config table
    is a decision someone wrote, not evidence that anything is on disk. Notes
    shipped the other way round — `[apps.notes]` alone made a failed install read
    as installed for months.

    Current engine rows name their repo, commit and artifacts. Legacy rows
    count only when their state includes `committed`; intent alone is not an
    installation. Reading a mixed old snapshot must keep committed installs.

    stdin is DEVNULL on purpose: this command reads package-info from stdin, and a
    server request that hands it a pipe nobody writes to blocks until it times out.
    """
    base = Path(root).resolve()
    env = os.environ.copy()
    for name in ("AIRLOCK_CONFIG_SNAPSHOT", "AIRLOCK_CONFIG_SNAPSHOT_SHA256",
                 "AIRLOCK_INSTALL_PKG_INFO_SHA256"):
        env.pop(name, None)
    argv = [sys.executable, str(base / "bin" / "airlock-ledger"), "list"]
    try:
        result = subprocess.run(argv, cwd=str(base), env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise AppsError("ledger_unavailable", str(exc)) from exc
    if result.returncode:
        raise AppsError("ledger_unavailable",
                        result.stderr.strip() or "airlock-ledger list failed")
    ids = []
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) < 2:
            continue
        if not (fields[1].startswith("repo=") or
                "committed" in fields[1].replace("state=", "").split("+")):
            continue
        app_id = fields[0].strip()
        if app_id and app_id not in ids:
            ids.append(app_id)
    return ids


def _sources(root: Path) -> dict[str, Any]:
    """① — the candidate list. It carries no install record, by design."""
    value = _command(root, ["sources"], json_output=True)
    apps = value.get("apps")
    if not isinstance(apps, dict):
        raise AppsError("config_unavailable", "airlock-config sources omitted apps")
    return value


def _platform_row(updates: Any) -> dict[str, Any]:
    """The platform's own row, so every row in the store is one shape.

    Three states and each says which one it is: measured-and-behind,
    measured-and-current, and not-measured. The third is NOT "nothing to do" —
    a client that cannot tell those apart is a client that shows a person an
    empty list and calls it current.
    """
    value = updates.get("platform") if isinstance(updates, dict) else None
    available = value.get("available") if isinstance(value, dict) else None
    if available is True:
        state, desc = "update", "새 플랫폼 버전이 있습니다"
    elif available is False:
        state, desc = "installed", "새 플랫폼 버전 없음"
    else:
        state, desc = "installed", "플랫폼 업데이트를 확인하지 못했습니다"
    return {"id": "platform", "origin": "public", "kind": "platform",
            "name": "Airlock 플랫폼", "desc": desc, "state": state, "detail": {}}


def store_rows(root: Path, updates: Any, installed: list[str],
               placed: set[str] | None = None) -> dict[str, Any]:
    """The store's rows, one per candidate, each carrying its own single state.

    `state` is decided here and nowhere else: the launcher's store draws it and
    its detail sheet draws it, so a row and its detail cannot disagree about
    whether something is installed. Three states, from three records:

      * an app is installed when ③ says so, and has an update when the current
        engine plan says so;
      * a link is installed when it is placed on the home screen (④) — a link
        has nothing to install, and "on my home screen" is the whole of it;
      * anything else is install.

    `placed` is the home order's ids. A link that has left its `links.toml`
    keeps its place (the order file is not this function's to rewrite) but draws
    no row, so the store never offers a link the box cannot resolve.
    """
    root = Path(root).resolve()
    placed = set(placed or ())
    source = _sources(root)
    by_update = _update_map(updates)
    # Only an upgrade row advertises an update the person can start.
    upgradable = {app_id for app_id, row in by_update.items()
                  if row.get("action") == "upgrade"}
    rows: list[dict[str, Any]] = []

    def emit(candidate: dict[str, Any], origin: str) -> None:
        app_id = str(candidate.get("id") or "")
        if not app_id:
            return
        row = {"id": app_id, "origin": origin, "kind": "app",
               "name": candidate.get("name") or app_id,
               "desc": candidate.get("desc") or "",
               "state": ("update" if app_id in upgradable else "installed")
                        if app_id in installed else "install",
               "detail": {}}
        if candidate.get("icon"):
            row["icon"] = candidate["icon"]
        if candidate.get("glyph"):
            row["glyph"] = candidate["glyph"]
        if candidate.get("source") or candidate.get("path"):
            row["detail"] = {"Path": candidate.get("source") or candidate["path"]}
        rows.append(row)

    for origin in ("public", "company", "personal"):
        for candidate in source["apps"].get(origin) or []:
            if isinstance(candidate, dict):
                emit(candidate, origin)

    seen = {row["id"] for row in rows}
    for link in source.get("links") or []:
        if not isinstance(link, dict):
            continue
        app_id = str(link.get("id") or "")
        if not app_id or app_id in seen:
            continue
        seen.add(app_id)
        row = {"id": app_id, "origin": "company" if link.get("origin") == "company"
               else "personal", "kind": "link", "name": link.get("name") or app_id,
               "desc": link.get("desc") or "", "url": link.get("url"),
               "state": "installed" if app_id in placed else "install",
               "detail": {}}
        if link.get("icon"):
            row["icon"] = link["icon"]
        if link.get("glyph"):
            row["glyph"] = link["glyph"]
        rows.append(row)

    # Nothing this box has installed may be missing from the store. A package the
    # three source lists do not describe — an app whose origin
    # repo is unreadable — still gets a row under its own id. A store that hides
    # an installed app cannot update or remove it.
    named = {row["id"] for row in rows}
    for app_id in installed:
        if app_id in named:
            continue
        # The same state calculation an ordinary candidate row gets: an app whose
        # origin no source describes is still updatable, and a fallback row that
        # ignored the engine plan would leave the one app with no menu unable to
        # update itself.
        rows.append({"id": app_id, "origin": "personal", "kind": "app",
                     "name": app_id, "desc": "",
                     "state": ("update" if app_id in upgradable else "installed"),
                     "detail": {}})
    rows.sort(key=lambda row: (row["origin"], row["id"]))
    rows.insert(0, _platform_row(updates))
    return {"rows": rows,
            "links_path": source.get("links_path"),
            "updates": updates if isinstance(updates, dict) else {"apps": []}}


def _checked_link(name, url):
    """The one accepted shape for a new personal link: a name, and an https url.

    This is the retired shortcut validator with its label renamed to the word
    the link file actually uses — not a new check. The url rules are
    unchanged and load-bearing: a link leaves this origin, so plain http is the
    mixed-content/HSTS trap, and credentials in the authority are somebody's
    password written into a file that gets published.
    """
    if (not isinstance(name, str) or not name.strip()
            or any(ord(c) < 32 or ord(c) == 127 for c in name)):
        raise AppsError("bad_link_name")
    if (not isinstance(url, str) or not url
            or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in url)):
        raise AppsError("bad_link_url")
    try:
        parsed = urlsplit(url)
        # Reading port also rejects malformed/out-of-range port values.
        _ = parsed.port
        if (parsed.scheme != "https" or not parsed.hostname
                or parsed.username is not None or parsed.password is not None
                or "\\" in url or "%" in parsed.netloc):
            raise ValueError("HTTPS hostname without credentials required")
        host = parsed.hostname.encode("idna").decode("ascii")
        if ":" not in host and any(not part or re.fullmatch(r"[a-zA-Z0-9-]+", part) is None
                                  or part.startswith("-") or part.endswith("-")
                                  for part in host.rstrip(".").split(".")):
            raise ValueError("invalid hostname")
    except (ValueError, UnicodeError) as exc:
        raise AppsError("bad_link_url", str(exc)) from exc
    return name.strip(), url


def add_link(*, root: Path, webroot: Path, name=None, url=None,
             order=None, installed: list | None = None):
    """Add one table to the personal links.toml, then place it on the home screen.

    The order is the whole design. The link file is written first and the Hub
    projection is republished from it; only once both have succeeded is the id
    appended to the home order. So:

      * a failed projection rolls the links file back and leaves the home order
        byte-identical — a link the launcher cannot draw is not a link added;
      * a failed home-order write is not rolled back. The link exists and the
        store shows it as Install, which is a truthful state, and pressing
        Install is exactly the operation that would place it.

    There is no removal counterpart. A link is removed by editing links.toml,
    and the home order keeps its id on purpose: the same rule that keeps a
    hidden app's place keeps a removed link's, and re-adding the file brings the
    tile back where it was.
    """
    name, url = _checked_link(name, url)
    base = Path(root).resolve()
    source = _sources(base)
    # The path is named in exactly one place, bin/airlock-config, and read from its
    # output. A second copy here would be a second answer to "where do this box's
    # personal links live", and only one of the two would ever be tested.
    raw_path = source.get("links_path")
    if not isinstance(raw_path, str) or not raw_path:
        raise AppsError("config_unavailable", "airlock-config sources omitted links_path")
    path = Path(raw_path).expanduser()
    existing = {row["id"]: row for row in source["links"]
                if row.get("origin") == "personal"}
    same = next((row_id for row_id, row in existing.items()
                 if row.get("url") == url), None)
    if same is not None:
        return {"id": same, "changed": False, "link": True}
    link_id = "link-" + hashlib.sha256(url.encode("utf-8")).hexdigest()[:12]
    if APP_ID.fullmatch(link_id) is None:  # unreachable: the digest is hex
        raise AppsError("bad_link_name")
    if link_id in existing:
        raise AppsError("link_id_conflict")
    before = None
    try:
        before = path.read_bytes()
    except FileNotFoundError:
        before = None
    except OSError as exc:
        raise AppsError("config_unwritable", str(exc)) from exc
    body = (before.decode("utf-8") if before is not None else "")
    if body and not body.endswith("\n"):
        body += "\n"
    body += "\n[%s]\n" % link_id
    body += "".join("%s = %s\n" % (key, json.dumps(value, ensure_ascii=False))
                    for key, value in (("name", name), ("url", url)))
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=".links.toml.", dir=str(path.parent))
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                os.fchmod(handle.fileno(), 0o600)
                handle.write(body)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
        except Exception:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise
        _republish_hub(base, webroot)
        _placed_in_projection(base, webroot, link_id)
    except AppsError:
        _restore(path, before)
        raise
    except OSError as exc:
        _restore(path, before)
        raise AppsError("hub_refresh_failed", str(exc)) from exc
    if order is not None:
        try:
            _place_on_home(order, installed or [], link_id)
        except (OSError, RuntimeError):
            pass
    return {"id": link_id, "changed": True, "link": True}


def _placed_in_projection(root: Path, webroot: Path, link_id: str) -> None:
    """The link has to be READABLE, not merely written.

    A links.toml that will not parse is skipped with one line on stderr and
    everything else carries on — which is right for reading and wrong for
    writing. Appending a table to a broken file produces a file that is still
    broken, the projection that was just published does not contain the link,
    and reporting success would put an id on the home screen that nothing can
    draw. So the projection is read back, and a link missing from it is a
    rollback like any other.
    """
    try:
        projection = json.loads((Path(webroot) / "__airlock.json").read_text())
    except (OSError, ValueError) as exc:
        raise AppsError("hub_refresh_failed", str(exc)) from exc
    if not isinstance(projection, dict) or link_id not in (projection.get("apps") or {}):
        raise AppsError("links_unreadable",
                        "the personal links file did not parse, so the new link "
                        "is not readable either — fix the file and try again")


def _restore(path: Path, before: bytes | None) -> None:
    """Put a link file back exactly as it was. Best effort, and never raising."""
    try:
        if before is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(before)
    except OSError:
        pass


def _republish_hub(root: Path, webroot: Path) -> None:
    """Render and publish Hub's frontend config from the committed links file."""
    webroot = Path(webroot)
    target = webroot / "__airlock.json"
    try:
        previous = json.loads(target.read_text()) if target.exists() else {}
        if not isinstance(previous, dict):
            raise ValueError("Hub config is not an object")
        projection = _command(root, ["webjson"], json_output=True)
        # The installer measured this hostname; the service does not re-measure it.
        if "fqdn" in previous:
            projection["fqdn"] = previous["fqdn"]
        else:
            projection.pop("fqdn", None)
        webroot.mkdir(parents=True, exist_ok=True)
        descriptor, name = tempfile.mkstemp(prefix=".__airlock.json.", dir=str(webroot))
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                os.fchmod(handle.fileno(), 0o644)
                json.dump(projection, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)
    except (OSError, ValueError) as exc:
        raise AppsError("hub_refresh_failed", str(exc)) from exc


def _place_on_home(order, installed: list, link_id: str) -> None:
    """Append one id to the home order — the same write the launcher makes."""
    current = order.read_order(installed)
    order.write_order(current + [link_id], installed)
