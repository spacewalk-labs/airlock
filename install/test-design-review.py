#!/usr/bin/env python3
"""install/test-design-review.py — the design review gate.

    python3 install/test-design-review.py

Two jobs, because the eight app frontends are in two different states and a gate
that pretended otherwise would either be a lie or a wall.

**Enforced.** An app that has adopted the design system is held to it completely:
no colour of its own, no undefined token, no emoji standing in for an icon, no
`theme-color` drifted from the palette, and every syntax colour measured against
the surface it is painted on. Today that is `fileview`, which was rewritten onto
`hub/assets/airlock-tokens.css` — its `tokens.css` holds role aliases
(`--bg: var(--airlock-surface-1)`) and its own components, and not one value.

**Ratcheted.** The other seven still carry palettes of their own; devterm alone
has 294 hard-coded colours. Enforcing the full rule on them today would fail the
build for work nobody has scheduled. So they are measured instead, against a
recorded ceiling: an app may lose raw colours and emoji, never gain them. That
turns "someone should port these one day" from a wish into a boundary — new UI in
those apps has to be written against the tokens, because the alternative no longer
compiles. The counts are printed on every run, so the size of the remaining work
is visible rather than remembered.

The enforced half has exactly three ways to rot, and there is one check per way.

  1. **A colour value comes back.** One hex in the alias layer and the palette has
     two sources of truth again, silently, in whichever theme nobody opened.

  2. **A token is used that nothing defines.** `var(--typo)` does not error — it
     falls back to nothing and one element renders unstyled. This was not
     hypothetical when the gate was written: `viewer.html` was using
     `--lh-relaxed`, which no file defined, on the inline editor.

  3. **The emoji come back.** They were the icon set: a folder, a page, a padlock's
     worth of file types, and a toolbar of pictographs. They are gone, and the
     reason they are gone is not taste — a per-type glyph sorts filenames into
     categories, and this app's central promise is that it sorts nothing. A
     monochrome redraw of the same idea would break the same promise. So the
     check is on the characters, and `install/test-fileview-tree.mjs` makes the
     structural half of the claim separately.

Every check runs a positive control, because a scanner that finds nothing looks
exactly like a scanner whose pattern never matched.
"""
from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))

SOT = os.path.join(ROOT, "hub", "assets", "airlock-tokens.css")
APPS = os.path.join(ROOT, "apps")
STATIC = os.path.join(APPS, "fileview", "static")
ALIASES = os.path.join(STATIC, "tokens.css")

# The ceiling for the apps that have not been ported yet. These are counts of raw
# colours and of emoji in each app's own HTML/CSS/JS — vendored libraries and built
# bundles excluded, because they are not ours to restyle. Lowering a number here is
# the point; raising one fails the build. Regenerate with --ratchet after a port.
RATCHET = {
    "code-server": {"hex": 32, "emoji": 1},
    "dev-monitor": {"hex": 49, "emoji": 37},
    # 2026-09-01 (ACCT_OWN): 294/95 -> 283/62. Nothing was restyled — the account
    # panel moved to hub/assets/accounts/ (platform asset), taking its colours and
    # emoji with it. This gate walks apps/ only, so that file is now unwatched;
    # banking the drop at least keeps devterm's own ceiling tight.
    "devterm":     {"hex": 283, "emoji": 62},
    "learning":    {"hex": 22, "emoji": 75},
    "notepad":     {"hex": 26, "emoji": 10},
    # #247 로 합류. 도구가 --ratchet 으로 낸 값 그대로이며 0/0 이라 이 앱은
    # 앞으로 hex·emoji 를 단 하나도 늘릴 수 없다(천장은 내려가기만 한다).
    "notes":       {"hex": 0, "emoji": 0},
    "paseo":       {"hex": 24, "emoji": 23},
    "publish":     {"hex": 27, "emoji": 17},
}
# Directories inside an app that hold somebody else's code.
NOT_OURS = {"vendor", "node_modules", "dist", "web-bundle", "patches"}
# The files this app writes, read off disk rather than listed. A fixed list is a
# gate with a door next to it: adding `/__fv/extra.css` full of hex and linking it
# from the viewer passed every check. `vendor/` is upstream marked, DOMPurify and
# highlight.js, and is not ours to hold to a house style.
def owned_files() -> list[str]:
    found = []
    for dirpath, dirnames, filenames in os.walk(STATIC):
        dirnames[:] = [d for d in dirnames if d != "vendor"]
        for name in sorted(filenames):
            if name.rsplit(".", 1)[-1] in ("css", "html", "js"):
                found.append(os.path.relpath(os.path.join(dirpath, name), STATIC))
    return found


