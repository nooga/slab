#!/usr/bin/env python3
"""cmi.py - unpack Fairlight CMI Series II / IIx disks into Unfairlight voices.

Bring your own disks: this reads ImageDisk (.IMD) or raw (.IMG, 512,512
bytes) images of CMI 8" floppies, and loose .VC voice files, and

  1. copies every voice into the Slab sample library,
     $SLAB_LIBRARY or ~/Music/Slab/Library, as cmi/<disk>/<VOICE>.vc;
  2. writes an Unfairlight TMI preset per voice into
     machines/unfairlight/presets/cmi-<disk>/, pointing at
     "lib:cmi/<disk>/<VOICE>.vc", with the voice's Page 7 settings when its
     disk carries its control file (NAME.CO: filter, attack, damping,
     level, vibrato, loop, start segment), else the voice's own loop;
  3. turns each instrument (NAME.IN: Page 3's registers, splits and
     layers) into a Rack preset in machines/rack/presets/cmi-<disk>/: a
     part per layered voice over its register's keys, tuned and capped at
     the register's polyphony.

Voices that form a multisample (same name but for a number, same disk,
tonal, at clearly different pitches that YIN and a harmonic product
spectrum agree on) also get a Rack in machines/rack/presets/multi-
<collection>/<disk>/: our guess at a split, each voice over the keys
nearest its pitch.  These aren't the CMI's own instruments.

Drum kits: KITS below picks voices from the drum and percussion disks
and places them on General MIDI keys, as SFZ files in lib:cmi/kits/ (one
shot, the hats choking each other, toms ordered by measured pitch) with an
Unfairlight preset each in cmi-kits/.  A kit whose voices you don't have
is skipped; one missing a few is written without them.

Usage:
  tools/library/cmi.py --collection NAME DISK.IMD [MORE ...]
  tools/library/cmi.py --collection NAME FOLDER/   images, .VC files and
                                                  8-bit WAV voice dumps under it
  tools/library/cmi.py --list DISK.IMD            what's on it, nothing written
  tools/library/cmi.py --catalog                  rewrite CATALOG.md
  tools/library/cmi.py --multisample              rewrite the multi-* racks
  tools/library/cmi.py --kits                     rewrite the drum kits

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
header sector; its data runs contiguously from the next one.

A .VC keeps its loop at 0x1332 (first segment, 0-based), 0x1333 (last) and
0x133B (on).  Page 7 lives in the .CO, 1,920 bytes: from 0x80 a list of
8-byte records [screen pos, param id, source, value (2, big-endian), 0 0
0], ended by id 0.  Source 0xB1 is a fixed value, 0xA0-0xA7 one patched to
a real-time controller (the value still set), 0xD0 key velocity; switches are 0xC0 on, 0xC1 off.  Ids, as the
IIx Page 7 screen names them: 1 MAIN LEVEL, 2 FILTER, 3 DAMPING-1, 4 VIB
DEPTH, 5 VIB SPEED, 6 MODE, 8 ATTACK (ms), 0x0F LOOP CNTRL, 0x10 LOOP START
(1-based), 0x11 LOOP LNGTH, 0x12 START SEG (1-based); later OS versions add
0x14-0x1B (pitch bend, aux level, damp mode, damping-2).

Pitch: the CMI's keyboard plays a voice at its own key table [the .IN
files' tables: per key an octave and a 10-bit pitch, the card's clock
registers], equal-tempered with a 128-sample waveform cycle at A440 on key
52, so MIDI = key + 17 and a voice at RATE 24000 has its root at 54.232.
Presets use that root, unless the voice is tonal and its measured pitch
sits off the CMI's semitones by more than half of one [sampled at another
key], when they take the measured pitch in the octave nearest it.
"""

import argparse
import json
import os
import re
import sys

SLAB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PRESETS = os.path.join(SLAB, "machines", "unfairlight", "presets")
RACK_PRESETS = os.path.join(SLAB, "machines", "rack", "presets")

TRACKS, SIDES, SECTORS, SECTOR = 77, 2, 26, 128
IMG_SIZE = TRACKS * SIDES * SECTORS * SECTOR  # 512,512
VC_SIZE = 21888
VC_RAM = 0x1500
VC_LOOP_START, VC_LOOP_END, VC_LOOP_ON = 0x1332, 0x1333, 0x133B  # src/keymap.zig


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


