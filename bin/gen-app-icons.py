#!/usr/bin/env python3
"""Generate every glyph app's favicon + iOS home-screen icon from the hub sprite.

Why this exists: an app's launcher tile and its own favicon used to be drawn
twice. hub/index.html already holds the glyph sprite and the category palette
that paint the tiles, and then each app shipped a second, hand-rolled mark —
devterm an SVG file, code-server and notepad and dev-monitor inline data URIs,
publish nothing at all. Editing a glyph moved the tile and left the favicons
behind, and a new app could ship with no icon with nothing to notice.

So the tile is the source and the icons are output. This reads:

  hub/index.html            the <symbol id="app-*"> sprite and the
                            .app[data-cat=...] tile/glyph colour pairs
  apps/*/airlock-app.toml   which glyph and which category each app declares —
                            i.e. the target list. An app that adds [tile] glyph
                            is covered without editing this script.

and writes, per app:

  hub/assets/app-icons/<id>.svg   favicon: a rounded tile at the launcher's own
                                  radius, read from its CSS (15px on a 60px tile
                                  today). The installer copies hub/assets/ into
                                  the webroot, so the hub and every same-origin
                                  subpath app reach it at /assets/app-icons/.
  hub/assets/app-icons/<id>.png   apple-touch-icon: 512x512, FULL-BLEED FLAT.
                                  No rounded corners — iOS masks the corners
                                  itself and rounds a rounded tile twice. iOS
                                  accepts PNG only here; an SVG is ignored. It
                                  carries a tEXt chunk naming its app, because a
                                  raster nobody can re-derive without a browser
                                  otherwise cannot be told from another app's
                                  (see stamp_png).

Two apps are gated on their own port, so /assets/ is a different origin from
their page and unreachable. They get the same artwork where their own server
looks for it (see SEPARATE_ORIGIN below):

  apps/devterm/web/         favicon.svg + apple-touch-icon.png — devterm-gate
                            serves its own web root, and [branding] icon_ring
                            re-writes favicon.svg in place at install time.
  apps/code-server/web/     the inline data URI in shell.html — that gate serves
                            the shell as a single static file and 204s
                            /favicon.ico, so the icon has to travel inside the
                            page. icon_ring re-wraps the same URI at install
                            time, which is why it stays a percent-encoded
                            data:image/svg+xml URI and not a file reference.

Punch-out: a sprite glyph draws its body with fill="currentColor" and any accent
CUT OUT of that body with fill="var(--app-tile,#fff)" — the accent has to show
the tile through it, so it is painted in the tile colour. This script does not
rewrite that: it sets --app-tile on the tile it draws, exactly as the launcher
sets it on .app[data-cat=...]. One value, read by both renderers, so the icon
cannot drift from the tile it is generated from. (It used to substitute #fff
here instead, which meant the launcher and the icon disagreed on every glyph
that had an accent — notepad's lines were white on a white pad, i.e. invisible,
on the launcher only — and it blanked any glyph that drew in #fff for a reason.)

Re-run after changing a glyph, a palette entry, or an app's [tile]:

    python3 bin/gen-app-icons.py

Needs google-chrome (or chromium) on PATH to bake the PNGs; no image library,
unlike bin/gen-hub-icons.py which needs Pillow. The generated files are
committed — the installer copies them, it does not run this script.
"""
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import tomllib
import zlib
from urllib.parse import quote

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
HUB = os.path.join(ROOT, "hub", "index.html")
APPS = os.path.join(ROOT, "apps")
OUT = os.path.join(ROOT, "hub", "assets", "app-icons")

PNG_SIZE = 512                  # what iOS is handed; not a launcher measurement

# The launcher's own tile geometry, read out of its CSS rather than transcribed:
# .app .ic is the tile (side + corner radius) and .app .ic svg is the glyph box.
# Hand-copied numbers here were a second place for the tile to be described, and
# a border-radius edit in hub/index.html would have moved every tile and left
# every icon square — the colour half of exactly that bug is what this script's
# --app-tile rewrite used to be.
TILE_SELECTOR = ".app .ic"
GLYPH_SELECTOR = ".app .ic svg"
CSS_COMMENT = re.compile(r'/\*.*?\*/', re.S)
HTML_COMMENT = re.compile(r'<!--.*?-->', re.S)
# \Z, not $: in Python `$` also matches before a trailing newline, so a declaration
# ending in one would be accepted as a clean px value (install/test-regex-anchors.py).
LENGTH_PX = re.compile(r'^\s*([0-9.]+)px\s*\Z')

