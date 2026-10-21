"""The harsh rigs (docs/43 §Rigs), written as FX Rack presets.

Each rig is built with slabkit's rack builder and saved, collapsed to its
macros, under machines/fxrack/presets/harsh/. Rerun after changing a
machine's presets or a rig here:

    PYTHONPATH=tools python3 tools/rigs/harsh.py
"""
import json
import os

from slabkit import fx, rack

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "machines", "fxrack", "presets", "harsh")

RIGS = []


def rig(name, note):
    def wrap(build):
        RIGS.append((name, note, build))
        return build
    return wrap


def static_lp(hz):
    """Wobble parked as a plain 24 dB lowpass: the clean sub lane's filter."""
    return fx("wob2", "pedal-wah", type=0, cutoff=hz, res=0.0, slope=1, depth=0.0, pos=0.0)


@rig("wobble-oktaver", "The GR6 wobble oktaver: the OC-2 sub under the note, a synced lowpass wobble on eighths, into fuzz. RATE steps the division, DEPTH opens the sweep.")
def wobble_oktaver():
    r = rack("Wobble Oktaver", kind="effect", collapsed=True)
    l = r.lane("OKT", fx=[fx("oct2", "oc-sub"), fx("wob2", "wobble-eighths", cutoff=160),
                          fx("sat2", mode="FUZZ", drive=22, sag=0.3, tone=9000)], level=-11)
    r.map(r.macro(1, "RATE", 0.5), l, "wob-div", insert=2, min=4, max=6)
    r.map(r.macro(2, "DEPTH", 0.8), l, "wob-depth", insert=2, min=1.0, max=6.0)
    r.map(r.macro(3, "SUB", 0.8), l, "oct-oct1", insert=1, min=0.0, max=1.0)
    r.map(r.macro(4, "FUZZ", 0.5), l, "sat-drive", insert=3, min=6.0, max=36.0)
    return r


@rig("sandwich", "Octave and wobble into overdrive, choked with an inverted chorus, then brought back with a grill distortion and OTT on top - the distortion-chorus-distortion sandwich.")
def sandwich():
    r = rack("Sandwich", kind="effect", collapsed=True)
    l = r.lane("CHAIN", fx=[
        fx("oct2", "oc-sub", oct1=0.6),
        fx("wob2", "wobble-eighths", cutoff=220, depth=4.0),
        fx("grind2", "blood-overdrive", stages=1),
        fx("chorus2", mode="I+II", depth=2.0, mix=0.5, fb=0.35, hp=150, invert="ON"),
        fx("grind2", "grill", tone=6500),
        fx("multi2", "ott", multi_mix=0.6),
    ], level=-3)
    r.map(r.macro(1, "WOBBLE", 0.7), l, "wob-depth", insert=2, min=0.0, max=6.0)
    r.map(r.macro(2, "DIRT", 0.5), l, "grind-drive", insert=3, min=12.0, max=44.0)
    r.map(r.macro(3, "CHOKE", 1.0), l, "chorus-mix", insert=4, min=0.0, max=0.5)
    r.map(r.macro(4, "BURGER", 0.5), l, "grind-drive", insert=5, min=8.0, max=36.0)
    r.map(r.macro(5, "OTT", 0.6), l, "multi-mix", insert=6, min=0.0, max=1.0)
    return r


@rig("octavia-portal", "Octavia into an auto-wah, folded, choked by the chorus, ground back up with sizzle and swept by a phaser - the second reference chain.")
def octavia_portal():
    r = rack("Octavia Portal", kind="effect", collapsed=True)
    l = r.lane("CHAIN", fx=[
        fx("oct2", "octavia"),
        fx("wob2", "auto-wah-guitar"),
        fx("grind2", "phase-smear", algo="FOLD", drive=16, phase=0.35),
        fx("chorus2", mode="I+II", mix=0.5, invert="ON", hp=200),
        fx("grind2", "blood-overdrive", sizzle=0.4, tone=6000),
        fx("phaser2", "four-stage-bite"),
    ], level=5)
    r.map(r.macro(1, "OCTAVE", 1.0), l, "oct-up", insert=1, min=0.0, max=1.0)
    r.map(r.macro(2, "WAH", 0.7), l, "wob-depth", insert=2, min=0.0, max=3.0)
    r.map(r.macro(3, "DIRT", 0.5), l, "grind-drive", insert=3, min=6.0, max=30.0)
    r.map(r.macro(4, "CHOKE", 1.0), l, "chorus-mix", insert=4, min=0.0, max=0.5)
    r.map(r.macro(5, "BURGER", 0.5), l, "grind-drive", insert=5, min=10.0, max=40.0)
    r.map(r.macro(6, "PHASE", 0.6), l, "ph-mix", insert=6, min=0.0, max=1.0)
    return r


