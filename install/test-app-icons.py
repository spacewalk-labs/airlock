#!/usr/bin/env python3
"""Every glyph app carries the icon its launcher tile promises, and carries only that.

    python3 install/test-app-icons.py

An app used to be able to ship with no favicon at all (publish did), with someone
else's (fileview pointed at the hub's porthole), or with a hand-drawn one that
stopped matching its tile the moment the sprite changed (devterm, code-server,
notepad, dev-monitor all did). None of that failed anything, because nothing
looked. bin/gen-app-icons.py made the tile the source; this is what makes a new
app unable to skip it.

Six claims, per app that declares [tile] glyph in apps/<id>/airlock-app.toml:

  1. hub/assets/app-icons/<id>.svg and .png exist, are non-empty, and the PNG is
     a 512x512 apple-touch-icon.
  2. The committed SVG is byte-identical to what bin/gen-app-icons.py produces
     from today's hub/index.html — i.e. nobody edited the sprite or the palette
     and left the icons behind.
  3. The committed PNG is this app's tile, baked by the generator. A raster
     cannot be re-derived here (that needs a browser), so it is asked instead:
     does its tEXt chunk name this app (bin/gen-app-icons.py stamps every PNG it
     bakes), is its corner the category's tile colour (the icon is full-bleed
     flat, so the corner IS the tile), does the glyph colour ink anything, is it
     opaque, and is it unlike every other app's. The first version of this test
     asked none of that: it compared the PNG to itself.
  4. Some page under apps/<id>/ declares BOTH a favicon that resolves to that
     SVG and an apple-touch-icon that resolves to that PNG — whether by
     /assets/app-icons/ (same-origin subpath apps), by a file beside the page
     (a separate-port gate serving its own web root), or by an inline data URI
     (a gate that serves one static file and can answer no second request; that
     one cannot carry a PNG, so EXEMPT_TOUCH below excuses the apple-touch half
     for exactly the apps named there).
  5. Something actually installs both that page and the artwork it points at —
     the hub asset copy in install/airlock-install.sh for /assets/..., the app's
     own install.sh for the page and for a file beside it. A committed icon
     nobody ships is a 404 with a green test, and a page nobody installs cannot
     answer for the app. This is a wiring read, not an execution proof: see
     named_by_installer.
  6. That page's <title> and apple-mobile-web-app-title say what the tile says.
     The tile label is the app's name; a tab reading "Notepad" under a tile
     reading "Clip Bridge" is two names for one app.

And two claims about the set as a whole: no HTML under apps/<id>/ may reference
an icon that is NOT the generated artwork — that is how a leftover ad-hoc data
URI is caught rather than quietly outliving its replacement — and
hub/assets/app-icons/ may hold nothing but the icons a live app owns, because
install/airlock-install.sh copies that directory into every webroot and never
prunes.

Brand-icon apps ([tile] icon = "<file>.png": the vendored upstream marks) and
the hub's own porthole (bin/gen-hub-icons.py) are not glyph apps and are not
checked here.
"""
import hashlib
import html as htmllib
import importlib.util
import os
import re
import struct
import sys
import tomllib
import urllib.parse
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
APPS = os.path.join(ROOT, 'apps')
ICONS = os.path.join(ROOT, 'hub', 'assets', 'app-icons')
INSTALLER = os.path.join(ROOT, 'install', 'airlock-install.sh')
PNG_SIDE = 512

# Apps whose page may carry a favicon and no apple-touch-icon, because their gate
# serves a single static file and can answer no second request. Pinned here AND in
# the generator (SEPARATE_ORIGIN), and the two are compared below: an exemption
# that lived only inside the code under test would let a new app excuse itself by
# editing that code.
EXEMPT_TOUCH = {'code-server'}

# A glyph must actually be painted. Measured today: the thinnest mark in the set
# (code-server's chevrons) inks 3.5% of the 512x512 field, the fattest (devterm's
# screen) 16.6%. 0.5% is well under the real floor and well over a rounding error.
GLYPH_INK_MIN = 0.005

