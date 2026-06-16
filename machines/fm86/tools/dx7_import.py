#!/usr/bin/env python3
"""Convert a DX7 32-voice bulk-dump .syx into FM-86 presets.

Offline tool (not part of the DAW frame): it reads the packed DX7 sysex format
and maps each voice's parameters to FM-86 control values, writing one
`<name>.preset` JSON per voice.

    python3 dx7_import.py ROM1A.syx ../presets

This is a Phase-1 mapping for auditioning patches — the DX7 rate/level/output
curves are approximated (documented inline). Tune the constants below by ear.

DX7 packed voice = 128 bytes, operators stored OP6..OP1 (17 bytes each), then
global params; layout from the DX7 MIDI spec.
"""
import sys, os, json, re

# ── tunable mapping constants ────────────────────────────────────────────
MASTER       = 0.6     # summed-carrier headroom (kernel clamps at +/-1)
FEEDBACK_MAX = 2.0     # DX7 feedback 0..7 -> 0..FEEDBACK_MAX (fm fb amount)
STEP_MIN     = 0.00001 # EG per-sample dB step at DX7 rate 0 (slowest)
STEP_MAX     = 0.08    # ... at DX7 rate 99 (fastest); matches fm86.fy r1-4 range
RATIO_MAX    = 32.0    # fm86.fy ratio range cap

def rate_to_step(r):           # DX7 0..99 (slow..fast) -> exponential per-sample step
    return STEP_MIN * (STEP_MAX / STEP_MIN) ** (r / 99.0)

def coarse_fine_ratio(coarse, fine):
    base = 0.5 if coarse == 0 else float(coarse)
    return min(base * (1.0 + fine / 100.0), RATIO_MAX)

def voice_params(v):
    """v: 128 packed bytes -> {control_id: value} for FM-86."""
    p = {
        "algo": (v[110] & 31) + 1,
        "feedback": round((v[111] & 7) / 7.0 * FEEDBACK_MAX, 4),
        "master": MASTER,
    }
    # FM-86 op i (0..5) == DX7 OP(i+1); packed stores OP6 first, so OP(i+1)
    # is at offset (5 - i) * 17.
    for i in range(6):
        op = v[(5 - i) * 17:(5 - i) * 17 + 17]
        r1, r2, r3, r4 = op[0], op[1], op[2], op[3]
        l1, l2, l3, l4 = op[4], op[5], op[6], op[7]
        outlevel = op[14]
        osc = op[15]
        mode = osc & 1               # 0 = ratio, 1 = fixed
        coarse = (osc >> 1) & 31
        fine = op[16]
        ratio = 1.0 if mode == 1 else coarse_fine_ratio(coarse, fine)
        n = i + 1
        p[f"op{n}-ratio"] = round(max(0.25, ratio), 4)
        p[f"op{n}-level"] = round(outlevel / 99.0, 4)
        p[f"op{n}-r1"] = round(rate_to_step(r1), 6)
        p[f"op{n}-r2"] = round(rate_to_step(r2), 6)
        p[f"op{n}-r3"] = round(rate_to_step(r3), 6)
        p[f"op{n}-r4"] = round(rate_to_step(r4), 6)
        p[f"op{n}-l1"] = round(l1 / 99.0, 4)
        p[f"op{n}-l2"] = round(l2 / 99.0, 4)
        p[f"op{n}-l3"] = round(l3 / 99.0, 4)
        p[f"op{n}-l4"] = round(l4 / 99.0, 4)
    return p

def parse_bulk(data):
    """Yield (name, 128-byte voice) for a 32-voice bulk dump."""
    assert data[0] == 0xF0 and data[3] == 0x09, "not a DX7 32-voice bulk dump"
    body = data[6:6 + 4096]
    for vi in range(32):
        v = body[vi * 128:(vi + 1) * 128]
        name = bytes(v[118:128]).decode("ascii", "replace").rstrip()
        yield name, v

def slug(name, idx):
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or f"voice-{idx + 1}"

def main():
    if len(sys.argv) != 3:
        print("usage: dx7_import.py <bank.syx> <out-dir>", file=sys.stderr)
        sys.exit(2)
    data = open(sys.argv[1], "rb").read()
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    seen = {}
    for idx, (name, v) in enumerate(parse_bulk(data)):
        params = voice_params(v)
        stem = slug(name, idx)
        seen[stem] = seen.get(stem, 0) + 1
        if seen[stem] > 1:
            stem = f"{stem}-{seen[stem]}"
        doc = {"schema": 1, "machine": "fm86",
               "note": f"DX7 import: {name.strip()} (alg {params['algo']})",
               "params": params}
        with open(os.path.join(out, stem + ".preset"), "w") as f:
            f.write(json.dumps(doc))
        print(f"{idx + 1:2d} {name.strip():12} -> {stem}.preset")

if __name__ == "__main__":
    main()
