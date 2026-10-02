"""char2 presets (docs/24 §char2 presets): mode and character fixed by
intent, THRESH solved on real material for a GR target (wet, makeup 0),
MAKEUP for a level target, as design_bus2.py does. MODE is an option
index: 0 FET, 1 OPTO, 2 VARI."""
import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tune import avg, show

DRUMS = ["glass_horizon.DRUMS", "paper_boulevard.DRUMS", "voltage_riot.DRUMS"]
BASS = ["glass_horizon.BASS", "paper_boulevard.BASS", "voltage_riot.BASS"]
PADS = ["glass_horizon.PAD", "paper_boulevard.PAD", "glass_horizon.CHOIR", "paper_boulevard.E.PIANO"]
VOICE = ["glass_horizon.VOICE"]
MIX = ["glass_horizon.MIX", "paper_boulevard.MIX", "voltage_riot.MIX"]
FET, OPTO, VARI, SMUSH = 0, 1, 2, 3
ANALOG, D90S, D80S = 0, 1, 2   # switches take the option index: rpm 0 33, 1 45, 2 78
# LO-FI and WOW: off while THRESH is solved [their delay and filtering
# break the bench's sample-wise gain], on for the level solve and the
# final measurement
FX = ("lofi", "ltype", "noise", "wow", "rpm")
D = {
 # 1176 all-buttons flavour for parallel smash: 20:1, fastest, dirty, under the dry kit
 "fet-smash":  dict(p=dict(mode=FET, ratio=20, atk=0.00005, rel=0.15, drive=0.7, mix=0.4), mat=DRUMS, key="g01", gr=14.0, lvl=1.5),
 # FET punch: 4:1, 3 ms lets the stick through, quick release, a little grit
 "fet-punch":  dict(p=dict(mode=FET, ratio=4, atk=0.003, rel=0.1, drive=0.3, mix=1), mat=DRUMS, key="g01", gr=5.0, lvl=0),
 # LA-2A on a vocal: 3:1, the opto release, light warmth
 "opto-vocal": dict(p=dict(mode=OPTO, ratio=3, atk=0.01, rel=1.0, drive=0.3, mix=1), mat=VOICE, key="g10", gr=4.0, lvl=0),
 # LA-2A on bass: 4:1, holds the line even; HPF off - the bass is the signal
 "opto-bass":  dict(p=dict(mode=OPTO, ratio=4, atk=0.01, rel=0.8, drive=0.35, mix=1), mat=BASS, key="g10", gr=4.0, lvl=0),
 # pads and keys: gentle opto levelling
 "opto-smooth": dict(p=dict(mode=OPTO, ratio=2.5, atk=0.01, rel=1.5, drive=0.15, mix=1), mat=PADS, key="g10", gr=2.5, lvl=0),
 # Fairchild on the mix bus: wide knee, slow floor, warm
 "vari-glue":  dict(p=dict(mode=VARI, ratio=2, atk=0.01, rel=0.4, drive=0.25, hpf=60, mix=1), mat=MIX, key="g10", gr=2.0, lvl=0),
 # vari-mu on drums: thick and warm, 4:1 at the top of its knee
 "vari-drums": dict(p=dict(mode=VARI, ratio=4, atk=0.003, rel=0.3, drive=0.5, hpf=60, mix=1), mat=DRUMS, key="g01", gr=5.0, lvl=0),
 # the SP-303 Vinyl Sim on a drum loop: deep squash, the room and hiss breathe up, a little wow
 "smush-vinyl": dict(p=dict(mode=SMUSH, ratio=20, atk=0.0015, rel=0.07, drive=0.3, mix=1, lofi=0.5, ltype=ANALOG, noise=0.3, wow=0.15), mat=DRUMS, key="g01", gr=15.0, lvl=0),
 # SP-1200 crunch: 12-bit 26 kHz grit under a hard squash, no wow
 "smush-1200": dict(p=dict(mode=SMUSH, ratio=20, atk=0.001, rel=0.06, drive=0.2, mix=1, lofi=0.4, ltype=D80S, noise=0.15), mat=DRUMS, key="g01", gr=12.0, lvl=0),
 # slam: everything flattened, dirty, for a parallel bus under the kit
 "smush-slam": dict(p=dict(mode=SMUSH, ratio=20, atk=0.0005, rel=0.05, drive=0.6, mix=0.5), mat=DRUMS, key="g01", gr=20.0, lvl=1.5),
 # dusty keys: gentle opto levelling into a worn 45 with 90s grit
 "opto-dusty-keys": dict(p=dict(mode=OPTO, ratio=3, atk=0.01, rel=1.0, drive=0.2, mix=1, lofi=0.35, ltype=D90S, noise=0.35, wow=0.45, rpm=1), mat=PADS, key="g10", gr=3.0, lvl=0),
}

def run(params, mat):
    return avg(params, mat, machine="char2", prefix="char")

def solve(d):
    p = dict(d["p"], makeup=0)
    wet = {k: v for k, v in dict(p, mix=1, makeup=0).items() if k not in FX}
    lo, hi = -40.0, 0.0
    for _ in range(9):
        mid = (lo + hi) / 2
        m, _ = run(dict(wet, thresh=mid), d["mat"])
        # SMUSH's auto makeup [char.fy CHAR-SMUSH-AUTO] is in the
        # measured gain; the target is the reduction under it
        auto = 0.5 * -mid * (1 - 1 / p["ratio"]) if p["mode"] == SMUSH else 0.0
        if -m[d["key"]] + auto > d["gr"]: lo = mid
        else: hi = mid
    p["thresh"] = round((lo + hi) / 2, 1)
    for _ in range(4):
        m, _ = run(p, d["mat"])
        p["makeup"] = round(max(0.0, min(24.0, p["makeup"] + d["lvl"] - (m["out_rms"] - m["in_rms"]))), 1)
    m, _ = run(p, d["mat"])
    return p, m

if __name__ == "__main__":
    only = sys.argv[1:] or list(D)
    out = {}
    for n in only:
        p, m = solve(D[n])
        out[n] = p
        print(show(n, m), " ", {k: p[k] for k in ("thresh", "makeup")}, flush=True)
    json.dump(out, open(os.environ.get("S", "scratch/comp2-presets") + "/designed_char2.json", "w"), indent=1)
