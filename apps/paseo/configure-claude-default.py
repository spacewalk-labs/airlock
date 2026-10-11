#!/usr/bin/env python3
"""Mark one Claude model as Paseo's default in <paseo-home>/config.json.

When a seat is created without a model (`paseo run --provider claude`, an MCP
create_agent with no model), the daemon picks the catalog entry flagged
`isDefault` and passes it to Claude explicitly. That flag comes from Paseo's
built-in manifest, which pins the previous Opus: on 2026-10-09
(@getpaseo/server 0.8.x) `--provider claude` opened `claude-opus-5` while
`claude-opus-5-5` was current. `agents.providers.claude.additionalModels`
entries with `isDefault: true` override that flag (provider-registry
mergeModelAdditions), so this writes exactly one such entry.

Owns only `isDefault` inside agents.providers.claude.additionalModels: other
entries keep their fields, and an already-correct file is left byte-identical.
An empty model id removes the flag and leaves Paseo's own default (the entry
itself stays; it only re-lists a model Paseo already knows).

Exit 0 = nothing changed, 2 = wrote a change (caller restarts the daemon).
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import tempfile
from pathlib import Path


def label(model: str) -> str:
    """Paseo's config schema requires a label. Same shape as its own catalog:
    claude-opus-5-5 -> "Opus 5.5", claude-fable-5-1 -> "Fable 5.1"."""
    family, *version = model.removeprefix("claude-").split("-")
    return " ".join([family.capitalize(), ".".join(version)]).strip()


def apply(config: dict, model: str) -> dict:
    claude = config.get("agents", {}).get("providers", {}).get("claude", {})
    entries = [dict(e) for e in claude.get("additionalModels", []) if isinstance(e, dict)]
    for entry in entries:
        entry.pop("isDefault", None)
    if model:
        match = next((e for e in entries if e.get("id") == model), None)
        if match is None:
            match = {"id": model}
            entries.append(match)
        match.setdefault("label", label(model))
        match["isDefault"] = True
    if entries:
        providers = config.setdefault("agents", {}).setdefault("providers", {})
        providers.setdefault("claude", {})["additionalModels"] = entries
    return config


def write(path: Path, data: dict) -> None:
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--paseo-home", required=True, type=Path)
    parser.add_argument("--model", required=True, help='e.g. "claude-opus-5-5"; "" = Paseo default')
    args = parser.parse_args()

    path = args.paseo_home / "config.json"
    before = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    after = apply(json.loads(json.dumps(before)), args.model.strip())
    if after == before:
        return 0
    write(path, after)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