COMMENT = re.compile(r'<!--.*?-->', re.S)
# Quote-aware: a '>' inside an attribute value does not end the tag. `[^>]*` did,
# so <link rel="icon" data-note="a>b" href="..."> was invisible to this scan while
# a browser read it as an icon link like any other.
LINK_TAG = re.compile(r'''<link\b(?:[^>"']|"[^"]*"|'[^']*')*>''')
META_TAG = re.compile(r'''<meta\b(?:[^>"']|"[^"]*"|'[^']*')*>''')
# Single quotes and bare values too. Browsers accept all three; a test that only
# read double-quoted attributes let rel='icon' through, and the whole point of the
# scan below is that nothing gets to declare an icon unnoticed.
ATTR = re.compile(r'''([A-Za-z][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'`=<>]+))''')
TITLE = re.compile(r'<title>([^<]*)</title>')
APPLE_TITLE = 'apple-mobile-web-app-title'
DATA_SVG = 'data:image/svg+xml,'

failures = []


def bad(msg):
    print(f'FAIL app-icons: {msg}')
    failures.append(msg)


def ok(msg):
    print(f'ok   app-icons: {msg}')


def load_generator():
    """Import bin/gen-app-icons.py so its parsing and drawing stay single-sourced.

    A second copy of "what the icon should look like" in here would be the very
    drift this test exists to catch, one level up.
    """
    global _GENERATOR
    if _GENERATOR is None:
        path = os.path.join(ROOT, 'bin', 'gen-app-icons.py')
        spec = importlib.util.spec_from_file_location('gen_app_icons', path)
        _GENERATOR = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_GENERATOR)
    return _GENERATOR


_GENERATOR = None
# The tEXt key the generator stamps into every PNG — from the generator, like
# everything else here that describes what an icon should be.
PNG_STAMP_KEY = load_generator().PNG_STAMP_KEY


def rgb(colour):
    """'#rgb' / '#rrggbb' -> (r, g, b)."""
    h = colour.lstrip('#')
    if len(h) == 3:
        h = ''.join(c * 2 for c in h)
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def png_size(path):
    """(width, height) from a PNG's IHDR, or None if it is not a PNG."""
    with open(path, 'rb') as f:
        head = f.read(24)
    if len(head) < 24 or head[:8] != b'\x89PNG\r\n\x1a\n' or head[12:16] != b'IHDR':
        return None
    return struct.unpack('>II', head[16:24])


