"""tape2 presets (docs/26 §Presets): format and wear fixed by intent, OUT
solved on real material for level-neutral output, as the compressor
tools solve MAKEUP. Switches take the option index: mode 0 CASS I,
1 CASS II, 2 CASS IV, 3 VHS LIN, 4 VHS HIFI; mains 0 50 Hz, 1 60 Hz."""
import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tune import avg, show

DRUMS = ["glass_horizon.DRUMS", "paper_boulevard.DRUMS", "voltage_riot.DRUMS"]
PADS = ["glass_horizon.PAD", "paper_boulevard.PAD", "paper_boulevard.E.PIANO"]
MIX = ["glass_horizon.MIX", "paper_boulevard.MIX", "voltage_riot.MIX"]
CI, CII, CIV, VLIN, VHIFI = 0, 1, 2, 3, 4
D = {
 # a fresh chrome tape on a good deck, Dolby B on: glue and a soft top on a mix
 "chrome-glue":   dict(p=dict(mode=CII, wear=0.05, drive=3, bias=0.6, wow=0.2, flutter=0.2, hiss=0.35, nr=1), mat=MIX),
 # a four-track demo: type I pushed, a little worn
 "four-track":    dict(p=dict(mode=CI, wear=0.35, drive=4, bias=0.5, hiss=0.5, nr=1), mat=DRUMS),
 # metal tape driven hard on drums: compression before the top goes
 "metal-hot":     dict(p=dict(mode=CIV, wear=0.1, drive=12, bias=0.65, hiss=0.3), mat=DRUMS),
 # a walkman with a tired belt: wobble, hiss, Dolby out of step
 "walkman":       dict(p=dict(mode=CI, wear=0.6, drive=2, bias=0.45, wow=0.55, flutter=0.5, hiss=0.6, nr=1), mat=PADS),
 # a tape that went through the washing machine
 "chewed":        dict(p=dict(mode=CI, wear=1.0, drive=4, bias=0.3, wow=0.6, flutter=0.6, drops=0.7, hiss=0.6, hum=0.3, nr=1), mat=PADS),
 # a rental VHS: mono linear track, dull, hum and buzz
 "vhs-rental":    dict(p=dict(mode=VLIN, wear=0.6, drive=3, hiss=0.5, hum=0.35), mat=MIX),
 # a Hi-Fi dub of a dub: clean band, the compander breathing, buzz
 "vhs-hifi-dub":  dict(p=dict(mode=VHIFI, wear=0.6, drive=0, hiss=0.5, hum=0.15, drops=0.2), mat=MIX),
}

def run(params, mat):
    return avg(params, mat, machine="tape2", prefix="tape")

def solve(d):
    p = dict(d["p"], out=0.0, mix=1)
    for _ in range(4):
        m, _ = run(p, d["mat"])
        p["out"] = round(max(-12.0, min(12.0, p["out"] - (m["out_rms"] - m["in_rms"]))), 1)
    m, _ = run(p, d["mat"])
    return p, m

if __name__ == "__main__":
    only = sys.argv[1:] or list(D)
    out = {}
    for n in only:
        p, m = solve(D[n])
        out[n] = p
        print(show(n, m), " ", {"out": p["out"]}, flush=True)
    json.dump(out, open(os.environ.get("S", "scratch/comp2-presets") + "/designed_tape2.json", "w"), indent=1)
