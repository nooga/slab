#!/usr/bin/env python3
"""design.py - FM-7.11's factory presets, designed by intent.

Each preset below is written from scratch: an algorithm, six operators and
what the sound is for.  Its intent is a set of measured targets (how much
brighter the attack is than the body, how long it rings, how velocity
moves it); this script writes the preset, renders it through the bench
(the DAW's own machine path), measures the targets and prints pass/fail.

It also checks each preset is its own: the distance in parameter space to
the nearest voice of a reference bank, by default the DX7 ROM voices in
your library (dx7_import.py puts them there).  The bank is only read, and
nothing from it goes into the presets.  A preset closer to a ROM voice
than three quarters of the ROM voices are to their own nearest neighbour
fails (the banks are full of variants of one voice, so the median is
tiny).

Usage:
  python3 machines/fm86/tools/design.py               design, render, measure all
  python3 machines/fm86/tools/design.py e-piano bass  just these
  python3 machines/fm86/tools/design.py --no-render   write + originality only
  --ref=DIR   reference bank (default $SLAB_LIBRARY/dx7/presets/fm86)
"""

import glob
import json
import os
import re
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../tools"))
from slabkit import analyze  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
MACHINE = os.path.join(ROOT, "machines/fm86")
BANK = os.path.join(MACHINE, "presets/slab")
OUT = os.path.join(ROOT, "scratch/fm86-design")
LIBRARY = os.environ.get("SLAB_LIBRARY", os.path.expanduser("~/Music/Slab/Library"))
SR = 48000
CHORD_PEAK = -6.0

# ── building a voice ─────────────────────────────────────────────────────


def op(ratio=1.0, ol=99, eg=(99, 50, 50, 70, 99, 90, 90, 0), kvs=0, rs=0, det=0,
       ks=(39, 0, 0, 0, 0), ams=0, fixed=False):
    """One operator.  ratio is the frequency ratio: 0.5..1 or 1..31.99, split
    into coarse and fine the DX7 way (coarse x (1 + fine/100), so 3.5 is
    coarse 3 fine 17, the nearest step); fixed=True takes (coarse, fine)
    as they are.  eg = r1..r4, l1..l4.
    ks = break point, left depth, right depth, left curve, right curve."""
    if fixed:
        coarse, fine = ratio
    elif ratio < 1.0:
        coarse, fine = 0, round((ratio / 0.5 - 1.0) * 100)
    else:
        coarse = int(ratio)
        fine = round((ratio / coarse - 1.0) * 100)
    assert 0 <= fine <= 99, (ratio, fine)
    r1, r2, r3, r4, l1, l2, l3, l4 = eg
    bp, ld, rd, lc, rc = ks
    return {"r1": r1, "r2": r2, "r3": r3, "r4": r4, "l1": l1, "l2": l2, "l3": l3, "l4": l4,
            "bp": bp, "ld": ld, "rd": rd, "lc": lc, "rc": rc, "rs": rs, "det": det,
            "ams": ams, "kvs": kvs, "ol": ol, "mode": 1 if fixed else 0,
            "coarse": coarse, "fine": fine}


def voice(algo, ops, fb=0, lfo=(35, 0, 0, 0, 0, 4), pms=0, peg=None, transpose=0,
          volume=1.0, oks=1):
    """lfo = speed, delay, pmd, amd, sync, wave; peg = (r1..r4, l1..l4)."""
    p = {}
    for i, o in enumerate(ops):
        for k, v in o.items():
            p[f"op{i + 1}-{k}"] = v
    pr = peg or (99, 99, 99, 99, 50, 50, 50, 50)
    for i in range(4):
        p[f"pr{i + 1}"] = pr[i]
        p[f"pl{i + 1}"] = pr[4 + i]
    s, d, pmd, amd, sync, wave = lfo
    p.update({"algo": algo, "feedback": fb, "oks": oks, "lfo-speed": s, "lfo-delay": d,
              "lfo-pmd": pmd, "lfo-amd": amd, "lfo-sync": sync, "lfo-wave": wave,
              "pms": pms, "transpose": transpose, "volume": volume})
    return p


