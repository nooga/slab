"""Polyphase IIR halfband design for kernels/00-primitives/oversample.fy.

Two parallel allpass chains (Valenzuela-Constantinides / the HIIR design by
Laurent de Soras): H(z) = 1/2 [A0(z^2) + z^-1 A1(z^2)], each A a cascade of
first-order allpass sections (c + z^-1)/(1 + c z^-1). Given a transition
bandwidth and stopband attenuation this prints the coefficients (even
indices on path 0, odd on path 1) and verifies the decimator numerically.
Run: python3 tools/fit/halfband.py [attenuation_db] [transition]
"""
import math
import sys
import numpy as np


def design(atten_db, transition):
    k = math.tan((1 - transition * 2) * math.pi / 4) ** 2
    kksqrt = (1 - k * k) ** 0.25
    e = 0.5 * (1 - kksqrt) / (1 + kksqrt)
    e4 = e ** 4
    q = e * (1 + e4 * (2 + e4 * (15 + 150 * e4)))
    a2 = 10 ** (-atten_db / 10)
    a = a2 / (1 - a2)
    order = math.ceil(math.log(a * a / 16) / math.log(q))
    if order % 2 == 0:
        order += 1
    n = (order - 1) // 2
    coefs = []
    for idx in range(n):
        c = idx + 1
        num, i, j = 0.0, 0, 1
        while True:
            t = q ** (i * (i + 1)) * math.sin((i * 2 + 1) * c * math.pi / order) * j
            num += t
            j, i = -j, i + 1
            if abs(t) < 1e-100:
                break
        den, i, j = 0.0, 1, -1
        while True:
            t = q ** (i * i) * math.cos(i * 2 * c * math.pi / order) * j
            den += t
            j, i = -j, i + 1
            if abs(t) < 1e-100:
                break
        ww = num * q ** 0.25 / (den + 0.5)
        wwsq = ww * ww
        x = math.sqrt((1 - wwsq * k) * (1 - wwsq / k)) / (1 + wwsq)
        coefs.append((1 - x) / (1 + x))
    return coefs


def allpass_chain(cs, x):
    """Chain of (c + z^-1)/(1 + c z^-1) at the low rate."""
    y = np.array(x, dtype=float)
    for c in cs:
        out = np.zeros_like(y)
        xm = ym = 0.0
        for n, v in enumerate(y):
            o = c * (v - ym) + xm
            xm, ym = v, o
            out[n] = o
        y = out
    return y


def decimate(coefs, x):
    """x at 2x rate -> low rate: path 0 on the odd (newer) sample, path 1 on the even."""
    a0 = allpass_chain(coefs[0::2], x[1::2])
    a1 = allpass_chain(coefs[1::2], x[0::2])
    return 0.5 * (a0 + a1)


def response(coefs, f):
    """Magnitude of the decimator for a sine at f (fraction of the 2x rate)."""
    n = 16384
    t = np.arange(n)
    x = np.sin(2 * np.pi * f * t)
    y = decimate(coefs, x)[n // 4:]
    return np.sqrt(2 * np.mean(y * y))


if __name__ == "__main__":
    atten = float(sys.argv[1]) if len(sys.argv) > 1 else 100.0
    tb = float(sys.argv[2]) if len(sys.argv) > 2 else 0.04
    cs = design(atten, tb)
    print(f"atten {atten} dB, transition {tb}: {len(cs)} coefficients")
    for i, c in enumerate(cs):
        print(f"  c{i} = {c!r}   (path {i % 2})")
    pass_edge = 0.25 - tb / 2
    stop_edge = 0.25 + tb / 2
    pr = [20 * math.log10(response(cs, f)) for f in np.linspace(0.01, pass_edge, 12)]
    sr = [20 * math.log10(response(cs, f) + 1e-20) for f in np.linspace(stop_edge, 0.49, 12)]
    print(f"passband ripple {min(pr):+.4f}..{max(pr):+.4f} dB  (to {pass_edge:.3f} fs2)")
    print(f"stopband worst {max(sr):.1f} dB  (from {stop_edge:.3f} fs2)")
