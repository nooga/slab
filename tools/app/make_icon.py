#!/usr/bin/env python3
"""Draw the Slab app icon (tools/app/icon.png, 1024x1024).

A chamfered graphite faceplate on the macOS icon grid: the gold wordmark
from slab.png, and below it a VFD window with a dot-matrix spectrum glowing
vfd orange behind glass (docs/06 tokens). Screws at the corners.

    python3 tools/app/make_icon.py
"""

import math
import os
import random

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "tools", "app", "icon.png")

S = 1024
PAD = 100            # macOS icon grid: 824 px body
CH = 92              # corner chamfer
VFD = (255, 122, 26)


def chamfer(x0, y0, x1, y1, c):
    return [(x0 + c, y0), (x1 - c, y0), (x1, y0 + c), (x1, y1 - c),
            (x1 - c, y1), (x0 + c, y1), (x0, y1 - c), (x0, y0 + c)]


def mask(poly):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).polygon(poly, fill=255)
    return m


def plate():
    rnd = random.Random(7)
    x0, y0, x1, y1 = PAD, PAD, S - PAD, S - PAD

    # Graphite with a faint vertical gradient and brushed grain.
    body = Image.new("RGB", (S, S))
    px = body.load()
    rows = [rnd.uniform(-5, 5) for _ in range(S)]
    for y in range(S):
        t = (y - y0) / (y1 - y0)
        base = 58 - 22 * t
        for x in range(S):
            v = base + rows[y] + rnd.uniform(-3, 3)
            px[x, y] = (int(v), int(v), int(v + 3))

    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Soft contact shadow under the plate (the icon sits on a desktop).
    sh = mask(chamfer(x0, y0 + 14, x1, y1 + 14, CH)).filter(ImageFilter.GaussianBlur(18))
    img.paste(Image.new("RGBA", (S, S), (0, 0, 0, 150)), (0, 0), sh)

    outer = chamfer(x0, y0, x1, y1, CH)
    img.paste(body, (0, 0), mask(outer))

    # Bevel: light catches the top and left edges, the rest falls away.
    d = ImageDraw.Draw(img)
    b = 7
    pts = outer + [outer[0]]
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        nx, ny = by - ay, ax - bx
        lit = (nx + ny) < 0
        col = (150, 150, 158, 255) if lit else (14, 14, 16, 255)
        d.line([(ax, ay), (bx, by)], fill=col, width=b)
    inner = chamfer(x0 + b, y0 + b, x1 - b, y1 - b, CH - 3)
    ip = inner + [inner[0]]
    for (ax, ay), (bx, by) in zip(ip, ip[1:]):
        nx, ny = by - ay, ax - bx
        lit = (nx + ny) < 0
        col = (92, 92, 98, 255) if lit else (26, 26, 30, 255)
        d.line([(ax, ay), (bx, by)], fill=col, width=3)
    return img


def screws(img):
    d = ImageDraw.Draw(img)
    for cx, cy in [(PAD + 70, PAD + 70), (S - PAD - 70, PAD + 70),
                   (PAD + 70, S - PAD - 70), (S - PAD - 70, S - PAD - 70)]:
        r = 17
        d.ellipse([cx - r - 3, cy - r - 3, cx + r + 3, cy + r + 3], fill=(20, 20, 22))
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(112, 112, 118))
        d.ellipse([cx - r + 4, cy - r + 4, cx + r - 2, cy + r - 2], fill=(86, 86, 92))
        a = math.radians(35)
        dx, dy = math.cos(a) * (r - 4), math.sin(a) * (r - 4)
        d.line([(cx - dx, cy - dy), (cx + dx, cy + dy)], fill=(34, 34, 38), width=6)


def wordmark(img):
    src = Image.open(os.path.join(ROOT, "slab.png")).convert("RGB")
    # Key the black background out: alpha from brightness, hard above a knee.
    lum = src.convert("L")
    alpha = lum.point(lambda v: 0 if v < 10 else min(255, (v - 10) * 8))
    logo = src.convert("RGBA")
    logo.putalpha(alpha)
    logo = logo.crop(logo.getbbox())
    w = 664
    h = round(logo.height * w / logo.width)
    logo = logo.resize((w, h), Image.LANCZOS)
    x = (S - w) // 2
    y = 252
    # Engraved drop shadow.
    shadow = Image.new("RGBA", logo.size, (0, 0, 0, 0))
    shadow.putalpha(logo.getchannel("A").point(lambda v: v * 0.8))
    shadow = shadow.filter(ImageFilter.GaussianBlur(6))
    img.alpha_composite(shadow, (x + 4, y + 10))
    img.alpha_composite(logo, (x, y))
    return y + h


def vfd(img, top):
    x0, x1 = PAD + 104, S - PAD - 104
    y0, y1 = top + 72, S - PAD - 132
    d = ImageDraw.Draw(img)
    # Recessed well: dark lip top/left, light lip bottom/right.
    d.rectangle([x0 - 8, y0 - 8, x1 + 8, y1 + 8], fill=(18, 18, 20))
    d.line([(x0 - 8, y1 + 8), (x1 + 8, y1 + 8)], fill=(120, 120, 126), width=4)
    d.line([(x1 + 8, y0 - 8), (x1 + 8, y1 + 8)], fill=(120, 120, 126), width=4)
    d.rectangle([x0, y0, x1, y1], fill=(16, 9, 6))

    # Dot-matrix spectrum.
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    pitch, r = 22, 7
    cols = (x1 - x0 - 24) // pitch
    rows = (y1 - y0 - 24) // pitch
    ox = x0 + (x1 - x0 - (cols - 1) * pitch) // 2
    oy = y0 + (y1 - y0 - (rows - 1) * pitch) // 2
    for i in range(cols):
        t = i / (cols - 1)
        level = 0.18 + 0.62 * math.exp(-((t - 0.2) / 0.22) ** 2) + 0.42 * math.exp(-((t - 0.66) / 0.13) ** 2)
        lit = max(1, round(min(1.0, level) * rows))
        for j in range(rows):
            cx, cy = ox + i * pitch, oy + (rows - 1 - j) * pitch
            if j < lit:
                gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=VFD + (255,))
            else:
                gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(48, 24, 14, 255))
    bloom = glow.filter(ImageFilter.GaussianBlur(9))
    img.alpha_composite(bloom)
    img.alpha_composite(glow)

    # Glass: a faint diagonal sheen across the upper part of the window.
    sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    sd.polygon([(x0, y0), (x1, y0), (x1, y0 + 40), (x0, y0 + 110)], fill=(255, 255, 255, 18))
    win = Image.new("L", (S, S), 0)
    ImageDraw.Draw(win).rectangle([x0, y0, x1, y1], fill=255)
    sheen.putalpha(ImageChops.multiply(sheen.getchannel("A"), win))
    img.alpha_composite(sheen)


def main():
    img = plate()
    screws(img)
    bottom = wordmark(img)
    vfd(img, bottom)
    img.save(OUT)
    print(OUT)


if __name__ == "__main__":
    main()