OWNED = owned_files()

failures: list[str] = []
passed = 0


def ok(message: str) -> None:
    global passed
    passed += 1
    print("ok   " + message)


def bad(message: str) -> None:
    failures.append(message)
    print("FAIL " + message, file=sys.stderr)


def since(mark: int) -> bool:
    """True when nothing has failed since `mark = len(failures)`.

    Guarding an `ok` on the GLOBAL failure list is a quiet bug: one unrelated
    failure earlier in the run swallows every later success line, and the output
    then under-reports what was actually checked."""
    return len(failures) == mark


def read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


# Three blocks are deliberately NOT in the range. Box drawing (U+2500–U+257F) is
# section furniture in comments, the same as every other file in this repo.
# Mathematical operators (U+2200–U+22FF) contains `≤`, and Braille (U+2800–U+28FF)
# is text — neither is an icon, and a gate that fails on a maths symbol is a gate
# people route around. Everything else here is a pictograph, an arrow, a dingbat or a
# fullwidth form — an icon someone typed instead of drawing.
#
# The three singletons at the top are not decorative. `·` and `‹›` are the exact
# glyphs the deleted fileIcon() used for "unknown file" and "source file"; they
# are below the emoji planes and would have slipped back in unnoticed, which is
# the specific regression this check exists to stop.
EMOJI = re.compile(
    "["
    "\u00b7"            # MIDDLE DOT — fileIcon()'s "unknown file" mark
    "\u2039\u203a"      # ‹ › — fileIcon()'s "source file" mark
    "\u2190-\u21ff"     # arrows
    "\u2300-\u24ff"     # technical, control pictures, enclosed alphanumerics
    "\u2580-\u27ff"     # blocks, geometric shapes, misc symbols, dingbats
    "\u2900-\u2bff"     # supplemental arrows, misc symbols and arrows
    "\ufe0f"            # variation selector-16, which is what makes text render as emoji
    "\uff01-\uff5e"     # fullwidth forms
    "\U0001f000-\U0001faff"
    "]"
)

# A colour, as CSS writes them. `#` inside a URL fragment or an SVG id reference
# is not one, so the pattern requires 3, 4, 6 or 8 hex digits and nothing else.
HEX = re.compile(r"#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\b")

