#!/usr/bin/env python3
"""Plot Slab kernel-probe CSV/metrics artifacts.

Input is a kernel-probe output prefix, for example:
  scratch/kernel_tanh_table_fast

Outputs:
  <prefix>_transfer.png
  <prefix>_report.png
"""

from __future__ import annotations

import argparse
import csv
import json
import math
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


def load_artifacts(prefix: Path):
    lanes_path = prefix.with_name(prefix.name + "_lanes.csv")
    metrics_path = prefix.with_name(prefix.name + "_metrics.json")

    with lanes_path.open(newline="") as f:
        rows = list(csv.DictReader(f))
    with metrics_path.open() as f:
        metrics = json.load(f)
    return rows, metrics


def as_float(row, key: str) -> float:
    value = row.get(key, "")
    if value == "":
        return math.nan
    return float(value)


def style_axes(ax):
    ax.set_facecolor("#f3f3f3")
    ax.grid(True, color="#c6c6c6", linewidth=0.7, alpha=0.7)
    for spine in ax.spines.values():
        spine.set_linewidth(1.0)
        spine.set_color("#222222")


def plot_tanh_transfer(prefix: Path, rows, metrics):
    np, plt = require_plot_libs()
    x = np.array([as_float(r, "input") for r in rows], dtype=np.float64)
    y = np.array([as_float(r, "out") for r in rows], dtype=np.float64)
    expected = np.array([as_float(r, "expected") for r in rows], dtype=np.float64)
    err = y - expected

    drive = float(metrics.get("drive", 1.0))
    dense_x = np.linspace(float(np.min(x)), float(np.max(x)), 2048)
    ideal = np.tanh(dense_x * drive)

    fig, (ax0, ax1) = plt.subplots(
        2,
        1,
        figsize=(12, 8),
        gridspec_kw={"height_ratios": [3, 1]},
        sharex=True,
    )
    fig.patch.set_facecolor("#e8e8e8")

    ax0.plot(dense_x, ideal, color="#202020", linewidth=1.2, label=f"true tanh({drive:g}x)")
    ax0.plot(x, expected, color="#247a7a", linewidth=1.8, label="table linear oracle")
    ax0.scatter(x, y, s=22, color="#d13f31", zorder=3, label="fy dsp samples")
    ax0.plot(x, x, color="#777777", linewidth=0.9, linestyle="--", label="dry")
    ax0.set_title("k-tanh-table transfer")
    ax0.set_ylabel("output")
    ax0.set_ylim(-1.08, 1.08)
    ax0.legend(loc="lower right", frameon=True, facecolor="#eeeeee", edgecolor="#222222")
    style_axes(ax0)

    ax1.axhline(0, color="#222222", linewidth=0.9)
    ax1.plot(x, err, color="#d13f31", linewidth=1.2)
    ax1.scatter(x, err, s=14, color="#d13f31")
    ax1.set_xlabel("input sample")
    ax1.set_ylabel("fy - oracle")
    style_axes(ax1)

    fig.tight_layout()
    out = prefix.with_name(prefix.name + "_transfer.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return out


def plot_lane_result(prefix: Path, rows, metrics):
    np, plt = require_plot_libs()
    labels = [r.get("lane", r.get("sample", str(i))) for i, r in enumerate(rows)]
    y = np.array([as_float(r, "out") for r in rows], dtype=np.float64)
    expected = np.array([as_float(r, "expected") for r in rows], dtype=np.float64)

    fig, ax = plt.subplots(figsize=(9, 4))
    fig.patch.set_facecolor("#e8e8e8")
    pos = np.arange(len(rows))
    width = 0.36
    ax.bar(pos - width / 2, y, width, color="#d13f31", label="out")
    ax.bar(pos + width / 2, expected, width, color="#247a7a", label="expected")
    ax.set_xticks(pos, labels)
    ax.set_title(f"{metrics.get('word', 'kernel')} lanes")
    ax.set_ylabel("value")
    ax.legend(loc="best", frameon=True, facecolor="#eeeeee", edgecolor="#222222")
    style_axes(ax)
    fig.tight_layout()
    out = prefix.with_name(prefix.name + "_lanes.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return out


def plot_saw_oscillator(prefix: Path, rows, metrics):
    np, plt = require_plot_libs()
    y = np.array([as_float(r, "out") for r in rows], dtype=np.float64)
    expected = np.array([as_float(r, "expected") for r in rows], dtype=np.float64)
    naive = np.array([as_float(r, "naive") for r in rows], dtype=np.float64)
    sample_rate = float(metrics.get("sample_rate", 48000.0))
    n = len(y)
    t_ms = np.arange(n, dtype=np.float64) * 1000.0 / sample_rate

    window = np.hanning(n)
    freq = np.fft.rfftfreq(n, d=1.0 / sample_rate)
    spec = 20.0 * np.log10(np.maximum(np.abs(np.fft.rfft(y * window)), 1.0e-12))
    naive_spec = 20.0 * np.log10(np.maximum(np.abs(np.fft.rfft(naive * window)), 1.0e-12))
    spec -= np.max(spec)
    naive_spec -= np.max(naive_spec)

    fig, (ax0, ax1, ax2) = plt.subplots(
        3,
        1,
        figsize=(12, 9),
        gridspec_kw={"height_ratios": [2.2, 1.0, 1.8]},
    )
    fig.patch.set_facecolor("#e8e8e8")

    show = min(512, n)
    ax0.plot(t_ms[:show], naive[:show], color="#777777", linewidth=0.9, label="naive saw")
    ax0.plot(t_ms[:show], y[:show], color="#d13f31", linewidth=1.2, label="fy polyBLEP")
    ax0.plot(t_ms[:show], expected[:show], color="#247a7a", linewidth=0.9, linestyle="--", label="zig oracle")
    ax0.set_title(f"{metrics.get('word', 'saw')} waveform")
    ax0.set_ylabel("sample")
    ax0.legend(loc="best", frameon=True, facecolor="#eeeeee", edgecolor="#222222")
    style_axes(ax0)

    err = y - expected
    ax1.plot(t_ms[:show], err[:show], color="#2c2c2c", linewidth=1.0)
    ax1.set_ylabel("fy - oracle")
    style_axes(ax1)

    ax2.plot(freq, naive_spec, color="#777777", linewidth=0.9, label="naive")
    ax2.plot(freq, spec, color="#d13f31", linewidth=1.1, label="polyBLEP")
    ax2.set_xlim(0, sample_rate / 2.0)
    ax2.set_ylim(-120, 4)
    ax2.set_xlabel("frequency (Hz)")
    ax2.set_ylabel("dBFS rel.")
    ax2.legend(loc="best", frameon=True, facecolor="#eeeeee", edgecolor="#222222")
    style_axes(ax2)

    fig.tight_layout()
    out = prefix.with_name(prefix.name + "_oscillator.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return out


def plot_envelope(prefix: Path, rows, metrics):
    np, plt = require_plot_libs()
    t = np.array([as_float(r, "time") for r in rows], dtype=np.float64)
    y = np.array([as_float(r, "out") for r in rows], dtype=np.float64)
    expected = np.array([as_float(r, "expected") for r in rows], dtype=np.float64)
    gate = float(metrics.get("gate", 0.0))
    attack = float(metrics.get("attack", 0.0))
    decay = float(metrics.get("decay", 0.0))
    release_end = float(metrics.get("release_end", gate))

    fig, (ax0, ax1) = plt.subplots(
        2,
        1,
        figsize=(12, 7),
        gridspec_kw={"height_ratios": [3, 1]},
        sharex=True,
    )
    fig.patch.set_facecolor("#e8e8e8")

    ax0.plot(t, y, color="#d13f31", linewidth=1.8, label="fy envelope")
    ax0.plot(t, expected, color="#247a7a", linewidth=1.1, linestyle="--", label="zig oracle")
    markers = [
        (attack, "attack"),
        (attack + decay, "decay"),
        (gate, "gate off"),
        (release_end, "release end"),
    ]
    for x, label in markers:
        ax0.axvline(x, color="#2c2c2c", linewidth=0.8, linestyle=":")
        ax0.text(x, 1.03, label, rotation=90, va="bottom", ha="right", fontsize=8)
    ax0.set_ylim(-0.05, 1.1)
    ax0.set_title(f"{metrics.get('word', 'envelope')} ADSR")
    ax0.set_ylabel("level")
    ax0.legend(loc="best", frameon=True, facecolor="#eeeeee", edgecolor="#222222")
    style_axes(ax0)

    err = y - expected
    ax1.axhline(0, color="#222222", linewidth=0.9)
    ax1.plot(t, err, color="#2c2c2c", linewidth=1.0)
    ax1.set_xlabel("time (s)")
    ax1.set_ylabel("fy - oracle")
    style_axes(ax1)

    fig.tight_layout()
    out = prefix.with_name(prefix.name + "_envelope.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return out


def read_wav_mono(path: Path):
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
    return data, sample_rate


def plot_ms20_filter_grid(prefix: Path, rows, metrics):
    np, plt = require_plot_libs()
    wav_path = Path(str(metrics.get("wav_path", prefix.with_suffix(".wav"))))
    if not wav_path.is_absolute():
        wav_path = prefix.parent / wav_path.name
    y, sample_rate = read_wav_mono(wav_path)

    resonances = [float(v) for v in metrics.get("resonances", [])]
    render_frames = int(metrics.get("render_frames", 0))
    gap_frames = int(metrics.get("gap_frames", 0))
    if render_frames <= 0 or not resonances:
        raise ValueError("ms20-lpf-grid metrics must include render_frames and resonances")

    nfft = 2048
    hop = 512
    window = np.hanning(nfft)
    freqs = np.fft.rfftfreq(nfft, d=1.0 / sample_rate)
    freq_mask = (freqs >= 20.0) & (freqs <= min(12000.0, sample_rate / 2.0))
    shown_freqs = freqs[freq_mask]
    spectrograms = []
    ridge_p90 = []
    offset = 0
    for _resonance in resonances:
        segment = y[offset : offset + render_frames]
        if len(segment) < render_frames:
            segment = np.pad(segment, (0, render_frames - len(segment)))
        cols = []
        ridge_excess = []
        for start in range(0, max(1, len(segment) - nfft), hop):
            frame = segment[start : start + nfft]
            if len(frame) < nfft:
                frame = np.pad(frame, (0, nfft - len(frame)))
            power = np.abs(np.fft.rfft(frame * window)) ** 2
            db = 10.0 * np.log10(np.maximum(power, 1.0e-24))
            cols.append(db[freq_mask])

            t = (start + nfft * 0.5) / sample_rate
            pos = min(1.0, t / (render_frames / sample_rate))
            cutoff = float(metrics.get("cutoff_start_hz", 80.0)) * math.exp(
                math.log(float(metrics.get("cutoff_end_hz", 8000.0)) / float(metrics.get("cutoff_start_hz", 80.0))) * pos
            )
            band = (freqs > cutoff * 0.92) & (freqs < cutoff * 1.08)
            sides = ((freqs > cutoff * 0.55) & (freqs < cutoff * 0.75)) | (
                (freqs > cutoff * 1.35) & (freqs < min(sample_rate / 2.0, cutoff * 1.8))
            )
            if np.any(band) and np.any(sides):
                ridge_excess.append(float(np.max(db[band]) - np.median(db[sides])))
        spectrograms.append(np.stack(cols, axis=1))
        ridge_p90.append(float(np.percentile(ridge_excess, 90)) if ridge_excess else math.nan)
        offset += render_frames + gap_frames

    all_db = np.concatenate([s.reshape(-1) for s in spectrograms])
    vmin = float(np.percentile(all_db, 8))
    vmax = float(np.percentile(all_db, 99.7))
    seconds = render_frames / sample_rate
    cutoff_t = np.linspace(0.0, seconds, 512)
    cutoff_y = float(metrics.get("cutoff_start_hz", 80.0)) * np.exp(
        np.log(float(metrics.get("cutoff_end_hz", 8000.0)) / float(metrics.get("cutoff_start_hz", 80.0))) * (cutoff_t / seconds)
    )

    fig, axes = plt.subplots(
        len(resonances),
        1,
        figsize=(13, 2.4 * len(resonances) + 1.0),
        sharex=True,
        sharey=True,
        constrained_layout=True,
    )
    if len(resonances) == 1:
        axes = [axes]
    fig.patch.set_facecolor("#e8e8e8")

    last_image = None
    for ax, resonance, spec, ridge in zip(axes, resonances, spectrograms, ridge_p90):
        last_image = ax.imshow(
            spec,
            origin="lower",
            aspect="auto",
            extent=[0.0, seconds, float(shown_freqs[0]), float(shown_freqs[-1])],
            cmap="magma",
            vmin=vmin,
            vmax=vmax,
            interpolation="nearest",
        )
        ax.plot(cutoff_t, cutoff_y, color="#c7f3ff", linewidth=1.0, alpha=0.95)
        ax.set_ylim(20, min(12000, sample_rate / 2))
        ax.set_ylabel(f"res {resonance:.2f}\n+{ridge:.1f} dB")
        style_axes(ax)

    axes[0].set_title(
        f"{metrics.get('word', 'ms20-lpf')} cutoff sweep "
        f"{float(metrics.get('cutoff_start_hz', 0.0)):.0f}-"
        f"{float(metrics.get('cutoff_end_hz', 0.0)):.0f} Hz"
    )
    axes[-1].set_xlabel("time (s)")
    if last_image is not None:
        fig.colorbar(last_image, ax=axes, fraction=0.018, pad=0.012, label="dB, shared scale")
    out = prefix.with_name(prefix.name + "_ms20_spectrogram.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return out


def is_envelope_case(metrics) -> bool:
    return str(metrics.get("case", "")).startswith("adsr-")


def plot_report(prefix: Path, metrics):
    np, plt = require_plot_libs()
    keys = [
        "instruction_count",
        "push_count",
        "pop_count",
        "float_alu_count",
        "neon_float_alu_count",
        "neon_load_count",
        "neon_store_count",
    ]
    values = np.array([float(metrics.get(k, 0)) for k in keys], dtype=np.float64)
    labels = [k.replace("_count", "").replace("_", "\n") for k in keys]

    fig, (ax0, ax1) = plt.subplots(
        1,
        2,
        figsize=(12, 4.8),
        gridspec_kw={"width_ratios": [2.3, 1]},
    )
    fig.patch.set_facecolor("#e8e8e8")

    colors = ["#2c2c2c", "#777777", "#777777", "#247a7a", "#d13f31", "#d13f31", "#d13f31"]
    ax0.bar(np.arange(len(keys)), values, color=colors)
    ax0.set_xticks(np.arange(len(keys)), labels)
    ax0.set_title("compiler report counts")
    ax0.set_ylabel("count")
    style_axes(ax0)

    ns = float(metrics.get("ns_per_iter", 0.0))
    max_error = float(metrics.get("max_abs_error", 0.0))
    lines = [
        metrics.get("word", "kernel"),
        f"case: {metrics.get('case', '-')}",
        f"ns/iter: {ns:.3f}",
        f"max error: {max_error:.3e}",
        f"iterations: {int(metrics.get('iterations', 0))}",
        f"instructions: {int(metrics.get('instruction_count', 0))}",
    ]
    if "libc_tanh_ns_per_iter" in metrics:
        lines.insert(3, f"libc tanh: {float(metrics['libc_tanh_ns_per_iter']):.3f}")
        lines.insert(4, f"fy/libc: {float(metrics.get('table_vs_libc_tanh_speedup', 0.0)):.2f}x")
    if "zig_table_ns_per_iter" in metrics:
        lines.insert(5, f"zig table: {float(metrics['zig_table_ns_per_iter']):.3f}")
        lines.insert(6, f"zig/libc: {float(metrics.get('zig_table_vs_libc_tanh_speedup', 0.0)):.2f}x")
    if "table_vs_libc_tanh_max_abs_error" in metrics:
        lines.insert(7, f"vs tanh err: {float(metrics['table_vs_libc_tanh_max_abs_error']):.3e}")
    if "alias_residual_db" in metrics:
        lines.insert(3, f"rms/peak: {float(metrics.get('rms', 0.0)):.3f}/{float(metrics.get('peak', 0.0)):.3f}")
        lines.insert(4, f"freq: {float(metrics.get('fundamental_hz', 0.0)):.2f} Hz")
        lines.insert(5, f"alias: {float(metrics['alias_residual_db']):.2f} dB")
        lines.insert(6, f"naive alias: {float(metrics.get('naive_alias_residual_db', 0.0)):.2f} dB")
    if is_envelope_case(metrics):
        lines.insert(3, f"a/d/s/r: {float(metrics.get('attack', 0.0)):.3f}/{float(metrics.get('decay', 0.0)):.3f}/{float(metrics.get('sustain', 0.0)):.3f}/{float(metrics.get('release', 0.0)):.3f}")
        lines.insert(4, f"gate: {float(metrics.get('gate', 0.0)):.3f} s")
        lines.insert(5, f"rms/peak: {float(metrics.get('rms', 0.0)):.3f}/{float(metrics.get('peak', 0.0)):.3f}")
    if metrics.get("case") == "ms20-lpf-grid":
        lines.insert(3, f"renders: {int(metrics.get('renders', 0))}")
        lines.insert(4, f"cutoff: {float(metrics.get('cutoff_start_hz', 0.0)):.0f}-{float(metrics.get('cutoff_end_hz', 0.0)):.0f} Hz")
        lines.insert(5, f"drive: {float(metrics.get('drive', 0.0)):.2f}")
        lines.insert(6, f"rms/peak: {float(metrics.get('rms', 0.0)):.3f}/{float(metrics.get('peak', 0.0)):.3f}")
    ax1.axis("off")
    ax1.set_facecolor("#f3f3f3")
    ax1.text(
        0.03,
        0.95,
        "\n".join(lines),
        va="top",
        ha="left",
        fontfamily="monospace",
        fontsize=11,
        bbox={"facecolor": "#f3f3f3", "edgecolor": "#222222", "linewidth": 1.0, "pad": 10},
    )

    fig.tight_layout()
    out = prefix.with_name(prefix.name + "_report.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("prefix", type=Path)
    args = parser.parse_args()

    rows, metrics = load_artifacts(args.prefix)
    outputs = []
    if metrics.get("case") == "tanh-table-sweep":
        outputs.append(plot_tanh_transfer(args.prefix, rows, metrics))
    elif metrics.get("case") == "ms20-lpf-grid":
        outputs.append(plot_ms20_filter_grid(args.prefix, rows, metrics))
    elif is_envelope_case(metrics):
        outputs.append(plot_envelope(args.prefix, rows, metrics))
    elif "alias_residual_db" in metrics:
        outputs.append(plot_saw_oscillator(args.prefix, rows, metrics))
    else:
        outputs.append(plot_lane_result(args.prefix, rows, metrics))
    outputs.append(plot_report(args.prefix, metrics))

    for out in outputs:
        print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
