#!/usr/bin/env python3
"""Draw the DMG window's background (tools/app/dmg-background.png and
@2x): a Slab faceplate with two bays, the app and Applications, and a
patch cable from the app's OUT jack to Applications' IN under a VFD of
chevrons. Palette and Tamzen from docs/06; the panel is drawn at 1x and
scaled by whole pixels, the cable and glow at each scale.

    python3 tools/app/make_dmg_background.py

The window and icon positions in tools/app/dmg_settings.py match W, H,
APP and APPS here.
"""

import math
import os
import tempfile

from PIL import BdfFontFile, Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.join(ROOT, "tools", "app")

W, H = 640, 400
APP = (164, 196)    # icon centres, points (dmg_settings.py)
APPS = (476, 196)
BAY = 168           # bay size around a 128 pt icon

CHASSIS = (0x11, 0x12, 0x15)
FACE = (0x33, 0x36, 0x3C)
FACE_HI = (0x4E, 0x52, 0x5A)
FACE_LO = (0x23, 0x25, 0x2A)
EDGE = (0x08, 0x09, 0x0B)
WELL = (0x0A, 0x0B, 0x0D)
TEXT_DIM = (0xA7, 0xAB, 0xB2)
TEXT_MUTE = (0x6F, 0x74, 0x7C)
VFD = (0xFF, 0x9A, 0x2E)
MOD = (0x6B, 0x8C, 0xFF)
STRIP = (0x8C, 0x90, 0x97)   # scribble strip under a label: black or white text reads


def tamzen(name):
    tmp = tempfile.mkdtemp()
    with open(os.path.join(ROOT, "vendor", "tamzen", name), "rb") as f:
        BdfFontFile.BdfFontFile(f).save(os.path.join(tmp, "t"))
    return ImageFont.load(os.path.join(tmp, "t.pil"))


SMALL = tamzen("Tamzen6x12r.bdf")
BOLD = tamzen("Tamzen8x16b.bdf")


def bevel(d, x0, y0, x1, y1, raised=True):
    hi, lo = (FACE_HI, FACE_LO) if raised else (FACE_LO, FACE_HI)
    d.line([(x0, y1), (x0, y0), (x1, y0)], fill=hi)
    d.line([(x1, y0 + 1), (x1, y1), (x0 + 1, y1)], fill=lo)


def text(d, xy, s, font, fill, anchor_center=False):
    x, y = xy
    if anchor_center:
        w = d.textlength(s, font=font)
        x = round(x - w / 2)
    d.text((x, y), s, font=font, fill=fill)