# The token AND the character that closes it: `)` means the stylesheet is relying
# on the token being defined; `,` means it carries its own fallback and does not.
# Testing that per occurrence matters — `--syn-pun` appears both ways in this app,
# and a whole-file "does a fallback exist anywhere" test would have exempted the
# occurrence that has none.
VAR_USE = re.compile(r"var\(\s*(--[\w-]+)\s*([,)])")
# Colours CSS writes without a `#`. The alias layer must not contain these either;
# without them the rule reads as "no hex", which is a rule about notation rather
# than about where colours live.
FUNC_COLOUR = re.compile(r"\b(?:rgba?|hsla?|color|lab|lch|oklab|oklch)\s*\(")
# ...and the ones CSS spells out. `--bg: white` is a colour value by any reading of
# the rule, and it passed both scanners above until this list existed. The set is
# the CSS named colours that plausibly get typed; it is not the full 148, because a
# gate nobody can read is a gate nobody maintains. Matched only where a colour can
# legally appear — after `:` in a declaration or inside an SVG fill/stroke — so the
# word "black" in a comment is not a failure.
NAMED = (
    "aqua|aquamarine|azure|beige|black|blue|brown|coral|crimson|cyan|darkblue|"
    "darkgray|darkgrey|darkgreen|darkred|dodgerblue|firebrick|fuchsia|gold|gray|"
    "grey|green|hotpink|indigo|ivory|khaki|lavender|lightblue|lightgray|lightgrey|"
    "lightgreen|lime|magenta|maroon|navy|olive|orange|orangered|orchid|pink|plum|"
    "purple|red|salmon|seagreen|sienna|silver|skyblue|slategray|slategrey|snow|"
    "steelblue|tan|teal|tomato|turquoise|violet|wheat|white|yellow"
)
NAMED_COLOUR = re.compile(  # noqa: regex-anchor  (NAMED is a 140-name alternation built above)
    r"(?::\s*|\b(?:fill|stroke|stop-color|flood-color)\s*=\s*[\"'])\s*(" + NAMED + r")\b",
    re.IGNORECASE)
VAR_DEF = re.compile(r"(--[\w-]+)\s*:")
# `/* --gone: removed */` is a note about a token, not a token. Counting it as a
# definition made the undefined-token check pass for a name nothing defines.
CSS_COMMENT = re.compile(r"/\*.*?\*/", re.S)
# No `$`: with re.M and no re.S, `.` never crosses a newline, so `.*` already
# ends at the line end. Dropping it keeps install/test-regex-anchors.py green
# without spending an opt-out on a pattern that does not need one.
LINE_COMMENT = re.compile(r"^\s*//.*", re.M)


def uncommented(src: str) -> str:
    return LINE_COMMENT.sub("", CSS_COMMENT.sub("", src))


# --- 1. no colour values in the alias layer -------------------------------
alias_src = read(ALIASES)
strays = sorted(set(HEX.findall(alias_src))
                | set(FUNC_COLOUR.findall(alias_src))
                | set(NAMED_COLOUR.findall(alias_src)))
if strays:
    bad("apps/fileview/static/tokens.css declares colour values (%s) — it is an "
        "alias layer over hub/assets/airlock-tokens.css and must reference, not copy"
        % ", ".join(strays))
else:
    ok("the alias layer holds no colour values of its own")

# The same claim, one layer out: the viewer's own <style> block and the style
# strings app.js builds its srcdoc documents from. Two literals survive there and
# both are named, because neither is a palette value a token could carry:
#   `theme-color` is read by the browser chrome before any stylesheet loads;
#   `--nb-plate` is the white a matplotlib figure was drawn on, and it stays white
#   in the dark theme for the same reason a photograph does.
# The exemption is per LITERAL, not per line. Skipping the whole line let anything
# else on it through — and app.js's --nb-plate line is a 400-character CSS string
# with room for a dozen more colours after it.
HEX_ALLOWED = {"theme-color": ("#0a0f1e", "#f5f5f7"), "--nb-plate": ("#ffffff",)}
# Every file this app owns, not a named pair. Scanning only viewer.html and app.js
# left a door: a new `/__fv/extra.css` full of hex, linked from the viewer, passed
# the whole gate. hljs-theme.css is the one file exempted, because the syntax
# palette is genuinely its own — and it is not unguarded, it is contrast-checked
# below against the surface it paints on.
mark = len(failures)
for name in [f for f in OWNED if os.path.basename(f) != "hljs-theme.css"]:
    for lineno, line in enumerate(read(os.path.join(STATIC, name)).splitlines(), 1):
        allowed = []
        for key, values in HEX_ALLOWED.items():
            if key in line:
                allowed.extend(values)
        for hexval in HEX.findall(line):
            if hexval.lower() in allowed:
                allowed.remove(hexval.lower())
                continue
            bad("apps/fileview/static/%s:%d hard-codes the colour %s — components "
                "read tokens" % (name, lineno, hexval))
        # `color-mix()` is composition over tokens, not a colour of its own, and is
        # the one function form this app uses on purpose.
        for fn in FUNC_COLOUR.findall(line):
            if "color-mix" in line:
                continue
            bad("apps/fileview/static/%s:%d builds a colour with %s() — components "
                "read tokens" % (name, lineno, fn))
        for named in NAMED_COLOUR.findall(line):
            bad("apps/fileview/static/%s:%d hard-codes the colour `%s` — components "
                "read tokens" % (name, lineno, named))
