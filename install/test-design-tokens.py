#!/usr/bin/env python3
"""install/test-design-tokens.py — the design token gate.

Three things are checked, and each of them is a mistake that has actually
shipped in some design system rather than a hypothetical:

  1. **Every foreground/background pair meets WCAG AA.** A mid grey that looks
     correct on a designer's monitor lands at 3.3:1 and fails outright; the
     only way to know is to compute it. Warning-only contrast checks get
     ignored, so this one fails the build.

  2. **Every token used is defined.** A `var(--airlock-typo)` silently falls
     back to nothing and the component renders unstyled in exactly the theme
     nobody tested.

  3. **Both themes define the same token names.** A token present in dark and
     missing in light does not error — it inherits the dark value and produces
     one illegible element.

Run: python3 install/test-design-tokens.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOKENS = ROOT / "hub" / "assets" / "airlock-tokens.css"

# Files that consume tokens. Kept explicit rather than globbed: a glob would
# quietly start scanning vendored upstream CSS and report failures we do not own.
CONSUMERS = [
    ROOT / "hub" / "index.html",
    ROOT / "hub" / "wrong-owner.html",
]

AA_NORMAL = 4.5   # body text
AA_LARGE = 3.0    # >=24px, or >=19px bold
AA_NONTEXT = 3.0  # borders, focus rings, icon glyphs


def srgb_to_linear(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(hex_colour: str) -> float:
    h = hex_colour.lstrip("#")
    if len(h) == 3:
        h = "".join(ch * 2 for ch in h)
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return (0.2126 * srgb_to_linear(r)
            + 0.7152 * srgb_to_linear(g)
            + 0.0722 * srgb_to_linear(b))


def contrast(fg: str, bg: str) -> float:
    a, b = luminance(fg), luminance(bg)
    lo, hi = sorted((a, b))
    return (hi + 0.05) / (lo + 0.05)


def parse_block(css: str, selector: str) -> dict[str, str]:
    """Return the --airlock-* declarations inside the first matching block."""
    idx = css.find(selector)
    if idx < 0:
        return {}
    start = css.index("{", idx)
    depth, end = 0, start
    for i in range(start, len(css)):
        if css[i] == "{":
            depth += 1
        elif css[i] == "}":
            depth -= 1
            if depth == 0:
                end = i
                break
    body = css[start:end]
    return dict(re.findall(r"(--airlock-[\w-]+)\s*:\s*([^;]+);", body))


# Foreground, background, minimum ratio, and what the pair is for. Only pairs
# that actually occur in the UI are listed — inventing pairs to test would
# manufacture failures for combinations no one renders.
PAIRS = [
    # Both text ladders, on all three surfaces. The full cross-product is
    # listed because the pair that failed last time (a secondary grey inside a
    # badge) passed on the page and on a card — only the third surface caught it.
    ("--airlock-ink",        "--airlock-canvas",    AA_NORMAL,  "primary text on the page"),
    ("--airlock-ink",        "--airlock-surface-1", AA_NORMAL,  "primary text on a card"),
    ("--airlock-ink",        "--airlock-surface-2", AA_NORMAL,  "primary text on a nested surface"),
    ("--airlock-body",       "--airlock-canvas",    AA_NORMAL,  "secondary text on the page"),
    ("--airlock-body",       "--airlock-surface-1", AA_NORMAL,  "secondary text on a card"),
    ("--airlock-body",       "--airlock-surface-2", AA_NORMAL,  "secondary text on a nested surface"),
    ("--airlock-mute",       "--airlock-canvas",    AA_NORMAL,  "label on the page"),
    ("--airlock-mute",       "--airlock-surface-1", AA_NORMAL,  "label on a card"),
    ("--airlock-mute",       "--airlock-surface-2", AA_NORMAL,  "label on a nested surface"),
    ("--airlock-primary",    "--airlock-canvas",    AA_NORMAL,  "link on the page"),
    ("--airlock-primary",    "--airlock-surface-1", AA_NORMAL,  "link on a card"),
    ("--airlock-primary",    "--airlock-surface-2", AA_NORMAL,  "link on a nested surface"),
    ("--airlock-on-primary", "--airlock-primary",   AA_NORMAL,  "label on a primary button"),
    ("--airlock-warning",    "--airlock-canvas",    AA_LARGE,   "warning text on the page"),
    ("--airlock-warning",    "--airlock-surface-1", AA_LARGE,   "warning text on a card"),
    ("--airlock-danger",     "--airlock-canvas",    AA_LARGE,   "danger text on the page"),
    ("--airlock-danger",     "--airlock-surface-1", AA_LARGE,   "danger text on a card"),
    ("--airlock-hairline",   "--airlock-canvas",    1.0,        "hairline on the page (informational)"),
]

THEMES = {"dark (canonical)": ":root", "light": '[data-theme="light"]'}


def main() -> int:
    if not TOKENS.exists():
        print(f"FAIL  token file missing: {TOKENS}", file=sys.stderr)
        return 1

    css = TOKENS.read_text(encoding="utf-8")
    themes = {name: parse_block(css, sel) for name, sel in THEMES.items()}
    failures: list[str] = []

    # --- 3. both themes define the same names -----------------------------
    dark, light = themes["dark (canonical)"], themes["light"]
    if not dark or not light:
        print("FAIL  could not parse both theme blocks", file=sys.stderr)
        return 1

    colour_only = {k for k, v in dark.items() if v.strip().startswith("#")}
    missing = sorted(colour_only - set(light))
    if missing:
        failures.append(
            "light theme does not override these colour tokens, so they inherit "
            "the dark value: " + ", ".join(missing))

    # --- 1. contrast -------------------------------------------------------
    print("contrast (WCAG AA)")
    for theme, tok in themes.items():
        print(f"  {theme}")
        for fg, bg, minimum, what in PAIRS:
            if fg not in tok or bg not in tok:
                failures.append(f"[{theme}] {what}: {fg} or {bg} is not defined")
                continue
            fg_v, bg_v = tok[fg].strip(), tok[bg].strip()
            if not (fg_v.startswith("#") and bg_v.startswith("#")):
                continue
            ratio = contrast(fg_v, bg_v)
            ok = ratio >= minimum
            mark = "ok  " if ok else "FAIL"
            note = "" if minimum > 1.0 else "  (informational)"
            print(f"    {mark} {ratio:5.2f}:1  (min {minimum})  {what}{note}")
            if not ok and minimum > 1.0:
                failures.append(
                    f"[{theme}] {what}: {fg_v} on {bg_v} is {ratio:.2f}:1, "
                    f"needs {minimum}:1")

    # --- 2. every token used is defined ------------------------------------
    defined = set(dark) | set(light)
    for path in CONSUMERS:
        if not path.exists():
            continue
        used = set(re.findall(r"var\(\s*(--airlock-[\w-]+)", path.read_text(encoding="utf-8")))
        for name in sorted(used - defined):
            failures.append(f"{path.relative_to(ROOT)} uses {name}, which is not defined")

    print()
    if failures:
        for f in failures:
            print(f"FAIL  {f}", file=sys.stderr)
        print(f"\n{len(failures)} failure(s)", file=sys.stderr)
        return 1

    print(f"ok — {len(dark)} tokens, {len(PAIRS)} pairs, both themes complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
