"""Mix analysis for a rendered WAV: loudness, peaks, band balance,
stereo width, per-section levels and how hard the master soft-clip is
working. Numbers to steer by, not a substitute for listening.

Loudness is BS.1770 (K-weighted, gated), computed with an FFT-domain
K-filter, so it reads within a few tenths of a dB of a real meter.
"""
import os
import wave

import numpy as np

# Slab's master output stage is linear to ±0.7 and soft-clips above
# (src/engine.zig masterSoftClip). Samples past this are being bent.
KNEE = 0.7

BANDS = [("sub", 20, 60), ("low", 60, 250), ("lowmid", 250, 1000),
         ("mid", 1000, 4000), ("high", 4000, 10000), ("air", 10000, 20000)]


def read_wav(path):
    with wave.open(path, "rb") as w:
        ch, width, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if width == 3:
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        x = (b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8) | (b[:, 2].astype(np.int32) << 16))
        x = np.where(x >= 1 << 23, x - (1 << 24), x) / float(1 << 23)
    elif width == 2:
        x = np.frombuffer(raw, dtype=np.int16) / 32768.0
    else:
        raise ValueError(f"{path}: {width * 8}-bit WAV not supported")
    x = x.reshape(-1, ch)
    if ch == 1:
        x = np.repeat(x, 2, axis=1)
    return x, sr


def _biquad_response(b, a, w):
    z = np.exp(-1j * w)
    return (b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z)