if since(mark):
    ok("no hard-coded colour in any of the %d files this app owns" % len(OWNED))

if not HEX.search("--bg: #141b2e;"):
    bad("positive control failed: the colour scanner does not match a plain hex")
else:
    ok("positive control: the colour scanner matches a hex it is shown")

# Every colour alias must resolve into the design system rather than into another
# local name that could quietly stop being a token at all.
mark_aliases = len(failures)
colour_aliases = [
    "--chrome", "--bg", "--bg-hover", "--code-bg",
    "--text", "--text-body", "--text-muted",
    "--border", "--border-muted",
    "--accent", "--accent-contrast",
    "--color-warning", "--color-danger",
]
for name in colour_aliases:
    m = re.search(re.escape(name) + r"\s*:\s*([^;]+);", alias_src)  # noqa: regex-anchor  (token name is the loop variable)
    if not m:
        bad("apps/fileview/static/tokens.css no longer defines %s" % name)
    elif "var(--airlock-" not in m.group(1):
        bad("%s is defined as %r — a colour alias must point at an --airlock-* token"
            % (name, m.group(1).strip()))
if since(mark_aliases):
    ok("all %d colour aliases resolve to an --airlock-* token" % len(colour_aliases))


# --- 2. every token used is defined ---------------------------------------
# The union of what the design system defines, what the alias layer defines, and
# what the syntax palette defines. app.js is included because it builds the
# <style> block of every sandboxed srcdoc document as a string — the CSS that
# renders a JSON tree or a notebook lives there, not in a stylesheet.
defined = set(VAR_DEF.findall(uncommented(read(SOT))))
for name in OWNED:
    defined |= set(VAR_DEF.findall(uncommented(read(os.path.join(STATIC, name)))))
# Two are supplied by the element that uses them, not by a sheet.
defined |= {"--app-glyph", "--app-tile"}

undefined: list[tuple[str, str]] = []
for name in OWNED:
    src = read(os.path.join(STATIC, name))
    for use, closer in VAR_USE.findall(src):
        if closer == ",":      # carries its own fallback; needs no definition
            continue
        if use not in defined and (name, use) not in undefined:
            undefined.append((name, use))
for name, use in undefined:
    bad("apps/fileview/static/%s uses %s, which nothing defines" % (name, use))
if not undefined:
    ok("every token used by fileview is defined by the design system or by this app")

if "--definitely-not-a-token" in defined:
    bad("positive control failed: the definition set is not a real set")
else:
    ok("positive control: an invented token name is not in the definition set")


# --- 3. no emoji ----------------------------------------------------------
found: list[tuple[str, int, str]] = []
for name in OWNED:
    for lineno, line in enumerate(read(os.path.join(STATIC, name)).splitlines(), 1):
        for ch in EMOJI.findall(line):
            found.append((name, lineno, ch))
for name, lineno, ch in found:
    bad("apps/fileview/static/%s:%d contains %r (U+%04X) — icons in this app are "
        "drawn, not typed" % (name, lineno, ch, ord(ch)))
if not found:
    ok("no emoji, arrows, dingbats or fullwidth forms in the %d files this app owns"
       % len(OWNED))

if not EMOJI.search("\U0001f4c1"):
    bad("positive control failed: the emoji scanner does not match a folder emoji")
elif EMOJI.search("─── Surfaces ───"):
    bad("positive control failed: the emoji scanner flags box-drawing furniture")
