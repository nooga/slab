#!/usr/bin/env python3
"""vcsl.py - fetch the Versilian Community Sample Library and make it playable.

VCSL (https://github.com/sgossner/VCSL) is a CC0 / public-domain library of
some 190 instruments: pianos, harpsichords, organs, winds, mallets, kalimbas
and a lot of percussion.  This script

  1. downloads it (pinned to one commit) into the Slab sample library,
     $SLAB_LIBRARY or ~/Music/Slab/Library, under vcsl/samples/;
  2. writes an SFZ per instrument under vcsl/<bank>/, mapping keys,
     velocity layers and round robins from the file names, tuning each
     sample to its measured pitch and levelling each instrument;
  3. composes GM drum kits from the percussion;
  4. writes a sampler preset per SFZ into the pack, vcsl/presets/sampler/vcsl-*/,
     pointing at "lib:vcsl/...", so the presets work on any machine that
     ran this script.

Usage:
  tools/library/vcsl.py                  everything: ~6 GB download
  tools/library/vcsl.py --list           instruments and sizes; nothing fetched
  tools/library/vcsl.py --only marimba --only hi-hat
                                         instruments whose path contains any
                                         of these (case-insensitive)
  tools/library/vcsl.py --no-fetch       regenerate from what's on disk

Release samples (Releases/, Rel/) become trigger=release regions of the
instrument they belong to: the sampler plays them at note-off.  Pitch and level measurement needs numpy; without it the
names are trusted and nothing is levelled.  Measurements are cached in
vcsl/analysis.json, so a rerun is quick.
"""

import argparse
import concurrent.futures as cf
import json
import math
import os
import re
import struct
import sys
import time
import urllib.error
import urllib.request

REPO = "sgossner/VCSL"
COMMIT = "c1ea7bcc3c7309650ab0da9d15c9cd1fbc4a4c7e"  # master, 2026-01-14
RAW = f"https://raw.githubusercontent.com/{REPO}/{COMMIT}/"
TREE = f"https://api.github.com/repos/{REPO}/git/trees/{COMMIT}?recursive=1"

SLAB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

MAX_ZONES = 256  # src/keymap.zig MAX_ZONES
TARGET_PEAK_DB = -6.0

try:
    import numpy as np
except ImportError:  # measuring is optional
    np = None


# ── paths ────────────────────────────────────────────────────────────────


def library_root():
    """Sample packs: $SLAB_LIBRARY, else <home>/Library (src/storage.zig)."""
    root = os.environ.get("SLAB_LIBRARY")
    if root:
        return root.rstrip("/")
    home = os.environ.get("SLAB_HOME") or os.path.join(os.path.expanduser("~"), "Music", "Slab")
    return os.path.join(home.rstrip("/"), "Library")


def pack_presets(pack, machine):
    """A pack's presets for a machine: lib:<pack>/presets/<machine>/ (docs/25 §Pack presets)."""
    return os.path.join(library_root(), pack, "presets", machine)


def release_of(folder):
    """The sustain folder a release folder belongs to, or None.
    VCSL keeps them side by side: .../Releases/x beside .../Sustains/x, and
    the Steinway's Rel beside NoSus (the pedal-down Sus needs none)."""
    parts = folder.split("/")
    for i, p in enumerate(parts):
        if p.lower() == "releases":
            return "/".join(parts[:i] + ["Sustains"] + parts[i + 1:])
        if p.lower() == "rel":
            return "/".join(parts[:i] + ["NoSus"] + parts[i + 1:])
    return None


# ── the tree ─────────────────────────────────────────────────────────────


