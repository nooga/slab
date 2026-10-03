#!/usr/bin/env python3
"""Draw the Slab app icon (tools/app/icon.png, 1024x1024).

The gold S from the wordmark (slab.png) on a black tile, laid out on
Apple's macOS icon grid: an 824x824 rounded square (continuous corners)
centred on the 1024 canvas, with the system's soft drop shadow below it.

    python3 tools/app/make_icon.py
"""

import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "tools", "app", "icon.png")

S = 1024
BODY = 824                  # the tile, per the macOS icon template
OFF = (S - BODY) // 2       # 100 px margin
SS = 4                      # supersampling for clean edges
S_BOX = (20, 18, 530, 461)  # the S in slab.png
GLYPH_H = 520               # the S's height on the tile


def squircle_mask(n=5.0):
    """A superellipse |x|^n + |y|^n = 1: the continuous-corner shape macOS
    icons use, close enough at icon sizes."""
    big = S * SS
    c = big / 2
    r = BODY / 2 * SS
    pts = []
    for i in range(4096):
        t = 2 * math.pi * i / 4096
        ct, st = math.cos(t), math.sin(t)
        pts.append((c + r * math.copysign(abs(ct) ** (2 / n), ct),
                    c + r * math.copysign(abs(st) ** (2 / n), st)))
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m.resize((S, S), Image.LANCZOS)


def tile():
    # Near-black with a faint top-to-bottom falloff, like the logo's backdrop.
    g = Image.new("RGB", (S, S))
    top, bottom = (34, 33, 36), (8, 8, 9)
    d = ImageDraw.Draw(g)
    for y in range(S):
        t = min(1.0, max(0.0, (y - OFF) / BODY))
        d.line([(0, y), (S, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return g.convert("RGBA")


def glyph():
    src = Image.open(os.path.join(ROOT, "slab.png")).convert("RGB").crop(S_BOX)
    # Key out the black: alpha from brightness, solid above a low knee.
    alpha = src.convert("L").point(lambda v: 0 if v < 8 else min(255, (v - 8) * 10))
    g = src.convert("RGBA")
    g.putalpha(alpha)
    g = g.crop(g.getbbox())
    w = round(g.width * GLYPH_H / g.height)
    return g.resize((w, GLYPH_H), Image.LANCZOS)


def main():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = squircle_mask()

    # System-style drop shadow: soft, offset down.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(mask.point(lambda v: v * 0.5))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)), (0, 12))

    body = tile()
    body.putalpha(mask)
    img.alpha_composite(body)

    # A hairline of light on the tile's edge so it reads on dark docks.
    rim = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    rim.putalpha(mask.filter(ImageFilter.FIND_EDGES).point(lambda v: min(40, v // 4)))
    img.alpha_composite(rim)

    g = glyph()
    x, y = (S - g.width) // 2, (S - g.height) // 2
    gs = Image.new("RGBA", g.size, (0, 0, 0, 0))
    gs.putalpha(g.getchannel("A").point(lambda v: v * 0.7))
    img.alpha_composite(gs.filter(ImageFilter.GaussianBlur(10)), (x, y + 14))
    img.alpha_composite(g, (x, y))

    img.save(OUT)
    print(OUT)


if __name__ == "__main__":
    main()