else:
    ok("positive controls: the emoji scanner matches an emoji and spares a box rule")


# --- 4. the SoT is actually reachable at runtime ---------------------------
# An alias layer whose target never loads renders every colour as nothing. The
# link has to be in the viewer AND in the srcdoc documents app.js builds, which
# have their own <head> and inherit no stylesheet from the parent.
LINK = "/assets/airlock-tokens.css"
mark_link = len(failures)
for name in ("viewer.html", "app.js"):
    if LINK not in read(os.path.join(STATIC, name)):
        bad("apps/fileview/static/%s does not link %s — its aliases would resolve "
            "to nothing" % (name, LINK))
if since(mark_link):
    ok("the viewer and the sandboxed srcdoc documents both link the design system")

# The syntax palette has to reach BOTH documents for the same reason, and it did
# not: markdown renders into the viewer's own pane, not into a srcdoc, so its
# fenced code blocks are highlighted by spans in this document. They were coloured
# by a set of leftover !important rules in tokens.css, and removing those left
# every code block in a .md file grey. The link is the fix; this is the guard.
for name in ("viewer.html", "app.js"):
    if "/__fv/hljs-theme.css" not in read(os.path.join(STATIC, name)):
        bad("apps/fileview/static/%s does not link the syntax palette — highlighted "
            "code would render as one flat colour" % name)
if not any("syntax palette" in f for f in failures):
    ok("the viewer and the srcdoc documents both link the syntax palette")


# --- 5. the two literal colours, and the seven the design system does not own ---
# `theme-color` is read before any stylesheet loads, so it cannot be a token —
# but it can be checked against the one it is supposed to equal.
def block(css: str, selector: str) -> dict:
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
    return dict(re.findall(r"(--[\w-]+)\s*:\s*([^;]+);", css[start:end]))


sot_src = read(SOT)
sot = {
    "dark": block(sot_src, ":root"),
    "light": block(sot_src, '[data-theme="light"]'),
}
viewer_src = read(os.path.join(STATIC, "viewer.html"))
for scheme in ("dark", "light"):
    m = re.search(  # noqa: regex-anchor  (scheme is the loop variable)
        r'<meta name="theme-color" media="\(prefers-color-scheme: %s\)"\s*content="(#[0-9a-fA-F]{6})"'
        % scheme, viewer_src)
    if not m:
        bad("viewer.html declares no theme-color for the %s scheme" % scheme)
        continue
    want = sot["%s" % scheme].get("--airlock-canvas", "").strip()
    if m.group(1).lower() != want.lower():
        bad("viewer.html's %s theme-color is %s but --airlock-canvas is %s"
            % (scheme, m.group(1), want))
if not any("theme-color" in f for f in failures):
    ok("both theme-color values match --airlock-canvas")


