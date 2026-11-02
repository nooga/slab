#!/usr/bin/env python3
"""Write Ambika's presets (machines/ambika/presets/*.preset).

The patches are ours. The firmware repository's golden card
(controller/data/goldencard) has the Ambika's own banks; they are not imported yet. They are written with the unit's
raw numbers (docs/48-ambika.md), so each reads as it would on the
hardware's screen. Chord pads first: it is a polysynth.

    python3 tools/ambika/factory_presets.py
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "machines", "ambika", "presets")

SHAPES = "NONE SAW SQUARE TRIANG SINE ZSAW LPZSAW PKZSAW BPZSAW HPZSAW LPZPLS PKZPLS BPZPLS HPZPLS ZTRI PAD FM 8BITS PWM NOISE VOWEL MALE FEMALE CHOIR TAMPURA BOWED CELLO VIBES SLAP EPIANO ORGAN WAVES DIGITAL DRONE1 DRONE2 METALLIC BELL WAVQNCE".split()
SRCS = "ENV1 ENV2 ENV3 LFO1 LFO2 LFO3 LFO4 MOD1 MOD2 MOD3 MOD4 VELO AFTR BEND MWHL WHL2 PDAL NOTE GATE NOIS RAND [256] [128] [64] [32] [16] [8] [4]".split()
DSTS = "PRM1 PRM2 OSC1 OSC2 ~1+2 VIBR MIX XMOD NOIS SUB FUZZ CRSH FREQ RESO ATTK DECA RELE LFO4 VCA".split()
OPS = "SUM SYNC RING XOR FOLD BITS".split()
SUBS = "SQ1 TR1 PL1 SQ2 TR2 PL2 CLICK GLITCH BLOW METAL POP".split()
LFOW = "TRI SQR S&H RAMP".split() + [f"WAV{i}" for i in range(1, 17)]


def patch(name, note, osc1, osc2, mix=None, filt=None, env=None, lfo=None, slots=(), part=None, mods=None):
    p = {}
    for n, o in ((1, osc1), (2, osc2)):
        shape, para, rang, tune = (list(o) + [0, 0, 0])[:4] if isinstance(o, tuple) else (o, 0, 0, 0)
        p[f"am-o{n}-shape"] = SHAPES.index(shape)
        p[f"am-o{n}-prm"] = para
        p[f"am-o{n}-range"] = rang
        p[f"am-o{n}-tune"] = tune
    m = dict(mix or {})
    p["am-balance"] = m.get("mix", 32)
    p["am-op"] = OPS.index(m.get("op", "SUM"))
    p["am-mixprm"] = m.get("amnt", 0)
    p["am-sub-shape"] = SUBS.index(m.get("subwave", "SQ1"))
    p["am-sub-lvl"] = m.get("sub", 0)
    p["am-noise"] = m.get("noise", 0)
    p["am-fuzz"] = m.get("fuzz", 0)
    p["am-crush"] = m.get("crush", 0)
    f = dict(filt or {})
    p["am-cutoff"] = f.get("freq", 90)
    p["am-reso"] = f.get("reso", 10)
    p["am-env2"] = f.get("env2", 0)
    p["am-lfo2"] = f.get("lfo2", 0)
    e = env or {}
    for k in (1, 2, 3):
        a, d, s, r = e.get(k, (0, 40, 100, 60))
        p[f"am-e{k}-a"], p[f"am-e{k}-d"], p[f"am-e{k}-s"], p[f"am-e{k}-r"] = a, d, s, r
    for k, (w, rate) in enumerate((lfo or {}).get("part", [("TRI", 40)] * 3), 1):
        p[f"am-l{k}-shape"] = LFOW.index(w)
        p[f"am-l{k}-rate"] = rate
    vw, vr = (lfo or {}).get("voice", ("TRI", 40))
    p["am-vl-shape"], p["am-vl-rate"] = LFOW.index(vw), vr
    # matrix: the unit's defaults for the last three slots (ENV3 and VELO to VCA, bend), ours first
    for i, (s, d, a) in enumerate(slots, 1):
        p[f"am-m{i}-src"], p[f"am-m{i}-dst"], p[f"am-m{i}-amt"] = SRCS.index(s), DSTS.index(d), a
    for i in range(len(slots) + 1, 11):
        p[f"am-m{i}-amt"] = 0
    for i, (a, b, op) in enumerate(mods or [], 1):
        p[f"am-d{i}-in1"], p[f"am-d{i}-in2"], p[f"am-d{i}-op"] = SRCS.index(a), SRCS.index(b), "OFF ADD PRD ATTN MAX MIN XOR >= <= QTZ LAG".split().index(op)
    pt = part or {}
    p["am-volume"] = pt.get("volume", 100)
    p["am-legato"] = pt.get("legato", 0)
    p["am-porta"] = pt.get("porta", 0)
    p["am-gain"] = 0.5
    return {"slab": "preset", "schema": 1, "machine": "ambika", "note": f"{name}: {note}", "params": p}


PRESETS = [
    patch("INIT SAW", "Two saws a hair apart through the 4-pole: the unit's blank patch.",
          "SAW", ("SAW", 0, 0, 6), filt={"freq": 90, "reso": 10, "env2": 30}, env={3: (0, 40, 127, 60), 2: (0, 40, 20, 60)}),
    patch("PAD WASH", "The quad-saw pad over a saw, a slow ENV 3, the filter breathing with LFO 2.",
          ("PAD", 70), ("SAW", 0, 0, 5), mix={"mix": 24, "sub": 12},
          filt={"freq": 64, "reso": 14, "env2": 22, "lfo2": 10},
          env={3: (70, 60, 110, 90), 2: (60, 60, 60, 80)},
          lfo={"part": [("TRI", 30), ("TRI", 20), ("TRI", 40)], "voice": ("TRI", 50)},
          slots=[("LFO1", "~1+2", 2), ("LFO3", "MIX", 10)]),
    patch("CHOIR", "A choir wavetable scanned by a slow LFO, a soft attack: chords sound sung.",
          ("CHOIR", 40), ("FEMALE", 50, 0, 4), mix={"mix": 30, "noise": 2},
          filt={"freq": 80, "reso": 6},
          env={3: (50, 60, 120, 70)},
          lfo={"part": [("TRI", 22), ("TRI", 30), ("TRI", 40)], "voice": ("TRI", 35)},
          slots=[("LFO1", "PRM1", 22), ("LFO2", "PRM2", 18), ("LFO4", "VIBR", 6)]),
    patch("GLASS KEYS", "Vibes wavetable swept by a decaying ENV 1: a struck, bell-like chord.",
          ("VIBES", 10), ("BELL", 30, 12, 0), mix={"mix": 40},
          filt={"freq": 100, "reso": 8},
          env={1: (0, 55, 0, 60), 3: (0, 60, 0, 70)},
          slots=[("ENV1", "PRM1", 50), ("ENV1", "PRM2", 30)]),
    patch("ZSAW LEAD", "A resonant phase-distortion saw swept by ENV 1, glided in legato.",
          ("LPZSAW", 40), ("SAW", 0, -12, 0), mix={"mix": 20, "sub": 10},
          filt={"freq": 96, "reso": 8},
          env={1: (0, 50, 30, 50), 3: (0, 40, 110, 40)},
          slots=[("ENV1", "PRM1", 40), ("LFO4", "VIBR", 5)],
          part={"legato": 1, "porta": 40}, lfo={"voice": ("TRI", 60)}),
    patch("VOWEL PAD", "The vowel oscillator morphing under a saw, held chords that talk.",
          ("VOWEL", 20), ("SAW", 0, 0, 7), mix={"mix": 38},
          filt={"freq": 70, "reso": 10},
          env={3: (40, 60, 115, 80)},
          lfo={"part": [("TRI", 14), ("TRI", 20), ("TRI", 40)]},
          slots=[("LFO1", "PRM1", 40)]),
    patch("SYNC BASS", "OSC 2 hard-synced to OSC 1 and swept by ENV 1; a square sub underneath.",
          "SAW", ("SAW", 0, 7, 0), mix={"op": "SYNC", "mix": 40, "sub": 30},
          filt={"freq": 70, "reso": 18, "env2": 30},
          env={1: (0, 45, 0, 40), 2: (0, 40, 10, 40), 3: (0, 45, 90, 30)},
          slots=[("ENV1", "OSC2", 32)]),
    patch("FOLD BELL", "Two-operator FM with a fold: metallic and clangorous, short ring.",
          ("FM", 40, 3), ("SINE", 0, 12, 3), mix={"op": "FOLD", "amnt": 20, "mix": 36},
          filt={"freq": 110, "reso": 4},
          env={1: (0, 50, 0, 50), 3: (0, 58, 0, 66)},
          slots=[("ENV1", "PRM1", 40), ("ENV1", "XMOD", 20)]),
    patch("CLICK PLUCK", "A narrow pulse with a click transient: a dry pluck for stabs.",
          ("SQUARE", 50), ("SAW", 0, 0, 5), mix={"mix": 24, "subwave": "CLICK", "sub": 28},
          filt={"freq": 70, "reso": 12, "env2": 36},
          env={2: (0, 36, 0, 40), 3: (0, 40, 0, 44)}),
    patch("CRUSHED ORGAN", "The organ wavetable run through the crusher and a little fuzz.",
          ("ORGAN", 30), ("TRIANG", 0, 12, 0), mix={"mix": 30, "fuzz": 10, "crush": 4},
          filt={"freq": 104, "reso": 4},
          env={3: (0, 40, 120, 30)}),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    for i, p in enumerate(PRESETS, 1):
        name = p["note"].split(":")[0].lower().replace(" ", "-")
        with open(os.path.join(OUT, f"{i:02d}-{name}.preset"), "w") as f:
            json.dump(p, f)
            f.write("\n")
    print(len(PRESETS), "presets")


main()