# Apps whose page is served by their own gate on their own port. /assets/ is a
# different origin there, so the icon must be delivered where that server looks.
SEPARATE_ORIGIN = {
    # <id>: (favicon svg copy, apple-touch-icon png copy)
    "devterm": ("apps/devterm/web/favicon.svg", "apps/devterm/web/apple-touch-icon.png"),
    # code-server carries its favicon inline (see the module docstring) and has
    # nowhere to serve a PNG from, so it gets no apple-touch-icon.
    "code-server": (None, None),
}
# The tEXt key each baked PNG carries, naming the app it belongs to (stamp_png).
PNG_STAMP_KEY = b"airlock-app"
# The one file whose favicon lives inside it rather than beside it.
SHELL_HTML = "apps/code-server/web/shell.html"
SHELL_LINK = re.compile(r'(<link rel="icon" type="image/svg\+xml" href=")data:image/svg\+xml,[^"]*(">)')


def top_level_rules(html):
    """Yield (selector, declarations) for every CSS rule at the top of a stylesheet.

    A substring search for `.app .ic {` was not good enough. It hit the same
    text inside `.legacy .app .ic {`, inside `@media print {`, and inside a
    comment, and `re.search` then took whichever came first in the file rather
    than whichever wins the cascade — so a plausible edit to hub/index.html
    could hand this script a wrong number and every icon would be redrawn to
    it without a word. Tracking the braces costs ten lines and turns that
    class of edit into a loud failure instead.

    Rules nested in an at-rule are deliberately not yielded: the caller wants
    the one unconditional declaration, and a tile that changes with the
    viewport is a decision this script should not guess at.
    """
    text = HTML_COMMENT.sub("", html)
    text = CSS_COMMENT.sub("", text)
    depth, start = 0, 0
    for m in re.finditer(r'[{}]', text):
        if m.group() == "{":
            if depth == 0:
                selector, body_start = text[start:m.start()], m.end()
            depth += 1
        elif depth:
            depth -= 1
            if depth == 0:
                yield selector.strip(), text[body_start:m.start()]
                start = m.end()


def declared_px(declarations, prop):
    """The value of `prop` in a rule body, in px, or None.

    Split on `;` and match the property whole — `[^}]*?width:` also matched
    `min-width:` and `max-width:`, which is how a responsive tweak could have
    become the tile's width."""
    for decl in declarations.split(";"):
        name, sep, value = decl.partition(":")
        if sep and name.strip() == prop:
            px = LENGTH_PX.match(value)
            return float(px.group(1)) if px else None
    return None


def declared_once(html, selector, prop, wanted):
    """The px value `selector` gives `prop`, when exactly one rule declares it.

    Splitting a selector's declarations across rules is ordinary CSS, so having
    several `.app .ic svg` rules is fine — what is not fine is two of them
    setting the same property, because then the cascade decides and this script
    does not implement the cascade. Loud on 0 and loud on 2+."""
    hits = [v for sel, body in top_level_rules(html)
            if selector in [s.strip() for s in sel.split(",")]
            for v in [declared_px(body, prop)] if v is not None]
    if len(hits) != 1:
        fail(f"{HUB}: {len(hits)} top-level `{selector}` rules give `{prop}` a px value, "
             f"expected 1 — the launcher's {wanted} is drawn from it. With none, the value "
             "moved or is in rem/%/var(); with several, the cascade decides and this script "
             "would be guessing.")
    return hits[0]


def fail(msg):
    sys.stdout.flush()          # so the error lands after the progress it interrupted
    print(f"gen-app-icons: {msg}", file=sys.stderr)
    sys.exit(1)


def read_hub():
    """Return (palette, sprite, geom) parsed out of the hub launcher."""
    html = open(HUB, encoding="utf-8").read()
    palette = {
        m.group(1): (m.group(2), m.group(3))
        for m in re.finditer(
            r'\.app\[data-cat="([a-z-]+)"\]\s*\{\s*--app-tile:\s*(#[0-9a-fA-F]{3,8});'
            r'\s*--app-glyph:\s*(#[0-9a-fA-F]{3,8});',
            html,
        )
    }
    if not palette:
        fail(f"no .app[data-cat=...] colour rules in {HUB} — the palette moved or changed shape")
    sprite = {
        m.group(1): m.group(2)
        for m in re.finditer(r'<symbol id="(app-[a-z0-9-]+)" viewBox="0 0 24 24">(.*?)</symbol>', html)
    }
    if not sprite:
        fail(f"no <symbol id=\"app-*\"> glyphs in {HUB} — the sprite moved or changed shape")
    side = declared_once(html, TILE_SELECTOR, "width", "tile size")
    radius = declared_once(html, TILE_SELECTOR, "border-radius", "corner radius")
    glyph_box = declared_once(html, GLYPH_SELECTOR, "width", "glyph box")
    # In the sprite's own 24-unit viewBox, whatever pixel sizes the CSS uses.
    geom = {"radius": 24 * radius / side, "scale": glyph_box / side}
    return palette, sprite, geom


