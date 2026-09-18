#!/usr/bin/env python3
"""Register the agy-acp Paseo provider and the Gemini/agy skills.json entry.

Two idempotent, minimal-footprint JSON edits — neither ever touches a field it
does not own:

  <paseo-home>/config.json  agents.providers.agy = {"extends": "acp", ...}
    "extends": "acp" is Paseo's existing generic-ACP provider type
    (GenericACPAgentClient) — no Paseo source patch is involved. There is no
    "models" key: the fork's acp-agent.js probes `agy models` itself and
    reports the live catalog over ACP, so a static list here would only go
    stale. See apps/paseo/agy-acp/README.md.

  <home>/.gemini/config/skills.json  entries += {"path": "<home>/.claude/skills"}
    Absolute path — `~` is not expanded by whatever reads this file, so the
    literal `~` would resolve relative to nothing.

Both writes are additive and comparison-gated: an already-correct file is left
byte-identical (no unnecessary daemon restart, no unnecessary agy relaunch).
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import tempfile
from pathlib import Path


def read_json(path: Path) -> dict:
    if not path.exists():
        return {}
    raw = path.read_text(encoding="utf-8")
    if not raw.strip():
        return {}
    parsed = json.loads(raw)
    if not isinstance(parsed, dict):
        raise ValueError(f"{path}: top level must be an object")
    return parsed


def atomic_write_if_changed(path: Path, data: dict) -> bool:
    """Writes `data` to `path` only if the parsed content actually differs.

    Returns True if the file was written. Mirrors install/configure-opencode.py's
    atomic_write (tempfile + fsync + os.replace + directory fsync), plus a
    before/after comparison so re-running the installer is a true no-op.
    """
    if path.exists():
        try:
            if read_json(path) == data:
                return False
        except (ValueError, json.JSONDecodeError):
            pass  # unreadable/corrupt existing file — fall through and overwrite
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    return True


def _require_object(value: object, name: str) -> dict:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return value


def _points_at_unpatched_global_install(entry: object) -> bool:
    """True if a provider's command runs the OLD unpatched npm-global
    translator (`.../node_modules/google-antigravity-acp/dist/cli.js`) rather
    than this fork's own managed install (`~/.local/share/agy-acp/...`).

    Pre-dates this installer: earlier exploratory sessions hand-wrote
    `agy-low`/`agy-opus`/`agy-gpt` providers pointing at a global `npm install
    -g google-antigravity-acp` — unpatched upstream, none of this fork's
    interrupt/resume/mode fixes. Matched on the npm package directory name,
    not the exact nvm version path (which varies per box/upgrade), and
    excludes anything already under our own install dir so a second
    `agy-acp/install.sh` run never removes what it just wrote.
    """
    if not isinstance(entry, dict):
        return False
    command = entry.get("command")
    if not isinstance(command, list):
        return False
    marker = "/node_modules/google-antigravity-acp/"
    return any(
        isinstance(arg, str) and marker in arg and "/.local/share/agy-acp/" not in arg
        for arg in command
    )


def remove_stale_manual_aliases(providers: dict) -> list[str]:
    """Removes agy-* provider entries (agy-low, agy-opus, agy-gpt, ...) that
    still point at the pre-fork global install. Never touches `agy` itself,
    and never touches an agy-* entry that doesn't match — an operator's own
    differently-configured agy-* provider is not this installer's to remove.
    """
    stale = [
        key
        for key, entry in list(providers.items())
        if key != "agy" and key.startswith("agy-") and _points_at_unpatched_global_install(entry)
    ]
    for key in stale:
        del providers[key]
    return stale


def configure_provider(paseo_home: Path, command: list[str], label: str, description: str) -> tuple[bool, list[str]]:
    path = paseo_home / "config.json"
    config = read_json(path)
    agents = _require_object(config.setdefault("agents", {}), "agents")
    providers = _require_object(agents.setdefault("providers", {}), "agents.providers")
    removed = remove_stale_manual_aliases(providers)
    providers["agy"] = {
        "extends": "acp",
        "label": label,
        "description": description,
        "command": command,
    }
    written = atomic_write_if_changed(path, config)
    return written, removed


def configure_skills(home: Path) -> bool:
    path = home / ".gemini" / "config" / "skills.json"
    config = read_json(path)
    entries = config.setdefault("entries", [])
    if not isinstance(entries, list):
        raise ValueError(f"{path}: entries must be an array")
    skills_path = str(home / ".claude" / "skills")
    if not any(isinstance(e, dict) and e.get("path") == skills_path for e in entries):
        entries.append({"path": skills_path})
    return atomic_write_if_changed(path, config)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, required=True, help="$HOME (for ~/.gemini/config/skills.json)")
    parser.add_argument("--paseo-home", type=Path, required=True, help="Paseo home (for config.json)")
    parser.add_argument("--node-bin", required=True, help="absolute path to node")
    parser.add_argument("--cli-js", required=True, help="absolute path to the fork's dist/cli.js")
    parser.add_argument("--label", default="Antigravity (agy)")
    parser.add_argument("--description", default="Google Antigravity CLI (agy) via the Airlock agy-acp fork")
    args = parser.parse_args()

    command = [args.node_bin, args.cli_js]
    provider_written, removed_aliases = configure_provider(args.paseo_home, command, args.label, args.description)
    skills_written = configure_skills(args.home)

    print(f"agy provider config: {'written' if provider_written else 'already up to date'} ({args.paseo_home / 'config.json'})")
    if removed_aliases:
        print(f"agy provider config: removed stale manual alias(es) pointing at the pre-fork global install: {', '.join(sorted(removed_aliases))}")
    print(f"gemini skills.json: {'written' if skills_written else 'already up to date'} ({args.home / '.gemini' / 'config' / 'skills.json'})")
    if provider_written:
        print("note: the paseo daemon must restart to pick up the new provider")


if __name__ == "__main__":
    main()