FILE_SIZES = {"VC": VC_SIZE, "CO": 1920, "IN": 2944}


def files_on(img, kinds=("VC", "CO", "IN")):
    """(name, type, bytes) of the disk's voices, control and instrument files."""
    for name, kind, block in directory(img):
        kind = kind.upper()
        if kind not in kinds:
            continue
        # the block is the file's header sector; its data follows
        at = (block + 1) * SECTOR
        data = img[at:at + FILE_SIZES[kind]]
        if len(data) == FILE_SIZES[kind]:
            yield name, kind, data


def voices_on(img):
    for name, _kind, vc in files_on(img, ("VC",)):
        yield name, vc


# ── voices ───────────────────────────────────────────────────────────────

RATE = 24000  # the Unfairlight's RATE the presets use; roots are measured at it
CMI_ROOT = 54.232  # MIDI note a voice plays at RATE on the CMI's own key table


def cmi_root(v):
    """ROOT for a voice index entry: the CMI's tuning, or the measured pitch
    near it when the voice was sampled off the CMI's semitones."""
    if not v.get("tonal"):
        return CMI_ROOT
    m = v["root"]
    m += 12 * round((CMI_ROOT - m) / 12)
    return CMI_ROOT if abs(m - CMI_ROOT) <= 0.5 else round(m, 2)


def vc_params(vc):
    return {"loop_on": vc[VC_LOOP_ON] != 0, "loop_start": vc[VC_LOOP_START] & 0x7F,
            "loop_end": vc[VC_LOOP_END] & 0x7F}


CO_SIZE = 1920
CO_FIELDS = {1: "level", 2: "filter", 3: "damping", 4: "vib_depth", 5: "vib_speed", 6: "mode",
             8: "attack", 0x0F: "loop", 0x10: "loop_start", 0x11: "loop_len", 0x12: "start_seg"}


def co_params(co):
    """Page 7 from a .CO control file as {field: value}, None if it isn't one.
    Switches read True/False; a level or attack under key velocity reads
    "keyvel"; one patched to a real-time controller reads its set value."""
    if len(co) < CO_SIZE:
        return None
    out, o = {}, 0x80
    while o + 5 <= len(co) and co[o + 1] != 0:
        pid, src, val = co[o + 1], co[o + 2], (co[o + 3] << 8) | co[o + 4]
        name = CO_FIELDS.get(pid)
        if name:
            if src in (0xC0, 0xC1):
                out[name] = src == 0xC0
            elif src == 0xD0:
                out[name] = "keyvel"
            else:
                out[name] = val
                if src & 0xF0 in (0x90, 0xA0):
                    out.setdefault("patched", []).append(name)
        o += 8
        if o > 0x80 + 8 * 40:
            return None
    if out.get("mode") not in (1, 4):  # the first record is always MODE: else not a .CO
        return None
    for k in ("filter", "damping", "attack", "loop_start", "loop_len", "start_seg"):
        if isinstance(out.get(k), int) and out[k] > 65535 // 2:
            return None
    return out


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


def pitch_hps(vc):
    """Root at RATE by harmonic product spectrum: a second opinion on
    pitch() that errs by octaves differently."""
    try:
        import numpy as np
    except ImportError:
        return None
    x = (np.frombuffer(ram_of(vc), dtype=np.uint8).astype(np.float64) - 128) / 128
    p, used = vc_params(vc), used_segments(vc)
    if p["loop_on"] and p["loop_end"] - p["loop_start"] >= 3:
        seg = x[p["loop_start"] * 128:(p["loop_end"] + 1) * 128]
    else:
        a = min(4, used // 4) * 128
        seg = x[a:min(a + 64 * 128, used * 128)]
    if len(seg) < 512:
        return None
    seg = seg - seg.mean()
    n = 1 << 16
    spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg)), n))
    f = np.fft.rfftfreq(n, 1 / RATE)
    h = spec.copy()
    for k in (2, 3, 4):
        dec = spec[::k]
        h[:len(dec)] *= dec
        h[len(dec):] = 0
    lo, hi = np.searchsorted(f, 30), np.searchsorted(f, 3000)
    i = lo + int(np.argmax(h[lo:hi]))
    return float(69 + 12 * np.log2(f[i] / 440))


