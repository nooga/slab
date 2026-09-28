"""multi2 presets (docs/24 §multi2 presets): character fixed by intent, each
band's THRESH solved from that band's own level on real material, OUT for
a level target.

A band's level is read from the dry stem split with the crossover's LR4
magnitudes (an FFT mask - phase doesn't matter for a level), as the peak
of each 10 ms window over the windows where the mix is above -45 dBFS.
`gr` is the static gain reduction wanted at the band's loud level (its
p90 window peak): THRESH = L90 - gr / (1 - 1/ratio). OUT is then solved
with the bench's `file` case so the output RMS matches the input's."""
import json, os, sys, wave
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tune import avg, show, DRY

MIX = ["glass_horizon.MIX", "paper_boulevard.MIX", "voltage_riot.MIX"]
BANDS = ("mlo", "mmid", "mhi")
D = {
 # mastering balance: every band a little, low slow, top catching peaks
 "master-balance": dict(x=(120, 3000), t=(0.01, 0.15), up=0.0, mat=MIX,
                        b=[(2.0, 2.5), (1.5, 1.0), (2.0, 1.5)]),
 # hold kick and bass to one level; mid and top untouched
 "low-control":    dict(x=(150, 3000), t=(0.005, 0.1), up=0.0, mat=MIX,
                        b=[(3.0, 4.0), (1.0, 0), (1.0, 0)]),
 # a fast top-band limiter for cymbals and harsh synths
 "de-harsh":       dict(x=(120, 4500), t=(0.001, 0.08), up=0.0, mat=MIX,
                        b=[(1.0, 0), (1.0, 0), (4.0, 3.0)]),
 # dense and loud: all bands 4:1, quick, upward lift under the quiet parts
 "radio":          dict(x=(120, 2500), t=(0.003, 0.08), up=0.4, mat=MIX,
                        b=[(4.0, 4.0), (4.0, 3.0), (4.0, 3.0)]),
 # bring the detail up: gentle downward, strong upward under it
 "upward-lift":    dict(x=(120, 3000), t=(0.01, 0.2), up=0.8, mat=MIX,
                        b=[(1.5, 1.0), (1.5, 1.0), (1.5, 1.0)]),
}

def load(stem):
    w = wave.open(f"{DRY}/{stem}.wav")
    raw = np.frombuffer(w.readframes(w.getnframes()), dtype=np.uint8).reshape(-1, 3)
    v = (raw[:, 0].astype(np.int32) | (raw[:, 1].astype(np.int32) << 8) | (raw[:, 2].astype(np.int32) << 16))
    v = np.where(v >= 1 << 23, v - (1 << 24), v).astype(np.float64) / (1 << 23)
    return v.reshape(-1, w.getnchannels()), w.getframerate()

_levels = {}
def band_l90(stem, xlo, xhi):
    key = (stem, xlo, xhi)
    if key in _levels: return _levels[key]
    x, sr = load(stem)
    W = sr // 100
    n = (len(x) // W) * W
    x = x[:n]
    act = 20 * np.log10(np.sqrt((x ** 2).reshape(-1, W, 2).mean(axis=(1, 2))) + 1e-12) > -45
    f = np.fft.rfftfreq(n, 1 / sr)
    lo4, hi4 = (f / xlo) ** 4, (f / xhi) ** 4
    lp_lo, hp_lo = 1 / (1 + lo4), lo4 / (1 + lo4)
    lp_hi, hp_hi = 1 / (1 + hi4), hi4 / (1 + hi4)
    X = np.fft.rfft(x, axis=0)
    out = []
    for m in (lp_lo, hp_lo * lp_hi, hp_lo * hp_hi):
        b = np.fft.irfft(X * m[:, None], n, axis=0)
        pk = np.abs(b).max(axis=1).reshape(-1, W).max(axis=1)
        out.append(float(np.percentile(20 * np.log10(pk[act] + 1e-12), 90)))
    _levels[key] = out
    return out

def params_of(d):
    xlo, xhi = d["x"]
    ls = np.mean([band_l90(s, xlo, xhi) for s in d["mat"]], axis=0)
    p = {"multi-xlo": xlo, "multi-xhi": xhi, "multi-atk": d["t"][0], "multi-rel": d["t"][1],
         "multi-up": d["up"], "multi-mix": 1, "multi-out": 0.0}
    for pre, (r, gr), l90 in zip(BANDS, d["b"], ls):
        p[f"{pre}-ratio"] = r
        p[f"{pre}-gain"] = 0
        # a band left at 1:1 still gets a threshold for UP and the display
        p[f"{pre}-thresh"] = round(float(np.clip(l90 - (gr / (1 - 1 / r) if r > 1 else 6.0), -48, 0)), 1)
    return p, ls

def solve(d):
    p, ls = params_of(d)
    for _ in range(3):
        m, _ = avg(p, d["mat"], machine="multi2", prefix=None)
        p["multi-out"] = round(float(np.clip(p["multi-out"] - (m["out_rms"] - m["in_rms"]), -12, 12)), 1)
    m, _ = avg(p, d["mat"], machine="multi2", prefix=None)
    return p, m, ls

if __name__ == "__main__":
    only = sys.argv[1:] or list(D)
    out = {}
    for n in only:
        p, m, ls = solve(D[n])
        out[n] = p
        print(show(n, m), " L90", [round(float(v), 1) for v in ls],
              {k: v for k, v in p.items() if k.endswith("thresh") or k == "multi-out"}, flush=True)
    json.dump(out, open(os.environ.get("S", "scratch/comp2-presets") + "/designed_multi2.json", "w"), indent=1)
