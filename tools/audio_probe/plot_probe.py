#!/usr/bin/env python3
"""Plot Slab machine-probe WAV files with matplotlib.

Outputs:
  <prefix>_waveform.png
  <prefix>_levels.png
  <prefix>_spectrum.png
  <prefix>_spectrogram.png
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
    if channels not in (1, 2) or sampwidth != 2:
        raise SystemExit(f"expected mono/stereo 16-bit PCM WAV, got channels={channels} width={sampwidth}")
    data = np.frombuffer(raw, dtype="<i2").astype(np.float32).reshape(-1, channels) / 32768.0
    if channels == 1:
        data = np.repeat(data, 2, axis=1)
    return sample_rate, data


def moving_rms(x, win):
    np, _ = require_plot_libs()
    if len(x) == 0:
        return x
    win = max(1, min(win, len(x)))
    kernel = np.ones(win, dtype=np.float32) / win
    return np.sqrt(np.convolve(x * x, kernel, mode="same"))


def plot_waveform(prefix: Path, sr: int, data):
    np, plt = require_plot_libs()
    t = np.arange(len(data)) / sr
    fig, ax = plt.subplots(figsize=(13, 4))
    ax.plot(t, data[:, 0], label="L", linewidth=0.75)
    ax.plot(t, data[:, 1], label="R", linewidth=0.75, alpha=0.8)
    ax.axhline(0, color="black", linewidth=0.5)
    ax.set_title("Waveform")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Amplitude")
    ax.set_ylim(-1.05, 1.05)
    ax.grid(True, alpha=0.25)
    ax.legend(loc="upper right")
    fig.tight_layout()
    fig.savefig(prefix.with_name(prefix.name + "_waveform.png"), dpi=140)
    plt.close(fig)


def plot_levels(prefix: Path, sr: int, data):
    np, plt = require_plot_libs()
    mono = data.mean(axis=1)
    win = max(32, int(sr * 0.01))
    rms = moving_rms(mono, win)
    peak = np.maximum(np.abs(data[:, 0]), np.abs(data[:, 1]))
    t = np.arange(len(data)) / sr
    eps = 1e-9
    fig, ax = plt.subplots(figsize=(13, 4))
    ax.plot(t, 20 * np.log10(np.maximum(peak, eps)), label="peak", linewidth=0.7)
    ax.plot(t, 20 * np.log10(np.maximum(rms, eps)), label="rms 10ms", linewidth=1.0)
    ax.set_title("Levels")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("dBFS")
    ax.set_ylim(-100, 3)
    ax.grid(True, alpha=0.25)
    ax.legend(loc="upper right")
    fig.tight_layout()
    fig.savefig(prefix.with_name(prefix.name + "_levels.png"), dpi=140)
    plt.close(fig)


def plot_spectrum(prefix: Path, sr: int, data):
    np, plt = require_plot_libs()
    mono = data.mean(axis=1)
    n = min(len(mono), 1 << 16)
    if n < 16:
        return
    window = np.hanning(n)
    spec = np.fft.rfft(mono[:n] * window)
    freq = np.fft.rfftfreq(n, 1 / sr)
    mag = 20 * np.log10(np.maximum(np.abs(spec), 1e-10))
    fig, ax = plt.subplots(figsize=(13, 4))
    ax.semilogx(freq[1:], mag[1:], linewidth=0.8)
    ax.set_title("Spectrum")
    ax.set_xlabel("Frequency (Hz)")
    ax.set_ylabel("dB")
    ax.set_xlim(20, sr / 2)
    ax.grid(True, which="both", alpha=0.25)
    fig.tight_layout()
    fig.savefig(prefix.with_name(prefix.name + "_spectrum.png"), dpi=140)
    plt.close(fig)


def plot_spectrogram(prefix: Path, sr: int, data):
    _, plt = require_plot_libs()
    mono = data.mean(axis=1)
    fig, ax = plt.subplots(figsize=(13, 5))
    ax.specgram(mono, NFFT=1024, Fs=sr, noverlap=768, cmap="magma")
    ax.set_title("Spectrogram")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Frequency (Hz)")
    ax.set_ylim(0, min(16000, sr / 2))
    fig.tight_layout()
    fig.savefig(prefix.with_name(prefix.name + "_spectrogram.png"), dpi=140)
    plt.close(fig)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("wav", type=Path)
    parser.add_argument("--out-prefix", type=Path)
    args = parser.parse_args()

    sr, data = read_wav(args.wav)
    prefix = args.out_prefix if args.out_prefix else args.wav.with_suffix("")
    plot_waveform(prefix, sr, data)
    plot_levels(prefix, sr, data)
    plot_spectrum(prefix, sr, data)
    plot_spectrogram(prefix, sr, data)
    print(f"wrote plots with prefix {prefix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
