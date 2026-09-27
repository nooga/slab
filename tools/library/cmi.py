#!/usr/bin/env python3
"""cmi.py - unpack Fairlight CMI Series II / IIx disks into Unfairlight voices.

Bring your own disks: this reads ImageDisk (.IMD) or raw (.IMG, 512,512
bytes) images of CMI 8" floppies, and loose .VC voice files, and

  1. copies every voice into the Slab sample library,
     $SLAB_LIBRARY or ~/Music/Slab/Library, as cmi/<disk>/<VOICE>.vc;
  2. writes an Unfairlight CIA preset per voice into
     machines/unfairlight/presets/cmi-<disk>/, with the voice's own loop
     and filter, pointing at "lib:cmi/<disk>/<VOICE>.vc".

Usage:
  tools/library/cmi.py DISK.IMD [MORE.IMD ...]
  tools/library/cmi.py ~/cmi-disks/            every image and .VC under it
  tools/library/cmi.py --list DISK.IMD         what's on it, nothing written

The disk: 77 tracks x 2 sides x 26 sectors of 128 bytes, tracks in the
image in cylinder-then-head order; a QDOS filesystem with its directory
at sector 3, 160 entries of 16 bytes: name (8), type (2), first block
(2, big-endian), attributes (2, 0 = free).  A file runs from its block
(x 128 bytes).  A .VC is 21,888 bytes: parameters, then the 16,384-byte
waveform RAM at 0x1580.  The loop and filter offsets come from the
nattvard.com IIx notes; --list prints them per voice to check.
"""

import argparse
import json
import os
import re
import sys

SLAB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PRESETS = os.path.join(SLAB, "machines", "unfairlight", "presets")

TRACKS, SIDES, SECTORS, SECTOR = 77, 2, 26, 128
IMG_SIZE = TRACKS * SIDES * SECTORS * SECTOR  # 512,512
VC_SIZE = 21888
VC_RAM = 0x1580
VC_LOOP_START, VC_LOOP_END, VC_LOOP_ON, VC_FILTER = 0x1332, 0x1333, 0x133B, 0x141C  # src/keymap.zig


def library_root():
    root = os.environ.get("SLAB_LIBRARY")
    if root:
        return root.rstrip("/")
    return os.path.join(os.path.expanduser("~"), "Music", "Slab", "Library")


# ── disk images ──────────────────────────────────────────────────────────


def imd_unpack(data):
    """ImageDisk → the raw image: tracks in file order, sectors by their map."""
    p = data.index(0x1A) + 1  # after the ASCII header
    out = bytearray(IMG_SIZE)
    for t in range(TRACKS * SIDES):
        if p + 5 > len(data):
            break
        _mode, _cyl, head, nsec, size_code = data[p:p + 5]
        p += 5
        size = 128 << size_code
        smap = data[p:p + nsec]
        p += nsec
        if head & 0x80:  # cylinder map
            p += nsec
        if head & 0x40:  # head map
            p += nsec
        track = bytearray(SECTORS * SECTOR)
        for i in range(nsec):
            kind = data[p]
            p += 1
            if kind == 0:  # unavailable: leave zeros
                sec = bytes(size)
            elif kind in (1, 3, 5, 7):  # normal (deleted / error variants)
                sec = data[p:p + size]
                p += size
            elif kind in (2, 4, 6, 8):  # compressed: one fill byte
                sec = bytes([data[p]]) * size
                p += 1
            else:
                raise ValueError(f"unknown IMD sector record {kind} in track {t}")
            n = smap[i] - 1
            if 0 <= n < SECTORS and size >= SECTOR:
                track[n * SECTOR:(n + 1) * SECTOR] = sec[:SECTOR]
        out[t * SECTORS * SECTOR:(t + 1) * SECTORS * SECTOR] = track
    return bytes(out)


def read_image(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:3] == b"IMD":
        return imd_unpack(data)
    if len(data) == IMG_SIZE:
        return data
    raise ValueError(f"{path}: neither IMD nor a {IMG_SIZE}-byte raw image")


def directory(img):
    """[(name, type, block)] of the QDOS directory's used entries."""
    out = []
    for i in range(160):
        e = img[3 * SECTOR + 16 * i: 3 * SECTOR + 16 * (i + 1)]
        if e[0] in (0, 0xFF):
            continue
        attr = (e[12] << 8) | e[13]
        if attr == 0:
            continue
        name = e[:8].decode("latin-1").rstrip(" \0")
        kind = e[8:10].decode("latin-1").rstrip(" \0")
        out.append((name, kind, (e[10] << 8) | e[11]))
    return out


