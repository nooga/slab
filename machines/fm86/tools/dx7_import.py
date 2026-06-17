#!/usr/bin/env python3
"""Convert a DX7 32-voice bulk-dump .syx into FM-86 presets.

Offline tool (not part of the DAW frame). Reads the packed DX7 sysex format and
maps each voice to FM-86 control values, writing one `<name>.preset` JSON.

    python3 dx7_import.py ROM1A.syx ../presets

Mapping follows Dexed/msfa (the open DX7 emulation) rather than naive linear
scaling — the DX7 output level and EG levels are EXPONENTIAL (~6 dB per 8 raw
levels, via Env::scaleoutlevel), and feedback is `(y0+y1) >> (8 - fb)`:

  * feedback   -> 2^(fb - 7)            (fb7 -> 1.0, fb6 -> 0.5, fb0 -> 0)
  * output lvl -> 2^((sol(L) - 127)/8)  carrier = volume; modulator x MOD_INDEX
  * EG level   -> 1 + (sol(L) - 127)/128 in FM-86's dB-domain value (1 = 0 dB)

The DX7 rate->time curve is still a rough exponential (TODO: Dexed qrate/statics
table). Tune the constants below by ear.
"""
import sys, os, json, re, math

# ── tunable mapping constants ────────────────────────────────────────────
MASTER_BASE = 0.75    # divided by the summed carrier level for headroom
MOD_INDEX   = 2.0     # extra output scaling for modulators (index, not volume)
OL_MAX      = 2.5     # matches fm86.fy op-level range
# EG per-sample step. Calibrated to DX7 segment times: rate 0 ~ 40 s full
# traversal, rate 99 ~ a few ms (at 48 kHz). step(rate) = MIN*(MAX/MIN)^(r/99).
# (Previously ~10x too fast, so notes only played their attack.)
STEP_MIN    = 0.0000005 # rate 0  -> ~1/(STEP_MIN*48k) ~= 42 s for a full segment
STEP_MAX    = 0.01      # rate 99 -> ~2 ms; both within fm86.fy r1-4 range
RATIO_MAX   = 32.0

# Carriers (output operators) per DX7 algorithm, op numbers 1..6. From the
# validated dx7_algorithms table; everything else in an algorithm is a modulator.
CARRIERS = {
    1:{1,3}, 2:{1,3}, 3:{1,4}, 4:{1,4}, 5:{1,3,5}, 6:{1,3,5}, 7:{1,3}, 8:{1,3},
    9:{1,3}, 10:{1,4}, 11:{1,4}, 12:{1,3}, 13:{1,3}, 14:{1,3}, 15:{1,3}, 16:{1},
    17:{1}, 18:{1}, 19:{1,4,5}, 20:{1,2,4}, 21:{1,2,4,5}, 22:{1,3,4,5},
    23:{1,2,4,5}, 24:{1,2,3,4,5}, 25:{1,2,3,4,5}, 26:{1,2,4}, 27:{1,2,4},
    28:{1,3,6}, 29:{1,2,3,5}, 30:{1,2,3,6}, 31:{1,2,3,4,5}, 32:{1,2,3,4,5,6},
}

LEVELLUT = [0,5,9,13,17,20,23,25,27,29,31,33,35,37,39,41,42,43,45,46]
def scaleoutlevel(L):                       # Env::scaleoutlevel
    return 28 + L if L >= 20 else LEVELLUT[L]

def out_gain(L):                            # DX7 level (0-99) -> linear gain, 0 dB at 99
    return 2.0 ** ((scaleoutlevel(L) - 127) / 8.0)

def eg_value(L):                            # DX7 EG level -> FM-86 dB-domain value (1 = 0 dB)
    return max(0.0, min(1.0, 1.0 + (scaleoutlevel(L) - 127) / 128.0))

def rate_to_step(r):                        # DX7 0..99 (slow..fast) -> per-sample step (rough)
    return STEP_MIN * (STEP_MAX / STEP_MIN) ** (r / 99.0)

def coarse_fine_ratio(coarse, fine):
    base = 0.5 if coarse == 0 else float(coarse)
    return min(base * (1.0 + fine / 100.0), RATIO_MAX)

def voice_params(v):
    algo = (v[110] & 31) + 1
    fb = v[111] & 7
    carriers = CARRIERS[algo]
    p = {"algo": algo, "feedback": round(2.0 ** (fb - 7) if fb else 0.0, 4)}

    sum_carrier_gain = 0.0
    # FM-86 op i (0..5) == DX7 OP(i+1); packed stores OP6 first -> offset (5-i)*17.
    for i in range(6):
        op = v[(5 - i) * 17:(5 - i) * 17 + 17]
        n = i + 1                            # DX7 OP number
        is_carrier = n in carriers
        outlevel = op[14]
        gain = out_gain(outlevel)
        if is_carrier:
            ol = min(gain, OL_MAX)
            sum_carrier_gain += gain
        else:
            ol = min(gain * MOD_INDEX, OL_MAX)
        osc = op[15]
        ratio = 1.0 if (osc & 1) else coarse_fine_ratio((osc >> 1) & 31, op[16])
        p[f"op{n}-ratio"] = round(max(0.25, ratio), 4)
        p[f"op{n}-level"] = round(ol, 5)
        for k in range(4):
            p[f"op{n}-r{k+1}"] = round(rate_to_step(op[k]), 6)
            p[f"op{n}-l{k+1}"] = round(eg_value(op[4 + k]), 4)

    p["master"] = round(max(0.05, min(0.85, MASTER_BASE / max(1.0, sum_carrier_gain))), 4)
    return p

def parse_bulk(data):
    assert data[0] == 0xF0 and data[3] == 0x09, "not a DX7 32-voice bulk dump"
    body = data[6:6 + 4096]
    for vi in range(32):
        v = body[vi * 128:(vi + 1) * 128]
        yield bytes(v[118:128]).decode("ascii", "replace").rstrip(), v

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
        print(f"{idx + 1:2d} {name.strip():12} -> {stem}.preset  master={params['master']} fb={params['feedback']}")

if __name__ == "__main__":
    main()
