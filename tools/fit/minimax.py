"""Polynomial fits for kernels/00-primitives/math.fy (dsp-std).

Weighted least squares at Chebyshev nodes, solved in the Chebyshev basis
(well conditioned), then refined by Lawson reweighting toward the minimax
fit. Prints monomial coefficients, low to high, and the max weighted error.
Run: python3 tools/fit/minimax.py
"""
import numpy as np

C = np.polynomial.chebyshev
P = np.polynomial.Polynomial


def fit(f, w, a, b, n, iters=200):
    m = 4000
    t = -np.cos(np.pi * (np.arange(m) + 0.5) / m)
    s = (a + b) / 2 + (b - a) / 2 * t
    V = C.chebvander(t, n)
    y, ws = f(s), w(s)
    lw = np.ones(m) / m
    for _ in range(iters):
        sw = np.sqrt(lw) * ws
        ch = np.linalg.lstsq(V * sw[:, None], y * sw, rcond=None)[0]
        e = np.abs(ws * (y - V @ ch))
        lw = lw * e
        lw /= lw.sum()
    mono = P(C.cheb2poly(ch))(P([-(a + b) / (b - a), 2 / (b - a)])).coef
    g = np.linspace(a, b, 200001)
    return mono, np.max(np.abs(w(g) * (f(g) - P(mono)(g))))


def show(name, c, e):
    print(f"{name}: max weighted error {e:.3e}")
    for i, v in enumerate(c):
        print(f"  c{i} = {float(v)!r}")


if __name__ == "__main__":
    A = lambda s: np.asarray(s, dtype=float)
    eps = 1e-12
    # Each fit pins the value at zero exactly (2^0 = 1, cos 0 = 1, sin r ~ r),
    # so 0 dB is exactly unity gain and tanh(0) is exactly zero.

    # 2^f = 1 + f Q(f), f in [-1/2, 1/2]; relative error of 2^f.
    def qe(f):
        f = A(f)
        return np.where(np.abs(f) < eps, np.log(2) * (1 + f * np.log(2) / 2), np.expm1(f * np.log(2)) / np.where(np.abs(f) < eps, 1, f))
    show("exp2: 2^f = 1 + f Q(f), Q deg 6", *fit(qe, lambda f: np.abs(A(f)) * 2.0 ** -A(f), -0.5, 0.5, 6))

    umax2 = ((np.sqrt(2) - 1) / (np.sqrt(2) + 1)) ** 2
    def q(s):
        s = np.maximum(A(s), 1e-300)
        r = np.sqrt(s)
        return np.where(s < 1e-14, 2 / np.log(2) * (1 + s / 3), np.log2((1 + r) / (1 - r)) / r)
    show("log2: log2 m = u Q(u^2), Q deg 4 (abs)", *fit(q, lambda s: np.sqrt(np.maximum(A(s), 0)), 0.0, umax2, 4))

    # sin r = r (1 + s S(s)), s = r^2 in [0, (pi/2)^2]; relative error.
    def sp(s):
        s = A(s)
        r = np.sqrt(np.maximum(s, 1e-300))
        return np.where(s < 1e-6, -1 / 6 + s / 120, (np.sin(r) / r - 1) / np.where(s < 1e-6, 1, s))
    show("sin: r (1 + s S(s)), S deg 4", *fit(sp, lambda s: A(s), 0.0, (np.pi / 2) ** 2, 4))

    # cos r = 1 + s C(s); absolute error.
    def cp(s):
        s = A(s)
        return np.where(s < 1e-6, -0.5 + s / 24, (np.cos(np.sqrt(np.maximum(s, 0))) - 1) / np.where(s < 1e-6, 1, s))
    show("cos: 1 + s C(s), C deg 5", *fit(cp, lambda s: A(s), 0.0, (np.pi / 2) ** 2, 5))
