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
  tools/library/cmi.py --collection NAME DISK.IMD [MORE ...]
  tools/library/cmi.py --collection NAME FOLDER/   images, .VC files and
                                                  8-bit WAV voice dumps under it
  tools/library/cmi.py --list DISK.IMD            what's on it, nothing written
  tools/library/cmi.py --catalog                  rewrite CATALOG.md

Each voice is stored once, by the hash of its RAM, under
lib:cmi/<collection>/<disk>/; a voice that another disk already carries
points at the first copy.  index.json keeps what was imported and
CATALOG.md lists it.  WAV dumps (8-bit, 16,384 samples or fewer) become
.VC files with a neutral header and no loop.  Tonal voices get their
pitch measured (YIN, numpy) and ROOT set to it at the presets' RATE.

The disk: 77 tracks x 2 sides x 26 sectors of 128 bytes, tracks in the
image in cylinder-then-head order; a QDOS filesystem with its directory
at sector 3, 160 entries of 16 bytes: name (8), type (2), first block
(2, big-endian), attributes (2, 0 = free).  The block is the file's
header sector; its data runs contiguously from the next one.  The loop and filter offsets come from the
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
VC_RAM = 0x1500
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
        # the block is the file's header sector; its data follows
        at = (block + 1) * SECTOR
        vc = img[at:at + VC_SIZE]
        if len(vc) == VC_SIZE:
            yield name, vc


# ── voices ───────────────────────────────────────────────────────────────

RATE = 24000  # the Unfairlight's RATE the presets use; roots are measured at it


def vc_params(vc):
    return {"loop_on": vc[VC_LOOP_ON] != 0, "loop_start": vc[VC_LOOP_START] & 0x7F,
            "loop_end": vc[VC_LOOP_END] & 0x7F, "filter": vc[VC_FILTER]}


def ram_of(vc):
    return vc[VC_RAM:VC_RAM + 16384]


def used_segments(vc):
    """Segments up to the last one that isn't silence (0x80 or 0x00 fill)."""
    ram = ram_of(vc)
    last = 0
    for s in range(128):
        seg = ram[s * 128:(s + 1) * 128]
        if any(b not in (0x80, 0x7F, 0x00) for b in seg):
            last = s + 1
    return last


def vc_from_ram(ram):
    """A .VC around bare voice RAM (a WAV dump): no loop, a neutral header."""
    ram = bytes(ram[:16384]) + bytes([0x80]) * max(0, 16384 - len(ram))
    return bytes(VC_RAM) + ram + bytes(VC_SIZE - VC_RAM - 16384)


def wav_ram(path):
    """8-bit mono WAV of at most 16,384 samples → the raw bytes, else None."""
    with open(path, "rb") as f:
        b = f.read()
    i, fmt, data = 12, None, None
    while i + 8 <= len(b):
        cid, sz = b[i:i + 4], int.from_bytes(b[i + 4:i + 8], "little")
        if cid == b"fmt ":
            fmt = b[i + 8:i + 24]
        elif cid == b"data":
            data = b[i + 8:i + 8 + sz]
        i += 8 + sz + (sz & 1)
    if fmt is None or data is None:
        return None
    ch, bits = int.from_bytes(fmt[2:4], "little"), int.from_bytes(fmt[14:16], "little")
    if ch != 1 or bits != 8 or len(data) > 16384:
        return None
    return data


