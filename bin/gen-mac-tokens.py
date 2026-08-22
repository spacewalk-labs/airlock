#!/usr/bin/env python3
"""Generate the Mac launcher's design tokens from the one file that owns them.

    python3 bin/gen-mac-tokens.py            # write mac/Sources/.../DesignTokens.swift
    python3 bin/gen-mac-tokens.py --stdout   # print instead, for the drift test

Why this exists: `hub/assets/airlock-tokens.css` says it in its own rule 4 —
"Components read tokens. No raw hex outside this file." A Swift app cannot read a
CSS custom property at runtime, so the only honest way for it to obey that rule is
for its values to be *derived* from that file rather than typed a second time. Every
hex in the generated Swift is therefore a copy the machine made, and
install/test-mac-tokens.py fails the build the moment the two disagree.

The alternative — a hand-written Swift palette — is the thing rule 4 forbids, and it
would not fail anything when the CSS moved. It would just look slightly wrong on one
platform, which is the failure mode nobody reports.

The generated file lives in `AirlockLauncherCore`, which has no SwiftUI in it (see
mac/Package.swift), so colours come out as plain component values and the SwiftUI
layer turns them into `Color`.
"""
from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
CSS = os.path.join(ROOT, "hub", "assets", "airlock-tokens.css")
OUT = os.path.join(ROOT, "mac", "Sources", "AirlockLauncherCore", "DesignTokens.swift")

# The palette, in the order the CSS groups it. Names are the CSS token minus the
# prefix; the Swift property is the camelCase of that. Listed explicitly rather than
# scraped so that a token DISAPPEARING from the CSS is an error here rather than a
# property that silently stops existing.
PALETTE = [
    ("canvas", "canvas"),
    ("surface-1", "surface1"),
    ("surface-2", "surface2"),
    ("hairline", "hairline"),
    ("ink", "ink"),
    ("body", "body"),
    ("mute", "mute"),
    ("primary", "primary"),
    ("on-primary", "onPrimary"),
    ("warning", "warning"),
    ("danger", "danger"),
    ("edge", "edge"),
]
RADII = [("r-sm", "sm"), ("r-md", "md"), ("r-lg", "lg"), ("r-tile", "tile")]
SPACING = [("sp-1", "s1"), ("sp-2", "s2"), ("sp-3", "s3"), ("sp-4", "s4"),
           ("sp-5", "s5"), ("sp-6", "s6"), ("sp-8", "s8"), ("sp-12", "s12")]
FONT_SIZES = [("fs-body", "body"), ("fs-lg", "lg"), ("fs-sm", "sm"),
              ("fs-xs", "xs"), ("fs-h1", "h1"), ("fs-h2", "h2")]
WEIGHTS = [("fw-regular", "regular"), ("fw-medium", "medium"),
           ("fw-semibold", "semibold"), ("fw-bold", "bold")]

BLOCK = re.compile(r"(?P<sel>:root|\[data-theme=\"light\"\])\s*\{(?P<body>[^}]*)\}", re.S)
DECL = re.compile(r"--airlock-([a-z0-9-]+)\s*:\s*([^;]+);")


def die(message: str) -> None:
    sys.stderr.write("gen-mac-tokens: %s\n" % message)
    raise SystemExit(1)


def blocks(css: str) -> dict:
    """The two theme blocks, by selector. The `@media (prefers-color-scheme: light)`
    copy is deliberately NOT read: it is the same values as `[data-theme="light"]`,
    the CSS says so, and reading both would make this generator's answer depend on
    which one it happened to match first."""
    found = {}
    for match in BLOCK.finditer(css):
        selector = match.group("sel")
        if selector in found:
            continue                      # first wins; see the note above
        found[selector] = dict(
            (name, value.strip()) for name, value in DECL.findall(match.group("body")))
    for required in (":root", '[data-theme="light"]'):
        if required not in found:
            die("%s has no %s block" % (CSS, required))
    return found


def rgba(value: str, token: str) -> tuple:
    value = value.strip()
    hexed = re.fullmatch(r"#([0-9a-fA-F]{6})", value)
    if hexed:
        raw = hexed.group(1)
        return (int(raw[0:2], 16) / 255, int(raw[2:4], 16) / 255,
                int(raw[4:6], 16) / 255, 1.0)
    functional = re.fullmatch(r"rgba\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]*)\s*\)",
                              value)
    if functional:
        red, green, blue, alpha = functional.groups()
        return (float(red) / 255, float(green) / 255, float(blue) / 255,
                float(alpha if alpha not in ("", ".") else "0"))
    die("--airlock-%s is %r, which is neither #rrggbb nor rgba()" % (token, value))


def px(value: str, token: str) -> float:
    match = re.fullmatch(r"([0-9.]+)px", value.strip())
    if not match:
        die("--airlock-%s is %r, which is not a px length" % (token, value))
    return float(match.group(1))