def srgb(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(hexcolour: str) -> float:
    h = hexcolour.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return 0.2126 * srgb(r) + 0.7152 * srgb(g) + 0.0722 * srgb(b)


def ratio(fg: str, bg: str) -> float:
    lo, hi = sorted((luminance(fg), luminance(bg)))
    return (hi + 0.05) / (lo + 0.05)


# Syntax colours are body-size text on the code surface, so the bar is 4.5:1.
# Two of them shipped under it — the light comment grey was 2.82:1, tuned for the
# beige surface this app used to have. A comment nobody can read is not a
# de-emphasised comment.
syntax_src = read(os.path.join(STATIC, "hljs-theme.css"))
# Three blocks, not two. The third is inside `@media (prefers-color-scheme: dark)`
# and targets `[data-theme="system"]` — which is the DEFAULT, so it is the one that
# paints code for anyone who has not touched the theme buttons. Leaving it out of
# the contrast check meant checking every state except the usual one.
SYNTAX_BLOCKS = {
    "light": ':root, :root[data-theme="light"]',
    "dark": ':root[data-theme="dark"]',
    "system (dark)": '[data-theme="system"]',
}
SYNTAX_SURFACE = {"light": "light", "dark": "dark", "system (dark)": "dark"}
mark_syntax = len(failures)
for scheme, selector in SYNTAX_BLOCKS.items():
    surface = sot[SYNTAX_SURFACE[scheme]].get("--airlock-surface-2", "").strip()
    for name, value in block(syntax_src, selector).items():
        value = value.split("/*")[0].strip()
        if not value.startswith("#"):
            continue
        r = ratio(value, surface)
        if r < 4.5:
            bad("hljs-theme.css %s in the %s theme is %.2f:1 on the code surface "
                "(%s), under AA 4.5:1" % (name, scheme, r, surface))
# And the two dark blocks have to agree. They are hand-maintained duplicates, so
# the failure mode is one of them being updated: the theme button would then paint
# code differently from the system default, which is the hardest kind of colour bug
# to notice because you have to switch themes to see it.
dark_block = block(syntax_src, SYNTAX_BLOCKS["dark"])
system_block = block(syntax_src, SYNTAX_BLOCKS["system (dark)"])
for name, value in sorted(dark_block.items()):
    other = system_block.get(name, "").strip()
    if other != value.strip():
        bad("hljs-theme.css %s is %s under [data-theme=\"dark\"] but %s under the "
            "system default — the theme button would paint code differently from "
            "no theme button at all" % (name, value.strip(), other or "(absent)"))
if since(mark_syntax):
    ok("every syntax colour clears AA on the code surface it is painted on, in all "
       "%d blocks, and the two dark blocks agree" % len(SYNTAX_BLOCKS))

# The state colours, where this app actually paints them as text. The design
# system checks --airlock-warning and --airlock-danger at the LARGE-text bar,
# because that is what they are for; every one of these is small text, so 4.5:1
# is the bar and the SoT's own gate cannot know that. Three sites failed when this
# table was written — 4.47:1, 4.22:1, 4.22:1, all warning, all in the light theme —
# and they were changed to ink with a coloured mark rather than coloured text.
STATE_TEXT = [
    ("--airlock-danger",  "--airlock-surface-1", "Delete in the context menu"),
    ("--airlock-danger",  "--airlock-canvas",    "a tree error under the search bar"),
    ("--airlock-danger",  "--airlock-surface-2", "a notebook error output"),
    ("--airlock-warning", "--airlock-surface-1", "the fallback banner in a srcdoc bar"),
]
mark_state = len(failures)
for fg, bg, what in STATE_TEXT:
    for scheme in ("dark", "light"):
        a, b = sot[scheme].get(fg, "").strip(), sot[scheme].get(bg, "").strip()
        if not (a.startswith("#") and b.startswith("#")):
            bad("cannot measure %s on %s in the %s theme" % (fg, bg, scheme))
            continue
        r = ratio(a, b)
        if r < 4.5:
            bad("%s: %s on %s in the %s theme is %.2f:1, under AA 4.5:1 for small "
                "text. Set the words in --text and let the state colour carry a "
                "mark instead." % (what, fg, bg, scheme, r))
if since(mark_state):
    ok("every state colour this app sets as text clears AA in both themes")

if ratio("#8a8f98", "#eceff2") >= 4.5:
    bad("positive control failed: the contrast maths does not fail a grey that did")
else:
    ok("positive control: the contrast maths fails the grey that shipped under AA")


# --- 7. the ratchet, for the apps that have not been ported ---------------
def app_sources(app: str) -> list[str]:
    found = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(APPS, app)):
        dirnames[:] = [d for d in dirnames if d not in NOT_OURS]
        for name in sorted(filenames):
            if name.rsplit(".", 1)[-1] in ("html", "css", "js"):
                found.append(os.path.join(dirpath, name))
    return found