def read_targets():
    """Every packaged app that declares [tile] glyph, in directory order.

    Brand-icon apps ([tile] icon = "...png": orca, paseo) are not targets — they
    ship an upstream mark. The hub's own porthole comes from bin/gen-hub-icons.py.
    """
    targets = []
    for app_id in sorted(os.listdir(APPS)):
        manifest = os.path.join(APPS, app_id, "airlock-app.toml")
        if not os.path.isfile(manifest):
            continue
        with open(manifest, "rb") as f:
            tile = tomllib.load(f).get("tile", {})
        if "glyph" not in tile:
            continue
        for key in ("cat", "label"):
            if key not in tile:
                fail(f"{app_id}: [tile] declares glyph but no {key} — an icon needs both a colour and a name")
        targets.append((app_id, tile["glyph"], tile["cat"], tile["label"]))
    if not targets:
        fail(f"no app under {APPS} declares a [tile] glyph — nothing to generate")
    return targets


def tile_svg(inner, tile, glyph, geom, *, rounded, size=None):
    """One flat tile: the category colour, the glyph centred at the launcher's scale.

    The sprite is copied verbatim. Both of the colours it reads are supplied the
    way the launcher supplies them — --app-tile for punched-out accents, color
    for fill="currentColor" — so this file renders what the tile renders.
    """
    scale = geom["scale"]
    offset = 24 * (1 - scale) / 2
    dim = f' width="{size}" height="{size}"' if size else ""
    rect = f'<rect width="24" height="24" rx="{geom["radius"]:g}" fill="{tile}"/>' if rounded \
        else f'<rect width="24" height="24" fill="{tile}"/>'
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg"{dim} viewBox="0 0 24 24"'
        f' style="--app-tile:{tile}">'
        f"{rect}"
        f'<g transform="translate({offset:g} {offset:g}) scale({scale:g})" style="color:{glyph}">'
        f"{inner}</g></svg>\n"
    )


def chrome():
    for exe in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser"):
        found = shutil.which(exe)
        if found:
            return found
    fail("no headless browser on PATH (google-chrome or chromium) — the apple-touch-icon PNGs cannot be baked")