@rig("kodiak", "Big and gnarly: a clean low-passed sub lane under a lane of octave-down, dynamic folding, RAT and OTT. SIZE is the sub, GNARL the dirt.")
def kodiak():
    r = rack("Kodiak", kind="effect", collapsed=True)
    sub = r.lane("SUB", fx=[static_lp(140), fx("sat2", mode="TAPE", drive=6)])
    gnarl = r.lane("GNARL", fx=[
        fx("eq2", hpf_on="ON", hpf_hz=160),
        fx("oct2", "oc-sub", oct1=0.5),
        fx("fold2", "dynamic-fold"),
        fx("grind2", "rat"),
        fx("multi2", "ott", multi_mix=0.7),
    ], level=-5)
    r.map(r.macro(1, "SIZE", 0.7), sub, "level", min=-30.0, max=0.0)
    r.map(r.macro(2, "GNARL", 0.5), gnarl, "grind-drive", insert=4, min=14.0, max=44.0)
    r.map(r.macro(3, "FOLD", 0.4), gnarl, "fold-fold", insert=3, min=0.0, max=24.0)
    r.map(r.macro(4, "SQUASH", 0.7), gnarl, "multi-mix", insert=5, min=0.0, max=1.0)
    return r


@rig("cross-bass", "Justice-style bass: a clean sub lane, and a dirty lane cut below 250 Hz, crushed to 12 bits, overdriven, through a Brit 4x12, slammed by a FET and taped.")
def cross_bass():
    r = rack("Cross Bass", kind="effect", collapsed=True)
    sub = r.lane("SUB", fx=[static_lp(150), fx("sat2", mode="TAPE", drive=4)])
    dirt = r.lane("DIRT", fx=[
        fx("eq2", hpf_on="ON", hpf_hz=250),
        fx("era", "lofi-12"),
        fx("grind2", "cross-dirt"),
        fx("amp2", "guitar-crunch", cab="4x12"),
        fx("char2", "fet-smash"),
        fx("tape2", "metal-hot"),
    ], level=2)
    r.map(r.macro(1, "DIRT", 0.5), dirt, "grind-drive", insert=3, min=12.0, max=40.0)
    r.map(r.macro(2, "CRUSH", 0.3), dirt, "era-bits", insert=2, min=16.0, max=6.0)
    r.map(r.macro(3, "SQUASH", 0.6), dirt, "char-thresh", insert=5, min=-10.0, max=-34.0)
    r.map(r.macro(4, "SUB", 0.8), sub, "level", min=-30.0, max=0.0)
    return r


@rig("phantom-stack", "Three Grinders in a row - soft, RAT, hard - then a phaser: stacked clipping that turns any saw into a wall.")
def phantom_stack():
    r = rack("Phantom Stack", kind="effect", collapsed=True)
    l = r.lane("STACK", fx=[fx("grind2", "soft-clipper", drive=14), fx("grind2", "rat", drive=24),
                            fx("grind2", "fast-dist", drive=12), fx("phaser2", "six-stage-keys")])
    stack = r.macro(1, "STACK", 0.5)
    for i, (lo, hi) in enumerate([(4, 24), (12, 40), (4, 24)]):
        r.map(stack, l, "grind-drive", insert=i + 1, min=lo, max=hi)
    r.map(r.macro(2, "TONE", 0.6), l, "grind-tone", insert=3, min=2500.0, max=16000.0)
    r.map(r.macro(3, "PHASE", 0.5), l, "ph-mix", insert=4, min=0.0, max=1.0)
    return r


@rig("gated-fuzz", "A starved fuzz into a fast gate: notes sputter and cut off dead.")
def gated_fuzz():
    r = rack("Gated Fuzz", kind="effect", collapsed=True)
    l = r.lane("FUZZ", fx=[fx("sat2", mode="FUZZ", drive=30, sag=1.0, tone=7000),
                           fx("gate2", thresh=-30, range=-80, atk=0.0005, hold=0.01, rel=0.02)], level=-13)
    r.map(r.macro(1, "FUZZ", 0.6), l, "sat-drive", insert=1, min=12.0, max=44.0)
    r.map(r.macro(2, "CHOP", 0.5), l, "gate-thresh", insert=2, min=-50.0, max=-14.0)
    return r