NON_MELODIC = re.compile(r"drum|percus|cymbal|kick|snare|tom|transport|fx|sfx|enviro|animal|weather|construct")


def multisample_racks(root, index, collections=None):
    """Write a Rack per multisample family (see the module notes) into
    machines/rack/presets/multi-<collection>/<disk>/. Returns how many."""
    import shutil
    fams = {}
    for h, v in index["voices"].items():
        for r in v["refs"]:
            m = re.match(r"^(.*?[A-Z])[-_ ]?(\d+)$", r["name"].upper())
            if not m or len(m.group(1)) < 2 or not v.get("tonal"):
                continue
            if collections and r["collection"] not in collections:
                continue
            fams.setdefault((r["collection"], r["disk"], m.group(1)), []).append((r, v))
    done, seen = 0, set()
    for c in collections or index["collections"]:
        shutil.rmtree(os.path.join(RACK_PRESETS, f"multi-{c}"), ignore_errors=True)
    for (c, disk, stem), mem in sorted(fams.items()):
        if len(mem) < 2 or NON_MELODIC.search(disk):
            continue
        key = frozenset(v["path"] for _, v in mem)
        if key in seen:
            continue
        seen.add(key)
        mem.sort(key=lambda rv: rv[1]["root"])
        roots = [v["root"] for _, v in mem]
        if min(b - a for a, b in zip(roots, roots[1:])) < 2:
            continue  # same pitch: variants, not a multisample
        stored = []
        for r, v in mem:
            with open(os.path.join(root, v["path"]), "rb") as fh:
                vc = fh.read()
            second = pitch_hps(vc)
            if second is None or abs(second - v["root"]) > 0.7:
                break  # the two pitch methods disagree: no split on a guess
            stored.append(vc)
        else:
            parts = []
            for i, ((r, v), vc) in enumerate(zip(mem, stored)):
                lo = 0 if i == 0 else int(round((roots[i - 1] + roots[i]) / 2))
                hi = 127 if i == len(mem) - 1 else int(round((roots[i] + roots[i + 1]) / 2)) - 1
                vp = preset(vc, f"lib:cmi/{v['path']}", r["name"], min(96.0, max(24.0, v["root"])), r.get("co"))
                parts.append({"machine": "unfairlight", "name": r["name"], "lo": lo, "hi": hi, "vlo": 1, "vhi": 127,
                              "transpose": 0, "level": 0, "pan": 0, "poly": 0, "mute": False,
                              "params": vp["params"], "assets": vp["assets"]})
            pdir = os.path.join(RACK_PRESETS, f"multi-{c}", disk)
            os.makedirs(pdir, exist_ok=True)
            names = ", ".join(f"{r['name']} {v['root']:.1f}" for r, v in mem)
            with open(os.path.join(pdir, safe(stem).lower() + ".preset"), "w") as fh:
                fh.write(json.dumps({"schema": 1, "machine": "rack",
                                     "note": f"Multisample guessed by cmi.py, not a CMI instrument: {names}",
                                     "parts": parts}) + "\n")
            done += 1
    return done