def pitch(vc):
    """(root MIDI note at RATE, confidence 0..1) of a tonal voice, or None.
    YIN on the loop when there is one, else on the body past the attack."""
    try:
        import numpy as np
    except ImportError:
        return None
    x = (np.frombuffer(ram_of(vc), dtype=np.uint8).astype(np.float64) - 128) / 128
    p = vc_params(vc)
    used = used_segments(vc)
    if p["loop_on"] and p["loop_end"] - p["loop_start"] >= 3:
        seg = x[p["loop_start"] * 128:(p["loop_end"] + 1) * 128]
    else:
        a = min(4, used // 4) * 128
        seg = x[a:min(a + 32 * 128, used * 128)]
    if len(seg) < 1024 or np.abs(seg).max() < 0.02:
        return None
    seg = seg - seg.mean()
    n = len(seg)
    w = min(n // 2, 2048)
    tmax = min(n - w, 2000)
    if tmax <= 8:
        return None
    # d(t) = sum over the window of (x[j] - x[j+t])^2, cumulative-mean normalized
    ac = np.correlate(seg[:w + tmax - 1], seg[:w], mode="valid")[:tmax]
    e = np.concatenate([[0.0], np.cumsum(seg ** 2)])
    energy0 = e[w]
    energy_t = e[np.arange(tmax) + w] - e[np.arange(tmax)]
    d = np.maximum(energy0 + energy_t - 2 * ac, 0)
    d[0] = 0
    cm = d[1:] * np.arange(1, tmax) / np.maximum(np.cumsum(d[1:]), 1e-12)
    cm = np.concatenate([[1.0], cm])
    cand = np.where(cm[4:] < 0.15)[0]
    if len(cand) == 0:
        return None
    t = cand[0] + 4
    while t + 1 < tmax and cm[t + 1] < cm[t]:
        t += 1
    if 1 <= t < tmax - 1:
        a, b, c = cm[t - 1], cm[t], cm[t + 1]
        den = a - 2 * b + c
        t = t + (0.5 * (a - c) / den if den != 0 else 0)
    root = 69 + 12 * np.log2(RATE / t / 440)
    return float(root), float(1 - cm[int(round(t))])


def safe(name):
    return re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("_") or "voice"


def disk_slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "disk"


def preset(vc, lib_path, note, root):
    p = vc_params(vc)
    loop = p["loop_on"] and p["loop_end"] >= p["loop_start"]
    # the file's filter byte reads as an amount of filtering: 0 on hats and
    # rims, 100-127 on kicks; the card's latch runs the other way
    latch = max(0, min(255, 255 - 2 * p["filter"]))
    return {"schema": 1, "machine": "unfairlight", "note": note,
            "params": {"cmi-rate": RATE, "cmi-root": round(root, 2), "cmi-tune": 0,
                       "cmi-loop": 1 if loop else 0,
                       "cmi-loop-start": p["loop_start"] if loop else 0,
                       "cmi-loop-end": p["loop_end"] if loop else 127,
                       "cmi-filter": latch,
                       "cmi-atk": 0.002, "cmi-damp": 0.3, "cmi-vel": 0, "cmi-vol": 0.6},
            "assets": {"voice": lib_path}}


def sources(paths, deleted=False):
    """(disk name, [(voice name, .VC bytes)]): one per disk image, one per
    folder of loose .VC files or 8-bit WAV voice dumps."""
    for path in paths:
        if not os.path.exists(path):
            print(f"  {path}: no such file or folder", file=sys.stderr)
            continue
        if os.path.isdir(path):
            for dirpath, dirs, files in os.walk(path):
                dirs.sort()
                loose = []
                for f in sorted(files):
                    full = os.path.join(dirpath, f)
                    low = f.lower()
                    if low.startswith("deleted") and not deleted:
                        continue
                    if low.endswith((".imd", ".img")):
                        yield from sources([full])
                    elif low.endswith(".vc"):
                        with open(full, "rb") as fh:
                            loose.append((os.path.splitext(f)[0], fh.read()))
                    elif low.endswith(".wav") and not low.endswith(".vc.wav"):
                        ram = wav_ram(full)
                        if ram is not None:
                            loose.append((os.path.splitext(f)[0], vc_from_ram(ram)))
                if loose:
                    yield disk_slug(os.path.basename(dirpath)), loose
        elif path.lower().endswith(".vc"):
            with open(path, "rb") as fh:
                yield "loose", [(os.path.splitext(os.path.basename(path))[0], fh.read())]
        else:
            try:
                img = read_image(path)
            except (ValueError, OSError) as e:
                print(f"  skipping {path}: {e}", file=sys.stderr)
                continue
            yield disk_slug(os.path.splitext(os.path.basename(path))[0]), list(voices_on(img))


# ── the library index and catalog ───────────────────────────────────────


def load_index(root):
    p = os.path.join(root, "index.json")
    return json.load(open(p)) if os.path.exists(p) else {"voices": {}, "collections": {}}


def save_index(root, index):
    with open(os.path.join(root, "index.json"), "w") as f:
        json.dump(index, f, indent=1, sort_keys=True)


def write_catalog(root, index):
    by = {}
    for h, v in index["voices"].items():
        for ref in v["refs"]:
            by.setdefault((ref["collection"], ref["disk"]), []).append((ref["name"], h, v))
    lines = ["# CMI voice library", "",
             "Generated by tools/library/cmi.py. Each voice is stored once (by the",
             "hash of its RAM) and listed on every disk that carries it. ROOT is the",
             f"measured pitch at RATE {RATE} Hz (tonal voices); presets are",
             "machines/unfairlight/presets/cmi-<collection>/<disk>/.", ""]
    for c, meta in sorted(index["collections"].items()):
        n = sum(1 for (cc, _), _ in by.items() if cc == c)
        lines += [f"## {c}: {meta.get('title', c)}", "", meta.get("note", ""), "",
                  f"{n} disks.", ""]
        for (cc, disk), vs in sorted(by.items()):
            if cc != c:
                continue
            lines += [f"### {disk}", "", "| voice | segs | loop | filter | root | also on |", "|---|---|---|---|---|---|"]
            for name, h, v in sorted(vs):
                others = [f"{r['collection']}/{r['disk']}/{r['name']}" for r in v["refs"]
                          if (r["collection"], r["disk"], r["name"]) != (c, disk, name)]
                loop = f"{v['loop'][0]}-{v['loop'][1]}" if v["loop"] else "-"
                root_s = f"{v['root']:.1f}" if v.get("tonal") else "-"
                lines.append(f"| {name} | {v['segments']} | {loop} | {v['filter']} | {root_s} | {', '.join(others[:3])} |")
            lines.append("")
    with open(os.path.join(root, "CATALOG.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def import_collection(root, index, collection, paths, title, note, deleted, presets):
    import hashlib
    index["collections"][collection] = {"title": title or collection, "note": note or ""}
    count = new = 0
    for disk, voices in sources(paths, deleted):
        for name, vc in voices:
            if len(vc) < VC_RAM + 16384:
                continue
            h = hashlib.sha1(ram_of(vc)).hexdigest()[:16]
            v = index["voices"].get(h)
            if v is None:
                fname = safe(name).upper() + ".vc"
                rel = f"{collection}/{disk}/{fname}"
                dest = os.path.join(root, rel)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as fh:
                    fh.write(vc)
                pr = pitch(vc)
                p = vc_params(vc)
                v = index["voices"][h] = {
                    "path": rel, "segments": used_segments(vc), "filter": p["filter"],
                    "loop": [p["loop_start"], p["loop_end"]] if p["loop_on"] else None,
                    "root": pr[0] if pr else 57.0, "tonal": pr is not None, "refs": []}
                new += 1
            ref = {"collection": collection, "disk": disk, "name": name}
            if ref not in v["refs"]:
                v["refs"].append(ref)
            if presets:
                with open(os.path.join(root, v["path"]), "rb") as fh:
                    stored = fh.read()
                root_note = min(96.0, max(24.0, v["root"]))
                pdir = os.path.join(PRESETS, f"cmi-{collection}", disk)
                os.makedirs(pdir, exist_ok=True)
                with open(os.path.join(pdir, safe(name).lower() + ".preset"), "w") as fh:
                    fh.write(json.dumps(preset(stored, f"lib:cmi/{v['path']}",
                                               f"CMI {collection} / {disk} / {name}", root_note)) + "\n")
            count += 1
    return count, new


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", help="IMD/IMG images, .VC files, WAV voice dumps, or folders of them")
    ap.add_argument("--list", action="store_true", help="print the voices, write nothing")
    ap.add_argument("--collection", default="user", help="collection name: lib:cmi/<collection>/<disk>/")
    ap.add_argument("--title", help="the collection's title in CATALOG.md")
    ap.add_argument("--note", help="a line about the collection for CATALOG.md")
    ap.add_argument("--deleted", action="store_true", help="include DELETED- files recovered from disk free space")
    ap.add_argument("--no-presets", action="store_true", help="copy the voices only")
    ap.add_argument("--catalog", action="store_true", help="rewrite CATALOG.md from the index only")
    args = ap.parse_args()

    root = os.path.join(library_root(), "cmi")
    if args.list:
        for disk, voices in sources(args.paths, args.deleted):
            print(f"{disk}: {len(voices)} voices")
            for name, vc in voices:
                p = vc_params(vc)
                pr = pitch(vc)
                print(f"  {name:8s}  {used_segments(vc):3d} segments  loop {'on ' if p['loop_on'] else 'off'} "
                      f"{p['loop_start']:3d}-{p['loop_end']:3d}  filter {p['filter']:3d}"
                      + (f"  root {pr[0]:5.1f}" if pr else ""))
        return
    os.makedirs(root, exist_ok=True)
    index = load_index(root)
    if not args.catalog:
        if not args.paths:
            ap.error("nothing to import")
        count, new = import_collection(root, index, disk_slug(args.collection), args.paths, args.title,
                                       args.note, args.deleted, not args.no_presets)
        print(f"{args.collection}: {count} voices, {new} new to the library")
        save_index(root, index)
    write_catalog(root, index)
    print(f"{len(index['voices'])} voices in {root} (CATALOG.md)")


if __name__ == "__main__":
    main()
