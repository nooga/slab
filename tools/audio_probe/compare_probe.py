#!/usr/bin/env python3
"""Compare two Slab machine-probe WAV files.

Outputs:
  <prefix>_overlay.png
  <prefix>_diff.png
  <prefix>_spectrum_delta.png
"""

from __future__ import annotations

import argparse
import sys
import wave
from pathlib import Path


def require_plot_libs():
    try:
        import numpy as np
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ModuleNotFoundError as exc:
        print(
            f"missing Python dependency: {exc.name}\n"
            "Install plotting deps, for example:\n"
            "  python3 -m pip install matplotlib numpy",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return np, plt


def read_wav(path: Path):
    np, _ = require_plot_libs()
    with wave.open(str(path), "rb") as w:
        channels = w.getnchannels()
        sample_rate = w.getframerate()
        sampwidth = w.getsampwidth()
        frames = w.getnframes()
        raw = w.readframes(frames)
    if channels != 2 or sampwidth != 2:
        raise SystemExit(f"{path}: expected stereo 16-bit PCM WAV")
    data = np.frombuffer(raw, dtype="<i2").astype(np.float32).reshape(-1, 2) / 32768.0
    return sample_rate, data


def main() -> int:
    np, plt = require_plot_libs()
    parser = argparse.ArgumentParser()
    parser.add_argument("a", type=Path)
    parser.add_argument("b", type=Path)
    parser.add_argument("--out-prefix", type=Path, default=Path("scratch/compare"))
    args = parser.parse_args()

    sr_a, a = read_wav(args.a)
    sr_b, b = read_wav(args.b)
    if sr_a != sr_b:
        raise SystemExit(f"sample-rate mismatch: {sr_a} vs {sr_b}")
    n = min(len(a), len(b))
    a = a[:n]
    b = b[:n]
    t = np.arange(n) / sr_a
    mono_a = a.mean(axis=1)
    mono_b = b.mean(axis=1)
    diff = mono_b - mono_a

    fig, ax = plt.subplots(figsize=(13, 4))
    ax.plot(t, mono_a, label=args.a.name, linewidth=0.7)
    ax.plot(t, mono_b, label=args.b.name, linewidth=0.7, alpha=0.8)
    ax.set_title("Waveform Overlay")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Amplitude")
    ax.grid(True, alpha=0.25)
    ax.legend(loc="upper right")
    fig.tight_layout()
    fig.savefig(args.out_prefix.with_name(args.out_prefix.name + "_overlay.png"), dpi=140)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(13, 4))
    ax.plot(t, diff, linewidth=0.7)
    ax.axhline(0, color="black", linewidth=0.5)
    ax.set_title("Difference: B - A")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Amplitude")
    ax.grid(True, alpha=0.25)
    fig.tight_layout()
    fig.savefig(args.out_prefix.with_name(args.out_prefix.name + "_diff.png"), dpi=140)
    plt.close(fig)

    fft_n = min(n, 1 << 16)
    window = np.hanning(fft_n)
    spec_a = np.abs(np.fft.rfft(mono_a[:fft_n] * window))
    spec_b = np.abs(np.fft.rfft(mono_b[:fft_n] * window))
    freq = np.fft.rfftfreq(fft_n, 1 / sr_a)
    delta = 20 * np.log10(np.maximum(spec_b, 1e-10)) - 20 * np.log10(np.maximum(spec_a, 1e-10))
    fig, ax = plt.subplots(figsize=(13, 4))
    ax.semilogx(freq[1:], delta[1:], linewidth=0.8)
    ax.axhline(0, color="black", linewidth=0.5)
    ax.set_title("Spectrum Delta: B - A")
    ax.set_xlabel("Frequency (Hz)")
    ax.set_ylabel("dB")
    ax.set_xlim(20, sr_a / 2)
    ax.grid(True, which="both", alpha=0.25)
    fig.tight_layout()
    fig.savefig(args.out_prefix.with_name(args.out_prefix.name + "_spectrum_delta.png"), dpi=140)
    plt.close(fig)

    print(f"wrote comparison plots with prefix {args.out_prefix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