# ── the presets ─────────────────────────────────────────────────────────
#
# Targets (measured on the bench's C3 cases, see measure()):
#   bark      attack centroid (first 40 ms) over held centroid (0.5-1.0 s)
#   vel_db    level change from velocity 0.25 to 1.0
#   vel_bright  centroid ratio, velocity 1.0 over 0.25
#   t20       seconds from the peak to -20 dB while the key is held
#   rise      seconds from onset to the peak
#   nonharm   held non-harmonic energy, dB (from the bench report)
#   flat      level spread across C2..C5, dB
#   motion    std of the held centroid over 0.3-2 s, as a fraction of its mean
#   inharm    share of the strike's energy (50-400 ms) off C3's harmonics
#
# Every preset is then levelled so the bench's four-note chord peaks at
# CHORD_PEAK dBFS (the VOL control), so the bank plays at one loudness.

PRESETS = {
    # A tine piano: three 1:1 stacks.  The middle stack's modulator at 13:1
    # is the tine, a bark that only hard hits reach and that dies in a
    # quarter second; the outer two are the warm body and a slightly
    # detuned twin for the chorus-like beat.  Everything decays, faster
    # up the keyboard.
    "e-piano": dict(
        note="Slab: tine e-piano. Soft keys give a round, bell-less body; hard keys bark with a 13:1 tine that dies in a quarter second. Two detuned 1:1 bodies beat slowly.",
        voice=voice(5, [
            op(1, 99, (96, 32, 26, 66, 99, 86, 0, 0), kvs=3, rs=3, det=+2),
            op(1, 66, (94, 52, 36, 70, 99, 48, 0, 0), kvs=7, rs=3),
            op(1, 92, (97, 34, 28, 66, 99, 82, 0, 0), kvs=3, rs=3, det=-2),
            op(13, 76, (99, 66, 50, 80, 99, 20, 0, 0), kvs=7, rs=4, ks=(60, 0, 40, 0, 0)),
            op(1, 80, (95, 32, 26, 66, 99, 86, 0, 0), kvs=3, rs=3, det=+5),
            op(1, 36, (92, 56, 38, 70, 99, 46, 0, 0), kvs=6, rs=3),
        ], fb=3, lfo=(30, 0, 0, 0, 0, 4)),
        targets=dict(bark=(1.4, 4.0), vel_db=(9, 22), vel_bright=(1.25, 4.0), t20=(0.8, 4.0),
                     rise=(0, 0.03), flat=(0, 8)),
    ),
    # A plucked bass that holds: one carrier fed by three chains.  A
    # 7:1 click on the attack, a 1:1 thump that falls to a low sustain,
    # and a 2:1 feedback pair that keeps a moderate body while held.
    "bass": dict(
        note="Slab: rubber bass. A pick click and a thump on the attack, then a round, slightly hollow sustain that holds while the key is down; velocity opens the thump.",
        voice=voice(16, [
            op(1, 99, (99, 38, 26, 78, 99, 90, 78, 0), kvs=2, rs=1),
            op(1, 82, (99, 55, 32, 75, 99, 50, 30, 0), kvs=5, rs=1),
            op(1, 72, (99, 62, 40, 75, 99, 40, 0, 0), kvs=4, rs=1),
            op(7, 60, (99, 82, 60, 80, 99, 0, 0, 0), kvs=6, rs=2),
            op(2, 64, (99, 45, 30, 75, 99, 72, 60, 0), kvs=3, rs=1),
            op(1, 52, (99, 50, 30, 75, 99, 70, 58, 0), kvs=2, rs=1),
        ], fb=5, transpose=0),
        targets=dict(bark=(1.3, 5.0), vel_db=(6, 20), vel_bright=(1.15, 4.0), rise=(0, 0.02),
                     nonharm=(-200, -40), flat=(0, 9)),
    ),
    # Brass: one feedback modulator drives three detuned 1:1 carriers, a
    # second pair adds the edge.  The modulators swell in slower than the
    # carriers, so a note blooms from dark to bright; the pitch scoops up a
    # few cents into the note and a delayed vibrato comes in on long notes.
    "brass": dict(
        note="Slab: synth brass. Notes bloom from dark to bright over 150 ms with a small upward scoop; three detuned carriers and a late vibrato on held notes.",
        voice=voice(22, [
            op(1, 96, (54, 40, 30, 68, 99, 94, 92, 0), kvs=2, rs=1),
            op(1, 78, (48, 46, 38, 66, 99, 86, 82, 0), kvs=3, rs=1),
            op(1, 92, (53, 40, 30, 68, 99, 94, 92, 0), kvs=2, rs=1, det=-3),
            op(1, 90, (53, 40, 30, 68, 99, 94, 92, 0), kvs=2, rs=1, det=+3),
            op(0.5, 74, (53, 40, 30, 68, 99, 94, 92, 0), kvs=2, rs=1),
            op(1, 74, (46, 48, 38, 66, 99, 84, 80, 0), kvs=3, rs=1),
        ], fb=6, lfo=(33, 62, 7, 0, 0, 4), pms=3, peg=(80, 68, 99, 60, 46, 50, 50, 50)),
        targets=dict(bark=(0.4, 1.0), rise=(0.06, 0.4), vel_bright=(1.1, 3.0), vel_db=(3, 14),
                     flat=(0, 8)),
    ),
    # Bells: two carriers an octave and a twelfth apart, each struck by an
    # inharmonic modulator (3.5:1 and 1.41:1) that fades faster than the
    # carrier.  The strike is clangorous, the long ring nearly pure.
    "bells": dict(
        note="Slab: struck bells. A clangorous, inharmonic strike that fades to a nearly pure ring over several seconds; the third carrier adds a high shimmer.",
        voice=voice(5, [
            op(1, 99, (99, 26, 18, 30, 99, 70, 0, 0), kvs=2, rs=2),
            op(3.5, 78, (99, 34, 22, 40, 99, 50, 0, 0), kvs=4, rs=2),
            op(3, 84, (99, 30, 18, 32, 99, 64, 0, 0), kvs=2, rs=2),
            op(1.41, 70, (99, 40, 24, 40, 99, 40, 0, 0), kvs=4, rs=2),
            op(5, 66, (99, 38, 22, 38, 99, 50, 0, 0), kvs=3, rs=3, det=+4),
            op(7.13, 50, (99, 50, 30, 40, 99, 30, 0, 0), kvs=4, rs=3),
        ], fb=0, oks=1),
        targets=dict(bark=(1.3, 6.0), t20=(1.5, float("inf")), inharm=(0.15, 1.0), rise=(0, 0.02),
                     vel_bright=(1.15, 5.0)),
    ),
    # Strings: two saw-like carriers (each a 1:1 modulator with feedback
    # on the chain) detuned apart, slow attack and release, and a delayed
    # vibrato.  Velocity changes little; it's an ensemble, not a bow.
    "strings": dict(
        note="Slab: string ensemble. Two saw-like voices detuned apart swell in over 300 ms and fade on release; a slow vibrato arrives on held chords.",
        voice=voice(1, [
            op(1, 98, (49, 30, 30, 50, 99, 94, 94, 0), kvs=1, rs=1, det=+4),
            op(1, 80, (47, 32, 28, 48, 99, 90, 90, 0), kvs=2, rs=1),
            op(1, 96, (49, 30, 30, 50, 99, 94, 94, 0), kvs=1, rs=1, det=-4),
            op(1, 74, (47, 30, 28, 48, 99, 90, 90, 0), kvs=2, rs=1),
            op(2, 56, (45, 30, 28, 48, 99, 88, 88, 0), kvs=1, rs=1),
            op(1, 60, (47, 30, 30, 48, 99, 90, 90, 0), kvs=0, rs=1),
        ], fb=6, lfo=(30, 70, 6, 0, 0, 4), pms=3),
        targets=dict(rise=(0.15, 0.8), bark=(0.3, 1.3), vel_db=(1, 9), flat=(0, 8)),
    ),
    # Something a DX7 bank rarely has: the LFO's sample-and-hold steps
    # the modulators' amplitude (AMS 3), so a held chord's timbre jumps
    # to a new random brightness several times a second, over a glassy
    # 1:1 / 3:1 body with a fixed 1.2 kHz formant operator.
    "sample-hold-glass": dict(
        note="Slab: sample-and-hold glass. A held chord's brightness steps to a new random value six times a second over a glassy body and a fixed 1.2 kHz formant; play it under a slow pad or alone as a texture.",
        voice=voice(5, [
            op(1, 99, (80, 40, 30, 55, 99, 92, 90, 0), kvs=1, rs=1),
            op(3, 80, (99, 40, 30, 55, 99, 90, 88, 0), kvs=2, rs=1, ams=3),
            op(1, 90, (80, 40, 30, 55, 99, 92, 90, 0), kvs=1, rs=1, det=+3),
            op(1, 78, (99, 40, 30, 55, 99, 88, 86, 0), kvs=2, rs=1, ams=3),
            op(2, 74, (80, 40, 30, 55, 99, 92, 90, 0), kvs=1, rs=1),
            op((3, 20), 68, (99, 40, 30, 55, 99, 90, 88, 0), kvs=2, rs=0, ams=2, fixed=True),
        ], fb=0, lfo=(62, 0, 0, 72, 0, 5), pms=0),
        targets=dict(motion=(0.08, 1.0), rise=(0, 0.2), flat=(0, 9)),
    ),
}