def png_census(path):
    """What the PNG at <path> is made of, or None if it is not one we can read.

    Returns (corner pixel, {(r,g,b): count}, pixel count, min alpha, stamp),
    where stamp is the app id bin/gen-app-icons.py wrote into a tEXt chunk.

    Stdlib only, and deliberately so: Pillow is not a dependency of this repo
    (bin/gen-app-icons.py bakes these with a headless browser precisely to avoid
    one). Everything asked of the pixels here — corner colour, glyph ink,
    opacity — needs no more than IHDR, a zlib inflate of the IDAT stream, and
    PNG's five scanline filters. Returns None for anything but the 8-bit
    non-interlaced truecolour PNG a browser screenshot produces, and for a file
    too damaged to walk: a corrupt icon is a finding, not a stack trace.
    """
    with open(path, 'rb') as f:
        raw = f.read()
    if raw[:8] != b'\x89PNG\r\n\x1a\n':
        return None
    width = height = depth = ctype = interlace = None
    stamp = None
    idat = bytearray()
    pos = 8
    try:
        while pos + 8 <= len(raw):
            length = struct.unpack('>I', raw[pos:pos + 4])[0]
            kind = raw[pos + 4:pos + 8]
            body = raw[pos + 8:pos + 8 + length]
            if len(body) != length:
                return None
            if kind == b'IHDR':
                width, height, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
            elif kind == b'IDAT':
                idat += body
            elif kind == b'tEXt' and body.startswith(PNG_STAMP_KEY + b'\0'):
                stamp = body[len(PNG_STAMP_KEY) + 1:].decode('ascii', 'replace')
            elif kind == b'IEND':
                break
            pos += 12 + length
    except struct.error:
        return None
    if depth != 8 or ctype not in (2, 6) or interlace != 0 or not idat:
        return None
    bpp = 3 if ctype == 2 else 4
    try:
        data = zlib.decompress(bytes(idat))
    except zlib.error:
        return None
    stride = width * bpp
    if len(data) != height * (stride + 1):
        return None

    counts = {}
    alpha = 255
    prev = bytearray(stride)
    corner = None
    at = 0
    for _ in range(height):
        ftype = data[at]
        line = bytearray(data[at + 1:at + 1 + stride])
        at += 1 + stride
        if ftype == 1:                                  # Sub
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 0xFF
        elif ftype == 2:                                # Up
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif ftype == 3:                                # Average
            for x in range(stride):
                left = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((left + prev[x]) >> 1)) & 0xFF
        elif ftype == 4:                                # Paeth
            for x in range(stride):
                left = line[x - bpp] if x >= bpp else 0
                up = prev[x]
                upleft = prev[x - bpp] if x >= bpp else 0
                guess = left + up - upleft
                dl, du, dul = abs(guess - left), abs(guess - up), abs(guess - upleft)
                near = left if (dl <= du and dl <= dul) else (up if du <= dul else upleft)
                line[x] = (line[x] + near) & 0xFF
        elif ftype != 0:
            return None
        if corner is None:
            corner = tuple(line[:3])
        for pixel in struct.iter_unpack(f'{bpp}B', bytes(line)):
            key = pixel[:3]
            counts[key] = counts.get(key, 0) + 1
            if bpp == 4 and pixel[3] < alpha:
                alpha = pixel[3]
        prev = line
    return corner, counts, width * height, alpha, stamp


def pages(app_id):
    """Every HTML page under apps/<id>/, vendored bundles excluded (not ours to edit)."""
    found = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(APPS, app_id)):
        dirnames[:] = [d for d in dirnames if d not in ('vendor', 'web-bundle', 'node_modules')]
        for name in sorted(filenames):
            if name.endswith('.html'):
                found.append(os.path.join(dirpath, name))
    return sorted(found)


def attrs_of(tag):
    """{name: value} for one tag, values entity-decoded the way a browser decodes them.

    &#105;con in a rel is `icon` to a parser; a raw substring test read it as an
    unknown token and skipped the link.
    """
    out = {}
    for m in ATTR.finditer(tag):
        value = m.group(2) if m.group(2) is not None else \
                m.group(3) if m.group(3) is not None else m.group(4)
        out.setdefault(m.group(1).lower(), htmllib.unescape(value))
    return out


def icon_links(html):
    """[(kind, rel, href)] for every link a browser would take as an icon.

    rel is a TOKEN LIST, and browsers honour more spellings than two: `shortcut
    icon` is the ancient favicon form, `apple-touch-icon-precomposed` the iOS one,
    `mask-icon` Safari's pinned tab. Matching only rel="icon" and
    rel="apple-touch-icon" let all three past — including a `shortcut icon`
    pointing at the hub's porthole, i.e. exactly the bug the generated icons were
    introduced to fix, wearing a different rel. Any token containing "icon" is in
    scope, and anything spelled apple-touch-icon* is the home-screen half.
    """
    out = []
    for tag in LINK_TAG.findall(html):
        attrs = attrs_of(tag)
        tokens = [t for t in attrs.get('rel', '').lower().split() if 'icon' in t]
        if not tokens or 'href' not in attrs:
            continue
        kind = 'apple-touch' if any(t.startswith('apple-touch-icon') for t in tokens) else 'icon'
        out.append((kind, attrs['rel'], attrs['href']))
    return out


