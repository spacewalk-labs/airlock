#!/usr/bin/env python3
"""Generate Airlock's brand marks (favicon + iOS home-screen icon).

Single source of truth for the porthole marks shipped in hub/assets/:
  - apple-touch-icon.png : 512x512 full-bleed square tile (iOS masks the corners)
  - favicon.png          : 64x64 round "porthole coin" (transparent corners)

Both show the same porthole: a dome + perspective grid seen through a hatch
window, over a green deep-space gradient with a hatch ring and rim glints. The
disc is a vertical gradient (darker green at the top, green at the bottom) so the
dome reads cleanly; the tone is a green in place of the internal build's navy,
keeping the two recognizably apart on a phone home screen. The dome/grid artwork
lives in bin/airlock-mark.png (white, transparent); this script tints the tile
and composites the mark, drawn at high resolution and downsampled for clean
edges.

Re-run after changing PARAMS:  python3 bin/gen-hub-icons.py   (needs Pillow)
"""
import math
import os

from PIL import Image, ImageChops, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "hub", "assets")
MARK = Image.open(os.path.join(HERE, "airlock-mark.png")).convert("RGBA")
SS = 4  # supersample, then downsample for antialiasing

# green deep-space palette (vertical gradient: darker top -> green bottom)
GTOP = (22, 76, 50)     # gradient top (muted deep emerald)
GBOT = (14, 48, 32)     # gradient bottom (forest green)
GLOW = (150, 224, 184)  # soft glow behind the dome
GLOW_A = 55             # glow strength (kept gentle so the top stays dark)
RING = (200, 240, 216)  # hatch ring
GLINT1 = (238, 255, 246)
GLINT2 = (224, 250, 235)


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