def bake_png(browser, svg, dest):
    """Rasterise a full-bleed SVG to PNG_SIZE square. Chrome renders a standalone
    SVG document edge to edge, so there is no HTML wrapper and no margin to trim."""
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "tile.svg")
        with open(src, "w", encoding="utf-8") as f:
            f.write(svg)
        try:
            subprocess.run(
                [browser, "--headless", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
                 f"--user-data-dir={os.path.join(tmp, 'profile')}",
                 "--force-device-scale-factor=1", f"--window-size={PNG_SIZE},{PNG_SIZE}",
                 f"--screenshot={dest}", f"file://{src}"],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        except subprocess.CalledProcessError as exc:
            # A dead browser is a plain failure, not a stack trace. Nothing has been
            # written into the repo at this point — see main().
            fail(f"{os.path.basename(browser)} exited {exc.returncode} rendering {os.path.basename(dest)} "
                 "— no icon was written; re-run once the browser works")
    if not os.path.exists(dest) or not os.path.getsize(dest):
        fail(f"{dest} came out empty — the headless render produced nothing")


def stamp_png(png, app_id):
    """Return <png> carrying a tEXt chunk that names the app it was baked for.

    Why: the PNG is the one artifact nothing can re-derive without a browser, so
    a reviewer's test can only ask it questions — and colour questions cannot
    tell two apps of the same category apart. Copy publish.png over markwand.png
    and every colour in it is still right. The chunk is the icon saying whose it
    is, and install/test-app-icons.py reads it back. tEXt is standard PNG
    (chunk order after IHDR is free, browsers ignore it) and deterministic, so
    the generator stays idempotent.
    """
    if png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
        fail(f"{app_id}: the headless render did not produce a PNG")
    body = PNG_STAMP_KEY + b"\0" + app_id.encode("ascii")
    chunk = (struct.pack(">I", len(body)) + b"tEXt" + body
             + struct.pack(">I", zlib.crc32(b"tEXt" + body) & 0xFFFFFFFF))
    end = 8 + 12 + struct.unpack(">I", png[8:12])[0]      # just past IHDR
    return png[:end] + chunk + png[end:]


def write(rel, data):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # Never follow a symlink out of the tree. install/airlock-install.sh refuses
    # symlinks at every destination component when it stages an icon; a generator
    # that happily writes through one is the weaker end of the same pipe.
    if os.path.islink(path):
        fail(f"{rel} is a symlink — this script writes files it owns, not wherever "
             "something else points. Remove it and re-run.")
    with open(path, "wb") as f:
        f.write(data)
    print(f"  {rel}")


def patch_shell_favicon(svg):
    """code-server's shell with the generated mark as its inline data URI. Pure."""
    path = os.path.join(ROOT, SHELL_HTML)
    html = open(path, encoding="utf-8").read()
    # Percent-encode everything but /:= — the form the file already used, and the
    # form install.sh's icon_ring rewrite greps for (href="data:image/svg+xml,...",
    # no base64). '#' MUST be encoded: unescaped it ends the URI at the first
    # fill="#..." and the browser gets half a document.
    uri = "data:image/svg+xml," + quote(svg.strip(), safe="/:=")
    patched, n = SHELL_LINK.subn(lambda m: m.group(1) + uri + m.group(2), html, count=1)
    if n != 1:
        fail(f"{SHELL_HTML}: no inline <link rel=\"icon\" type=\"image/svg+xml\"> to replace — "
             "the shell's favicon line moved, and icon_ring greps for that same line")
    return patched.encode("utf-8")


def sweep(keep):
    """Delete generated icons no app owns any more.

    Only writing is not enough: install/airlock-install.sh copies hub/assets/
    recursively into the webroot and never prunes, so a file left behind by a
    renamed or removed app is served on every box, forever, with nothing left
    in the repo that explains it.
    """
    for name in sorted(os.listdir(OUT)):
        if name in keep:
            continue
        path = os.path.join(OUT, name)
        if not os.path.isfile(path):
            fail(f"hub/assets/app-icons/{name} is not a generated icon and not a file — "
                 "this directory holds one .svg + one .png per glyph app and nothing else")
        os.remove(path)
        print(f"  removed hub/assets/app-icons/{name} (no app declares it any more)")


def main():
    palette, sprite, geom = read_hub()
    targets = read_targets()

    # Draw and validate everything BEFORE touching the tree. A fail() or a crashed
    # chrome halfway down the app list used to leave the earlier apps rewritten and
    # the rest stale, and the SVG was written before its PNG was baked — so a bake
    # that died left a new SVG beside last week's PNG, a state the test reads as
    # "icons in sync". Nothing below writes into the repo until the loop is done.
    plan = []
    for app_id, sym, cat, label in targets:
        if sym not in sprite:
            fail(f"{app_id}: [tile] glyph = \"{sym}\" but hub/index.html has no such <symbol>")
        if cat not in palette:
            fail(f"{app_id}: [tile] cat = \"{cat}\" but hub/index.html has no colour for that category")
        tile, glyph = palette[cat]
        plan.append((app_id, sym, cat, label, tile,
                     tile_svg(sprite[sym], tile, glyph, geom, rounded=True),
                     tile_svg(sprite[sym], tile, glyph, geom, rounded=False, size=PNG_SIZE)))

    browser = chrome()
    pending = {}                      # repo-relative path -> bytes, written only at the end
    with tempfile.TemporaryDirectory() as staging:
        for app_id, sym, cat, label, tile, rounded, flat in plan:
            print(f"{app_id} ({label}) <- {sym} / {cat} {tile}")
            baked = os.path.join(staging, f"{app_id}.png")
            bake_png(browser, flat, baked)
            with open(baked, "rb") as f:
                png = stamp_png(f.read(), app_id)
            pending[f"hub/assets/app-icons/{app_id}.svg"] = rounded.encode("utf-8")
            pending[f"hub/assets/app-icons/{app_id}.png"] = png

            svg_copy, png_copy = SEPARATE_ORIGIN.get(app_id, (None, None))
            if svg_copy:
                pending[svg_copy] = rounded.encode("utf-8")
            if png_copy:
                # the same bytes, not a second bake: the copy must not be able to differ
                pending[png_copy] = png
            if app_id == "code-server":
                pending[SHELL_HTML] = patch_shell_favicon(rounded)

    os.makedirs(OUT, exist_ok=True)
    for rel, data in pending.items():
        write(rel, data)
    sweep({f"{app_id}.{ext}" for app_id, *_ in plan for ext in ("svg", "png")})


if __name__ == "__main__":
    main()