def fetch_tree(cache):
    if os.path.exists(cache):
        with open(cache) as f:
            return json.load(f)
    print("listing VCSL ...", flush=True)
    req = urllib.request.Request(TREE, headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        tree = json.load(r)
    if tree.get("truncated"):
        sys.exit("the GitHub tree listing came back truncated")
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    with open(cache, "w") as f:
        json.dump(tree, f)
    return tree


def instruments(tree):
    """(instruments, releases, files): every folder holding WAVs is an
    instrument, {folder: [(file name, size)]}, except release folders,
    which play at note-off on the instrument they belong to: releases maps
    an instrument to its release folder, files holds both kinds."""
    out, rel = {}, {}
    for b in tree["tree"]:
        if b["type"] != "blob" or not b["path"].lower().endswith(".wav"):
            continue
        folder, name = b["path"].rsplit("/", 1)
        out.setdefault(folder, []).append((name, b["size"]))
    for v in out.values():
        v.sort()
    for f in list(out):
        sus = release_of(f)
        if sus is not None:
            if sus in out:
                rel[sus] = f
            else:
                del out[f]
    return {f: v for f, v in out.items() if release_of(f) is None}, rel, out


# ── download ─────────────────────────────────────────────────────────────


def download(jobs, workers=8):
    todo = [(url, dest, size) for url, dest, size in jobs
            if not (os.path.exists(dest) and os.path.getsize(dest) == size)]
    total = sum(s for _, _, s in todo)
    if not todo:
        return
    print(f"fetching {len(todo)} files, {total / 1e6:.0f} MB", flush=True)
    done = [0, 0]
    t0 = time.time()
    shown = [0.0]

    def one(job):
        url, dest, size = job
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        part = dest + ".part"
        for attempt in range(4):
            try:
                with urllib.request.urlopen(url, timeout=120) as r, open(part, "wb") as f:
                    while True:
                        chunk = r.read(1 << 16)
                        if not chunk:
                            break
                        f.write(chunk)
                if os.path.getsize(part) != size:
                    raise IOError(f"short read ({os.path.getsize(part)} of {size})")
                os.replace(part, dest)
                return size
            except (urllib.error.URLError, IOError, TimeoutError) as e:
                if attempt == 3:
                    print(f"\n  failed: {url}: {e}", file=sys.stderr)
                    return 0
                time.sleep(2 * (attempt + 1))

    with cf.ThreadPoolExecutor(workers) as ex:
        for got in ex.map(one, todo):
            done[0] += 1
            done[1] += got
            now = time.time()
            if now - shown[0] > 1 or done[0] == len(todo):
                shown[0] = now
                rate = done[1] / max(now - t0, 1e-3) / 1e6
                print(f"\r  {done[0]}/{len(todo)}  {done[1] / 1e6:.0f}/{total / 1e6:.0f} MB  {rate:.1f} MB/s   ",
                      end="" if sys.stdout.isatty() else "\n", flush=True)
    print()


# ── wav reading and measurement ─────────────────────────────────────────


def read_wav(path):
    """(mono float samples, rate) for PCM 8/16/24/32 and float WAVs."""
    with open(path, "rb") as f:
        b = f.read()
    i, fmt, data = 12, None, None
    while i + 8 <= len(b):
        cid, sz = b[i:i + 4], struct.unpack("<I", b[i + 4:i + 8])[0]
        if cid == b"fmt ":
            fmt = b[i + 8:i + 8 + sz]
        elif cid == b"data":
            data = b[i + 8:i + 8 + sz]
        i += 8 + sz + (sz & 1)
    if fmt is None or data is None:
        raise ValueError("not a WAV")
    tag, ch, sr, _, _, bits = struct.unpack("<HHIIHH", fmt[:16])
    if tag == 0xFFFE and len(fmt) >= 26:  # extensible: the subformat's tag
        tag = struct.unpack("<H", fmt[24:26])[0]
    bw = bits // 8
    n = len(data) // (bw * ch)
    raw = np.frombuffer(data[:n * bw * ch], dtype=np.uint8).reshape(n, ch, bw)
    if tag == 3:
        x = raw.reshape(n, ch * bw).view("<f4" if bw == 4 else "<f8").astype(np.float64)
    elif bw == 1:
        x = (raw[:, :, 0].astype(np.float64) - 128) / 128
    else:
        v = np.zeros((n, ch), dtype=np.int64)
        for k in range(bw):
            v |= raw[:, :, k].astype(np.int64) << (8 * k)
        v = np.where(v >= 1 << (bits - 1), v - (1 << bits), v)
        x = v / float(1 << (bits - 1))
    return x.mean(axis=1), sr


def measure(path, guess_midi):
    """{"peak": linear, "oct": -1/0/+1 vote, "cents": fine offset or None}."""
    x, sr = read_wav(path)
    out = {"peak": float(np.abs(x).max()) if len(x) else 0.0, "oct": 0, "cents": None}
    if guess_midi is None or len(x) < sr // 20:
        return out
    on = int(np.argmax(np.abs(x) > 0.3 * max(out["peak"], 1e-9)))
    seg = x[on + int(0.02 * sr): on + int(0.02 * sr) + sr // 2]
    if len(seg) < 2048:
        return out
    n = 1 << 18
    mag = np.abs(np.fft.rfft(seg * np.hanning(len(seg)), n))
    freqs = np.fft.rfftfreq(n, 1 / sr)
    f0 = 440 * 2 ** ((guess_midi - 69) / 12)

    def peak_near(f):
        m = (freqs > f * 2 ** (-1 / 12)) & (freqs < f * 2 ** (1 / 12))
        if not m.any():
            return 0.0, f
        k = int(np.argmax(np.where(m, mag, 0)))
        # parabolic interpolation around the bin
        if 0 < k < len(mag) - 1:
            a, b_, c = np.log(mag[k - 1] + 1e-12), np.log(mag[k] + 1e-12), np.log(mag[k + 1] + 1e-12)
            d = 0.5 * (a - c) / (a - 2 * b_ + c) if (a - 2 * b_ + c) != 0 else 0
            return float(mag[k]), float((k + d) * sr / n)
        return float(mag[k]), float(freqs[k])

    m1, fa = peak_near(f0)
    mu, fu = peak_near(2 * f0)
    md, fd = peak_near(f0 / 2)
    # a whole octave off only when the named fundamental is nearly absent
    if mu > 4 * m1 and mu > 2 * md:
        out["oct"], fa = 1, fu
    elif md > 4 * m1 and md > 2 * mu and f0 / 2 > 25:
        out["oct"], fa = -1, fd
    ref = f0 * 2 ** out["oct"]
    if fa > 0:
        c = 1200 * math.log2(fa / ref)
        if abs(c) < 60:
            out["cents"] = round(c, 1)
    return out


# ── file names ───────────────────────────────────────────────────────────

NOTE_RE = re.compile(r"(?:^|(?<=[_\s-]))([A-Ga-g])(#?)(-?\d)(?=$|[_\s-])")
PC = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}
DYN = {"ppp": 1, "pp": 2, "p": 3, "mp": 4, "mf": 5, "f": 6, "ff": 7, "fff": 8,
       "quiet": 2, "soft": 3, "med": 5, "medium": 5, "loud": 7}
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def note_name(m):
    return f"{NAMES[m % 12]}{m // 12 - 1}"


def parse(name):
    """File name → (midi or None, velocity rank or None, rr tokens, art tokens)."""
    stem = name[:-4]
    midi = None
    m = NOTE_RE.search(stem)
    if m:
        midi = (int(m.group(3)) + 1) * 12 + PC[m.group(1).lower()] + (1 if m.group(2) else 0)
        stem = stem[:m.start()] + "_" + stem[m.end():]
    vel, rr, art = None, [], []
    for t in re.split(r"[_\s-]+", stem):
        if not t:
            continue
        lt = t.lower()
        if (mm := re.fullmatch(r"vl?(\d+)", lt)):
            vel = int(mm.group(1))
        elif (mm := re.fullmatch(r"(ppp|pp|p|mp|mf|f|ff|fff|quiet|soft|med|medium|loud)(\d*)", lt)):
            vel = DYN[mm.group(1)]
            if mm.group(2):
                rr.append(mm.group(2))
        elif (mm := re.fullmatch(r"(?:rr|r|var)(\d+)", lt)) or re.fullmatch(r"\d+", lt):
            rr.append(lt)
        else:
            art.append(t)
    return midi, vel, tuple(rr), tuple(art)


# ── mapping ──────────────────────────────────────────────────────────────

SUSTAINED = re.compile(r"sus|organ|recorder|harmonica|ocarina|longbow|bowed|glass|saxophone|saxello|vib\b|nv\b",
                       re.I)
STACCATO = re.compile(r"stac|stcts|spic|short", re.I)
INHARMONIC = re.compile(r"bell|chime|timpani|gong|flexatone|cymbal", re.I)
HAT_KEYS = {"HitC": (42, "closed hat"), "Close": (44, "pedal hat"), "HitO": (46, "open hat")}


def slug(folder):
    parts = [p for p in folder.split("/")[2:] if p.lower() != "sustains"]
    s = re.sub(r"[^a-z0-9]+", "-", " ".join(parts).lower()).strip("-")
    return s or re.sub(r"[^a-z0-9]+", "-", folder.split("/")[-1].lower()).strip("-")


def bank(folder, melodic):
    top = folder.split("/")[0]
    if top == "Aerophones":
        return "vcsl-winds"
    if top == "Electrophones" or re.search(r"piano|harpsichord", folder, re.I):
        return "vcsl-keys"
    if top == "Chordophones":
        return "vcsl-strings"
    if top == "Idiophones" and melodic:
        return "vcsl-mallets"
    return "vcsl-perc"


class Sample:
    def __init__(self, folder, name):
        self.folder, self.name = folder, name
        self.rel = f"{folder}/{name}"
        self.midi, self.vel, self.rr, self.art = parse(name)


def layers_by_vel(samples):
    """[[rr variants] per velocity layer, soft to loud], splitting 0..127."""
    ranks = sorted({s.vel if s.vel is not None else 0 for s in samples})
    groups = [[s for s in samples if (s.vel if s.vel is not None else 0) == r] for r in ranks]
    for g in groups:
        g.sort(key=lambda s: s.name)
    return groups


def cap(groups_per_key):
    """Thin round robins, then velocity layers, until the zones fit."""
    def count():
        return sum(len(rr) for layers in groups_per_key for rr in layers)
    keep_rr = max((len(rr) for layers in groups_per_key for rr in layers), default=1)
    while count() > MAX_ZONES and keep_rr > 1:
        keep_rr -= 1
        for layers in groups_per_key:
            for i, rr in enumerate(layers):
                layers[i] = rr[:keep_rr]
    while count() > MAX_ZONES:
        for i, layers in enumerate(groups_per_key):
            if len(layers) > 1:
                groups_per_key[i] = layers[1::2] if len(layers) > 2 else layers[1:]
        if all(len(layers) <= 1 for layers in groups_per_key):
            break
    return groups_per_key


def regions_for(layers, lokey, hikey, root, label, oneshot, group=0, analysis=None, tune_of=None, gain_db=0.0,
                release=None):
    out = []
    n = len(layers)
    for li, rr in enumerate(layers):
        lovel, hivel = (128 * li) // n, (128 * (li + 1)) // n - 1
        for pi, s in enumerate(rr):
            op = [f"lokey={lokey}", f"hikey={hikey}", f"pitch_keycenter={root}",
                  f"lovel={lovel}", f"hivel={hivel}"]
            if len(rr) > 1:
                op += [f"seq_length={len(rr)}", f"seq_position={pi + 1}"]
            if tune_of:
                t = tune_of(s)
                if t:
                    op.append(f"tune={t:g}")
            if gain_db:
                op.append(f"volume={gain_db:g}")
            if oneshot:
                op.append("loop_mode=one_shot")
            if group:
                op += [f"group={group}", f"off_by={group}"]
            if release is not None:
                op += ["trigger=release"] + ([f"rt_decay={release:g}"] if release else [])
            op.append(f"region_label={label}")
            out.append((op, s))
    return out


def write_sfz(path, title, regions, root):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = [f"// {title}", "// VCSL (CC0), https://github.com/sgossner/VCSL - generated by tools/library/vcsl.py", ""]
    for op, s in regions:
        rel = os.path.relpath(os.path.join(root, "samples", s.rel), os.path.dirname(path))
        # sample= last: its value may hold spaces and runs to the line end
        lines.append("<region> " + " ".join(op) + f" sample={rel}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def peak_db(samples, analysis):
    pk = max((analysis.get(s.rel, {}).get("peak", 0.0) for s in samples), default=0.0)
    return 20 * math.log10(pk) if pk > 0 else None


def level_for(samples, analysis):
    db = peak_db(samples, analysis)
    return round(TARGET_PEAK_DB - db, 1) if db is not None else 0.0


def map_melodic(folder, samples, analysis, releases=()):
    # octave: an instrument-wide vote, so a weak piano fundamental can't move one note
    votes = [analysis.get(s.rel, {}).get("oct", 0) for s in samples]
    shift = 0
    for o in (1, -1):
        if votes and votes.count(o) >= 0.6 * len(votes):
            shift = 12 * o
    fine = not INHARMONIC.search(folder)

    def tune_of(s):
        c = analysis.get(s.rel, {}).get("cents")
        return -c if (fine and c is not None and abs(c) > 2) else 0

    roots = sorted({s.midi + shift for s in samples})
    per_key = [layers_by_vel([s for s in samples if s.midi + shift == r]) for r in roots]
    per_key = cap(per_key)
    gain = level_for(samples, analysis)
    regions = []
    for i, r in enumerate(roots):
        lo = 0 if i == 0 else (roots[i - 1] + r) // 2 + 1
        hi = 127 if i == len(roots) - 1 else (r + roots[i + 1]) // 2
        regions += regions_for(per_key[i], max(lo, 0), min(hi, 127), r, note_name(r), False,
                               tune_of=tune_of, gain_db=gain)
    rel = [s for s in releases if s.midi is not None]
    if rel:
        regions += map_releases(folder, rel, shift, roots, gain, MAX_ZONES - len(regions))
    return regions


def map_releases(folder, rel, shift, roots, gain, budget):
    """Release samples on their own key split, velocity layers and round
    robins, labelled like the sustain root that owns their key so the
    zone list edits them with it. The instrument's level and octave; no
    fine tuning (a damper thump has no pitch to speak of). A piano's
    release gets quieter the longer the key was held, 3 dB a second."""
    rroots = sorted({s.midi + shift for s in rel})
    per_key = [layers_by_vel([s for s in rel if s.midi + shift == r]) for r in rroots]
    while sum(len(rr) for layers in per_key for rr in layers) > budget:
        before = sum(len(rr) for layers in per_key for rr in layers)
        per_key = [[rr[:max(1, len(rr) - 1)] for rr in layers] for layers in per_key]
        per_key = [layers[1::2] if len(layers) > 1 and sum(len(rr) for rr in layers) == len(layers) else layers
                   for layers in per_key]
        if sum(len(rr) for layers in per_key for rr in layers) == before:
            return []
    rt = 3 if re.search(r"piano", folder, re.I) else 0

    def owner(k):
        return min(roots, key=lambda r: (abs(r - k), r))

    out = []
    for i, r in enumerate(rroots):
        lo = 0 if i == 0 else (rroots[i - 1] + r) // 2 + 1
        hi = 127 if i == len(rroots) - 1 else (r + rroots[i + 1]) // 2
        out += regions_for(per_key[i], max(lo, 0), min(hi, 127), r, note_name(owner(r)), False,
                           gain_db=gain, release=rt)
    return out


def art_label(art):
    s = " ".join(art).strip()
    s = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", s)
    return s.lower() or "hit"


def map_percussion(folder, samples, analysis):
    common = set(samples[0].art)
    for s in samples[1:]:
        common &= set(s.art)
    arts = {}
    for s in samples:
        key = tuple(t for t in s.art if t not in common)
        if s.midi is not None:
            key += (note_name(s.midi),)
        arts.setdefault(key, []).append(s)
    names = sorted(arts)
    hat = "Hi-Hat" in folder
    regions = []
    if len(names) == 1:
        # one sound: across the keyboard, played at pitch on C4
        ss = arts[names[0]]
        layers = cap([layers_by_vel(ss)])[0]
        return regions_for(layers, 0, 127, 60, folder.split("/")[-1].lower(), True,
                           gain_db=level_for(ss, analysis))
    key = 36
    budget = max(1, MAX_ZONES // len(names))
    for a in names[:127 - 36]:
        ss = arts[a]
        layers = cap([layers_by_vel(ss)])[0]
        while sum(len(rr) for rr in layers) > budget and max(len(rr) for rr in layers) > 1:
            m = max(len(rr) for rr in layers) - 1
            layers = [rr[:m] for rr in layers]
        while sum(len(rr) for rr in layers) > budget and len(layers) > 1:
            layers = layers[1::2]
        label, group, k = art_label(a), 0, key
        if hat and len(a) == 1 and a[0] in HAT_KEYS:
            k, label = HAT_KEYS[a[0]]
            group = 1
        else:
            key += 1
            while hat and key in (42, 44, 46):
                key += 1
        regions += regions_for(layers, k, k, k, label, True, group=group, gain_db=level_for(ss, analysis))
    return regions


# ── composed kits ────────────────────────────────────────────────────────
# (key, label, folder, art pattern): the first sound in the folder whose
# articulation matches.  Every piece is levelled on its own.

KITS = {
    "acoustic-kit": ("VCSL acoustic kit on GM keys", [
        (36, "kick", "Membranophones/Struck Membranophones/Bass Drum 1", r""),
        (37, "side stick", "Membranophones/Struck Membranophones/Snare Drum, Modern 1", r"^stick"),
        (38, "snare", "Membranophones/Struck Membranophones/Snare Drum, Modern 1", r"^hitsn$"),
        (39, "clap", "Idiophones/Struck Idiophones/Claps", r"^clap$"),
        (40, "snare off", "Membranophones/Struck Membranophones/Snare Drum, Modern 1", r"^hitns$"),
        (41, "low tom", "Membranophones/Struck Membranophones/Tom 2/Stick", r"hits"),
        (42, "closed hat", "Idiophones/Struck Idiophones/Hi-Hat Cymbal", r"^hitc$"),
        (44, "pedal hat", "Idiophones/Struck Idiophones/Hi-Hat Cymbal", r"^close$"),
        (45, "mid tom", "Membranophones/Struck Membranophones/Tom 2/Mallet", r"hitm"),
        (46, "open hat", "Idiophones/Struck Idiophones/Hi-Hat Cymbal", r"^hito$"),
        (48, "high tom", "Membranophones/Struck Membranophones/Tom 1/Stick", r"hits"),
        (49, "crash", "Idiophones/Struck Idiophones/Clash Cymbals 2", r""),
        (54, "tambourine", "Idiophones/Struck Idiophones/Tambourine 1", r"hit"),
        (56, "cowbell", "Idiophones/Struck Idiophones/Cowbells", r"hit"),
        (69, "cabasa", "Idiophones/Struck Idiophones/Cabasa", r"hit"),
        (70, "shaker", "Idiophones/Struck Idiophones/Shaker, Large", r"hit"),
        (75, "claves", "Idiophones/Struck Idiophones/Claves", r""),
        (76, "woodblock", "Idiophones/Struck Idiophones/Woodblock", r""),
    ]),
    "latin-kit": ("VCSL hand percussion on GM keys", [
        (60, "hi bongo", "Membranophones/Struck Membranophones/Bongos", r"bongoh.*hit"),
        (61, "low bongo", "Membranophones/Struck Membranophones/Bongos", r"bongol.*hit"),
        (62, "conga mute", "Membranophones/Struck Membranophones/Conga", r"conga.*hitfm"),
        (63, "conga open", "Membranophones/Struck Membranophones/Conga", r"conga.*hitn"),
        (64, "tumba", "Membranophones/Struck Membranophones/Conga", r"tumba.*hitn"),
        (65, "cajon", "Idiophones/Struck Idiophones/Cajon", r""),
        (66, "darbuka", "Membranophones/Struck Membranophones/Darbuka", r""),
        (67, "agogo hi", "Idiophones/Struck Idiophones/Agogo Bells", r"high"),
        (68, "agogo lo", "Idiophones/Struck Idiophones/Agogo Bells", r"low"),
        (69, "cabasa", "Idiophones/Struck Idiophones/Cabasa", r"hit"),
        (70, "shaker", "Idiophones/Struck Idiophones/Shaker, Small", r""),
        (73, "guiro short", "Idiophones/Struck Idiophones/Guiro", r"hit"),
        (74, "guiro long", "Idiophones/Struck Idiophones/Guiro", r"slow"),
        (75, "claves", "Idiophones/Struck Idiophones/Claves", r""),
        (76, "slit drum hi", "Idiophones/Struck Idiophones/Slit Drum", r"drumhi"),
        (77, "slit drum lo", "Idiophones/Struck Idiophones/Slit Drum", r"drumlo"),
        (80, "triangle mute", "Idiophones/Struck Idiophones/Triangles", r"hitm"),
        (81, "triangle", "Idiophones/Struck Idiophones/Triangles", r"hit"),
    ]),
}


def kit_folders():
    return {f for _, entries in KITS.values() for _, _, f, _ in entries}


def map_kit(entries, insts, analysis):
    regions, missing = [], []
    budget = max(1, MAX_ZONES // len(entries))
    for key, label, folder, pat in entries:
        files = insts.get(folder)
        if not files:
            missing.append(label)
            continue
        samples = [Sample(folder, n) for n, _ in files]
        common = set(samples[0].art)
        for s in samples[1:]:
            common &= set(s.art)
        arts = {}
        for s in samples:
            arts.setdefault(tuple(t for t in s.art if t not in common), []).append(s)
        pick = next((a for a in sorted(arts) if re.search(pat, "".join(a).lower())), None)
        if pick is None:
            missing.append(label)
            continue
        layers = layers_by_vel(arts[pick])
        while sum(len(rr) for rr in layers) > budget and max(len(rr) for rr in layers) > 1:
            m = max(len(rr) for rr in layers) - 1
            layers = [rr[:m] for rr in layers]
        group = 1 if "hat" in label else 0
        regions += regions_for(layers, key, key, key, label, True, group=group,
                               gain_db=level_for(arts[pick], analysis))
    return regions, missing


# ── presets ──────────────────────────────────────────────────────────────

BASE = {"smp-tune": 0, "smp-root": 60, "smp-start": 0, "smp-loop": 0, "smp-loop-start": 0,
        "smp-loop-end": 1, "smp-model": 0, "smp-engine": 0, "smp-rate": 48000, "smp-bits": 16,
        "smp-quant": 0, "smp-filter": 20000, "smp-trk": 0, "smp-res": 0, "smp-atk": 0.002,
        "smp-dec": 1.0, "smp-sus": 1, "smp-rel": 0.5, "smp-vel": 0.7, "smp-level": 0.8}


def preset_params(folder, kind, layered, has_rel=False):
    p = dict(BASE)
    if kind == "perc":
        p.update({"smp-atk": 0.001, "smp-rel": 0.3, "smp-vel": 0.5 if layered else 0.8})
    elif SUSTAINED.search(folder) and not STACCATO.search(folder):
        p.update({"smp-atk": 0.01, "smp-rel": 0.35})
    elif STACCATO.search(folder):
        p.update({"smp-atk": 0.002, "smp-rel": 0.12})
    else:
        p.update({"smp-atk": 0.001, "smp-rel": 0.6})
    if kind != "perc":
        p["smp-vel"] = 0.4 if layered else 0.8
    if has_rel:
        # the release sample carries the note's end: the body gets out of
        # its way (a damped piano string stops fast, a breath ends in its tail)
        p["smp-rel"] = 0.15 if re.search(r"piano|harpsichord", folder, re.I) else 0.06
    return p


def write_preset(bank_name, name, note, lib_path, params, pack="vcsl"):
    path = os.path.join(pack_presets(pack, "sampler"), bank_name, name + ".preset")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    d = {"slab": "preset", "schema": 1, "machine": "sampler", "note": note, "params": params, "assets": {"smp": lib_path}}
    with open(path, "w") as f:
        f.write(json.dumps(d) + "\n")


# ── main ─────────────────────────────────────────────────────────────────


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", action="append", default=[], help="instrument path contains (repeatable)")
    ap.add_argument("--list", action="store_true", help="list instruments, fetch nothing")
    ap.add_argument("--no-fetch", action="store_true", help="use what's on disk")
    ap.add_argument("--no-presets", action="store_true", help="write the SFZs only")
    ap.add_argument("--jobs", type=int, default=8, help="parallel downloads")
    args = ap.parse_args()

    root = os.path.join(library_root(), "vcsl")
    tree = fetch_tree(os.path.join(root, "tree.json"))
    insts, releases, files = instruments(tree)

    only = [o.lower() for o in args.only]
    chosen = sorted(f for f in insts if not only or any(o in f.lower() for o in only))
    if args.list:
        def size(f):
            return sum(s for _, s in files[f]) + (sum(s for _, s in files[releases[f]]) if f in releases else 0)
        for f in chosen:
            print(f"{size(f) / 1e6:8.1f} MB {len(insts[f]):4d}{' +rel' if f in releases else '     '}  {f}")
        print(f"{sum(size(f) for f in chosen) / 1e9:.2f} GB in {len(chosen)} instruments")
        return
    # kits draw on their folders: fetch those too when every kit piece is wanted
    want_kits = not only or any(o in "kits" for o in only)
    fetch = set(chosen) | (kit_folders() & set(insts) if want_kits else set())
    fetch |= {releases[f] for f in fetch if f in releases}

    if not args.no_fetch:
        jobs = [(RAW + urllib.request.quote(f"{f}/{n}"), os.path.join(root, "samples", f, n), sz)
                for f in sorted(fetch) for n, sz in files[f]]
        download(jobs, args.jobs)

    def on_disk(f):
        return [n for n, _ in files[f] if os.path.exists(os.path.join(root, "samples", f, n))]

    # measure what's new
    cache_path = os.path.join(root, "analysis.json")
    analysis = json.load(open(cache_path)) if os.path.exists(cache_path) else {}
    if np is None:
        print("numpy not found: names are trusted, nothing is levelled")
    else:
        todo = [(f, n) for f in sorted(fetch) for n in on_disk(f) if f"{f}/{n}" not in analysis]
        for i, (f, n) in enumerate(todo):
            try:
                analysis[f"{f}/{n}"] = measure(os.path.join(root, "samples", f, n), parse(n)[0])
            except Exception as e:  # a broken file is skipped, not fatal
                print(f"\n  can't read {f}/{n}: {e}", file=sys.stderr)
            if i % 50 == 0 or i == len(todo) - 1:
                print(f"\r  measuring {i + 1}/{len(todo)}   ", end="" if sys.stdout.isatty() else "\n", flush=True)
                with open(cache_path, "w") as fh:
                    json.dump(analysis, fh)
        if todo:
            print()

    made = []
    for f in chosen:
        names = on_disk(f)
        if not names:
            continue
        samples = [Sample(f, n) for n in names]
        noted = [s for s in samples if s.midi is not None]
        melodic = len(noted) >= 0.8 * len(samples) and len({s.midi for s in noted}) >= 3
        rel = [Sample(releases[f], n) for n in on_disk(releases[f])] if f in releases else []
        regions = map_melodic(f, noted, analysis, rel) if melodic else map_percussion(f, samples, analysis)
        if not regions:
            continue
        b, s = bank(f, melodic), slug(f)
        sfz = os.path.join(root, b, s + ".sfz")
        title = f.replace("/", " / ")
        write_sfz(sfz, title, regions, root)
        layered = len({r[1].vel for r in regions}) > 1
        has_rel = any("trigger=release" in r[0] for r in regions)
        if not args.no_presets:
            note = "VCSL " + " / ".join(f.split("/")[2:] or f.split("/")[-1:])
            if has_rel:
                note += ", with release samples"
            write_preset(b, s, note, f"lib:vcsl/{b}/{s}.sfz",
                         preset_params(f, "melodic" if melodic else "perc", layered, has_rel))
        made.append((b, s, len(regions)))

    if want_kits:
        for name, (title, entries) in KITS.items():
            regions, missing = map_kit(entries, {f: [(n, 0) for n in on_disk(f)] for f in insts}, analysis)
            if not regions:
                continue
            if missing:
                print(f"  {name}: no {', '.join(missing)}")
            sfz = os.path.join(root, "vcsl-kits", name + ".sfz")
            write_sfz(sfz, title, regions, root)
            if not args.no_presets:
                write_preset("vcsl-kits", name, title, f"lib:vcsl/vcsl-kits/{name}.sfz",
                             preset_params(name, "perc", True))
            made.append(("vcsl-kits", name, len(regions)))

    with open(os.path.join(root, "README.txt"), "w") as fh:
        fh.write("Versilian Community Sample Library (VCSL), CC0 1.0 / public domain.\n"
                 f"https://github.com/{REPO} at {COMMIT}\n"
                 "samples/ is the library as published; the SFZ files beside it are generated by\n"
                 "Slab's tools/library/vcsl.py. Slab presets refer to them as lib:vcsl/...\n")
    for b, s, n in made:
        print(f"  {b}/{s}: {n} zones")
    print(f"{len(made)} instruments in {root}")


if __name__ == "__main__":
    main()
