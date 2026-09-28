"""bus2 presets (docs/24 §bus2 presets): character fixed by intent, THRESH
solved on real material for a GR target, MAKEUP for a level target, as
design.py does for comp2. Switches are option indices:
ratio 2/4/10; atk .1/.3/1/3/10/30 ms; rel .1/.3/.6/1.2 s/AUTO; hpf OFF/60/90/150/250."""
import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tune import avg, show

DRUMS = ["glass_horizon.DRUMS", "paper_boulevard.DRUMS", "voltage_riot.DRUMS"]
MIX = ["glass_horizon.MIX", "paper_boulevard.MIX", "voltage_riot.MIX"]
AUTO = 4
D = {
 # glue a kit: 4:1, 10 ms lets the stick through, AUTO holds a floor
 "drum-bus":    dict(p=dict(ratio=1, atk=4, rel=AUTO, hpf=2, color=0.25, mix=1), mat=DRUMS, key="g01", gr=5.0, lvl=0),
 # the classic mix-bus setting: 2:1, 30 ms, AUTO, 2 dB on the loud parts
 "mix-glue":    dict(p=dict(ratio=0, atk=5, rel=AUTO, hpf=2, color=0.1, mix=1), mat=MIX, key="g10", gr=2.0, lvl=0),
 # master: lighter, clean
 "master-glue": dict(p=dict(ratio=0, atk=5, rel=AUTO, hpf=1, color=0.0, mix=1), mat=MIX, key="g10", gr=1.2, lvl=0),
 # parallel crush: 10:1, fastest attack, .1 s, dirty, blended under
 "drum-crush":  dict(p=dict(ratio=2, atk=0, rel=0, hpf=0, color=0.6, mix=0.4), mat=DRUMS, key="g01", gr=15.0, lvl=1.5),
 # dance breathing: 4:1, 1 ms, .3 s, no HPF so the kick drives it
 "pump":        dict(p=dict(ratio=1, atk=2, rel=1, hpf=0, color=0.15, mix=1), mat=MIX, key="g10", gr=6.0, lvl=0),
}

def run(params, mat):
    return avg(params, mat, machine="bus2", prefix="bus")

def solve(d):
    p = dict(d["p"], makeup=0)
    wet = dict(p, mix=1, makeup=0)
    lo, hi = -36.0, 0.0
    for _ in range(9):
        mid = (lo + hi) / 2
        m, _ = run(dict(wet, thresh=mid), d["mat"])
        if -m[d["key"]] > d["gr"]: lo = mid
        else: hi = mid
    p["thresh"] = round((lo + hi) / 2, 1)
    for _ in range(4):
        m, _ = run(p, d["mat"])
        p["makeup"] = round(max(0.0, min(15.0, p["makeup"] + d["lvl"] - (m["out_rms"] - m["in_rms"]))), 1)
    m, _ = run(p, d["mat"])
    return p, m

if __name__ == "__main__":
    only = sys.argv[1:] or list(D)
    out = {}
    for n in only:
        p, m = solve(D[n])
        out[n] = p
        print(show(n, m), " ", {k: p[k] for k in ("thresh", "makeup")}, flush=True)
    json.dump(out, open(os.environ.get("S", "scratch/comp2-presets") + "/designed_bus2.json", "w"), indent=1)