@rig("ring-growl", "The dry signal beside a lane ring-modulated by a low carrier and overdriven: growl and clang under the note.")
def ring_growl():
    r = rack("Ring Growl", kind="effect", collapsed=True)
    r.lane("DRY")
    g = r.lane("GROWL", fx=[fx("shift2", mode="RING", hz=60, mix=1.0), fx("grind2", "blood-overdrive", drive=20)],
               level=-6)
    r.map(r.macro(1, "GROWL", 0.8), g, "level", min=-30.0, max=0.0)
    r.map(r.macro(2, "CARRIER", 0.3), g, "shift-hz", insert=1, min=30.0, max=180.0)
    return r


@rig("ott-sandwich", "OTT, overdrive, OTT: tails and fizz pulled up, ground, and pulled up again.")
def ott_sandwich():
    r = rack("OTT Sandwich", kind="effect", collapsed=True)
    l = r.lane("OTT", fx=[fx("multi2", "ott"), fx("grind2", "blood-overdrive", drive=16), fx("multi2", "ott")],
               level=-8)
    depth = r.macro(1, "DEPTH", 0.6)
    r.map(depth, l, "multi-mix", insert=1, min=0.0, max=1.0)
    r.map(depth, l, "multi-mix", insert=3, min=0.0, max=1.0)
    r.map(r.macro(2, "DIRT", 0.4), l, "grind-drive", insert=2, min=4.0, max=36.0)
    return r


@rig("four-slot", "Distructor's layout: distortion, filter, chorus and amp in four slots, each slot's mix on a knob.")
def four_slot():
    r = rack("Four Slot", kind="effect", collapsed=True)
    l = r.lane("SLOTS", fx=[fx("grind2", "blood-overdrive"), fx("wob2", "envelope-filter"),
                            fx("chorus2", mix=0.5), fx("amp2", "guitar-crunch")])
    r.map(r.macro(1, "DIST", 1.0), l, "grind-mix", insert=1, min=0.0, max=1.0)
    r.map(r.macro(2, "FILTER", 0.6), l, "wob-mix", insert=2, min=0.0, max=1.0)
    r.map(r.macro(3, "CHORUS", 0.5), l, "chorus-mix", insert=3, min=0.0, max=0.5)
    r.map(r.macro(4, "AMP", 0.7), l, "amp-blend", insert=4, min=1.0, max=0.0)
    return r


@rig("bit-guitar", "Lows cut, crushed to 8 bits at 11 kHz, into a clean amp: aliased, zippy guitar.")
def bit_guitar():
    r = rack("Bit Guitar", kind="effect", collapsed=True)
    l = r.lane("BITS", fx=[fx("eq2", hpf_on="ON", hpf_hz=120), fx("era", bits=8, rate=11025, aa="OFF"),
                           fx("amp2", "guitar-clean")])
    r.map(r.macro(1, "BITS", 0.5), l, "era-bits", insert=2, min=12.0, max=4.0)
    r.map(r.macro(2, "RATE", 0.4), l, "era-rate", insert=2, min=22050.0, max=4000.0)
    return r


@rig("royal-split", "One bass, two amps: an octave-up lane through a high-gain 4x12 beside an octave-down lane through a bass 8x10.")
def royal_split():
    r = rack("Royal Split", kind="effect", collapsed=True)
    amp = r.lane("AMP", fx=[fx("oct2", "sub-and-up"), fx("amp2", "guitar-heavy")])
    bass = r.lane("BASS", fx=[fx("oct2", "oc-sub"), fx("amp2", "bass-vintage-15", cab="8x10")])
    blend = r.macro(1, "BLEND", 0.5)
    r.map(blend, amp, "level", min=-40.0, max=0.0, formula="clamp(2*x, 0, 1)")
    r.map(blend, bass, "level", min=-40.0, max=0.0, formula="clamp(2 - 2*x, 0, 1)")
    gain = r.macro(2, "GAIN", 0.5)
    r.map(gain, amp, "amp-gain", insert=2, min=0.3, max=1.0)
    r.map(gain, bass, "amp-gain", insert=2, min=0.2, max=0.8)
    return r


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, note, build in RIGS:
        state = build().build(f"rig {name}")
        preset = {"slab": "preset", "schema": 1, "machine": "fxrack", "note": note, **state}
        with open(os.path.join(OUT, name + ".preset"), "w") as f:
            json.dump(preset, f)
        print("wrote", name)


if __name__ == "__main__":
    main()