def voices_on(img):
    for name, kind, block in directory(img):
        if kind.upper() != "VC":
            continue
        at = block * SECTOR
        vc = img[at:at + VC_SIZE]
        if len(vc) == VC_SIZE:
            yield name, vc


# ── voices ───────────────────────────────────────────────────────────────


def vc_params(vc):
    return {"loop_on": vc[VC_LOOP_ON] != 0, "loop_start": vc[VC_LOOP_START] & 0x7F,
            "loop_end": vc[VC_LOOP_END] & 0x7F, "filter": vc[VC_FILTER]}


def used_segments(vc):
    """Segments up to the last one that isn't silence (0x80 or 0x00 fill)."""
    ram = vc[VC_RAM:VC_RAM + 16384]
    last = 0
    for s in range(128):
        seg = ram[s * 128:(s + 1) * 128]
        if any(b not in (0x80, 0x7F, 0x00) for b in seg):
            last = s + 1
    return last


def safe(name):
    return re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("_") or "voice"


def preset(vc, lib_path, note):
    p = vc_params(vc)
    loop = p["loop_on"] and p["loop_end"] >= p["loop_start"]
    return {"schema": 1, "machine": "unfairlight", "note": note,
            "params": {"cmi-rate": 24000, "cmi-root": 57, "cmi-tune": 0,
                       "cmi-loop": 1 if loop else 0,
                       "cmi-loop-start": p["loop_start"] if loop else 0,
                       "cmi-loop-end": p["loop_end"] if loop else 127,
                       "cmi-filter": p["filter"] or 160,
                       "cmi-atk": 0.002, "cmi-damp": 0.3, "cmi-vel": 0, "cmi-vol": 0.6},
            "assets": {"voice": lib_path}}


def sources(paths):
    """(disk name, [(voice name, bytes)]) per image or folder of .VC files."""
    for path in paths:
        if not os.path.exists(path):
            print(f"  {path}: no such file or folder", file=sys.stderr)
            continue
        if os.path.isdir(path):
            loose = []
            for dirpath, _, files in os.walk(path):
                for f in sorted(files):
                    full = os.path.join(dirpath, f)
                    if f.lower().endswith((".imd", ".img")):
                        yield from sources([full])
                    elif f.lower().endswith(".vc"):
                        with open(full, "rb") as fh:
                            loose.append((os.path.splitext(f)[0], fh.read()))
            if loose:
                yield safe(os.path.basename(path.rstrip("/"))), loose
        elif path.lower().endswith(".vc"):
            with open(path, "rb") as fh:
                yield "loose", [(os.path.splitext(os.path.basename(path))[0], fh.read())]
        else:
            try:
                img = read_image(path)
            except (ValueError, OSError) as e:
                print(f"  skipping {path}: {e}", file=sys.stderr)
                continue
            yield safe(os.path.splitext(os.path.basename(path))[0]).lower(), list(voices_on(img))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="IMD/IMG images, .VC files, or folders of them")
    ap.add_argument("--list", action="store_true", help="print the voices, write nothing")
    ap.add_argument("--no-presets", action="store_true", help="copy the voices only")
    args = ap.parse_args()

    root = os.path.join(library_root(), "cmi")
    total = 0
    for disk, voices in sources(args.paths):
        if not voices:
            print(f"{disk}: no voices")
            continue
        print(f"{disk}: {len(voices)} voices")
        for name, vc in voices:
            if len(vc) < VC_RAM + 16384:
                print(f"  {name}: short file ({len(vc)} bytes), skipped")
                continue
            p = vc_params(vc)
            if args.list:
                print(f"  {name:8s}  {used_segments(vc):3d} segments  loop {'on ' if p['loop_on'] else 'off'} "
                      f"{p['loop_start']:3d}-{p['loop_end']:3d}  filter {p['filter']:3d}")
                continue
            fname = safe(name).upper() + ".vc"
            dest = os.path.join(root, disk, fname)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as fh:
                fh.write(vc)
            if not args.no_presets:
                pdir = os.path.join(PRESETS, f"cmi-{disk}")
                os.makedirs(pdir, exist_ok=True)
                with open(os.path.join(pdir, safe(name).lower() + ".preset"), "w") as fh:
                    fh.write(json.dumps(preset(vc, f"lib:cmi/{disk}/{fname}", f"CMI {disk} / {name}")) + "\n")
            total += 1
    if not args.list:
        print(f"{total} voices in {root}")


if __name__ == "__main__":
    main()