# GM keys: kick 35/36, rim 37, snare 38/40, clap 39, hats 42/44/46, toms
# 41 43 45 47 48 50 (low to high), crash 49/57, ride 51, ride bell 53,
# tambourine 54, splash 55, cowbell 56, vibraslap 58, bongos 60/61,
# congas 62-64, timbales 65/66, cabasa 69, shaker 70, guiro 73, claves 75,
# wood blocks 76/77, triangle 81; "TOMS" is filled low to high.
TOM_KEYS = [41, 43, 45, 47, 48, 50]
HAT_KEYS = (42, 44, 46)
KITS = {
    "iix-acoustic": ("IIx acoustic kit", {
        36: "iix/01-drums-1-kick/KICK05", 35: "iix/01-drums-1-kick/KICK07",
        38: "iix/02-drums-2-snare/SNARE10", 40: "iix/02-drums-2-snare/SNARE12", 37: "iix/03-drums-3-toms/RIM01",
        39: "iix/06-percussion-1/CLAP05",
        42: "iix/05-cymbals-1/HHCLOS02", 44: "iix/05-cymbals-1/HHCLOS06", 46: "iix/05-cymbals-1/HHOPEN01",
        "TOMS": ["iix/03-drums-3-toms/TOM09", "iix/03-drums-3-toms/TOM10", "iix/03-drums-3-toms/TOM01", "iix/03-drums-3-toms/TOM03"],
        49: "iix/05-cymbals-1/CYMBAL02", 57: "iix/05-cymbals-1/CYMBAL04", 51: "iix/05-cymbals-1/RIDE01",
        53: "iix/05-cymbals-1/RIDE03", 55: "iix/05-cymbals-1/PANG01", 52: "iix/05-cymbals-1/GONG01",
        54: "iix/06-percussion-1/TMBOUR02", 69: "iix/06-percussion-1/CABASA01", 75: "iix/06-percussion-1/CLAVES03",
        76: "iix/06-percussion-1/WBLOCK01", 58: "iix/06-percussion-1/VIBSLP01"}),
    "iix-drum-machines": ("IIx drum machines: Emulator and LinnDrum", {
        36: "iix/01-drums-1-kick/EMUBASS1", 35: "iix/01-drums-1-kick/LINNBASS",
        38: "iix/02-drums-2-snare/EMUSNRE1", 40: "iix/02-drums-2-snare/EMUSNRE3", 39: "iix/06-percussion-1/CLAP06",
        42: "iix/05-cymbals-1/HHCLOS09", 44: "iix/05-cymbals-1/HHCLOS10", 46: "iix/05-cymbals-1/HHOPEN03",
        "TOMS": ["iix/03-drums-3-toms/EMUTOMS1", "iix/03-drums-3-toms/EMUTOMS2"],
        49: "iix/05-cymbals-1/CYMBEMU1", 51: "iix/05-cymbals-1/CYMBEMU2", 37: "iix/03-drums-3-toms/RIM02"}),
    "iix-electronic": ("IIx electronic: synth drums and Simmons", {
        36: "iix/01-drums-1-kick/KIKSYN01", 35: "iix/01-drums-1-kick/DIGBDRUM",
        38: "iix/02-drums-2-snare/SNRSYN01", 40: "iix/02-drums-2-snare/SNRSYN02", 39: "iix/06-percussion-1/CLAP07",
        42: "iix/05-cymbals-1/HHCLOS10", 46: "iix/05-cymbals-1/HHOPEN05",
        "TOMS": ["iix/04-drums-4-toms/SIMTOM1", "iix/04-drums-4-toms/SIMTOM2", "iix/04-drums-4-toms/SIMTOM4",
                 "iix/04-drums-4-toms/SIMTOM5", "iix/03-drums-3-toms/TOMSYN04", "iix/03-drums-3-toms/TOMSYN09"],
        49: "iix/05-cymbals-1/CYMBAL05", 51: "iix/05-cymbals-1/RIDE07"}),
    "iix-latin": ("IIx Latin percussion", {
        36: "iix/08-percussion-3/ALBIGDRM", 38: "iix/08-percussion-3/LTIMSLAP",
        60: "iix/06-percussion-1/BONGO01", 62: "iix/08-percussion-3/LCONSLAP", 63: "iix/08-percussion-3/LHCONGA",
        64: "iix/08-percussion-3/LLCONGA", 65: "iix/08-percussion-3/LHTIMB", 66: "iix/08-percussion-3/LLOTIMB",
        56: "iix/08-percussion-3/LCOWBELL", 54: "iix/08-percussion-3/LTAMBRIN", 70: "iix/08-percussion-3/LSHAKER",
        69: "iix/06-percussion-1/CABASA01", 73: "iix/06-percussion-1/GUIRO01", 75: "iix/06-percussion-1/CLAVES04",
        76: "iix/08-percussion-3/LHIBLOCK", 77: "iix/08-percussion-3/LLOBLOCK", 81: "iix/08-percussion-3/ATRIANGL",
        58: "iix/07-percussion-2/VIBSLP", 78: "iix/06-percussion-1/CSTNET01", 67: "iix/08-percussion-3/AHIDRUM",
        68: "iix/08-percussion-3/ALODRUM"}),
    "classic-kit": ("Series II factory drums", {
        36: "classic/drums/BDRUM", 35: "classic/drums/KICK1",
        38: "classic/drums/SNARE", 40: "classic/drums/MEDSNARE", 37: "classic/drums/RRIM", 39: "classic/percusn1/CLAP",
        42: "classic/cymbals/HHCLOSD", 44: "classic/cymbals/HIHAT1", 46: "classic/cymbals/HHOPEN1",
        "TOMS": ["classic/drums/FLOORTOM", "classic/drums/TOMNEW", "classic/drums/TTOM"],
        49: "classic/cymbals/CYMB0", 55: "classic/cymbals/CYMSPLS1", 53: "classic/cymbals/CYMBELL1",
        54: "classic/percusn1/TAMBHIT", 56: "classic/percusn1/COWBELL1", 69: "classic/percusn1/CABASA",
        81: "classic/percusn1/TRIANGLE", 76: "classic/percusn2/WOOD", 58: "classic/percusn2/VIBSLP",
        65: "classic/drums/TIMBALI"}),
}


