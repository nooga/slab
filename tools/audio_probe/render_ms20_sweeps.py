#!/usr/bin/env python3
"""Render MS-20-ish filter sweep listening fixtures.

This is an offline design probe, not the final fy kernel. It keeps the
current promising feedback-clipped profiles reproducible while the actual
stateful filter ABI is still moving.
"""

from __future__ import annotations

import argparse
import math
import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np


SAMPLE_RATE = 48_000
OSC_HZ = 82.4069
CUTOFF_START_HZ = 80.0
CUTOFF_END_HZ = 9_000.0
RESONANCES = (0.45, 0.80, 1.10, 1.38)
OVERSAMPLE = 4
RENDER_SECONDS = 4.5
GAP_SECONDS = 0.25


@dataclass(frozen=True)
class Profile:
    name: str
    drive: float
    fb_gain: float
    fb_clip: float
    out_clip: float
    damping_base: float
    damping_res: float
    leak: float
    saw_gain: float
    noise_gain: float


PROFILES = {
    "f-hot": Profile("f-hot", 2.10, 4.5, 2.25, 1.85, 0.62, 5.2, 0.99990, 0.62, 0.48),
    "g-wet": Profile("g-wet", 1.90, 5.4, 2.70, 2.10, 0.58, 6.2, 0.99988, 0.58, 0.44),
}


class FilterState:
    def __init__(self) -> None:
        self.ic1 = 0.0
        self.ic2 = 0.0
        self.fb_dc = 0.0
        self.out_dc = 0.0


def tanh_rational(x: float) -> float:
    x = max(-5.0, min(5.0, x))
    x2 = x * x
    y = x * (27.0 + x2) / (27.0 + 9.0 * x2)
    return max(-1.0, min(1.0, y))


def clip(x: float, amount: float) -> float:
    return tanh_rational(x * amount)


def polyblep(phase: float, dt: float) -> float:
    if phase < dt:
        u = phase / dt
        return u + u - u * u - 1.0
    if phase > 1.0 - dt:
        u = (phase - 1.0) / dt
        return u * u + u + u + 1.0
    return 0.0


def saw(phase: float, dt: float) -> float:
    return (phase + phase - 1.0) - polyblep(phase, dt)


def noise(state: list[int]) -> float:
    state[0] = (state[0] * 1_664_525 + 1_013_904_223) & 0xFFFF_FFFF
    return (((state[0] >> 8) & 0x00FF_FFFF) / 8_388_607.5) - 1.0


def cutoff_at(pos: float) -> float:
    if pos < 0.5:
        u = pos * 2.0
        return CUTOFF_START_HZ * math.exp(math.log(CUTOFF_END_HZ / CUTOFF_START_HZ) * u)
    u = (pos - 0.5) * 2.0
    return CUTOFF_END_HZ * math.exp(math.log(CUTOFF_START_HZ / CUTOFF_END_HZ) * u)


def filter_step(st: FilterState, x: float, cutoff_hz: float, resonance: float, profile: Profile) -> float:
    os_rate = SAMPLE_RATE * OVERSAMPLE
    fc = max(20.0, min(SAMPLE_RATE * 0.42, cutoff_hz))
    g = math.tan(math.pi * fc / os_rate)
    damping = max(0.035, profile.damping_base / (1.0 + resonance * profile.damping_res))
    fb_dc_coeff = 1.0 - math.exp(-2.0 * math.pi * 18.0 / os_rate)
    out_dc_coeff = 1.0 - math.exp(-2.0 * math.pi * 10.0 / os_rate)
    out = st.ic2

    for _ in range(OVERSAMPLE):
        fb_src = st.ic2
        st.fb_dc += fb_dc_coeff * (fb_src - st.fb_dc)
        feedback = clip((fb_src - st.fb_dc) * resonance * profile.fb_gain, profile.fb_clip)
        driven = clip(x * profile.drive - feedback, 1.0)

        h = 1.0 / (1.0 + 2.0 * damping * g + g * g)
        hp = (driven - (2.0 * damping + g) * st.ic1 - st.ic2) * h
        bp = g * hp + st.ic1
        next_ic1 = g * hp + bp
        lp = g * bp + st.ic2
        next_ic2 = g * bp + lp

        st.ic1 = profile.leak * next_ic1
        st.ic2 = profile.leak * next_ic2
        colored = clip(lp + 0.20 * bp, profile.out_clip)
        st.out_dc += out_dc_coeff * (colored - st.out_dc)
        out = colored - st.out_dc

    return out


