"""Generate machines/geq8/presets/*.preset.

Each preset lists the filters it uses as (type, Hz, gain dB, Q). A filter
goes into the free band whose default frequency is nearest, so the band
handles stay in frequency order across presets; spare bands are switched
off at their default frequency, flat. Every band is written, so loading a
preset fully replaces the previous one.

    python3 tools/geq8_presets/gen.py
"""
import json
import math
import os

TYPES = ["LC48", "LC12", "LSHLF", "BELL", "NOTCH", "HSHLF", "HC12", "HC48"]
SLOT_HZ = [60, 150, 350, 800, 1800, 4000, 8000, 12000]  # manifest defaults

PRESETS = {
    "flat": ("Every band on, flat: the init layout", 1, 0.0, [
        ("LSHLF", 60, 0, 0.71), ("BELL", 150, 0, 0.71), ("BELL", 350, 0, 0.71),
        ("BELL", 800, 0, 0.71), ("BELL", 1800, 0, 0.71), ("BELL", 4000, 0, 0.71),
        ("BELL", 8000, 0, 0.71), ("HSHLF", 12000, 0, 0.71)]),
    # ── drums ──
    "kick-punch": ("Kick: subsonic cut, weight at 60, boxiness out, beater click", 1, 0.0, [
        ("LC48", 28, 0, 0.71), ("BELL", 60, 3, 1.2), ("BELL", 380, -5, 1.4),
        ("BELL", 4000, 4, 1.0), ("HC12", 12000, 0, 0.71)]),
    "snare-crack": ("Snare: low cut, body, ring out, crack and air", 1, 0.0, [
        ("LC12", 90, 0, 0.71), ("BELL", 200, 2, 1.0), ("BELL", 900, -3, 2.0),
        ("BELL", 5000, 3, 1.0), ("HSHLF", 10000, 2, 0.71)]),
    "hat-tick": ("Hats: lows gone, the tick up, the hiss down", 1, 0.0, [
        ("LC48", 400, 0, 0.71), ("BELL", 3500, 2.5, 1.4), ("HSHLF", 11000, -4, 0.71)]),
    "drum-bus": ("Drum bus: rumble out, thump, a little less mud, snap and air", 1, 0.0, [
        ("LC48", 30, 0, 0.71), ("BELL", 70, 2, 1.0), ("BELL", 400, -2, 1.0),
        ("BELL", 3000, 1.5, 0.9), ("HSHLF", 10000, 2, 0.71)]),
    # ── tonal parts ──
    "bass-define": ("Bass: subsonics out, warmth, mud out, growl for small speakers", 1, 0.0, [
        ("LC48", 30, 0, 0.71), ("BELL", 80, 2, 1.0), ("BELL", 250, -3, 1.2),
        ("BELL", 900, 3, 1.2), ("HC12", 6000, 0, 0.71)]),
    "pad-clear": ("Pad: make room below 180, less boxiness, a sheen on top", 1, 0.0, [
        ("LC12", 180, 0, 0.71), ("BELL", 400, -3, 1.0), ("HSHLF", 9000, 2, 0.71)]),
    "lead-forward": ("Lead: thinned below, presence up so it cuts through", 1, 0.0, [
        ("LC12", 150, 0, 0.71), ("BELL", 300, -2, 1.0), ("BELL", 2500, 3, 1.0),
        ("HSHLF", 10000, 1.5, 0.71)]),
    "keys-bright": ("Keys / EP: less low-mid fog, bark and sparkle", 1, 0.0, [
        ("LC12", 80, 0, 0.71), ("BELL", 300, -2, 0.9), ("BELL", 2000, 2, 1.0),
        ("HSHLF", 7000, 3, 0.71)]),
    "de-mud": ("Two gentle dips where mixes go muddy", 1, 0.0, [
        ("BELL", 280, -4, 1.2), ("BELL", 500, -2, 1.4)]),
    # ── bus / master ──
    "mix-air": ("Master: rumble out, a touch of weight and air", 1, 0.0, [
        ("LC48", 22, 0, 0.71), ("LSHLF", 60, 1, 0.71), ("BELL", 300, -1, 0.8),
        ("HSHLF", 12000, 1.5, 0.71)]),
    "smile": ("The classic V: lows and highs up, mids scooped", 1, -2.0, [
        ("LSHLF", 80, 4, 0.71), ("BELL", 800, -3, 0.7), ("HSHLF", 8000, 4, 0.71)]),
    # ── effects ──
    "telephone": ("Phone line: 400 Hz to 3 kHz, honky", 0, 3.0, [
        ("LC48", 400, 0, 0.9), ("BELL", 1500, 4, 1.5), ("HC48", 3000, 0, 0.9)]),
    "am-radio": ("AM radio: soft band-limit, midrange push", 0, 2.0, [
        ("LC12", 200, 0, 0.71), ("BELL", 1000, 3, 0.8), ("HC12", 5000, 0, 0.71)]),
    "dark-room": ("Muffled, through the wall: a resonant 48 dB high cut", 0, 0.0, [
        ("LC12", 40, 0, 0.71), ("HC48", 700, 0, 1.4)]),
    "hum-50": ("Mains hum out at 50 Hz and its harmonics (Europe)", 0, 0.0, [
        ("NOTCH", 50, 0, 8), ("NOTCH", 100, 0, 8), ("NOTCH", 150, 0, 8),
        ("NOTCH", 200, 0, 8), ("NOTCH", 250, 0, 8), ("LC12", 30, 0, 0.71)]),
    "hum-60": ("Mains hum out at 60 Hz and its harmonics (Americas)", 0, 0.0, [
        ("NOTCH", 60, 0, 8), ("NOTCH", 120, 0, 8), ("NOTCH", 180, 0, 8),
        ("NOTCH", 240, 0, 8), ("NOTCH", 300, 0, 8), ("LC12", 30, 0, 0.71)]),
}