def drum_kits(root, index):
    """Write KITS as SFZ files in lib:cmi/kits/ and Unfairlight presets in
    cmi-kits/. Returns how many."""
    import shutil
    where = {}
    for v in index["voices"].values():
        for r in v["refs"]:
            where[f"{r['collection']}/{r['disk']}/{r['name']}".upper()] = v
    kdir = os.path.join(root, "kits")
    pdir = os.path.join(PRESETS, "cmi-kits")
    shutil.rmtree(pdir, ignore_errors=True)
    os.makedirs(kdir, exist_ok=True)
    done = 0
    for kit, (title, spec) in KITS.items():
        slots = [(k, n) for k, n in spec.items() if k != "TOMS"]
        toms = [(where[n.upper()]["root"] if where[n.upper()].get("tonal") else 60, n)
                for n in spec.get("TOMS", []) if n.upper() in where]
        slots += [(key, n) for key, (_, n) in zip(TOM_KEYS, sorted(toms))]
        slots = [(k, n, where[n.upper()]) for k, n in sorted(slots) if n.upper() in where]
        if len(slots) < 4:
            continue
        lines = [f"// {title}: CMI voices on General MIDI keys, by tools/library/cmi.py",
                 "<control> default_path=../", "<group> loop_mode=one_shot"]
        for k, n, v in slots:
            hat = " group=1 off_by=1" if k in HAT_KEYS else ""
            lines.append(f"<region> key={k} pitch_keycenter={k} region_label={n.split('/')[-1].lower()}{hat} sample={v['path']}")
        with open(os.path.join(kdir, kit + ".sfz"), "w") as fh:
            fh.write("\n".join(lines) + "\n")
        os.makedirs(pdir, exist_ok=True)
        params = {"cmi-rate": RATE, "cmi-root": CMI_ROOT, "cmi-tune": 0, "cmi-loop": 0, "cmi-loop-start": 0,
                  "cmi-loop-end": 127, "cmi-start": 0, "cmi-filter": 255, "cmi-atk": 0, "cmi-damp": 0.05,
                  "cmi-vib-depth": 0, "cmi-vib-rate": 5.5, "cmi-vel": 1, "cmi-vol": 0.6}
        with open(os.path.join(pdir, kit + ".preset"), "w") as fh:
            fh.write(json.dumps({"schema": 1, "machine": "unfairlight", "note": f"CMI kit: {title}",
                                 "params": params, "assets": {"voice": f"lib:cmi/kits/{kit}.sfz"}}) + "\n")
        done += 1
    return done


def safe(name):
    return re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("_") or "voice"


def disk_slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "disk"


def filter_latch(f):
    """Page 7 FILTER (0 dark .. ~25 open; 8 the usual) → the card's latch.
    The mapping is ours: the IIx software's scaling isn't documented, so
    FILTER 8 lands on the latch the hand-made presets use."""
    return max(0, min(255, 96 + 8 * f))


