#!/usr/bin/env python3
"""Plot Slab voice-probe WAV/CSV/metrics artifacts.

Input is a kernel-probe output prefix, for example:
  scratch/ms20_voice_probe_fused_fast

Outputs:
  <prefix>_voice_overview.png
  <prefix>_voice_zoom.png
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import tempfile
import wave
from pathlib import Path


def require_plot_libs():
    try:
        import numpy as np

        os.environ.setdefault("MPLCONFIGDIR", str(Path(tempfile.gettempdir()) / "slab-matplotlib"))
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
    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        sample_rate = wav.getframerate()
        frames = wav.getnframes()
        raw = wav.readframes(frames)
    if sample_width != 2:
        raise ValueError(f"only 16-bit PCM WAV is supported: {path}")
    data = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    if channels > 1:
        data = data.reshape(-1, channels)[:, 0]
    return sample_rate, data


def read_lanes(path: Path):
    np, _ = require_plot_libs()
    with path.open(newline="") as f:
        rows = list(csv.DictReader(f))
    out = {}
    for key in ("sample", "time", "out", "amp_env", "cutoff_hz", "note_hz", "gate"):
        out[key] = np.array([float(row[key]) for row in rows], dtype=np.float64)
    return out


def style_axes(ax):
    ax.set_facecolor("#f3f3f3")
    ax.grid(True, color="#c6c6c6", linewidth=0.7, alpha=0.7)
    for spine in ax.spines.values():
        spine.set_linewidth(1.0)
        spine.set_color("#222222")


def event_times(lanes):
    gate = lanes["gate"]
    time = lanes["time"]
    if len(gate) < 2:
        return []
    hits = []
    prev = gate[0]
    for i in range(1, len(gate)):
        cur = gate[i]
        if cur != prev:
            hits.append(float(time[i]))
        prev = cur
    return hits


def plot_overview(prefix: Path, sample_rate: int, wav, lanes, metrics):
    np, plt = require_plot_libs()
    seconds = len(wav) / sample_rate
    t = np.arange(len(wav), dtype=np.float64) / sample_rate
    events = event_times(lanes)

    fig, axes = plt.subplots(
        4,
        1,
        figsize=(13, 10),
        sharex=True,
        gridspec_kw={"height_ratios": [2.2, 1.0, 1.0, 3.2]},
        constrained_layout=True,
    )
    fig.patch.set_facecolor("#e8e8e8")

    axes[0].plot(t, wav, color="#2c2c2c", linewidth=0.55)
    axes[0].set_title(
        f"{metrics.get('word', 'voice')} voice render "
        f"peak={float(metrics.get('peak', 0.0)):.3f} "
        f"rms={float(metrics.get('rms', 0.0)):.3f} "
        f"{float(metrics.get('ns_per_sample', 0.0)):.2f} ns/sample"
    )
    axes[0].set_ylabel("sample")
    style_axes(axes[0])

    axes[1].plot(lanes["time"], lanes["amp_env"], color="#247a7a", linewidth=1.3)
    axes[1].fill_between(lanes["time"], 0.0, lanes["gate"], color="#d13f31", alpha=0.14, step="pre")
    axes[1].set_ylabel("amp / gate")
    axes[1].set_ylim(-0.05, 1.08)
    style_axes(axes[1])

    axes[2].step(lanes["time"], lanes["note_hz"], where="pre", color="#2c2c2c", linewidth=1.1)
    axes[2].set_ylabel("note Hz")
    style_axes(axes[2])

    _, _, _, image = axes[3].specgram(
        wav,
        NFFT=2048,
        Fs=sample_rate,
        noverlap=1536,
        cmap="magma",
        scale="dB",
        vmin=-120,
        vmax=-25,
    )
    axes[3].set_ylim(20, min(12000, sample_rate / 2))
    axes[3].set_ylabel("Hz")
    axes[3].set_xlabel("time (s)")
    style_axes(axes[3])
    fig.colorbar(image, ax=axes[3], fraction=0.018, pad=0.012, label="dB")

    for ax in axes:
        ax.set_xlim(0.0, seconds)
        for x in events:
            ax.axvline(x, color="#6d6d6d", linewidth=0.7, linestyle=":")

    out = prefix.with_name(prefix.name + "_voice_overview.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return out


def plot_zoom(prefix: Path, sample_rate: int, wav, lanes, metrics):
    np, plt = require_plot_libs()
    active = lanes["time"][lanes["gate"] > 0.5]
    center = float(active[0]) + 0.080 if len(active) else 0.080
    span = 0.045
    start = max(0, int((center - span * 0.5) * sample_rate))
    end = min(len(wav), int((center + span * 0.5) * sample_rate))
    segment = wav[start:end]
    t_ms = (np.arange(start, end, dtype=np.float64) / sample_rate - start / sample_rate) * 1000.0

    fig, axes = plt.subplots(
        2,
        1,
        figsize=(13, 7),
        sharex=False,
        gridspec_kw={"height_ratios": [2.2, 2.2]},
        constrained_layout=True,
    )
    fig.patch.set_facecolor("#e8e8e8")

    axes[0].plot(t_ms, segment, color="#2c2c2c", linewidth=0.8)
    axes[0].set_title(f"{metrics.get('word', 'voice')} zoomed oscillogram")
    axes[0].set_ylabel("sample")
    axes[0].set_xlabel(f"milliseconds from {start / sample_rate:.3f}s")
    style_axes(axes[0])

    nfft = min(8192, max(256, len(segment)))
    window = np.hanning(nfft)
    frame = segment[:nfft] * window
    freqs = np.fft.rfftfreq(nfft, d=1.0 / sample_rate)
    spec = 20.0 * np.log10(np.maximum(np.abs(np.fft.rfft(frame)), 1.0e-12))
    spec -= np.max(spec)
    axes[1].plot(freqs, spec, color="#247a7a", linewidth=1.0)
    axes[1].set_xlim(0, min(12000, sample_rate / 2))
    axes[1].set_ylim(-110, 4)
    axes[1].set_ylabel("dB rel.")
    axes[1].set_xlabel("frequency (Hz)")
    style_axes(axes[1])

    out = prefix.with_name(prefix.name + "_voice_zoom.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("prefix", type=Path)
    args = parser.parse_args()

    metrics_path = args.prefix.with_name(args.prefix.name + "_metrics.json")
    lanes_path = args.prefix.with_name(args.prefix.name + "_lanes.csv")
    with metrics_path.open() as f:
        metrics = json.load(f)
    wav_path = Path(str(metrics.get("wav_path", args.prefix.with_suffix(".wav"))))
    if not wav_path.is_absolute():
        wav_path = args.prefix.parent / wav_path.name

    sample_rate, wav = read_wav(wav_path)
    lanes = read_lanes(lanes_path)
    for out in (
        plot_overview(args.prefix, sample_rate, wav, lanes, metrics),
        plot_zoom(args.prefix, sample_rate, wav, lanes, metrics),
    ):
        print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
