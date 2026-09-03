#!/usr/bin/env python3
"""Pure data boundary for the Ubuntu Airlock installer window.

GTK imports deliberately live elsewhere so this module can be exercised headlessly in CI.
"""

from __future__ import annotations

import hashlib
import json
import re
import tarfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO


CONFIG_SCHEMA = "airlock.gui-installer-config/v1"
PROFILE_SCHEMA = "airlock.gui-default-profile/v1"
SELECTION_SCHEMA = "airlock.gui-install-request/v1"
MEMBER_ROOT = "airlock/"
PRODUCTION_HELPER = Path("/usr/libexec/airlock-gui-installer-helper")
DNS_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
EXPECTED_PROFILE = {
    "schema": PROFILE_SCHEMA,
    "always": ["hub"],
    "required": ["devterm", "fileview", "publish"],
    "default": ["paseo"],
    "install": ["devterm", "fileview", "publish", "paseo"],
}


class ContractError(ValueError):
    """The installed GUI inputs do not agree with the pinned bundle contract."""


@dataclass(frozen=True)
class InstallerInputs:
    bundle: Path
    bundle_sha256: str
    helper: Path
    expected_tailnet: str
    source_sha: str
    profile: dict[str, Any]
    catalog: dict[str, Any]


@dataclass(frozen=True)
class PickerApp:
    app_id: str
    label: str
    subtitle: str
    locked: bool
    checked: bool


def _object(raw: bytes, label: str) -> dict[str, Any]:
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ContractError(f"{label} is not valid UTF-8 JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be a JSON object")
    return value