# ── originality ─────────────────────────────────────────────────────────


def param_ranges():
    """{id: (min, max)} for every FM-7.11 control, from the manifest."""
    src = open(os.path.join(MACHINE, "fm86.fy")).read()
    ranges = {}
    for line in src.splitlines():
        m = re.search(r'"([a-z0-9-]+)"\s+Fm86Params\.\S+(?:\s+DxOpP\.\S+\s+\+)?\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(int-step|curve)', line)
        if m:
            ranges[m.group(1)] = (float(m.group(2)), float(m.group(3)))
            continue
        m = re.search(r'"([a-z0-9-]+)"\s+Fm86Params\.\S+(?:\s+DxOpP\.\S+\s+\+)?\s+-?[\d.]+\s+switch(.*)', line)
        if m:
            opts = len(re.findall(r"\bopt\b", m.group(2))) or 2
            ranges[m.group(1)] = (0.0, float(max(opts - 1, 1)))
    # lfo-wave's options continue on the next line
    ranges["lfo-wave"] = (0.0, 5.0)
    return ranges


def vec(params, keys, ranges):
    return np.array([(float(params.get(k, ranges[k][0])) - ranges[k][0]) / (ranges[k][1] - ranges[k][0])
                     for k in keys])


def load_bank(ref):
    bank = {}
    for f in sorted(glob.glob(os.path.join(ref, "**/*.preset"), recursive=True)):
        try:
            bank[os.path.relpath(f, ref)[:-7]] = json.load(open(f))["params"]
        except (ValueError, KeyError):
            pass
    return bank


