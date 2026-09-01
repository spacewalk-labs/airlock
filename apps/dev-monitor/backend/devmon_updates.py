"""Collect and read the small, owner-scoped Airlock update snapshot.

The collector is a systemd oneshot, not a second daemon.  Its only durable output is
an atomically replaced JSON file: if a collection fails, the API continues to expose
the last complete observation and its original checkedAt value rather than inventing
a reassuring empty result.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def default_root() -> Path:
    return Path(__file__).resolve().parents[3]


# The update timer is a systemd --user service, whose PATH normally omits the
# per-user Node CLI locations.  Use the platform's shared resolver rather than
# treating a login-shell PATH as the installation contract.
sys.path.insert(0, str(default_root() / "bin"))
import bin_discovery  # noqa: E402


def default_state() -> Path:
    return Path(os.environ.get("AIRLOCK_UPDATES_STATE",
                               "~/.local/state/airlock/updates.json")).expanduser()


def _run(argv: list[str], *, input_text: str | None = None, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, input=input_text, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=timeout, check=False)


def _platform(root: Path) -> dict[str, Any]:
    result = _run(["bash", str(root / "bin" / "airlock-update"), "--dry-run", "--json"],
                  timeout=120)
    if result.returncode:
        raise RuntimeError("airlock-update --dry-run failed: " + result.stderr.strip())
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("airlock-update did not return JSON") from exc
    if (not isinstance(value, dict) or type(value.get("available")) is not bool
            or type(value.get("changedCount")) is not int
            or not isinstance(value.get("ref"), str)):
        raise RuntimeError("airlock-update returned an invalid JSON shape")
    return {"available": value["available"], "changedCount": value["changedCount"],
            "ref": value["ref"]}


def _source_classes(package_info: dict[str, Any]) -> dict[str, str]:
    packages = package_info.get("packages")
    if not isinstance(packages, dict):
        return {}
    return {str(app_id): str(raw.get("source_class", "explicit"))
            for app_id, raw in packages.items() if isinstance(raw, dict)}


def _lock_mismatches(stderr: str) -> list[dict[str, str]]:
    # airlock-config is the lock authority.  Do not calculate a second digest here:
    # this only turns its explicit refusal into the UI's display-only action.
    ids = sorted(set(re.findall(r"package '([a-z0-9][a-z0-9-]{0,31})': package lock digest mismatch", stderr)))
    return [{"id": app_id, "action": "lock-mismatch", "sourceClass": "explicit"}
            for app_id in ids]


def _apps(root: Path) -> list[dict[str, str]]:
    config = _run([sys.executable, str(root / "bin" / "airlock-config"), "package-info"])
    if config.returncode:
        mismatches = _lock_mismatches(config.stderr)
        if mismatches:
            return mismatches
        raise RuntimeError("airlock-config package-info failed: " + config.stderr.strip())
    try:
        package_info = json.loads(config.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("airlock-config package-info did not return JSON") from exc
    plan = _run([sys.executable, str(root / "bin" / "airlock-ledger"), "plan"],
                input_text=config.stdout)
    if plan.returncode not in (0, 3):
        raise RuntimeError("airlock-ledger plan failed: " + plan.stderr.strip())
    classes = _source_classes(package_info)
    result = []
    for line in plan.stdout.splitlines():
        action, sep, app_id = line.partition("\t")
        if not sep or not app_id or not action.startswith("upgrade-"):
            continue                         # reinstall means it is already current.
        result.append({"id": app_id, "action": "upgrade",
                       "sourceClass": classes.get(app_id, "explicit")})
    return sorted(result, key=lambda item: item["id"])


def _first_line(argv: list[str], timeout: int = 20) -> str | None:
    try:
        result = _run(argv, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode:
        return None
    value = result.stdout.strip().splitlines()
    return value[0] if value else None


# `codex --version` prints "codex-cli 0.144.4" and `claude --version` prints
# "2.1.257 (Claude Code)", while `npm view` prints a bare "0.152.0".  Comparing the
# raw lines therefore answers "outdated" for a STRUCTURAL reason and keeps answering
# it after an upgrade — measured on this box's live snapshot 2026-09-01, where
# installed "codex-cli 0.144.4" could never equal latest "0.152.0" no matter what was
# installed.  Both sides are reduced to the same thing, a dotted version run, so that
# "these differ" means the versions differ.
_VERSION = re.compile(r"[0-9]+(?:\.[0-9]+)+(?:[-+][0-9A-Za-z.-]+)?")


def _version(line: str | None) -> str | None:
    """The version inside a `--version` line, or None when there is not one.

    None rather than the raw line: an unrecognised line is "we could not read the
    version", and the panel's comparison must not turn that into a version claim.
    """
    if not isinstance(line, str):
        return None
    found = _VERSION.search(line)
    return found.group(0) if found else None


def _cli(name: str) -> str | None:
    """The installed version of a user-installed CLI, or None if it is not there."""
    path, _ = bin_discovery.find_bin(name)
    return _version(_first_line([path, "--version"])) if path else None


def _skill_roots() -> tuple[Path, ...]:
    """The two wiring roots, in the order the panel names them.

    They are per-agent, not per-box: Claude Code reads ~/.claude/skills and the Codex
    CLI reads ~/.agents/skills.  Counting only one of them is the exact silence this
    row exists to break — a skill wired for one agent and missing for the other raises
    no error anywhere; it is simply absent for that agent.
    """
    return (Path("~/.claude/skills").expanduser(), Path("~/.agents/skills").expanduser())


def _skill_names(root: Path) -> list[str]:
    """Directory names under one root that an agent can actually invoke.

    Valid local skill copies count too: whether they are the current canonical content
    belongs to skill-wiring-check's separate drift verdict, not to this inventory.
    """
    if not root.is_dir():
        return []
    try:
        entries = sorted(root.iterdir())
    except OSError:
        return []
    return [d.name for d in entries if d.is_dir() and (d / "SKILL.md").is_file()]


def _canon_of(entry: Path) -> Path | None:
    """Where one wired skill's content actually lives, or None for a local copy.

    Two wiring shapes are both real and both count: the directory itself is a symlink
    into the canonical repository, or the directory is real and only its SKILL.md is a
    symlink (used where the canonical directory carries more than the skill).  A skill
    that is neither is a local copy and names no upstream.
    """
    if entry.is_symlink():
        return entry.resolve()
    manifest = entry / "SKILL.md"
    return manifest.resolve().parent if manifest.is_symlink() else None


def _skill_canon(roots: tuple[Path, ...]) -> dict[str, Any] | None:
    """Which repository the wired skills come from, and when it last fetched.

    Derived from the symlinks the box already has rather than from a configured path,
    so the public package carries no particular company's clone layout: resolve every
    wired skill, walk up to the git working tree that contains it, and take the one
    most of them share.  `syncedAt` is that repository's last fetch — a fact this
    process can measure — never "up to date", which would need the network.
    """
    owners: dict[Path, int] = {}
    for root in roots:
        for name in _skill_names(root):
            canon = _canon_of(root / name)
            if canon is None:
                continue
            for parent in (canon, *canon.parents):
                if (parent / ".git").exists():
                    owners[parent] = owners.get(parent, 0) + 1
                    break
    if not owners:
        return None
    repo = max(owners, key=lambda path: (owners[path], str(path)))
    stamp = None
    for candidate in (repo / ".git" / "FETCH_HEAD", repo / ".git" / "HEAD"):
        try:
            stamp = datetime.fromtimestamp(candidate.stat().st_mtime, timezone.utc)
            break
        except OSError:
            continue
    return {"name": repo.name, "wired": owners[repo],
            "syncedAt": stamp.isoformat().replace("+00:00", "Z") if stamp else None}


# The one harness binary that does not update itself, named once so the collector that
# reports it behind and the wrapper that upgrades it cannot drift apart.
CODEX_PACKAGE = "@openai/codex"


def codex_latest() -> str | None:
    """The published version, or None when the registry could not be asked."""
    return _version(_first_line(["npm", "view", CODEX_PACKAGE, "version"], timeout=45))


def _harness() -> dict[str, Any]:
    installed = _cli("codex")
    latest = codex_latest()
    codex = {"installed": installed, "latest": latest} if installed or latest else None
    # Claude Code updates itself, so there is nothing to compare and nothing to press:
    # the panel shows the version and says so.  Reported under its own key rather than
    # beside codex's installed/latest pair precisely so no reader can build an
    # "outdated" verdict out of a value that has no `latest` to be behind.
    claude_installed = _cli("claude")
    claude = {"installed": claude_installed} if claude_installed else None

    # The harness exposes this stable, user-owned wiring point.  Do not bake a
    # particular company's clone layout into the public Airlock package.
    hook_check = Path(os.environ.get("AIRLOCK_HARNESS_HOOK_CHECK",
                                    "~/.claude/hooks/harness-morning-check.sh")).expanduser()
    hook_out = _first_line(["bash", str(hook_check), "--check-claude-hook-wiring"])
    hooks_drift = hook_out != "claude-hook-wiring: ok"

    roots = _skill_roots()
    names = [_skill_names(root) for root in roots]
    # Per-root counts, because "wired" is per agent.  `skillsWired` stays the total it
    # has always been so an older reader keeps working; the panel reads the split.
    # Per-root counts, and no verdict about the difference between them.  Measured on
    # this box 2026-09-01: of the 8 names present for Claude and not for the Codex CLI,
    # 2 were opt-in canon (no wiring obligation) and 6 were local copies with no canon
    # at all — so "one root has more" is NOT "the other is missing something", and a
    # chip saying it was would have been an alarm that is wrong on its first reading.
    # Which names are OWED to a root is a judgment about the canon, and it belongs to
    # the wiring checker that reads the canon, which lives outside this package.
    skills = {"claude": len(names[0]), "codex": len(names[1]),
              "canon": _skill_canon(roots)}
    return {"claude": claude, "codex": codex, "hooksDrift": hooks_drift,
            "hooksDetail": hook_out, "skills": skills,
            "skillsWired": skills["claude"] + skills["codex"]}


def collect(root: Path, state: Path) -> dict[str, Any]:
    snapshot = {"checkedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "platform": _platform(root), "apps": _apps(root), "harness": _harness()}
    write_snapshot(state, snapshot)
    return snapshot


def write_snapshot(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".updates.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def read_snapshot(path: Path | None = None) -> dict[str, Any] | None:
    try:
        with (path or default_state()).open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return None
    if not _snapshot_shape(value):
        return None
    return value


def _snapshot_shape(value: Any) -> bool:
    """The API never turns a truncated/manual state file into a reassuring 200."""
    if not isinstance(value, dict) or not isinstance(value.get("checkedAt"), str):
        return False
    platform = value.get("platform")
    if platform is not None and (not isinstance(platform, dict)
                                 or type(platform.get("available")) is not bool
                                 or type(platform.get("changedCount")) is not int
                                 or not isinstance(platform.get("ref"), str)):
        return False
    apps = value.get("apps")
    if not isinstance(apps, list):
        return False
    for app in apps:
        if (not isinstance(app, dict) or not isinstance(app.get("id"), str)
                or app.get("action") not in ("upgrade", "lock-mismatch")
                or app.get("sourceClass") not in ("shipped", "explicit")):
            return False
    harness = value.get("harness")
    if (not isinstance(harness, dict) or type(harness.get("hooksDrift")) is not bool
            or type(harness.get("skillsWired")) is not int):
        return False
    # The four fields below arrived after the first shipped collector, so absence is a
    # valid older snapshot and is accepted; a present field still has to be the right
    # shape, because the panel reads it without a second opinion.
    if not _cli_shape(harness.get("codex"), ("installed", "latest")):
        return False
    if not _cli_shape(harness.get("claude"), ("installed",)):
        return False
    if harness.get("hooksDetail") is not None and not isinstance(harness["hooksDetail"], str):
        return False
    return _skills_shape(harness.get("skills"))


def _cli_shape(value: Any, fields: tuple[str, ...]) -> bool:
    if value is None:
        return True
    return isinstance(value, dict) and all(
        value.get(field) is None or isinstance(value.get(field), str) for field in fields)


def _skills_shape(value: Any) -> bool:
    if value is None:
        return True
    if not isinstance(value, dict):
        return False
    if any(type(value.get(key)) is not int for key in ("claude", "codex")):
        return False
    canon = value.get("canon")
    if canon is None:
        return True
    return (isinstance(canon, dict) and isinstance(canon.get("name"), str)
            and type(canon.get("wired")) is int
            and (canon.get("syncedAt") is None or isinstance(canon.get("syncedAt"), str)))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="collect the Airlock update snapshot")
    parser.add_argument("collect", nargs="?")
    parser.add_argument("--root", type=Path, default=default_root())
    parser.add_argument("--state", type=Path, default=default_state())
    args = parser.parse_args(argv)
    try:
        value = collect(args.root.resolve(), args.state.expanduser())
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print("airlock-updates: " + str(exc), file=sys.stderr)
        return 1
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
