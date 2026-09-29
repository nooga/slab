#!/usr/bin/env python3
"""Convert a DX7 32-voice bulk-dump .syx into FM-86 presets.

Offline tool (not part of the DAW frame). FM-86's parameters are the
DX7's own (0..99 levels and rates, coarse / fine / detune, the keyboard
scaling, sensitivities, LFO and pitch EG), so a voice is copied across
byte for byte; the engine [kernels/06-voices/fm86_voice.fy] does what
the DX7 did with them, after Dexed's msfa.

    python3 dx7_import.py BANK.syx OUT-DIR

Packed voice layout (128 bytes; operators stored OP6 first, 17 bytes
each; then the globals at 102): see voice_params.
"""
import sys, os, json, re

CURVES = 4


def voice_params(v):
    p = {}
    for n in range(1, 7):                   # DX7 OP n is stored at (6 - n) * 17
        o = v[(6 - n) * 17:(6 - n) * 17 + 17]
        q = f"op{n}-"
        for k in range(4):
            p[q + f"r{k + 1}"] = o[k] & 0x7F
            p[q + f"l{k + 1}"] = o[4 + k] & 0x7F
        p[q + "bp"] = o[8] & 0x7F
        p[q + "ld"] = o[9] & 0x7F
        p[q + "rd"] = o[10] & 0x7F
        p[q + "lc"] = o[11] & 3
        p[q + "rc"] = (o[11] >> 2) & 3
        p[q + "rs"] = o[12] & 7
        p[q + "det"] = ((o[12] >> 3) & 15) - 7
        p[q + "ams"] = o[13] & 3
        p[q + "kvs"] = (o[13] >> 2) & 7
        p[q + "ol"] = o[14] & 0x7F
        p[q + "mode"] = o[15] & 1
        p[q + "coarse"] = (o[15] >> 1) & 31
        p[q + "fine"] = o[16] & 0x7F
    for k in range(4):
        p[f"pr{k + 1}"] = v[102 + k] & 0x7F
        p[f"pl{k + 1}"] = v[106 + k] & 0x7F
    p["algo"] = (v[110] & 31) + 1
    p["feedback"] = v[111] & 7
    p["oks"] = (v[111] >> 3) & 1
    p["lfo-speed"] = v[112] & 0x7F
    p["lfo-delay"] = v[113] & 0x7F
    p["lfo-pmd"] = v[114] & 0x7F
    p["lfo-amd"] = v[115] & 0x7F
    p["lfo-sync"] = v[116] & 1
    p["lfo-wave"] = (v[116] >> 1) & 7
    p["pms"] = (v[116] >> 4) & 7
    p["transpose"] = (v[117] & 0x7F) - 24   # 24 = C3, no transpose
    # clamp into the controls' ranges (some cartridges carry junk bits)
    for k, lim in (("lfo-wave", 5), ("feedback", 7), ("pms", 7)):
        p[k] = min(p[k], lim)
    for k in list(p):
        if k.endswith(("-r1", "-r2", "-r3", "-r4", "-l1", "-l2", "-l3", "-l4", "-bp", "-ld", "-rd", "-ol", "-fine")) or \
           k in ("lfo-speed", "lfo-delay", "lfo-pmd", "lfo-amd") or re.fullmatch(r"p[rl]\d", k):
            p[k] = min(p[k], 99)
    p["transpose"] = max(-24, min(24, p["transpose"]))
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
        print(f"{idx + 1:2d} {name.strip():12} -> {stem}.preset  alg {params['algo']}")


if __name__ == "__main__":
    main()
