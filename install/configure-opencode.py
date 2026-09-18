#!/usr/bin/env python3
"""Install Airlock's standard OpenCode model and subagent defaults."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat
import tempfile


MODEL = "xai/grok-4.6"
# Live standard (2026-09-16): opencode-go + xai + google + openai. Anthropic is
# deliberately absent — OpenCode's Anthropic path bills the company 1P shared
# ANTHROPIC_API_KEY instead of a personal subscription, so it stays off.
ENABLED_PROVIDERS = ["opencode-go", "xai", "google", "openai"]
# Live whitelists (fresh-install defaults; existing member whitelists are
# preserved except for the two opencode-go guardrails below).
OPENCODE_GO_WHITELIST = ["muse-spark-1.3-contributor"]
XAI_WHITELIST = ["grok-4.6", "grok-build-0.1"]
GOOGLE_WHITELIST = [
    "gemini-3.7-flash",
    "gemini-3.6-flash",
    "gemini-3.5-flash",
    "gemini-3.5-flash-lite",
    "gemini-3.1-flash-lite",
]
OPENAI_WHITELIST = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
# Free Muse tier is not registered (human decision 2026-09-16). Never written;
# removed from an existing opencode-go whitelist if a member added it by hand.
FREE_MODEL_IDS = frozenset(
    {
        "muse-spark-1.3-contributor-free",
        "opencode/muse-spark-1.3-contributor-free",
    }
)
# OpenCode compacts at context - output. grok-4.6 compacts at 200k, before xAI's
# >=200k long-context price (cached input $1/M) applies to a cache-heavy agent loop.
GROK_CONTEXT = {
    "grok-4.6": 230_000,
    "grok-build-0.1": 400_000,
}
GROK_OUTPUT = {
    "grok-4.6": 30_000,
    "grok-build-0.1": 256_000,
}
# Live standard openai limits (2026-09-16): 350k context / 128k output.
OPENAI_CONTEXT = {
    "gpt-5.6-sol": 350_000,
    "gpt-5.6-terra": 350_000,
    "gpt-5.6-luna": 350_000,
}
OPENAI_OUTPUT = {
    "gpt-5.6-sol": 128_000,
    "gpt-5.6-terra": 128_000,
    "gpt-5.6-luna": 128_000,
}
AGENTS = {
    # Muse Spark 1.3 Contributor (OpenCode Go). Highest accepted variant is
    # xhigh — `max` is rejected by OpenCode Go with invalid_request_error
    # (measured 2026-09-16). Never write `max` here.
    "muse-spark-1.3-contributor": {
        "mode": "subagent",
        "model": "opencode-go/muse-spark-1.3-contributor",
        "variant": "xhigh",
        "description": "Muse Spark 1.3 Contributor (xhigh)",
    },
    "gpt-5.6-luna": {
        "mode": "subagent",
        "model": "openai/gpt-5.6-luna",
        "variant": "max",
        "description": "GPT-5.6 Luna (max)",
    },
    "gpt-5.6-terra": {
        "mode": "subagent",
        "model": "openai/gpt-5.6-terra",
        "variant": "high",
        "description": "GPT-5.6 Terra (high)",
    },
    "gpt-5.6-sol": {
        "mode": "subagent",
        "model": "openai/gpt-5.6-sol",
        "variant": "medium",
        "description": "GPT-5.6 Sol (medium)",
    },
    "grok-4.6": {
        "mode": "subagent",
        "model": "xai/grok-4.6",
        "variant": "high",
        "description": "Grok 4.6 (high)",
    },
    "gemini-3.7-flash": {
        "mode": "subagent",
        "model": "google/gemini-3.7-flash",
        "variant": "medium",
        "description": "Gemini 3.7 Flash (medium)",
    },
    "gemini-3.5-flash-lite": {
        "mode": "subagent",
        "model": "google/gemini-3.5-flash-lite",
        "description": "Gemini 3.5 Flash Lite (default)",
    },
}


def strip_jsonc(source: str) -> str:
    """Remove JSONC comments and trailing commas without touching strings."""
    out: list[str] = []
    index = 0
    in_string = False
    escaped = False
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if in_string:
            out.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            out.append(char)
            index += 1
            continue
        if char == "/" and next_char == "/":
            index += 2
            while index < len(source) and source[index] not in "\r\n":
                index += 1
            continue
        if char == "/" and next_char == "*":
            index += 2
            while index + 1 < len(source) and source[index : index + 2] != "*/":
                out.append("\n" if source[index] == "\n" else " ")
                index += 1
            if index + 1 >= len(source):
                raise ValueError("unterminated block comment")
            index += 2
            continue
        out.append(char)
        index += 1
    if in_string:
        raise ValueError("unterminated string")

    without_comments = "".join(out)
    out = []
    index = 0
    in_string = False
    escaped = False
    while index < len(without_comments):
        char = without_comments[index]
        if in_string:
            out.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            out.append(char)
            index += 1
            continue
        if char == ",":
            lookahead = index + 1
            while lookahead < len(without_comments) and without_comments[lookahead].isspace():
                lookahead += 1
            if lookahead < len(without_comments) and without_comments[lookahead] in "}]":
                index += 1
                continue
        out.append(char)
        index += 1
    return "".join(out)


def read_config(path: Path) -> dict:
    if not path.exists():
        return {"$schema": "https://opencode.ai/config.json"}
    raw = path.read_text(encoding="utf-8")
    parsed = json.loads(strip_jsonc(raw))
    if not isinstance(parsed, dict):
        raise ValueError("top level must be an object")
    return parsed


def atomic_write(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
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


def _require_object(value: object, name: str) -> dict:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return value


def apply_grok_limits(config: dict) -> None:
    provider = _require_object(config.setdefault("provider", {}), "provider")
    xai = _require_object(provider.setdefault("xai", {}), "provider.xai")
    models = _require_object(xai.setdefault("models", {}), "provider.xai.models")
    for model_id, output in GROK_OUTPUT.items():
        entry = models.get(model_id)
        if not isinstance(entry, dict):
            entry = {}
            models[model_id] = entry
        limit = entry.get("limit")
        if not isinstance(limit, dict):
            limit = {}
            entry["limit"] = limit
        limit["context"] = GROK_CONTEXT[model_id]
        # A box's own output survives, unless it would leave no room to compact.
        existing = limit.get("output")
        if not isinstance(existing, (int, float)) or existing >= limit["context"]:
            limit["output"] = output


def apply_enabled_providers(config: dict) -> None:
    """Ensure the live provider set without breaking boxes that lack a key.

    Fresh homes get exactly ENABLED_PROVIDERS. Existing lists keep their own
    entries and order; missing required providers are appended in canonical
    order and `anthropic` is removed (cost guardrail, see module comment).
    Never reads auth.json, so a box without an `opencode-go` key still gets a
    working config — OpenCode simply shows that provider as logged-out while
    xai/google/openai keep working. The default seat stays xai/grok-4.6.
    """
    existing = config.get("enabled_providers")
    if not isinstance(existing, list):
        config["enabled_providers"] = list(ENABLED_PROVIDERS)
        return
    cleaned: list[str] = []
    for entry in existing:
        if not isinstance(entry, str) or entry == "anthropic" or entry in cleaned:
            continue
        cleaned.append(entry)
    for required in ENABLED_PROVIDERS:
        if required not in cleaned:
            cleaned.append(required)
    config["enabled_providers"] = cleaned


def apply_provider_whitelists(config: dict) -> None:
    """Fresh-home whitelists; member whitelists are preserved.

    Only two guardrails touch an existing opencode-go whitelist: the Muse
    model is ensured present and the unregistered free tier is removed. Other
    providers' existing whitelists are left byte-for-byte alone.
    """
    provider = _require_object(config.setdefault("provider", {}), "provider")
    defaults = {
        "opencode-go": OPENCODE_GO_WHITELIST,
        "xai": XAI_WHITELIST,
        "google": GOOGLE_WHITELIST,
        "openai": OPENAI_WHITELIST,
    }
    for provider_id, default_list in defaults.items():
        entry = provider.get(provider_id)
        if not isinstance(entry, dict):
            entry = {}
            provider[provider_id] = entry
        whitelist = entry.get("whitelist")
        if not isinstance(whitelist, list):
            entry["whitelist"] = list(default_list)
        elif provider_id == "opencode-go":
            filtered = [m for m in whitelist if m not in FREE_MODEL_IDS]
            if "muse-spark-1.3-contributor" not in filtered:
                filtered.append("muse-spark-1.3-contributor")
            entry["whitelist"] = filtered


def apply_openai_limits(config: dict) -> None:
    provider = _require_object(config.setdefault("provider", {}), "provider")
    openai = _require_object(provider.setdefault("openai", {}), "provider.openai")
    models = _require_object(openai.setdefault("models", {}), "provider.openai.models")
    for model_id, output in OPENAI_OUTPUT.items():
        entry = models.get(model_id)
        if not isinstance(entry, dict):
            entry = {}
            models[model_id] = entry
        limit = entry.get("limit")
        if not isinstance(limit, dict):
            limit = {}
            entry["limit"] = limit
        limit["context"] = OPENAI_CONTEXT[model_id]
        existing = limit.get("output")
        if not isinstance(existing, (int, float)) or existing >= limit["context"]:
            limit["output"] = output


def configure(home: Path) -> None:
    path = home / ".config" / "opencode" / "opencode.jsonc"
    config = read_config(path)
    config["model"] = MODEL
    config["agent"] = AGENTS
    apply_enabled_providers(config)
    apply_provider_whitelists(config)
    apply_grok_limits(config)
    apply_openai_limits(config)
    atomic_write(path, config)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", type=Path, required=True)
    args = parser.parse_args()
    configure(args.home)


if __name__ == "__main__":
    main()