def panel_1x():
    img = Image.new("RGB", (W, H), CHASSIS)
    d = ImageDraw.Draw(img)

    # The faceplate: chamfered, bevelled, a faint vertical falloff.
    m = 6
    c = 10
    plate = [(m + c, m), (W - m - c, m), (W - m, m + c), (W - m, H - m - c),
             (W - m - c, H - m), (m + c, H - m), (m, H - m - c), (m, m + c)]
    grad = Image.new("RGB", (W, H))
    gd = ImageDraw.Draw(grad)
    for y in range(H):
        t = y / H
        gd.line([(0, y), (W, y)], fill=tuple(round(a - 6 * t) for a in FACE))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).polygon(plate, fill=255)
    img.paste(grad, (0, 0), mask)
    d.line(plate[7:] + plate[:3], fill=FACE_HI)
    d.line(plate[2:8], fill=FACE_LO)
    d.polygon(plate, outline=None)

    # Header: wordmark left, model line right, a seam below.
    logo = Image.open(os.path.join(ROOT, "slab.png")).convert("RGB")
    lh = 22
    logo = logo.resize((round(logo.width * lh / logo.height), lh), Image.LANCZOS)
    img.paste(logo, (24, 20), Image.eval(logo.convert("L"), lambda v: 0 if v < 10 else min(255, v * 3)))
    text(d, (W - 24 - d.textlength("AUDIO WORKSTATION", font=SMALL), 20), "AUDIO WORKSTATION", SMALL, TEXT_DIM)
    text(d, (W - 24 - d.textlength("FY-POWERED  LIVECODE", font=SMALL), 32), "FY-POWERED  LIVECODE", SMALL, TEXT_MUTE)
    d.line([(16, 56), (W - 16, 56)], fill=EDGE)
    d.line([(16, 57), (W - 16, 57)], fill=FACE_HI)

    # Bays: recessed wells, a scribble strip under each for Finder's label.
    for (cx, cy), legend in ((APP, "SOURCE"), (APPS, "DESTINATION")):
        x0, y0 = cx - BAY // 2, cy - BAY // 2 - 8
        x1, y1 = cx + BAY // 2, cy + BAY // 2 + 22
        text(d, (cx, y0 - 16), legend, SMALL, TEXT_DIM, anchor_center=True)
        d.rectangle([x0, y0, x1, y1], fill=(0x16, 0x17, 0x1B))
        bevel(d, x0 - 1, y0 - 1, x1 + 1, y1 + 1, raised=False)
        d.rectangle([x0, y0, x1, y1], outline=EDGE)
        sy = cy + 71
        d.rectangle([cx - 56, sy, cx + 56, sy + 20], fill=STRIP)
        bevel(d, cx - 57, sy - 1, cx + 57, sy + 21, raised=False)

    # Jacks: OUT on the app bay's right, IN on Applications' left.
    for (jx, jy), lab in (((APP[0] + BAY // 2 + 22, APP[1] + 40), "OUT"),
                          ((APPS[0] - BAY // 2 - 22, APPS[1] + 40), "IN")):
        d.ellipse([jx - 9, jy - 9, jx + 9, jy + 9], fill=FACE_LO, outline=EDGE)
        d.ellipse([jx - 6, jy - 6, jx + 6, jy + 6], fill=(0x9A, 0x9E, 0xA6))
        d.ellipse([jx - 3, jy - 3, jx + 3, jy + 3], fill=EDGE)
        text(d, (jx, jy - 25), lab, SMALL, TEXT_DIM, anchor_center=True)

    # The chevron display between the bays.
    vx0, vx1 = W // 2 - 60, W // 2 + 60
    vy0, vy1 = APP[1] - 70, APP[1] - 30
    d.rectangle([vx0, vy0, vx1, vy1], fill=WELL)
    bevel(d, vx0 - 1, vy0 - 1, vx1 + 1, vy1 + 1, raised=False)
    text(d, (W // 2, vy1 + 6), "INSTALL", SMALL, TEXT_DIM, anchor_center=True)

    # Footer: the instruction, engraved.
    d.line([(16, H - 44), (W - 16, H - 44)], fill=EDGE)
    d.line([(16, H - 43), (W - 16, H - 43)], fill=FACE_HI)
    text(d, (W // 2, H - 32), "PATCH SLAB INTO APPLICATIONS: DRAG THE ICON ACROSS", BOLD, TEXT_DIM, anchor_center=True)

    # Screws.
    for sx, sy in ((18, 18), (W - 18, 18), (18, H - 18), (W - 18, H - 18)):
        d.ellipse([sx - 5, sy - 5, sx + 5, sy + 5], fill=(0x7A, 0x7E, 0x86), outline=EDGE)
        d.line([(sx - 3, sy + 2), (sx + 3, sy - 2)], fill=FACE_LO, width=2)
    return img


def chevrons(img, s):
    """Dot-matrix chevrons glowing vfd in the display (at scale s)."""
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    pitch = 5 * s
    r = 1.7 * s
    cols, rows = 21, 7
    cx0 = W // 2 * s - (cols - 1) * pitch / 2
    cy = (APP[1] - 50) * s
    # Three chevrons, 7 rows tall, brightening towards Applications.
    for k in range(3):
        a = 120 + 65 * k
        for dy in range(-3, 4):
            for dx in (0, 1):
                x = cx0 + (1 + k * 6 + dx + (3 - abs(dy))) * pitch
                y = cy + dy * pitch
                gd.ellipse([x - r, y - r, x + r, y + r], fill=VFD + (min(255, a),))
    # Unlit dots behind them, the rest of the matrix.
    base = Image.new("RGBA", img.size, (0, 0, 0, 0))
    bd = ImageDraw.Draw(base)
    for i in range(cols):
        for j in range(-3, 4):
            x, y = cx0 + i * pitch, cy + j * pitch
            bd.ellipse([x - r, y - r, x + r, y + r], fill=(0x30, 0x1C, 0x10, 255))
    img.alpha_composite(base)
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(2.5 * s)))
    img.alpha_composite(glow)


def cable(img, s):
    """A patch cable sagging from OUT to IN, plugs in both jacks."""
    x0, y0 = (APP[0] + BAY // 2 + 22) * s, (APP[1] + 40) * s
    x1, y1 = (APPS[0] - BAY // 2 - 22) * s, (APPS[1] + 40) * s
    sag = 40 * s
    pts = []
    for i in range(101):
        t = i / 100
        x = x0 + (x1 - x0) * t
        y = y0 + (y1 - y0) * t + sag * 4 * t * (1 - t)
        pts.append((x, y))
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).line([(x, y + 6 * s) for x, y in pts], fill=(0, 0, 0, 150), width=round(7 * s))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(3 * s)))
    d = ImageDraw.Draw(img)
    d.line(pts, fill=tuple(round(v * 0.55) for v in MOD) + (255,), width=round(7 * s), joint="curve")
    d.line(pts, fill=MOD + (255,), width=round(5 * s), joint="curve")
    d.line([(x, y - 1.2 * s) for x, y in pts], fill=(0xB5, 0xC6, 0xFF, 200), width=max(1, round(1.2 * s)))
    # Plugs: a sleeve over each jack, the boot towards the cable.
    for (px, py), sign in (((x0, y0), 1), ((x1, y1), -1)):
        d.ellipse([px - 7 * s, py - 7 * s, px + 7 * s, py + 7 * s], fill=(0x2A, 0x2C, 0x31, 255))
        d.ellipse([px - 5 * s, py - 5 * s, px + 5 * s, py + 5 * s], fill=(0xC8, 0xCB, 0xD0, 255))
        d.ellipse([px - 3 * s, py - 3 * s, px + 2 * s, py + 2 * s], fill=(0xF2, 0xF3, 0xF5, 255))
    # An arrowhead riding the cable, pointing at IN.
    t = 0.74
    i = round(t * 100)
    (ax, ay), (bx, by) = pts[i - 1], pts[i + 1]
    ang = math.atan2(by - ay, bx - ax)
    hx, hy = pts[i]
    L, Wd = 12 * s, 7 * s
    tip = (hx + L / 2 * math.cos(ang), hy + L / 2 * math.sin(ang))
    back = (hx - L / 2 * math.cos(ang), hy - L / 2 * math.sin(ang))
    left = (back[0] + Wd * math.cos(ang + math.pi / 2), back[1] + Wd * math.sin(ang + math.pi / 2))
    right = (back[0] - Wd * math.cos(ang + math.pi / 2), back[1] - Wd * math.sin(ang + math.pi / 2))
    d.polygon([tip, left, right], fill=(0xB5, 0xC6, 0xFF, 255), outline=tuple(round(v * 0.55) for v in MOD) + (255,))


def render(s):
    img = panel_1x().resize((W * s, H * s), Image.NEAREST).convert("RGBA")
    chevrons(img, s)
    cable(img, s)
    return img.convert("RGB")


def main():
    render(1).save(os.path.join(HERE, "dmg-background.png"))
    render(2).save(os.path.join(HERE, "dmg-background@2x.png"))
    print(os.path.join(HERE, "dmg-background.png"))


if __name__ == "__main__":
    main()