def _regular_file(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise ContractError(f"{label} must be a regular non-symlink file: {path}")


def _trusted_file(path: Path, label: str, trusted_uid: int) -> None:
    if not path.is_absolute():
        raise ContractError(f"{label} path must be absolute: {path}")
    current = Path("/")
    for part in path.parts[1:]:
        current /= part
        try:
            stat = current.lstat()
        except OSError as exc:
            raise ContractError(f"{label} path cannot be inspected: {current}") from exc
        if current.is_symlink():
            raise ContractError(f"{label} path contains a symlink: {current}")
        if stat.st_mode & 0o022:
            raise ContractError(f"{label} path is group/world-writable: {current}")
        if stat.st_uid not in {0, trusted_uid}:
            raise ContractError(f"{label} path has an untrusted owner: {current}")
    _regular_file(path, label)
    if path.stat().st_uid != trusted_uid:
        raise ContractError(f"{label} file has an untrusted owner: {path}")


def _bundle_member(tf: tarfile.TarFile, name: str) -> bytes:
    if not name.startswith(MEMBER_ROOT) or ".." in Path(name).parts:
        raise ContractError(f"unsafe bundle member name: {name}")
    try:
        info = tf.getmember(name)
    except KeyError as exc:
        raise ContractError(f"bundle member is missing: {name}") from exc
    if not info.isfile() or info.issym() or info.islnk():
        raise ContractError(f"bundle member is not a regular file: {name}")
    stream = tf.extractfile(info)
    if stream is None:
        raise ContractError(f"bundle member cannot be read: {name}")
    return stream.read()


def load_inputs(
    config_path: str | Path,
    *,
    trusted_uid: int = 0,
    expected_helper: Path = PRODUCTION_HELPER,
) -> InstallerInputs:
    path = Path(config_path)
    _trusted_file(path, "installer config", trusted_uid)
    cfg = _object(path.read_bytes(), "installer config")
    if cfg.get("schema") != CONFIG_SCHEMA:
        raise ContractError("installer config schema is unsupported")

    bundle = Path(str(cfg.get("bundle", "")))
    helper = Path(str(cfg.get("helper", "")))
    digest = str(cfg.get("bundle_sha256", ""))
    tailnet = str(cfg.get("expected_tailnet", ""))
    _trusted_file(bundle, "GUI bundle", trusted_uid)
    _trusted_file(helper, "privileged helper", trusted_uid)
    if helper != expected_helper:
        raise ContractError("installer config names an unexpected privileged helper")
    if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise ContractError("bundle_sha256 must be 64 lowercase hexadecimal characters")
    if hashlib.sha256(bundle.read_bytes()).hexdigest() != digest:
        raise ContractError("GUI bundle digest does not match installer config")
    if (
        not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.ts\.net", tailnet)
        or ".." in tailnet
    ):
        raise ContractError("expected_tailnet must be a lowercase *.ts.net DNS suffix")

    try:
        tf = tarfile.open(bundle, "r:gz")
    except (OSError, tarfile.TarError) as exc:
        raise ContractError(f"GUI bundle cannot be opened: {exc}") from exc
    with tf:
        manifest = _object(
            _bundle_member(tf, "airlock/gui-provisioner-manifest.json"),
            "bundle manifest",
        )
        if manifest.get("schema") != "airlock.gui-provisioner-bundle/v1":
            raise ContractError("bundle manifest schema is unsupported")
        profile_path = str(manifest.get("profile_path", ""))
        catalog_path = str(manifest.get("catalog_path", ""))
        profile_raw = _bundle_member(tf, MEMBER_ROOT + profile_path)
        catalog_raw = _bundle_member(tf, MEMBER_ROOT + catalog_path)

    if hashlib.sha256(profile_raw).hexdigest() != manifest.get("profile_sha256"):
        raise ContractError("profile digest does not match bundle manifest")
    if hashlib.sha256(catalog_raw).hexdigest() != manifest.get("catalog_sha256"):
        raise ContractError("catalog digest does not match bundle manifest")
    profile = _object(profile_raw, "GUI profile")
    catalog = _object(catalog_raw, "GUI catalog")
    if profile != EXPECTED_PROFILE:
        raise ContractError("GUI profile drifted from the approved app contract")
    source_sha = str(manifest.get("source_sha", ""))
    if re.fullmatch(r"[0-9a-f]{40}", source_sha) is None:
        raise ContractError("bundle source SHA is invalid")

    apps = catalog.get("apps")
    if not isinstance(apps, list) or not apps:
        raise ContractError("bundled catalog app list is empty or invalid")
    catalog_ids: set[str] = set()
    for item in apps:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            raise ContractError("bundled catalog contains an invalid app entry")
        app_id = item["id"]
        if app_id in catalog_ids:
            raise ContractError("bundled catalog contains a duplicate app ID")
        tile = item.get("tile")
        if tile is not None and not isinstance(tile, dict):
            raise ContractError(f"bundled catalog tile is invalid: {app_id}")
        arch = item.get("arch") or []
        if not isinstance(arch, list) or any(not isinstance(value, str) for value in arch):
            raise ContractError(f"bundled catalog architecture is invalid: {app_id}")
        catalog_ids.add(app_id)
    required = profile.get("required")
    defaults = profile.get("default")
    always = profile.get("always")
    if not all(isinstance(value, list) for value in (required, defaults, always)):
        raise ContractError("GUI profile app lists are invalid")
    if set(required + defaults) - catalog_ids:
        raise ContractError("GUI profile names an app absent from the bundled catalog")
    if always != ["hub"]:
        raise ContractError("GUI profile core app contract drifted")
    if catalog.get("unavailable"):
        raise ContractError("bundled catalog contains unavailable apps")
    return InstallerInputs(bundle, digest, helper, tailnet, source_sha, profile, catalog)


def make_request(hostname: str, selected: list[str], inputs: InstallerInputs) -> bytes:
    hostname = hostname.strip().lower()
    if DNS_LABEL.fullmatch(hostname) is None:
        raise ContractError("기기 이름은 영문 소문자, 숫자, 하이픈만 사용할 수 있습니다.")
    by_id = {item["id"]: item for item in inputs.catalog["apps"]}
    catalog_ids = set(by_id)
    if any(not isinstance(app, str) for app in selected):
        raise ContractError("선택한 앱 ID가 올바르지 않습니다.")
    if len(selected) != len(set(selected)):
        raise ContractError("같은 앱을 두 번 선택할 수 없습니다.")
    unknown = sorted(set(selected) - catalog_ids)
    if unknown:
        raise ContractError("이 번들에 없는 앱입니다: " + ", ".join(unknown))
    unsupported = sorted(
        app
        for app in selected
        if (by_id[app].get("arch") or []) and "x86_64" not in by_id[app]["arch"]
    )
    if unsupported:
        raise ContractError("이 기기에서 지원하지 않는 앱입니다: " + ", ".join(unsupported))
    optional = sorted(set(selected) - set(inputs.profile["required"]))
    doc = {"schema": SELECTION_SCHEMA, "hostname": hostname, "selected_optional_apps": optional}
    return (json.dumps(doc, ensure_ascii=False, sort_keys=True) + "\n").encode()


def picker_apps(inputs: InstallerInputs) -> list[PickerApp]:
    required = set(inputs.profile["required"])
    defaults = set(inputs.profile["default"])
    rows = [PickerApp("hub", "Hub", "모든 앱으로 들어가는 기본 화면 · 필수", True, True)]
    for app in inputs.catalog["apps"]:
        tile = app.get("tile") or {}
        app_id = app["id"]
        arch = app.get("arch") or []
        supported = not arch or "x86_64" in arch
        locked = app_id in required or not supported
        subtitle = str(tile.get("sub") or "Airlock 앱")
        if app_id in required:
            subtitle += " · 필수"
        elif not supported:
            subtitle += " · 이 기기에서 지원 안 함"
        rows.append(
            PickerApp(
                app_id,
                str(tile.get("label") or app_id),
                subtitle,
                locked,
                supported and (app_id in required or app_id in defaults),
            )
        )
    return [rows[0], *sorted(rows[1:], key=lambda row: row.label.casefold())]


def parse_event(line: str) -> dict[str, Any] | None:
    try:
        value = json.loads(line)
    except json.JSONDecodeError:
        return None
    if not isinstance(value, dict) or not isinstance(value.get("event"), str):
        return None
    return value


def failure_copy(event: dict[str, Any]) -> tuple[str, str, str]:
    code = str(event.get("code") or "unexpected")
    message = str(event.get("message") or "설치를 끝내지 못했습니다.")
    remedy = str(
        event.get("remedy")
        or "자세히에서 기록을 확인한 뒤 다시 시도해 주세요. 계속되면 담당자에게 기록을 보여 주세요."
    )
    return code, message, remedy


def reconcile_exit(returncode: int, terminal_event: str, url: str) -> tuple[str, str, str]:
    """Reconcile the terminal NDJSON event with process exit after both pipes reach EOF."""
    if terminal_event in {"failed", "needs-auth"}:
        return "reported", "", ""
    if returncode == 0 and terminal_event == "finished" and url.startswith("https://"):
        return "success", "", ""
    if returncode in (126, 127) and not terminal_event:
        return (
            "failure",
            "privilege-cancelled",
            "관리자 권한을 받지 못했습니다.",
        )
    if terminal_event == "finished":
        return (
            "failure",
            "finished-exit-mismatch",
            "완료 신호 뒤에 설치 작업이 실패했습니다.",
        )
    if returncode == 0:
        return (
            "failure",
            "missing-terminal-event",
            "설치 작업이 결과를 남기지 않았습니다.",
        )
    return "failure", "unexpected-exit", "설치를 끝내지 못했습니다."


def write_all(stream: BinaryIO, payload: bytes) -> None:
    stream.write(payload)
    stream.flush()
    stream.close()
