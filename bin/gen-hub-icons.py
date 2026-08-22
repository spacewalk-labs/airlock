#!/usr/bin/env python3
"""Generate Airlock's brand marks (favicon + iOS home-screen icon).

Single source of truth for the porthole marks shipped in hub/assets/:
  - apple-touch-icon.png : 512x512 full-bleed square tile (iOS masks the corners)
  - favicon.png          : 64x64 round "porthole coin" (transparent corners)

Both show the same porthole: a dome + perspective grid seen through a hatch
window, over a deep-space navy gradient with a hatch ring and rim glints. The
disc is a vertical gradient (lighter navy at the top, darker at the bottom) so
the dome reads cleanly. The dome/grid artwork lives in bin/airlock-mark.png
(white, transparent); this script tints the tile and composites the mark, drawn
at high resolution and downsampled for clean edges.

On the colour: this shipped green for a while, specifically so that the public
build and the internal one could be told apart on a phone home screen. That is
no longer the goal — the owner decided on 2026-08-22 that the two should look
the same, and that the mark ships as-is. The distinction that green was buying
is gone on purpose, not by accident.

The mark is a trademark and is NOT covered by the source licence; see NOTICE.
Anyone redistributing a modified Airlock should replace these two files and the
`[branding]` block in airlock.toml.

Re-run after changing PARAMS:  python3 bin/gen-hub-icons.py   (needs Pillow)
"""
import math
import os

from PIL import Image, ImageChops, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "hub", "assets")
MARK = Image.open(os.path.join(HERE, "airlock-mark.png")).convert("RGBA")
SS = 4  # supersample, then downsample for antialiasing

# deep-space navy palette (vertical gradient: lighter top -> darker bottom).
# Keeps the green build's lightness relationships exactly; only the hue moved,
# so the dome and grid read at the same strength they were tuned for.
GTOP = (20, 52, 96)     # gradient top (deep royal navy)
GBOT = (10, 26, 56)     # gradient bottom (near the UI canvas, #0a0f1e)
GLOW = (150, 196, 240)  # soft glow behind the dome
GLOW_A = 55             # glow strength (kept gentle so the top stays dark)
RING = (204, 226, 250)  # hatch ring
GLINT1 = (240, 248, 255)
GLINT2 = (226, 240, 253)


def _vgrad(w, h, top, bot):
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        g.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bot)))
    return g.resize((w, h))


def _circle(cx, cy, r, k):
    return [(cx - r) * k, (cy - r) * k, (cx + r) * k, (cy + r) * k]


def _radial(w, color, maxa):
    """radial alpha (maxa at centre -> 0 at edge), colorized."""
    g = 320
    m = Image.new("L", (g, g), 0)
    px = m.load()
    c = g / 2.0
    for y in range(g):
        for x in range(g):
            d = math.hypot(x - c, y - c) / c
            px[x, y] = max(0, int(maxa * (1 - d))) if d < 1 else 0
    m = m.resize((w, w), Image.LANCZOS)
    layer = Image.new("RGBA", (w, w), color + (0,))
    layer.putalpha(m)
    return layer


def porthole(size: int, coin: bool = False) -> Image.Image:
    """Render the porthole. coin=False -> square tile (home icon);
    coin=True -> clip to a circle with transparent corners (favicon)."""
    W = size * SS
    k = W / 100.0
    base = _vgrad(W, W, GTOP, GBOT).convert("RGBA")

    # soft glow behind the dome (centred slightly high)
    gr = int(40 * k)
    base.alpha_composite(_radial(gr * 2, GLOW, GLOW_A), (int(50 * k) - gr, int(46 * k) - gr))

    # dome + perspective grid mark (white, full-bleed inside the window)
    ms = int(67 * k)
    base.alpha_composite(MARK.resize((ms, ms), Image.LANCZOS), (int(16.5 * k), int(16.5 * k)))

    # hatch ring + rim glints (on a layer so their alpha composites)
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.ellipse(_circle(50, 50, 38.5, k), outline=RING + (217,), width=max(1, int(2.6 * k)))
    ld.arc(_circle(50, 50, 38.5, k), 282, 339, fill=GLINT1 + (235,), width=max(1, int(3.2 * k)))
    ld.arc(_circle(50, 50, 40.5, k), 197, 242, fill=GLINT2 + (128,), width=max(1, int(2.6 * k)))
    base.alpha_composite(layer)

    if coin:
        # clip to a circle -> transparent corners (the favicon's "transparent bg")
        mask = Image.new("L", (W, W), 0)
        ImageDraw.Draw(mask).ellipse(_circle(50, 50, 49.3, k), fill=255)
        base.putalpha(ImageChops.multiply(base.split()[3], mask))

    return base.resize((size, size), Image.LANCZOS)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    porthole(512).save(os.path.join(OUT, "apple-touch-icon.png"))
    porthole(64, coin=True).save(os.path.join(OUT, "favicon.png"))
    print("wrote", os.path.join(OUT, "apple-touch-icon.png"))
    print("wrote", os.path.join(OUT, "favicon.png"))


if __name__ == "__main__":
    main()
