#!/usr/bin/env python3
"""Import the Ambika golden card's programs as Slab presets.

Usage: import_programs.py PATH/TO/goldencard

The card is controller/data/goldencard in https://github.com/pichenettes/ambika
(also ambika_golden_card.zip on the Mutable Instruments archive); each
PROGRAM/BANK/<bank>/<nnn>.PRO is a RIFF file with the program's name and its
112-byte Patch (common/patch.h). Writes machines/ambika/presets/<bank>/<nnn>-<name>.preset.

What does not carry over: the sequencer and arpeggiator sources (SEQ1, SEQ2,
ARP: their slots are zeroed), the step sequences, an LFO that retriggers an
envelope (it runs free), and tempo-synced LFO rates, which become the free
rate of the same cycle at 120 bpm [docs/48].
"""
import json
import math
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "machines", "ambika", "presets")

# firmware source index -> panel index (None: no such source here)
SRC = {i: i for i in range(11)}
SRC.update({11: None, 12: None, 13: None})
SRC.update({14: 11, 15: 12, 16: 13, 17: 14, 18: 15, 19: 16, 20: 17, 21: 18, 22: 19, 23: 20})
SRC.update({24 + k: 21 + k for k in range(7)})
TICKS = [96, 72, 64, 48, 36, 32, 24, 16, 12, 8, 6, 4, 3, 2, 1]
SYNCED = 15


def s8(b):
    return b - 256 if b > 127 else b


def rate(raw):
    """A firmware LFO rate byte as the panel's 0..127 free rate."""
    if raw >= SYNCED:
        return min(raw - SYNCED, 127), False
    hz = 48.0 / TICKS[raw]  # 24 ppqn at 120 bpm
    idx = round(127 * math.log(hz / 0.0625) / math.log(1600.0))
    return max(0, min(127, idx)), True


def parse(path):
    d = open(path, "rb").read()
    assert d[:4] == b"RIFF" and d[8:12] == b"MBKS"
    pos, name, patch = 12, "", None
    while pos + 8 <= len(d):
        tag, size = d[pos:pos + 4], struct.unpack("<I", d[pos + 4:pos + 8])[0]
        body = d[pos + 8:pos + 8 + size]
        if tag == b"name":
            name = body.rstrip(b" \x00").decode("ascii", "replace").strip()
        elif tag == b"obj " and patch is None:
            patch = body[4:4 + 112]
        pos += 8 + size + (size & 1)
    return name, patch


def convert(bank, num, name, b):
    p = {}
    for n in (1, 2):
        o = (n - 1) * 4
        p[f"am-o{n}-shape"] = min(b[o], 37)
        p[f"am-o{n}-prm"] = b[o + 1]
        p[f"am-o{n}-range"] = s8(b[o + 2])
        p[f"am-o{n}-tune"] = s8(b[o + 3])
    p["am-balance"], p["am-op"], p["am-mixprm"] = b[8], min(b[9], 5), b[10]
    p["am-sub-shape"], p["am-sub-lvl"], p["am-noise"] = min(b[11], 10), b[12], b[13]
    p["am-fuzz"], p["am-crush"] = b[14], b[15]
    p["am-cutoff"], p["am-reso"], mode = b[16], b[17], b[18]
    p["am-fmode"] = min(mode, 3)
    p["am-board"] = 1 if mode else 0
    p["am-env2"], p["am-lfo2"] = s8(b[22]), s8(b[23])
    notes = []
    for k in range(3):
        e = 24 + 8 * k
        p[f"am-e{k+1}-a"], p[f"am-e{k+1}-d"], p[f"am-e{k+1}-s"], p[f"am-e{k+1}-r"] = b[e:e + 4]
        p[f"am-l{k+1}-shape"] = min(b[e + 4], 19)
        r, synced = rate(b[e + 5])
        p[f"am-l{k+1}-rate"] = r
        if synced:
            notes.append(f"LFO {k+1} was tempo-synced")
        mode = b[e + 7]
        p[f"am-l{k+1}-trig"] = 1 if mode == 1 else 0
        if mode == 2:
            notes.append(f"LFO {k+1} retriggered ENV {k+1} each cycle")
    p["am-vl-shape"], p["am-vl-rate"] = min(b[48], 19), min(b[49], 127)
    dropped = 0
    for i in range(14):
        s, d, a = b[50 + 3 * i], b[51 + 3 * i], s8(b[52 + 3 * i])
        m = SRC.get(s)
        if m is None or d > 18:
            if a:
                dropped += 1
            m, d, a = 0, 0, 0
        p[f"am-m{i+1}-src"], p[f"am-m{i+1}-dst"], p[f"am-m{i+1}-amt"] = m, d, a
    if dropped:
        notes.append(f"{dropped} sequencer/arp routing(s) dropped")
    for i in range(4):
        x, y, op = b[92 + 3 * i], b[93 + 3 * i], b[94 + 3 * i]
        p[f"am-d{i+1}-in1"], p[f"am-d{i+1}-in2"] = SRC.get(x) or 0, SRC.get(y) or 0
        p[f"am-d{i+1}-op"] = min(op, 10)
    p.update({"am-volume": 100, "am-legato": 0, "am-porta": 0, "am-gain": 0.5})
    note = f"{name} (Ambika golden card, bank {bank} {num:03d})."
    if notes:
        note += " " + "; ".join(notes) + "."
    return {"slab": "preset", "schema": 1, "machine": "ambika", "note": note, "params": p}


def main():
    card = sys.argv[1]
    os.makedirs(OUT, exist_ok=True)
    count = 0
    for bank in sorted(os.listdir(os.path.join(card, "PROGRAM", "BANK"))):
        d = os.path.join(card, "PROGRAM", "BANK", bank)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if not f.endswith(".PRO"):
                continue
            num = int(f[:3])
            name, patch = parse(os.path.join(d, f))
            if patch is None or len(patch) < 112:
                continue
            slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "program"
            os.makedirs(os.path.join(OUT, bank), exist_ok=True)
            with open(os.path.join(OUT, bank, f"{num:03d}-{slug}.preset"), "w") as fh:
                json.dump(convert(bank, num, name, patch), fh)
                fh.write("\n")
            count += 1
    print(count, "presets")


main()