def page7(vc, co):
    """The Unfairlight params a voice's Page 7 sets: its .CO's when there is
    one, else the IIx defaults (ATTACK 10, DAMPING 50, FILTER 8) and the
    voice's own loop."""
    v = vc_params(vc)
    loop, ls, le = v["loop_on"] and v["loop_end"] >= v["loop_start"], v["loop_start"], v["loop_end"]
    co = co or {}
    num = lambda k, d: co[k] if isinstance(co.get(k), int) and not isinstance(co.get(k), bool) else d
    if "loop" in co:
        loop = bool(co["loop"])
        # points patched to a real-time controller were being played live:
        # the voice's saved loop is the better guess
        if not {"loop_start", "loop_len"} & set(co.get("patched", ())):
            ls = max(0, min(127, num("loop_start", 1) - 1))
            le = max(ls, min(127, ls + max(1, num("loop_len", 128)) - 1))
    level = co.get("level", 255)
    return {"cmi-loop": 1 if loop else 0,
            "cmi-loop-start": ls if loop else 0,
            "cmi-loop-end": le if loop else 127,
            "cmi-start": max(0, min(127, num("start_seg", 1) - 1)),
            "cmi-filter": filter_latch(num("filter", 8)),
            "cmi-atk": min(16.0, num("attack", 10) / 1000),
            "cmi-damp": max(0.005, min(60.0, num("damping", 50) / 1000)),
            "cmi-vib-depth": round(num("vib_depth", 0) / 64, 4),
            "cmi-vib-rate": round(num("vib_speed", 88) / 16, 3),
            "cmi-vel": 1 if level == "keyvel" else 0,
            "cmi-vol": round(0.6 * (level / 255 if isinstance(level, int) else 1.0), 4)}


def preset(vc, lib_path, note, root, co=None):
    params = {"cmi-rate": RATE, "cmi-root": round(root, 3), "cmi-tune": 0}
    params.update(page7(vc, co))
    return {"schema": 1, "machine": "unfairlight", "note": note,
            "params": params, "assets": {"voice": lib_path}}


class Disk:
    """One disk image or folder: its voices [(name, .VC bytes)], control
    files {NAME: .CO bytes} and instruments [(name, .IN bytes)]."""

    def __init__(self, name):
        self.name, self.voices, self.controls, self.instruments = name, [], {}, []

    def add(self, name, kind, data):
        if kind == "VC":
            self.voices.append((name, data))
        elif kind == "CO":
            self.controls[name.upper()] = data
        elif kind == "IN":
            self.instruments.append((name, data))

    def control(self, voice):
        co = self.controls.get(voice.upper())
        return co_params(co) if co else None


def sources(paths, deleted=False):
    """A Disk per disk image, and per folder of loose .VC / .CO / .IN files
    or 8-bit WAV voice dumps."""
    for path in paths:
        if not os.path.exists(path):
            print(f"  {path}: no such file or folder", file=sys.stderr)
            continue
        if os.path.isdir(path):
            for dirpath, dirs, files in os.walk(path):
                dirs.sort()
                disk = Disk(disk_slug(os.path.basename(dirpath)))
                for f in sorted(files):
                    full = os.path.join(dirpath, f)
                    low = f.lower()
                    if low.startswith("deleted") and not deleted:
                        continue
                    stem, ext = os.path.splitext(f)
                    if low.endswith((".imd", ".img")):
                        yield from sources([full])
                    elif ext.lower() in (".vc", ".co", ".in"):
                        with open(full, "rb") as fh:
                            disk.add(stem, ext[1:].upper(), fh.read())
                    elif low.endswith(".wav") and not low.endswith(".vc.wav"):
                        ram = wav_ram(full)
                        if ram is not None:
                            disk.add(stem, "VC", vc_from_ram(ram))
                if disk.voices:
                    yield disk
        elif path.lower().endswith(".vc"):
            disk = Disk("loose")
            with open(path, "rb") as fh:
                disk.add(os.path.splitext(os.path.basename(path))[0], "VC", fh.read())
            yield disk
        else:
            try:
                img = read_image(path)
            except (ValueError, OSError) as e:
                print(f"  skipping {path}: {e}", file=sys.stderr)
                continue
            disk = Disk(disk_slug(os.path.splitext(os.path.basename(path))[0]))
            for name, kind, data in files_on(img):
                disk.add(name, kind, data)
            yield disk


# ── instruments ──────────────────────────────────────────────────────

IN_SIZE = 2944
CARD_BASE = 253.451904296875  # the voice card's undivided clock per pitch step, Hz


def key_rate(word):
    """A key table entry's word (octave << 10 | 10-bit pitch) → the card's
    sample clock, Hz."""
    return (2048 + 2 * (word & 0x3FF)) * CARD_BASE * 2 ** ((word >> 10) - 8)