def resolve(href, page):
    """The bytes an href points at, or None if it points nowhere we can read.

    Absolute /assets/... is the hub webroot (install/airlock-install.sh copies
    hub/assets/. there); anything else relative is beside the page.
    """
    if href.startswith(DATA_SVG):
        return urllib.parse.unquote(href[len(DATA_SVG):]).encode('utf-8')
    href = re.split(r'[?#]', href, 1)[0]      # ?v=3 cache-busting still names one file
    if href.startswith('/assets/'):
        root, path = os.path.join(ROOT, 'hub', 'assets'), \
            os.path.join(ROOT, 'hub', 'assets', href[len('/assets/'):])
    elif href.startswith('/') or '://' in href:
        return None
    else:
        root, path = os.path.dirname(page), os.path.join(os.path.dirname(page), href)
    # `/assets/../nowhere/x.svg` used to be credited to the hub asset copy and
    # read from wherever it landed. Normalise, and keep the file inside the
    # directory the href claims — what ships is that directory, nothing above it.
    path = os.path.normpath(path)
    if os.path.commonpath([os.path.normpath(root), path]) != os.path.normpath(root):
        return None
    if not os.path.isfile(path):
        return None
    with open(path, 'rb') as f:
        return f.read()


def hub_assets_installed():
    """Does the orchestrator copy hub/assets/ into the webroot? (For /assets/... hrefs.)

    Both endpoints exactly: `WEBROOT/assets` as a loose substring also matches a
    copy into `$WEBROOT/assets-v2/`, where nothing serving /assets/ would find
    it. Like named_by_installer, this reads wiring and cannot see control flow —
    the line existing is not the line running.
    """
    with open(INSTALLER, encoding='utf-8') as f:
        for line in f:
            body = line.split('#', 1)[0]
            if '"$ROOT/hub/assets/."' in body and '"$WEBROOT/assets/"' in body and ' cp ' in body:
                return True
    return False


# Verbs that put a file somewhere. Deliberately not `>`: devterm's favicon.svg is
# also named by a `ring_icon_svg ... > $WEB_ROOT/favicon.svg` that runs only when
# [branding] icon_ring is set, and that line must not vouch for the unconditional
# copy. Pages get the wider set below, because two installers template their page
# through sed rather than copying it.
COPIES = re.compile(r'\b(install|cp|rsync|ln|tar)\b')
WRITES = re.compile(r'\b(install|cp|rsync|ln|tar|sed|cat|tee)\b')


def named_by_installer(app_id, rel_to_app, verbs):
    """Is <rel_to_app> written by apps/<id>/install.sh, per a line that writes?

    This is a wiring check, and it says only what a static read can say: the
    installer names the file on a line that copies or templates it. It cannot
    know that the line runs (a `if false; then` around it, or a copy to the wrong
    directory, still reads as shipped) — proving that needs a live install, which
    install/test-integration.sh's dry run is the closest this repo gets.
    """
    installer = os.path.join(APPS, app_id, 'install.sh')
    if not os.path.isfile(installer):
        return False
    with open(installer, encoding='utf-8') as f:
        # continuations joined: the install command that ships devterm's two icons
        # wraps, and the filenames sit on the continued line
        text = f.read().replace('\\\n', ' ')
    for line in text.splitlines():
        body = line.split('#', 1)[0]
        if rel_to_app in body and verbs.search(body):
            return True
    return False


