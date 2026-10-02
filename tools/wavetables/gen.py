#!/usr/bin/env python3
"""Generate Concoction's built-in wavetables (machines/concoction/assets).

bank.wav holds the tables the TABLE switch picks, FRAMES frames each, in
the order of BANK below; kick.wav is the default USER table [an
ICanHasKick-style chirp table, 64 frames: Serum position x / 4]; skill,
relish, bite and law are single cycles drawn in the bass patches
songs/pml_basses.py remakes. Both are
Serum-style: 2048-sample frames, a `clm ` chunk saying so, 16-bit PCM.

Every frame is built from its harmonics (1..1023), so the file is
already band-limited; the host mipmaps it further (src/wavetable.zig).
Each table is normalized on its own, so the bank's tables sit at the
same level.

    python3 tools/wavetables/gen.py
"""

import os
import struct

import numpy as np

N = 2048
H = 1023
FRAMES = 16  # per bank table; keep in sync with WT-BANK-FRAMES in concoction.fy
OS = 16      # oversampling for shapes defined in the time domain

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "machines", "concoction", "assets")


def from_harmonics(amps, phases=None):
    """One cycle from sine-phase harmonic amplitudes amps[1..]."""
    spec = np.zeros(N // 2 + 1, dtype=complex)
    k = min(len(amps) - 1, H)
    ph = np.zeros(k + 1) if phases is None else phases[: k + 1]
    # sin(2 pi h p + ph) -> -i/2 e^{i ph} in the rfft bin, scaled by N
    spec[1 : k + 1] = amps[1 : k + 1] * (-0.5j) * np.exp(1j * ph[1 : k + 1]) * N
    return np.fft.irfft(spec, N)


def from_shape(fn):
    """Band-limit a naive shape fn(p) (p in [0, 1)) to harmonics <= H."""
    p = np.arange(N * OS) / (N * OS)
    x = fn(p)
    spec = np.fft.rfft(x) / OS
    spec[0] = 0
    spec[H + 1 :] = 0
    return np.fft.irfft(spec[: N // 2 + 1], N)


def sine_amps(n):
    a = np.zeros(H + 1)
    a[1] = 1
    return a


def saw_amps():
    h = np.arange(H + 1, dtype=float)
    a = np.zeros(H + 1)
    a[1:] = 2 / (np.pi * h[1:])
    return a


def square_amps():
    h = np.arange(H + 1, dtype=float)
    a = np.zeros(H + 1)
    a[1::2] = 4 / (np.pi * h[1::2])
    return a


def tri_amps():
    h = np.arange(H + 1, dtype=float)
    a = np.zeros(H + 1)
    odd = h[1::2]
    a[1::2] = 8 / (np.pi**2 * odd**2) * np.where(((odd - 1) / 2) % 2 == 0, 1, -1)
    return a


def table(fn, frames=FRAMES):
    return [fn(i / (frames - 1)) for i in range(frames)]


# --- the bank -----------------------------------------------------------


def basic(t):
    # sine, triangle, saw, square at t = 0, 1/3, 2/3, 1; crossfaded between
    keys = [from_harmonics(sine_amps(1)), from_harmonics(tri_amps()),
            from_harmonics(saw_amps()), from_harmonics(square_amps())]
    x = t * 3
    i = min(int(x), 2)
    f = x - i
    return keys[i] * (1 - f) + keys[i + 1] * f


def pwm(t):
    w = 0.5 - 0.47 * t
    return from_shape(lambda p: np.where(p < w, 1.0, -1.0))


def sync(t):
    r = 1 + 7 * t
    return from_shape(lambda p: 1 - 2 * np.mod(p * r, 1.0))


def fm(t):
    i = 6 * t
    return from_shape(lambda p: np.sin(2 * np.pi * p + i * np.sin(2 * np.pi * p)))


def pd(t):
    # Casio CZ phase distortion: a cosine read through a bent phase,
    # sine at t = 0 to a resonant saw-like edge at t = 1
    d = 0.5 - 0.48 * t

    def f(p):
        q = np.where(p < d, p * 0.5 / d, 0.5 + (p - d) * 0.5 / (1 - d))
        return -np.cos(2 * np.pi * q)
    return from_shape(f)


def drive(t):
    g = 1 + 29 * t**2
    return from_shape(lambda p: np.tanh(g * np.sin(2 * np.pi * p)))


def fold(t):
    g = 1 + 9 * t
    return from_shape(lambda p: np.sin(0.5 * np.pi * g * np.sin(2 * np.pi * p)))


def harm(t):
    # a saw built up one harmonic at a time
    n = 1 + 63 * t**2
    h = np.arange(H + 1, dtype=float)
    a = np.zeros(H + 1)
    a[1:] = (1 / h[1:]) * np.clip(n - h[1:] + 1, 0, 1)
    return from_harmonics(a)


def reso(t):
    # a saw through a resonant lowpass whose peak climbs harmonic 2 .. 48
    c = 2 * 24 ** t
    h = np.arange(H + 1, dtype=float)
    a = np.zeros(H + 1)
    hh = h[1:]
    lp = 1 / np.sqrt(1 + (hh / c) ** 8)
    peak = 3.0 / (1 + ((hh - c) / (0.35 * c)) ** 2)
    a[1:] = (1 / hh) * (lp + peak * (hh <= c * 1.6))
    return from_harmonics(a)


VOWELS = [  # F1, F2, F3 in Hz
    (730, 1090, 2440),  # A
    (530, 1840, 2480),  # E
    (270, 2290, 3010),  # I
    (570, 840, 2410),   # O
    (300, 870, 2240),   # U
]


def vowel(t):
    x = t * 4
    i = min(int(x), 3)
    f = x - i
    fs = [a * (1 - f) + b * f for a, b in zip(VOWELS[i], VOWELS[i + 1])]
    f0 = 110.0
    h = np.arange(H + 1, dtype=float)
    a = np.zeros(H + 1)
    hz = h[1:] * f0
    env = np.zeros_like(hz)
    for F, g, bw in zip(fs, (1.0, 0.6, 0.3), (90.0, 110.0, 150.0)):
        env += g / (1 + ((hz - F) / bw) ** 2)
    a[1:] = env * (1 / np.sqrt(h[1:])) * (hz < 5000)
    return from_harmonics(a)


# TABLE switch order, in concoction.fy
BANK = [("BASIC", basic), ("PWM", pwm), ("SYNC", sync), ("FM", fm),
        ("PD", pd), ("DRIVE", drive), ("FOLD", fold), ("HARM", harm),
        ("RESO", reso), ("VOWEL", vowel)]


def kick(t):
    # a kick's pitch drop squeezed into one cycle, the way Serum's
    # ICanHasKick reads: a sine that starts fast and slows to a stop, more
    # cycles the further along the table [1 at the start, ~10 at the end].
    # The phase is bent back to a whole number of cycles so the frame
    # wraps without a step.
    n = 1 + 9.5 * t ** 1.6
    whole = max(1, round(n))

    def f(p):
        phi = n * (1 - (1 - p) ** 3)
        return np.sin(2 * np.pi * (phi + (whole - n) * p))
    return from_shape(f)


# Single cycles drawn in the video's patches, for USER slots.
def skill(p):
    # rounded rise to a peak just before mid-cycle, a hard drop, a rounded
    # climb back
    up = np.sin(0.5 * np.pi * np.clip(p / 0.47, 0, 1)) * np.where(p < 0.47, 1, 1 - (p - 0.47) * 3)
    down = -0.75 + 0.75 * np.sin(0.5 * np.pi * (p - 0.5) / 0.5)
    return np.where(p < 0.5, up, down)


def relish(p):
    # an accelerating rise to the drop at mid-cycle, then a rounded climb
    up = -0.05 + 1.05 * (p / 0.5) ** 1.8
    down = -0.8 + 0.75 * np.sin(0.5 * np.pi * (p - 0.5) / 0.5)
    return np.where(p < 0.5, up, down)


def bite(p):
    # a sine bent so its peak comes early: a quick rise, a long fall
    return -np.cos(2 * np.pi * p ** 0.457)


def law(p):
    # a smooth pulse: a raised-cosine bump over the first 40%
    return np.where(p < 0.4, 0.5 - 0.5 * np.cos(2 * np.pi * p / 0.4), 0.0)


def normalize(frames):
    peak = max(np.max(np.abs(f)) for f in frames)
    return [f * (0.98 / peak) for f in frames]


def write(path, frames):
    data = np.concatenate(frames)
    pcm = np.clip(np.round(data * 32767), -32768, 32767).astype("<i2").tobytes()
    clm = b"<!>2048 10000000 wavetable (slab)"
    if len(clm) % 2:
        clm += b"\0"
    fmt = struct.pack("<HHIIHH", 1, 1, 48000, 48000 * 2, 2, 16)
    body = (b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt
            + b"clm " + struct.pack("<I", len(clm)) + clm
            + b"data" + struct.pack("<I", len(pcm)) + pcm)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(body)) + body)
    print(f"{os.path.relpath(path)}: {len(frames)} frames")


def main():
    os.makedirs(OUT, exist_ok=True)
    bank = []
    for _, fn in BANK:
        bank += normalize(table(fn))
    write(os.path.join(OUT, "bank.wav"), bank)
    write(os.path.join(OUT, "kick.wav"), normalize(table(kick, 64)))
    for name, fn in (("skill", skill), ("relish", relish), ("bite", bite), ("law", law)):
        write(os.path.join(OUT, name + ".wav"), normalize([from_shape(fn)]))


if __name__ == "__main__":
    main()