class Originality:
    def __init__(self, ref):
        self.ranges = param_ranges()
        self.bank = load_bank(ref)
        self.keys = [k for k in sorted(self.ranges) if k not in ("volume", "engine", "transpose")]
        if not self.bank:
            self.floor = None
            return
        names = list(self.bank)
        m = np.stack([vec(self.bank[n], self.keys, self.ranges) for n in names])
        self.names, self.m = names, m
        d = np.abs(m[:, None, :] - m[None, :, :]).mean(axis=2)
        np.fill_diagonal(d, np.inf)
        nn = d.min(axis=1)
        nn = nn[nn > 1e-9]  # exact duplicates in the bank don't count
        self.nn = np.sort(nn)
        self.floor = float(np.percentile(nn, 75))

    def nearest(self, params):
        if self.floor is None:
            return None, None
        d = np.abs(self.m - vec(params, self.keys, self.ranges)[None, :]).mean(axis=1)
        i = int(d.argmin())
        return self.names[i], float(d[i])

    def percentile(self, d):
        return 100.0 * np.searchsorted(self.nn, d) / len(self.nn)


# ── rendering and measuring ─────────────────────────────────────────────


def write_preset(name, spec):
    os.makedirs(BANK, exist_ok=True)
    doc = {"slab": "preset", "schema": 1, "machine": "fm86", "note": spec["note"],
           "params": spec["voice"]}
    with open(os.path.join(BANK, name + ".preset"), "w") as f:
        json.dump(doc, f)
        f.write("\n")