def assign(filters):
    """Filter -> slot by nearest default frequency (log distance), in
    frequency order so the result is stable."""
    free = set(range(8))
    out = {}
    for f in sorted(filters, key=lambda f: f[1]):
        best = min(free, key=lambda s: abs(math.log(f[1] / SLOT_HZ[s])))
        free.remove(best)
        out[best] = f
    # Keep the slots in frequency order: re-deal the used ones sorted.
    used = sorted(out)
    fs = sorted(out.values(), key=lambda f: f[1])
    return dict(zip(used, fs))


def build(name, note, adapt, out_db, filters):
    assert len(filters) <= 8, name
    slots = assign(filters)
    params = {}
    for s in range(8):
        n = s + 1
        if s in slots:
            t, hz, g, q = slots[s]
            on = 1
        else:
            t, hz, g, q, on = ("BELL", SLOT_HZ[s], 0, 0.71, 0)
        params[f"geq-t{n}"] = TYPES.index(t)
        params[f"geq-f{n}"] = hz
        params[f"geq-q{n}"] = q
        params[f"geq-b{n}"] = g
        params[f"geq-on{n}"] = on
    params["geq-adapt"] = adapt
    params["geq-out"] = out_db
    return {"slab": "preset", "schema": 1, "machine": "geq8", "note": note, "params": params}


def main():
    root = os.path.join(os.path.dirname(__file__), "..", "..", "machines", "geq8", "presets")
    os.makedirs(root, exist_ok=True)
    for name, (note, adapt, out_db, filters) in PRESETS.items():
        with open(os.path.join(root, name + ".preset"), "w") as fh:
            json.dump(build(name, note, adapt, out_db, filters), fh)
            fh.write("\n")
    print(f"wrote {len(PRESETS)} presets to machines/geq8/presets")


if __name__ == "__main__":
    main()