def default_rate(key):
    """The CMI's own table: a 128-sample cycle at A440 on key 52."""
    return 440 * 128 * 2 ** ((key - 52) / 12)


def in_params(data):
    """An instrument's registers as [(register 0-7, first key, last key,
    [voice names layered], polyphony, tuning in semitones)], one per run of
    keys on the keyboard's table; None if it isn't an instrument."""
    import math
    if len(data) < IN_SIZE:
        return None
    names = [data[0x200 + 26 * i + 1:0x200 + 26 * i + 9].decode("latin-1").strip(" \0") for i in range(8)]
    table = data[0x300:0x300 + 240]
    runs = []
    for key in range(73):
        tag, word = table[3 * key], (table[3 * key + 1] << 8) | table[3 * key + 2]
        if not 0x41 <= tag <= 0x48 or word == 0:
            return None
        off = 12 * math.log2(key_rate(word) / default_rate(key))
        if runs and runs[-1][0] == tag - 0x41:
            runs[-1][2] = key
            runs[-1][3].append(off)
        else:
            runs.append([tag - 0x41, key, key, [off]])
    out = []
    for reg, a, z, offs in runs:
        mask = data[0xB0 + 2 * reg]
        layers = [names[i] for i in range(8) if mask >> i & 1 and names[i] and "\xe5" not in names[i]]
        offs.sort()
        out.append((reg, a, z, layers, data[0xC0 + 2 * reg] or 1, offs[len(offs) // 2]))
    return out


def rack_preset(disk, collection, inst, regs, voice_preset):
    """A Rack preset for instrument `inst`: `voice_preset(name)` gives a
    layered voice's Unfairlight preset (or None if the disk lacks it)."""
    parts = []
    for i, (reg, a, z, layers, poly, tune) in enumerate(regs):
        lo = 0 if i == 0 else a + 17  # the ends reach past the CMI's 73 keys
        hi = 127 if i == len(regs) - 1 else z + 17
        semis = round(tune)
        for name in layers:
            vp = voice_preset(name)
            if vp is None:
                continue
            params = dict(vp["params"])
            params["cmi-tune"] = round(params.get("cmi-tune", 0) + tune - semis, 3)
            parts.append({"machine": "unfairlight", "name": name, "lo": lo, "hi": hi, "vlo": 1, "vhi": 127,
                          "transpose": semis, "level": 0, "pan": 0, "poly": poly, "mute": False,
                          "params": params, "assets": vp["assets"]})
    if not parts:
        return None
    return {"schema": 1, "machine": "rack", "note": f"CMI {collection} / {disk} / {inst}", "parts": parts}


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
            lines += [f"### {disk}", "", "| voice | segs | loop | page 7 | root | also on |", "|---|---|---|---|---|---|"]
            for name, h, v in sorted(vs):
                others = [f"{r['collection']}/{r['disk']}/{r['name']}" for r in v["refs"]
                          if (r["collection"], r["disk"], r["name"]) != (c, disk, name)]
                loop = f"{v['loop'][0]}-{v['loop'][1]}" if v["loop"] else "-"
                root_s = f"{v['root']:.1f}" if v.get("tonal") else "-"
                ref = next(r for r in v["refs"] if (r["collection"], r["disk"], r["name"]) == (c, disk, name))
                co = ref.get("co")
                p7 = (f"atk {co.get('attack')} dmp {co.get('damping')} flt {co.get('filter')}"
                      + (f" vib {co['vib_depth']}/{co.get('vib_speed')}" if co.get("vib_depth") else "")) if co else "-"
                lines.append(f"| {name} | {v['segments']} | {loop} | {p7} | {root_s} | {', '.join(others[:3])} |")
            lines.append("")
    with open(os.path.join(root, "CATALOG.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def import_collection(root, index, collection, paths, title, note, deleted, presets):
    import hashlib
    old = index["collections"].get(collection, {})
    index["collections"][collection] = {"title": title or old.get("title") or collection,
                                        "note": note or old.get("note", "")}
    count = new = instruments = 0
    for d in sources(paths, deleted):
        disk = d.name
        for name, vc in d.voices:
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
                    "path": rel, "segments": used_segments(vc),
                    "loop": [p["loop_start"], p["loop_end"]] if p["loop_on"] else None,
                    "root": pr[0] if pr else 57.0, "tonal": pr is not None, "refs": []}
                new += 1
            co = d.control(name)
            ref = {"collection": collection, "disk": disk, "name": name}
            v["refs"] = [r for r in v["refs"] if (r["collection"], r["disk"], r["name"]) != (collection, disk, name)]
            if co:
                ref["co"] = co
            v["refs"].append(ref)
            if presets:
                with open(os.path.join(root, v["path"]), "rb") as fh:
                    stored = fh.read()
                root_note = cmi_root(v)
                pdir = os.path.join(PRESETS, f"cmi-{collection}", disk)
                os.makedirs(pdir, exist_ok=True)
                with open(os.path.join(pdir, safe(name).lower() + ".preset"), "w") as fh:
                    fh.write(json.dumps(preset(stored, f"lib:cmi/{v['path']}",
                                               f"CMI {collection} / {disk} / {name}", root_note, co)) + "\n")
            count += 1
        if presets:
            by_name = {n.upper(): vc for n, vc in d.voices}

            def voice_preset(name, d=d, by_name=by_name):
                vc = by_name.get(name.upper())
                if vc is None:
                    return None
                v = index["voices"].get(hashlib.sha1(ram_of(vc)).hexdigest()[:16])
                if v is None:
                    return None
                with open(os.path.join(root, v["path"]), "rb") as fh:
                    stored = fh.read()
                return preset(stored, f"lib:cmi/{v['path']}", name, cmi_root(v), d.control(name))

            for inst, data in d.instruments:
                regs = in_params(data)
                rp = rack_preset(disk, collection, inst, regs, voice_preset) if regs else None
                if rp is None:
                    continue
                pdir = os.path.join(RACK_PRESETS, f"cmi-{collection}", disk)
                os.makedirs(pdir, exist_ok=True)
                with open(os.path.join(pdir, safe(inst).lower() + ".preset"), "w") as fh:
                    fh.write(json.dumps(rp) + "\n")
                instruments += 1
    return count, new, instruments


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
    ap.add_argument("--multisample", action="store_true", help="rewrite the multi-* racks from the index only")
    ap.add_argument("--kits", action="store_true", help="rewrite the drum kits from the index only")
    args = ap.parse_args()

    root = os.path.join(library_root(), "cmi")
    if args.list:
        for d in sources(args.paths, args.deleted):
            print(f"{d.name}: {len(d.voices)} voices, {len(d.controls)} control files, {len(d.instruments)} instruments")
            for name, vc in d.voices:
                p = vc_params(vc)
                pr = pitch(vc)
                co = d.control(name)
                print(f"  {name:8s}  {used_segments(vc):3d} segments  loop {'on ' if p['loop_on'] else 'off'} "
                      f"{p['loop_start']:3d}-{p['loop_end']:3d}"
                      + (f"  root {pr[0]:5.1f}" if pr else "")
                      + (f"  page 7 {co}" if co else ""))
            for inst, data in d.instruments:
                regs = in_params(data)
                if regs:
                    print(f"  {inst}.IN  " + "  ".join(
                        f"{chr(65 + r)} keys {a + 17}-{z + 17} {'+'.join(l) or '-'} x{p} {t:+.2f}"
                        for r, a, z, l, p, t in regs))
        return
    os.makedirs(root, exist_ok=True)
    index = load_index(root)
    if args.multisample or args.kits:
        if args.multisample:
            print(f"{multisample_racks(root, index)} multisample racks")
        if args.kits:
            print(f"{drum_kits(root, index)} drum kits")
        return
    if not args.catalog:
        if not args.paths:
            ap.error("nothing to import")
        count, new, insts = import_collection(root, index, disk_slug(args.collection), args.paths, args.title,
                                              args.note, args.deleted, not args.no_presets)
        print(f"{args.collection}: {count} voices, {new} new to the library, {insts} instruments")
        if not args.no_presets:
            print(f"{multisample_racks(root, index, [disk_slug(args.collection)])} multisample racks")
            print(f"{drum_kits(root, index)} drum kits")
        save_index(root, index)
    write_catalog(root, index)
    print(f"{len(index['voices'])} voices in {root} (CATALOG.md)")


if __name__ == "__main__":
    main()