def bench(name):
    out = os.path.join(OUT, name)
    r = subprocess.run(["zig", "build", "bench", "--", "machines/fm86", f"--preset=slab/{name}",
                        "--no-sheets", f"--out={out}"], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(r.stderr[-2000:])
    return os.path.join(out, "fm86")


def read_wav(path):
    """Mono float64 from the bench's 16- or 24-bit WAVs (slabkit's reader)."""
    x, _ = analyze.read_wav(path)
    return x.mean(axis=1)


def centroid(x):
    if len(x) < 64 or not np.any(x):
        return 0.0
    w = np.hanning(len(x))
    s = np.abs(np.fft.rfft(x * w))
    f = np.fft.rfftfreq(len(x), 1 / SR)
    return float((s * f).sum() / max(s.sum(), 1e-12))


def rms_db(x):
    return 20 * np.log10(np.sqrt(np.mean(x * x)) + 1e-12)


def env(x, win=0.01):
    n = int(win * SR)
    k = len(x) // n
    return np.array([np.sqrt(np.mean(x[i * n:(i + 1) * n] ** 2)) + 1e-12 for i in range(k)]), win


def measure(dirpath):
    m = {}
    held = read_wav(os.path.join(dirpath, "held.wav"))
    e, w = env(held)
    on = int(np.argmax(e > e.max() * 1e-3))
    pk = int(np.argmax(e[: int(2.0 / w)]))
    m["rise"] = (pk - on) * w
    edb = 20 * np.log10(e / e[pk])
    below = np.nonzero(edb[pk: int(2.0 / w)] < -20)[0]
    m["t20"] = below[0] * w if len(below) else float("inf")
    a0 = on * int(w * SR)
    att = centroid(held[a0: a0 + int(0.04 * SR)])
    body = centroid(held[int(0.5 * SR): int(1.0 * SR)])
    m["bark"] = att / body if body else float("inf")
    cs = [centroid(held[int(t * SR): int((t + 0.05) * SR)]) for t in np.arange(0.3, 2.0, 0.05)]
    cs = np.array([c for c in cs if c > 0])
    m["motion"] = float(cs.std() / cs.mean()) if len(cs) else 0.0

    # share of the strike's energy (50-400 ms) away from C3's harmonics
    seg_ = held[int(0.05 * SR): int(0.4 * SR)] * np.hanning(int(0.35 * SR))
    sp = np.abs(np.fft.rfft(seg_)) ** 2
    f = np.fft.rfftfreq(len(seg_), 1 / SR)
    f0 = 440.0 * 2 ** ((48 - 69) / 12)
    h = f / f0
    near = np.abs(h - np.round(h)) * f0 < np.maximum(8.0, 0.015 * f)
    m["inharm"] = float(sp[~near].sum() / max(sp.sum(), 1e-20))

    vel = read_wav(os.path.join(dirpath, "velocity.wav"))
    seg = lambda i: vel[int(i * 0.75 * SR): int((i * 0.75 + 0.3) * SR)]
    m["vel_db"] = rms_db(seg(3)) - rms_db(seg(0))
    c0, c3 = centroid(seg(0)), centroid(seg(3))
    m["vel_bright"] = c3 / c0 if c0 else float("inf")

    notes = read_wav(os.path.join(dirpath, "notes.wav"))
    lv = [rms_db(notes[int(i * 0.75 * SR): int((i * 0.75 + 0.3) * SR)]) for i in range(4)]
    m["flat"] = max(lv) - min(lv)

    rep = open(os.path.join(dirpath, "report.md")).read()
    sec = rep.split("## held", 1)[1].split("##", 1)[0]
    mm = re.search(r"nonharm (-?[\d.]+) dB", sec)
    m["nonharm"] = float(mm.group(1)) if mm else float("nan")
    mm = re.search(r"peak (-?[\d.]+) dBFS", rep.split("## chord", 1)[1]) if "## chord" in rep else None
    m["chord_peak"] = float(mm.group(1)) if mm else float("nan")
    m["held_peak"] = float(re.search(r"peak (-?[\d.]+) dBFS", sec).group(1))
    return m


def main(argv):
    names = [a for a in argv if not a.startswith("-")] or list(PRESETS)
    render = "--no-render" not in argv
    ref = next((a[6:] for a in argv if a.startswith("--ref=")),
               os.path.join(LIBRARY, "dx7/presets/fm86"))
    orig = Originality(ref)
    if orig.floor is None:
        print(f"no reference bank in {ref}; originality not checked")
    else:
        print(f"reference: {len(orig.bank)} voices, nearest-neighbour distance p75 {orig.floor:.3f}")
    failed = 0
    for name in names:
        spec = PRESETS[name]
        write_preset(name, spec)
        line = [f"{name:<18}"]
        ok = True
        nn, d = orig.nearest(spec["voice"])
        if nn is not None:
            good = d > orig.floor
            ok &= good
            line.append(f"nearest {nn} {d:.3f} (p{orig.percentile(d):.0f}) {'ok' if good else 'TOO CLOSE'}")
        print("  ".join(line))
        if render:
            m = measure(bench(name))
            if abs(m["chord_peak"] - CHORD_PEAK) > 0.5:
                spec["voice"]["volume"] = round(spec["voice"]["volume"] * 10 ** ((CHORD_PEAK - m["chord_peak"]) / 20), 3)
                write_preset(name, spec)
                m = measure(bench(name))
            for k, (lo, hi) in spec["targets"].items():
                v = m[k]
                good = lo <= v <= hi
                ok &= good
                print(f"    {k:<11} {v:8.3f}   target {lo}..{hi}  {'ok' if good else 'MISS'}")
            print(f"    peaks: held {m['held_peak']:.1f} dBFS, chord {m['chord_peak']:.1f} dBFS "
                  f"(VOL {spec['voice']['volume']}); nonharm {m['nonharm']:.1f} dB")
        failed += not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