def ships(app_id, href, page, hub_copy):
    """What puts the file behind <href> on the box, or None if nothing does.

    A committed icon is artwork; an installed icon is an icon. Deleting the
    apple-touch-icon.png from apps/devterm/install.sh left every other claim in
    this file true and the gate serving a 404.

    The reference has to be on a line that copies — naming the file is not
    installing it. devterm's favicon.svg appears twice in its installer, once in
    the install command and once in a `ring_icon_svg ... > $WEB_ROOT/favicon.svg`
    that runs only when [branding] icon_ring is set; a bare substring search
    would call the unconditional copy present after it had been deleted.
    Backslash continuations are joined first: the install command that ships
    these two files wraps, and the filenames are on the continued line.
    """
    if href.startswith(DATA_SVG):
        return 'inline in the page'
    if href.startswith('/assets/'):
        return 'install/airlock-install.sh copies hub/assets/ into the webroot' if hub_copy else None
    src = os.path.relpath(os.path.join(os.path.dirname(page), href), os.path.join(APPS, app_id))
    return f'apps/{app_id}/install.sh installs {src}' \
        if named_by_installer(app_id, src, COPIES) else None


def check_png(app_id, png_path, tile, glyph):
    """Claim 3: the PNG really is this app's tile, baked by the generator."""
    census = png_census(png_path)
    if census is None:
        bad(f'{app_id}: app-icons/{app_id}.png is not the 8-bit truecolour PNG the '
            'generator bakes, or is damaged — nothing here can vouch for it')
        return
    corner, counts, total, alpha, stamp = census
    if stamp != app_id:
        bad(f'{app_id}: app-icons/{app_id}.png is stamped '
            + (f'"{stamp}"' if stamp else 'by nobody')
            + f', not "{app_id}" — every PNG bin/gen-app-icons.py bakes names its own app in '
            'a tEXt chunk. This one was drawn by hand, or belongs to another app.')
    if alpha != 255:
        bad(f'{app_id}: app-icons/{app_id}.png has transparent pixels (min alpha {alpha}) — '
            'iOS composites an apple-touch-icon onto black, so a transparent icon is a '
            'black icon. The tile is full-bleed and opaque.')
    want_tile, want_glyph = rgb(tile), rgb(glyph)
    if corner != want_tile:
        bad(f'{app_id}: app-icons/{app_id}.png starts with pixel {corner}, but the {app_id} tile '
            f'is {tile} {want_tile} — the apple-touch icon is full-bleed flat, so its corner IS '
            'the tile colour. This PNG was baked from some other tile.')
    ink = counts.get(want_glyph, 0)
    if ink < total * GLYPH_INK_MIN:
        bad(f'{app_id}: app-icons/{app_id}.png has {ink} pixel(s) of the glyph colour {glyph} out '
            f'of {total} — the glyph did not render. An icon that is a bare tile says nothing.')


