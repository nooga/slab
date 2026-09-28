import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tune import avg, show, MATERIAL
# Character by intent (docs/24 §Presets): fixed; THRESH solved for the GR
# target, MAKEUP for the level target.  key = which GR statistic.
D = {
 "bass-leveler":    dict(p=dict(ratio=4, knee=6, atk=0.003, rel=0.25, det=0, hpf=20, mix=1), key="gr50", gr=3.5, lvl=0),
 "vocal-leveler":   dict(p=dict(ratio=3, knee=10, atk=0.002, rel=0.15, det=0, hpf=80, mix=1), key="gr50", gr=3.5, lvl=0),
 "dialog-leveler":  dict(p=dict(ratio=6, knee=8, atk=0.002, rel=0.15, det=0, hpf=100, mix=1), key="gr50", gr=5.5, lvl=0),
 "smooth-pad-comp": dict(p=dict(ratio=2, knee=12, atk=0.025, rel=0.30, det=1, hpf=60, mix=1), key="gr50", gr=2.0, lvl=0),
 "dry-drum-punch":  dict(p=dict(ratio=4, knee=4, atk=0.010, rel=0.06, det=0, hpf=20, mix=1), key="gr99", gr=5.0, lvl=0),
 "drum-smash":      dict(p=dict(ratio=10, knee=3, atk=0.0003, rel=0.03, det=0, hpf=20, mix=0.5), key="gr99", gr=18.0, lvl=1.5),
 "rude-clap":       dict(p=dict(ratio=8, knee=2, atk=0.0001, rel=0.02, det=0, hpf=20, mix=0.9), key="gr99", gr=16.0, lvl=0),
 "pump":            dict(p=dict(ratio=4, knee=3, atk=0.003, rel=0.12, det=0, hpf=20, mix=1), key="gr90", gr=7.0, lvl=0),
 "audible-pump":    dict(p=dict(ratio=8, knee=2, atk=0.008, rel=0.22, det=0, hpf=20, mix=1), key="gr90", gr=9.5, lvl=0),
 "bus-glue":        dict(p=dict(ratio=2, knee=6, atk=0.010, rel=0.15, det=0, hpf=90, mix=1), key="gr90", gr=2.5, lvl=0),
 "gentle-bus-glue": dict(p=dict(ratio=2, knee=9, atk=0.030, rel=0.20, det=0, hpf=90, mix=1), key="gr90", gr=1.8, lvl=0),
 "gentle-glue":     dict(p=dict(ratio=1.5, knee=12, atk=0.030, rel=0.30, det=1, hpf=60, mix=1), key="gr90", gr=1.0, lvl=0),
 "drum-bus":        dict(p=dict(ratio=4, knee=4, atk=0.010, rel=0.15, det=0, hpf=90, mix=1), key="gr99", gr=4.0, lvl=0),
 "soft-master-glue":dict(p=dict(ratio=2, knee=12, atk=0.020, rel=0.30, det=1, hpf=60, mix=1), key="gr90", gr=2.0, lvl=0),
}

GKEY = {"gr50": "g50", "gr90": "g10", "gr99": "g01"}

def solve(name, d):
    p = dict(d["p"], makeup=0)
    wet = dict(p, mix=1, makeup=0)  # solve on the compressor's own GR
    lo, hi = -48.0, 0.0  # more threshold -> less GR
    for _ in range(9):
        mid = (lo + hi) / 2
        m, _ = avg(dict(wet, thresh=mid), MATERIAL[name])
        if -m[GKEY[d["key"]]] > d["gr"]: lo = mid
        else: hi = mid
    p["thresh"] = round((lo + hi) / 2, 1)
    for _ in range(4):
        m, _ = avg(p, MATERIAL[name])
        p["makeup"] = round(max(0.0, min(24.0, p["makeup"] + d["lvl"] - (m["out_rms"] - m["in_rms"]))), 1)
    m, per = avg(p, MATERIAL[name])
    return p, m

if __name__ == "__main__":
  only = sys.argv[1:] or list(D)
  out = {}
  for n in only:
    p, m = solve(n, D[n])
    out[n] = p
    print(show(n, m), " ", {k: p[k] for k in ("thresh", "makeup")}, flush=True)
  json.dump(out, open(os.environ.get("S", "scratch/comp2-presets") + "/designed.json", "w"), indent=1)