def fade(i: int, frames: int, fade_frames: int) -> float:
    amp = 1.0
    if i < fade_frames:
        u = i / fade_frames
        amp *= u * u * (3.0 - 2.0 * u)
    rem = frames - 1 - i
    if rem < fade_frames:
        u = rem / fade_frames
        amp *= u * u * (3.0 - 2.0 * u)
    return amp


def render(profile: Profile, source: str) -> np.ndarray:
    frames = int(SAMPLE_RATE * RENDER_SECONDS)
    gap = int(SAMPLE_RATE * GAP_SECONDS)
    fade_frames = int(SAMPLE_RATE * 0.06)
    samples: list[float] = []

    for pass_index, resonance in enumerate(RESONANCES):
        st = FilterState()
        phase = 0.37
        dt = OSC_HZ / SAMPLE_RATE
        noise_state = [0x1234ABCD + pass_index * 7919]

        for _ in range(int(SAMPLE_RATE * 0.25)):
            x = saw(phase, dt) * profile.saw_gain * 0.30 if source == "saw" else noise(noise_state) * profile.noise_gain * 0.50
            _ = filter_step(st, x, CUTOFF_START_HZ, resonance, profile)
            phase = (phase + dt) % 1.0

        for i in range(frames):
            pos = i / (frames - 1)
            if source == "saw":
                wobble = 0.90 + 0.10 * math.sin(2.0 * math.pi * 0.31 * (i / SAMPLE_RATE + pass_index * 0.37))
                x = saw(phase, dt) * profile.saw_gain * wobble
                phase = (phase + dt) % 1.0
            else:
                x = noise(noise_state) * profile.noise_gain
            y = filter_step(st, x, cutoff_at(pos), resonance, profile)
            samples.append(y * fade(i, frames, fade_frames))

        samples.extend([0.0] * gap)

    arr = np.array(samples, dtype=np.float64)
    arr -= float(np.mean(arr))
    arr *= 0.78 / (float(np.max(np.abs(arr))) or 1.0)
    return np.tanh(arr / 0.94) * 0.94


def write_wav(path: Path, samples: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = (np.clip(samples, -0.98, 0.98) * 32767.0).round().astype("<i2")
    stereo = np.column_stack([pcm, pcm]).reshape(-1)
    with wave.open(str(path), "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(stereo.tobytes())


def metrics(samples: np.ndarray) -> dict[str, float]:
    block = 1024
    rms = []
    mean = []
    for off in range(0, len(samples) - block, block):
        s = samples[off : off + block]
        rms.append(float(np.sqrt(np.mean(s * s))))
        mean.append(float(np.mean(s)))
    rms_a = np.array(rms)
    mean_a = np.array(mean)
    return {
        "peak": float(np.max(np.abs(samples))),
        "rms": float(np.sqrt(np.mean(samples * samples))),
        "mean": float(np.mean(samples)),
        "max_rms_jump": float(np.max(np.abs(np.diff(rms_a)))),
        "max_mean_jump": float(np.max(np.abs(np.diff(mean_a)))),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", choices=[*PROFILES.keys(), "all"], default="all")
    parser.add_argument("--source", choices=["saw", "noise", "both"], default="both")
    parser.add_argument("--out-dir", type=Path, default=Path("scratch"))
    args = parser.parse_args()

    profiles = PROFILES.values() if args.profile == "all" else [PROFILES[args.profile]]
    sources = ("saw", "noise") if args.source == "both" else (args.source,)
    for profile in profiles:
        for source in sources:
            samples = render(profile, source)
            path = args.out_dir / f"ms20_{source}_filter_sweeps_{profile.name}.wav"
            write_wav(path, samples)
            print(path, metrics(samples))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