def _k_weight(x, sr):
    """Apply the BS.1770 K-filter (shelf + RLB highpass) in the frequency
    domain. Coefficients derived for any rate per the standard."""
    f0, g, q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
    k = np.tan(np.pi * f0 / sr)
    vh = 10 ** (g / 20)
    vb = vh ** 0.4996667741545416
    a0 = 1 + k / q + k * k
    b1 = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0]
    a1 = [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
    f0, q = 38.13547087602444, 0.5003270373238773
    k = np.tan(np.pi * f0 / sr)
    a0 = 1 + k / q + k * k
    b2 = [1, -2, 1]
    a2 = [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
    n = len(x)
    nfft = 1 << (n - 1).bit_length()
    w = 2 * np.pi * np.fft.rfftfreq(nfft)
    h = _biquad_response(b1, a1, w) * _biquad_response(b2, a2, w)
    out = np.empty_like(x)
    for c in range(x.shape[1]):
        out[:, c] = np.fft.irfft(np.fft.rfft(x[:, c], nfft) * h, nfft)[:n]
    return out


def _blocks(kx, sr, win=0.4, hop=0.1):
    """Mean-square power per 400 ms block (75% overlap), summed over
    channels, with block start times."""
    n, h = int(win * sr), int(hop * sr)
    if len(kx) < n:
        return np.array([np.sum(np.mean(kx ** 2, axis=0))]), np.array([0.0])
    cs = np.vstack([np.zeros((1, kx.shape[1])), np.cumsum(kx ** 2, axis=0)])
    starts = np.arange(0, len(kx) - n + 1, h)
    p = (cs[starts + n] - cs[starts]) / n
    return p.sum(axis=1), starts / sr


def _lufs(p):
    return -0.691 + 10 * np.log10(max(p, 1e-12))


def integrated(powers):
    gated = powers[_lufs_arr(powers) > -70]
    if len(gated) == 0:
        return -70.0
    rel = _lufs(gated.mean()) - 10
    gated = gated[_lufs_arr(gated) > rel]
    return _lufs(gated.mean()) if len(gated) else -70.0


def _lufs_arr(p):
    return -0.691 + 10 * np.log10(np.maximum(p, 1e-12))


def db(x):
    return 20 * np.log10(max(x, 1e-9))


def analyze_wav(path, sections=()):
    """Stats dict for a WAV. `sections` is [(name, start_s, end_s)]."""
    x, sr = read_wav(path)
    # the render adds a 3 s tail; trim trailing silence so it doesn't skew
    loud = np.nonzero(np.max(np.abs(x), axis=1) > 1e-4)[0]
    if len(loud) == 0:
        return {"silent": True, "duration": len(x) / sr}
    x = x[: loud[-1] + 1]
    kx = _k_weight(x, sr)
    powers, times = _blocks(kx, sr)
    peak = float(np.max(np.abs(x)))
    rms = float(np.sqrt(np.mean(x ** 2)))
    lu = integrated(powers)
    short = _blocks(kx, sr, 3.0, 1.0)[0]
    st_max = _lufs(short.max()) if len(short) else lu

    mid = x.mean(axis=1)
    side = (x[:, 0] - x[:, 1]) / 2
    spec = np.abs(np.fft.rfft(mid)) ** 2
    freqs = np.fft.rfftfreq(len(mid), 1 / sr)
    total = spec[(freqs >= 20) & (freqs < 20000)].sum() or 1e-12
    bands = {name: float(spec[(freqs >= lo) & (freqs < hi)].sum() / total) for name, lo, hi in BANDS}

    l, r = x[:, 0], x[:, 1]
    denom = np.sqrt(np.sum(l * l) * np.sum(r * r)) or 1e-12
    corr = float(np.sum(l * r) / denom)
    width = float(np.sqrt(np.mean(side ** 2)) / max(np.sqrt(np.mean(mid ** 2)), 1e-12))

    secs = []
    for name, s0, s1 in sections:
        sel = (times >= s0) & (times + 0.4 <= s1 + 1e-6)
        p = powers[sel]
        a, b = int(s0 * sr), int(min(s1, len(x) / sr) * sr)
        pk = float(np.max(np.abs(x[a:b]))) if b > a else 0.0
        secs.append({"name": name, "lufs": integrated(p) if len(p) else -70.0, "peak_db": db(pk)})

    return {
        "silent": False,
        "duration": len(x) / sr,
        "lufs": lu,
        "short_term_max": st_max,
        "peak_db": db(peak),
        "rms_db": db(rms),
        "crest_db": db(peak) - db(rms),
        "plr": db(peak) - lu,
        "knee_frac": float(np.mean(np.abs(x) > KNEE)),
        "bands": bands,
        "correlation": corr,
        "width": width,
        "sections": secs,
    }


def advice(s):
    """Plain-language flags for the numbers most likely to be wrong."""
    out = []
    if s["silent"]:
        return ["the render is silent — check machine ids, mutes and that clips have notes"]
    if s["lufs"] > -8.5:
        out.append(f"very loud ({s['lufs']:.1f} LUFS): likely squashed; back off the master limiter gain")
    elif s["lufs"] < -16:
        out.append(f"quiet ({s['lufs']:.1f} LUFS): raise the master limiter gain toward -10..-12 LUFS")
    if s["knee_frac"] > 0.01:
        out.append(f"{100 * s['knee_frac']:.1f}% of samples are past the master soft-clip knee (-3.1 dBFS): "
                   "set limiter CEIL to -3.2 dB, or accept it as saturation")
    if s["crest_db"] < 8:
        out.append(f"crest factor {s['crest_db']:.1f} dB: dense/over-compressed; transients are flattened")
    b = s["bands"]
    if b["sub"] + b["low"] > 0.72:
        out.append(f"low end is {100 * (b['sub'] + b['low']):.0f}% of the energy: bass/kick too loud or pads not high-passed")
    if b["sub"] + b["low"] < 0.35:
        out.append(f"low end only {100 * (b['sub'] + b['low']):.0f}% of the energy: thin — more bass/kick or less top")
    if b["high"] + b["air"] > 0.12:
        out.append("a lot of top end: check hats, noise, bright presets")
    if s["correlation"] < 0.2:
        out.append(f"stereo correlation {s['correlation']:.2f}: wide to the point of mono-collapse risk")
    secs = s["sections"]
    if len(secs) >= 3:
        spread = max(x["lufs"] for x in secs) - min(x["lufs"] for x in secs if x["lufs"] > -60)
        if spread < 2:
            out.append(f"sections differ by only {spread:.1f} LU: the arrangement has little dynamic contour")
    return out


def print_report(path, s, stems=()):
    print(f"\n── {os.path.relpath(path)}")
    if s["silent"]:
        print("  SILENT")
        return
    m, sec = divmod(s["duration"], 60)
    print(f"  {int(m)}:{int(sec):02d}  {s['lufs']:.1f} LUFS integrated (short-term max {s['short_term_max']:.1f})  "
          f"peak {s['peak_db']:.1f} dBFS  crest {s['crest_db']:.1f} dB  PLR {s['plr']:.1f}")
    print(f"  soft-clip: {100 * s['knee_frac']:.2f}% of samples past knee   "
          f"stereo: corr {s['correlation']:.2f}, side/mid {s['width']:.2f}")
    print("  bands: " + "  ".join(f"{k} {100 * v:.0f}%" for k, v in s["bands"].items()))
    if s["sections"]:
        print("  sections: " + "  ".join(f"{x['name']} {x['lufs']:.1f}" for x in s["sections"]))
    for name, st in stems:
        if st["silent"]:
            print(f"  stem {name:<10} silent")
            continue
        b = st["bands"]
        top = max(b, key=b.get)
        print(f"  stem {name:<10} {st['lufs']:6.1f} LUFS  peak {st['peak_db']:6.1f}  crest {st['crest_db']:4.1f}  "
              f"mostly {top} ({100 * b[top]:.0f}%)  width {st['width']:.2f}")
    for a in advice(s):
        print("  ! " + a)