# `#207` is an issue number, not a colour, and three of them in a comment used to
# count as three hard-coded colours. A colour literal has to sit somewhere a colour
# can go, so the line has to look like one: a CSS declaration, a custom property,
# an inline style, or an SVG paint attribute.
COLOUR_CONTEXT = re.compile(
    r"(?:--[\w-]+\s*:|(?:color|background|background-color|border|border-\w+|outline|"
    r"box-shadow|text-shadow|fill|stroke|stop-color|flood-color|caret-color|"
    r"column-rule|accent-color|gradient)\s*[:=]|style\s*=)", re.IGNORECASE)


def measure(app: str) -> dict:
    hexes = emoji = 0
    for path in app_sources(app):
        try:
            src = read(path)
        except (OSError, UnicodeDecodeError):
            continue
        is_css = path.endswith(".css")
        for line in src.splitlines():
            if is_css or COLOUR_CONTEXT.search(line):
                hexes += len(HEX.findall(line))
            hexes += len(NAMED_COLOUR.findall(line))
        emoji += len(EMOJI.findall(src))
    return {"hex": hexes, "emoji": emoji}


# An app in neither half is an app this gate does not look at, and that is how a
# new frontend arrives fully unguarded. So the halves are checked against what is
# actually on disk rather than assumed to cover it.
ENFORCED = {"fileview"}
on_disk = {
    app for app in sorted(os.listdir(APPS))
    if os.path.isdir(os.path.join(APPS, app)) and app_sources(app)
}
unguarded = sorted(on_disk - ENFORCED - set(RATCHET))
for app in unguarded:
    bad("apps/%s has frontend source but is in neither half of this gate — add it "
        "to RATCHET (python3 %s --ratchet) or port it and add it to ENFORCED"
        % (app, os.path.relpath(__file__, ROOT)))
if not unguarded:
    ok("every app with a frontend is either enforced or ratcheted (%d + %d)"
       % (len(ENFORCED), len(RATCHET)))

measured = {app: measure(app) for app in sorted(RATCHET)}

if "--ratchet" in sys.argv:
    print("RATCHET = {")
    for app in sorted(on_disk - ENFORCED):
        measured.setdefault(app, measure(app))
    for app in sorted(measured):
        print('    %-14s {"hex": %d, "emoji": %d},'
              % ('"%s":' % app, measured[app]["hex"], measured[app]["emoji"]))
    print("}")
    sys.exit(0)

print()
print("not yet on the design system (ceiling / measured)")
print("  a ceiling is a count, so a swap — one colour removed, one added — passes.")
print("  it stops growth, not churn; raising a number here is visible in the diff.")
for app in sorted(measured):
    now, cap = measured[app], RATCHET[app]
    arrow = ""
    for kind in ("hex", "emoji"):
        if now[kind] > cap[kind]:
            bad("apps/%s gained %s: %d, over its recorded ceiling of %d. New UI in "
                "an app that has not been ported has to be written against the "
                "tokens — the ceiling only goes down. (python3 %s --ratchet)"
                % (app, "raw colours" if kind == "hex" else "emoji",
                   now[kind], cap[kind], os.path.relpath(__file__, ROOT)))
        elif now[kind] < cap[kind]:
            arrow = "  <- lower than recorded; rerun with --ratchet to bank it"
    print("  %-13s colours %4d/%-4d  emoji %3d/%-3d%s"
          % (app, now["hex"], cap["hex"], now["emoji"], cap["emoji"], arrow))
if not any("ceiling" in f for f in failures):
    ok("no unported app gained a colour or an emoji")

# Positive control: the ratchet has to be able to see a gain. Comparing a measured
# app against a ceiling one lower is the same arithmetic the loop runs.
probe = measured[next(iter(sorted(measured)))]
if not (probe["hex"] > probe["hex"] - 1):
    bad("positive control failed: the ratchet comparison cannot see a gain")
else:
    ok("positive control: the ratchet comparison can see a gain")

print()
if failures:
    print("%d failure(s)" % len(failures), file=sys.stderr)
    sys.exit(1)
print("ok — passed=%d failed=0" % passed)