def em(value: str, token: str) -> float:
    match = re.fullmatch(r"(-?[0-9.]+)em", value.strip())
    if not match:
        die("--airlock-%s is %r, which is not an em length" % (token, value))
    return float(match.group(1))


def integer(value: str, token: str) -> int:
    if not re.fullmatch(r"[0-9]+", value.strip()):
        die("--airlock-%s is %r, which is not an integer" % (token, value))
    return int(value)


def get(scope: dict, token: str) -> str:
    if token not in scope:
        die("--airlock-%s is not defined in %s" % (token, CSS))
    return scope[token]


def palette(name: str, scope: dict, base: dict) -> str:
    lines = ["    /// %s.\n    public static let %s = Palette(" % (
        "The canonical theme" if name == "dark" else "The light override", name)]
    body = []
    for token, swift in PALETTE:
        # A light block that does not restate a token inherits the dark value, which
        # is exactly what the CSS does — and exactly the bug test-design-tokens.py
        # names, so it is resolved here the same way the browser would.
        value = scope.get(token, base.get(token))
        if value is None:
            die("--airlock-%s is defined in neither theme" % token)
        red, green, blue, alpha = rgba(value, token)
        body.append("        %s: TokenColor(%.6f, %.6f, %.6f, %.6f)"
                    % (swift, red, green, blue, alpha))
    lines.append(",\n".join(body))
    lines.append("    )")
    return "\n".join(lines)


def render(css: str) -> str:
    found = blocks(css)
    dark = found[":root"]
    light = found['[data-theme="light"]']

    out = ['''// GENERATED FILE — do not edit.
//
// Source: hub/assets/airlock-tokens.css · Generator: bin/gen-mac-tokens.py
// Regenerate: python3 bin/gen-mac-tokens.py
// Drift gate: install/test-mac-tokens.py (runs in CI)
//
// The CSS is the single source of truth for Airlock's design values, and its own
// rule 4 is "no raw hex outside this file". A Swift app cannot read a CSS custom
// property, so these values are DERIVED from it rather than typed again — every
// number below was copied by the generator, and the gate fails the build if the two
// ever disagree.
//
// No SwiftUI here on purpose: this target is the SwiftUI-free core (mac/Package.swift),
// so a colour is its components and the view layer turns it into a `Color`.

/// One colour, as components in the 0...1 range the platform wants.
public struct TokenColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

public enum DesignTokens {
    /// Eleven colours in four groups, plus the edge rim. Hierarchy comes from the two
    /// ladders (canvas/surface/hairline, ink/body/mute), never from hue — see the
    /// rules at the top of the CSS.
    public struct Palette: Equatable, Sendable {''']

    fields = "\n".join("        public let %s: TokenColor" % swift for _, swift in PALETTE)
    out.append(fields)
    out.append("    }\n")
    out.append(palette("dark", dark, dark))
    out.append("")
    out.append(palette("light", light, dark))
    out.append("")

    out.append("    /// Corner radii. `tile` is its own step rather than part of the\n"
               "    /// scale: at 60 points the difference from 14 or 16 is visible.")
    out.append("    public enum Radius {")
    for token, swift in RADII:
        out.append("        public static let %s: Double = %g" % (swift, px(get(dark, token), token)))
    out.append("    }\n")

    out.append("    /// The 4-point spacing base.")
    out.append("    public enum Space {")
    for token, swift in SPACING:
        out.append("        public static let %s: Double = %g" % (swift, px(get(dark, token), token)))
    out.append("    }\n")

    out.append("    /// Literal sizes, not a computed scale — the CSS says they were chosen.")
    out.append("    public enum FontSize {")
    for token, swift in FONT_SIZES:
        out.append("        public static let %s: Double = %g" % (swift, px(get(dark, token), token)))
    out.append("    }\n")

    out.append("    public enum Weight {")
    for token, swift in WEIGHTS:
        out.append("        public static let %s: Int = %d" % (swift, integer(get(dark, token), token)))
    out.append("    }\n")

    out.append("    public enum Tracking {")
    out.append("        /// Body and headings.")
    out.append("        public static let tight: Double = %g" % em(get(dark, "track"), "track"))
    out.append("        /// Uppercase labels only.")
    out.append("        public static let caps: Double = %g" % em(get(dark, "track-caps"), "track-caps"))
    out.append("    }\n")

    out.append("    public enum LineHeight {")
    out.append("        public static let normal: Double = %g" % float(get(dark, "lh")))
    out.append("    }")
    out.append("}")
    return "\n".join(out) + "\n"


def main() -> int:
    if not os.path.exists(CSS):
        die("%s is missing — the tokens are the source, not this script" % CSS)
    swift = render(open(CSS, encoding="utf-8").read())
    if "--stdout" in sys.argv[1:]:
        sys.stdout.write(swift)
        return 0
    with open(OUT, "w", encoding="utf-8") as handle:
        handle.write(swift)
    sys.stderr.write("gen-mac-tokens: wrote %s\n" % os.path.relpath(OUT, ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