def main():
    gen = load_generator()
    palette, sprite, geom = gen.read_hub()
    targets = gen.read_targets()
    hub_copy = hub_assets_installed()
    print(f'ok   app-icons: {len(targets)} app(s) declare a [tile] glyph: '
          f'{", ".join(t[0] for t in targets)}')

    gen_exempt = {app for app, (_, png) in gen.SEPARATE_ORIGIN.items() if png is None}
    if gen_exempt != EXEMPT_TOUCH:
        bad(f'the apple-touch exemption disagrees with itself: bin/gen-app-icons.py exempts '
            f'{sorted(gen_exempt) or "nothing"}, this test allows {sorted(EXEMPT_TOUCH)}. An app '
            'may not excuse itself from shipping a home-screen icon by editing the generator '
            'alone — say why here too, or ship the PNG.')

    seen_png = {}
    for app_id, sym, cat, label in targets:
        # (1) the pair exists and the PNG is the size iOS is handed
        svg_path = os.path.join(ICONS, f'{app_id}.svg')
        png_path = os.path.join(ICONS, f'{app_id}.png')
        missing = False
        for path in (svg_path, png_path):
            rel = os.path.relpath(path, ROOT)
            if not os.path.isfile(path):
                bad(f'{app_id}: {rel} is missing — run `python3 bin/gen-app-icons.py` and commit it')
                missing = True
            elif not os.path.getsize(path):
                bad(f'{app_id}: {rel} is empty')
                missing = True
        if missing:   # every later claim about this app reads those two files
            continue
        size = png_size(png_path)
        if size is None:
            bad(f'{app_id}: app-icons/{app_id}.png is not a PNG — iOS takes PNG or nothing here')
        elif size != (PNG_SIDE, PNG_SIDE):
            bad(f'{app_id}: app-icons/{app_id}.png is {size[0]}x{size[1]}, '
                f'not {PNG_SIDE}x{PNG_SIDE}')

        # (2) the committed SVG is still what the sprite and palette say it is
        if sym not in sprite or cat not in palette:
            bad(f'{app_id}: [tile] names glyph "{sym}" / cat "{cat}", and hub/index.html has no such '
                'symbol or category — the tile itself is broken, not just the icon')
            continue
        tile, glyph = palette[cat]
        want = gen.tile_svg(sprite[sym], tile, glyph, geom, rounded=True)
        with open(svg_path, encoding='utf-8') as f:
            got = f.read()
        if got != want:
            bad(f'{app_id}: app-icons/{app_id}.svg no longer matches the {sym} glyph on a {cat} tile '
                '— the sprite or the palette moved; re-run `python3 bin/gen-app-icons.py`')
            continue
        with open(png_path, 'rb') as f:
            want_png = f.read()

        # (3) the PNG is a bake of THAT tile, and no other app ships the same one
        check_png(app_id, png_path, tile, glyph)
        digest = hashlib.sha256(want_png).hexdigest()
        if digest in seen_png:
            bad(f'{app_id}: app-icons/{app_id}.png is byte-identical to '
                f'app-icons/{seen_png[digest]}.png — two apps cannot wear one icon')
        else:
            seen_png[digest] = app_id

        # (4) some page wires both halves, (bad) no page wires anything else,
        # and (5) whatever a good link points at is actually installed
        exempt_touch = app_id in EXEMPT_TOUCH
        wired = None
        app_pages = pages(app_id)
        if not app_pages:
            bad(f'{app_id}: no HTML page under apps/{app_id}/ — nothing can reference the icon')
            continue
        for page in app_pages:
            rel_page = os.path.relpath(page, ROOT)
            try:
                with open(page, encoding='utf-8') as f:
                    html = f.read()
            except UnicodeDecodeError as exc:
                bad(f'{rel_page}: not UTF-8 ({exc}) — a page this scan cannot read is a page '
                    'that could be declaring anything')
                continue
            # A commented-out <link> is not a link. Both of publish's could be
            # wrapped in <!-- --> and this test still reported the page wired.
            html = COMMENT.sub('', html)
            links = icon_links(html)
            has_favicon = has_touch = False
            for kind, link_rel, href in links:
                body = resolve(href, page)
                if kind == 'apple-touch':
                    expected = want_png
                else:
                    # an inline data URI carries no trailing newline; the file does
                    expected, body = want.encode('utf-8').strip(), (body.strip() if body else body)
                if body is None:
                    bad(f'{rel_page}: rel="{link_rel}" href "{href[:60]}" points at nothing '
                        'this repo ships')
                    continue
                if body != expected:
                    bad(f'{rel_page}: rel="{link_rel}" is not the generated {app_id} mark — an app '
                        'may not carry a second, hand-drawn icon beside the one its tile produces')
                    continue
                if ships(app_id, href, page, hub_copy) is None:
                    bad(f'{rel_page}: rel="{link_rel}" href "{href[:60]}" is the right artwork, but '
                        'no installer puts it on the box — the page would 404 on its own icon')
                    continue
                if kind == 'icon':
                    has_favicon = True
                else:
                    has_touch = True
            if not (has_favicon and (has_touch or exempt_touch)):
                continue
            # ... and the page carrying them has to be a page the app installs.
            # Any .html under apps/<id>/ used to satisfy this, so adding a
            # correct-looking _iconcheck.html excused the real page entirely.
            page_src = os.path.relpath(page, os.path.join(APPS, app_id))
            if not named_by_installer(app_id, page_src, WRITES):
                bad(f'{rel_page} carries the generated mark, but apps/{app_id}/install.sh '
                    'never ships this page — a page nobody installs cannot answer for '
                    "the app's icon")
                continue
            wired = (rel_page, html)
        if wired is None:
            want_both = 'a favicon' if exempt_touch else 'both a favicon and an apple-touch-icon'
            bad(f'{app_id}: no page under apps/{app_id}/ declares {want_both} resolving to the '
                f'generated mark and installed with the app — a new app must not be able to '
                'ship without an icon')
            continue
        rel_page, html = wired
        ok(f'{app_id}: {rel_page} carries the generated mark'
           + (' (inline favicon only — its gate serves one static file)' if exempt_touch else ''))

        # (6) the tab and the home screen say what the tile says
        title = TITLE.search(html)
        if not title:
            bad(f'{rel_page}: no <title>')
        elif title.group(1) != label:
            bad(f'{rel_page}: <title>{title.group(1)}</title> but the tile label is "{label}" — '
                'one app, one name')
        apple = None
        for tag in META_TAG.findall(html):
            attrs = attrs_of(tag)
            if attrs.get('name', '').lower() == APPLE_TITLE:
                apple = attrs.get('content')
                break
        if apple is None:
            bad(f'{rel_page}: no apple-mobile-web-app-title — the iOS home screen would '
                f'invent a name instead of using "{label}"')
        elif apple != label:
            bad(f'{rel_page}: apple-mobile-web-app-title is "{apple}", '
                f'but the tile label is "{label}"')

    # No page may point at a generated icon that is not there — for EVERY packaged
    # app, not just the ones that declare a glyph today. Dropping `[tile] glyph`
    # takes an app out of `targets`, and every check above with it: the sweep then
    # deletes its icons on the next generator run and the page keeps pointing at
    # them. Green test, two 404s, and the remedy the failure text prints is what
    # caused it.
    for app_id in sorted(os.listdir(APPS)):
        if not os.path.isdir(os.path.join(APPS, app_id)):
            continue
        for page in pages(app_id):
            rel_page = os.path.relpath(page, ROOT)
            for tag in LINK_TAG.findall(open(page, encoding='utf-8').read()):
                href = attrs_of(tag).get('href', '')
                if 'app-icons/' not in href:
                    continue
                if resolve(href, page) is None:      # resolve returns the bytes, or None
                    bad(f'{rel_page}: href "{href}" points at a generated icon that does not '
                        f'exist. If this app no longer declares a [tile] glyph, its icons were '
                        'swept — take the <link> out too, or give the tile its glyph back.')

    # nothing in the generated directory that no live app owns
    owned = {f'{app_id}.{ext}' for app_id, *_ in targets for ext in ('svg', 'png')}
    for name in sorted(os.listdir(ICONS)) if os.path.isdir(ICONS) else ():
        if name not in owned:
            bad(f'hub/assets/app-icons/{name} belongs to no app that declares a [tile] glyph — '
                'install/airlock-install.sh copies this directory into every webroot and never '
                'prunes, so an orphan is served forever. `python3 bin/gen-app-icons.py` sweeps it.')

    if failures:
        print(f'\n{len(failures)} problem(s). The launcher tile is the source: hub/index.html holds '
              'the\nglyph sprite and the category palette, apps/<id>/airlock-app.toml says which '
              'glyph\nand which name, and bin/gen-app-icons.py turns that into the favicon and the '
              'iOS\nhome-screen icon. Re-run it and commit what changes:\n\n'
              '    python3 bin/gen-app-icons.py\n')
        return 1
    print('ok   app-icons: every glyph app has its generated pair, wired, installed, '
          'named after its tile')
    return 0


if __name__ == '__main__':
    sys.exit(main())
