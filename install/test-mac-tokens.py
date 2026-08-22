#!/usr/bin/env python3
"""install/test-mac-tokens.py — the Mac launcher's tokens are still the CSS's tokens.

    python3 install/test-mac-tokens.py

`hub/assets/airlock-tokens.css` owns Airlock's design values and says so in its own
rule 4: no raw hex outside that file. A Swift app cannot read a CSS custom property,
so `mac/Sources/AirlockLauncherCore/DesignTokens.swift` is GENERATED from it by
bin/gen-mac-tokens.py — and a generated file that nobody regenerates is just a stale
copy with a comment claiming otherwise.

So this runs the generator and compares. It is the only gate that fires when someone
changes a colour in the CSS and ships it to the web while the Mac app keeps the old
one: there is no macOS runner in CI, the Swift checks are run by hand on a Mac, and
a palette that differs by one shade fails nothing and is reported by nobody.

Four claims:

  1. The committed Swift is byte-identical to what the generator produces today.
  2. Every colour in the CSS palette reached the Swift file. A generator that
     silently dropped a token would still be byte-identical to itself.
  3. The two themes carry the same token names, so a Mac in light mode cannot
     inherit one dark value and render one illegible control. (The same claim
     install/test-design-tokens.py makes about the CSS, asked again after the
     values have crossed into another language.)
  4. No Swift source in the launcher carries a colour of its own — a hex literal, a
     component-built `Color`, an AppKit system colour, or one of SwiftUI's stock hues
     and hierarchical styles. That is rule 4 ("components read tokens") and rule 2
     ("hierarchy comes from the ladders, not from hue") checked where they can
     actually be broken, and it comes with a positive control: the same scanner is run
     over a line that is definitely wrong, because a scanner that finds nothing looks
     identical to one whose pattern never matches.
"""
from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
GENERATOR = os.path.join(ROOT, "bin", "gen-mac-tokens.py")
GENERATED = os.path.join(ROOT, "mac", "Sources", "AirlockLauncherCore", "DesignTokens.swift")
SOURCES = os.path.join(ROOT, "mac", "Sources")

failures = []
passed = 0


def ok(message: str) -> None:
    global passed
    passed += 1
    print("ok   %s" % message)


def bad(message: str) -> None:
    failures.append(message)
    print("FAIL %s" % message)


def load_generator():
    spec = importlib.util.spec_from_file_location("gen_mac_tokens", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


HEX = re.compile(r"#[0-9a-fA-F]{6}\b")
BUILT = re.compile(r"\bColor\s*\(\s*(?:\.sRGB|red|white|hue)\b")
SYSTEM = re.compile(r"\bColor\s*\(\s*nsColor:|\bNSColor\.")
# Stock hues and the hierarchical styles alike: hierarchy in this system comes from the
# ink/body/mute ladder, so `.secondary` bypasses it exactly as `.green` bypasses the
# palette. The lookbehind is what keeps `theme.primary` — a token — from matching.
STOCK = re.compile(r"(?<![\w.])\.(?:accentColor|green|red|orange|yellow|blue|purple|pink|"
                   r"gray|brown|teal|indigo|mint|cyan|primary|secondary|tertiary|quaternary)\b")


def own_colours(text: str) -> list:
    """Every place this Swift chooses a colour instead of reading one. Returns
    "<line> <what>" strings; the generated token file is the only legitimate source and
    is not passed here."""
    hits = []
    for pattern, what in ((HEX, "a hex literal"),
                          (BUILT, "a Color built from components"),
                          (SYSTEM, "an AppKit system colour"),
                          (STOCK, "a stock SwiftUI colour")):
        for match in pattern.finditer(text):
            hits.append("%d %s (%s)" % (text[:match.start()].count("\n") + 1, what,
                                        match.group(0).strip()))
    return hits


def main() -> int:
    if not os.path.exists(GENERATED):
        bad("mac/Sources/AirlockLauncherCore/DesignTokens.swift is missing — "
            "run python3 bin/gen-mac-tokens.py")
        print("---\npassed=%d failed=%d" % (passed, len(failures)))
        return 1

    # 1. Drift.
    produced = subprocess.run([sys.executable, GENERATOR, "--stdout"],
                              capture_output=True, text=True)
    if produced.returncode != 0:
        bad("the generator failed: %s" % produced.stderr.strip())
    else:
        committed = open(GENERATED, encoding="utf-8").read()
        if produced.stdout == committed:
            ok("the committed Swift tokens are what the CSS produces today")
        else:
            bad("mac/.../DesignTokens.swift has drifted from "
                "hub/assets/airlock-tokens.css — run python3 bin/gen-mac-tokens.py")

    generator = load_generator()
    css = open(generator.CSS, encoding="utf-8").read()
    blocks = generator.blocks(css)
    swift = open(GENERATED, encoding="utf-8").read()

    # 2. Nothing dropped on the way across. Compared as VALUES, not as names: a
    # generator that emitted the right property with the wrong colour would pass a
    # name check and is exactly the failure this file exists to catch.
    missing = []
    for token, prop in generator.PALETTE:
        red, green, blue, alpha = generator.rgba(blocks[":root"][token], token)
        literal = "%s: TokenColor(%.6f, %.6f, %.6f, %.6f)" % (prop, red, green, blue, alpha)
        if literal not in swift:
            missing.append(token)
    if missing:
        bad("the dark palette lost %s on the way into Swift" % ", ".join(missing))
    else:
        ok("every colour in the CSS palette reached the Swift file with its own value")

    # 3. Both themes, same names.
    dark_names = set(blocks[":root"]) & set(name for name, _ in generator.PALETTE)
    light_names = set(blocks['[data-theme="light"]']) & set(name for name, _ in generator.PALETTE)
    if dark_names - light_names:
        bad("light does not define %s, so a light Mac inherits a dark value"
            % ", ".join(sorted(dark_names - light_names)))
    else:
        ok("both themes define the same palette tokens")

    # 4. Rules 2 and 4, where they can be broken: a colour chosen in the app.
    strays = []
    for folder, _, names in os.walk(SOURCES):
        for name in names:
            if not name.endswith(".swift") or name == "DesignTokens.swift":
                continue
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, ROOT)
            strays.extend("%s:%s" % (relative, hit)
                          for hit in own_colours(open(path, encoding="utf-8").read()))
    if strays:
        bad("a colour is chosen outside the token file (rules 2 and 4): %s"
            % "; ".join(strays))
    else:
        ok("no Swift source outside the generated file chooses a colour of its own")

    # ...and the control. Three lines that are each a different way to break the rule;
    # if the scanner cannot see them, the clean result above means nothing.
    control = """
    Text(x).foregroundStyle(.secondary)
    shape.fill(Color(nsColor: .controlBackgroundColor))
    let c = Color(red: 0.1, green: 0.2, blue: 0.3)   // #2997ff
    """
    caught = own_colours(control)
    if len(caught) >= 4:
        ok("that scan can fail: it catches a stock hue, a system colour, a built "
           "Color and a hex literal")
    else:
        bad("the rule-4 scan found only %d of 4 planted colours (%s) — a clean tree "
            "proves nothing" % (len(caught), caught))

    print("---\npassed=%d failed=%d" % (passed, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
