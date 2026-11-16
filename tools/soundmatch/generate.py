#!/usr/bin/env python3
"""Bounded, reproducible target/current audio pairs; stdlib plus slabkit."""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import random
import shutil
import statistics
import subprocess
import sys
import time
import wave

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from slabkit import Song, fx

GIB = 1024 ** 3
# Physical units; log interpolation for frequencies and times.
CONTROLS = {
    "cutoff": (200, 5000, True), "contour": (0.2, 3, False),
    "emphasis": (0.05, 0.65, False), "f_dec": (0.05, 0.8, True),
    "a_rel": (0.03, 0.4, True), "drive": (0.1, 0.65, False),
    "detune2": (-0.15, 0.15, False), "lfo_cut": (0, 0.5, False),
    "delay_mix": (0.03, 0.3, False), "delay_fb": (0.1, 0.45, False),
    "comp_thresh": (-30, -12, False), "sweep": (0.6, 1.8, True),
}


def physical(key, value):
    lo, hi, log = CONTROLS[key]
    return lo * (hi / lo) ** value if log else lo + (hi - lo) * value


def make_project(path, state, notes, seed):
    p = {k: physical(k, v) for k, v in state.items()}
    song = Song("Correction pilot", bpm=120, groove_seed=seed)
    section = song.section("phrase", 2)
    params = {k: v for k, v in p.items()
              if not k.startswith(("delay_", "comp_")) and k != "sweep"}
    track = song.track("LEAD", "cream", "cream-lead", volume=0.22,
                       params=params, fx=[
                           fx("comp2", thresh=p["comp_thresh"], ratio=3, makeup=0),
                           fx("delay2", time=0.25, fb=p["delay_fb"],
                              mix=p["delay_mix"], damp=4000)])
    clip = track.clip(section)
    for pitch, onset, duration, velocity in notes:
        clip.note(pitch, onset, duration, velocity)
    track.automate("cutoff", (0, p["cutoff"]), (8, p["cutoff"] * p["sweep"]))
    song.master(volume=0.7)
    song.save(str(path), quiet=True)


def inspect_wav(path):
    with wave.open(str(path), "rb") as wav:
        assert wav.getsampwidth() == 2 and wav.getnchannels() == 2
        rate, frames = wav.getframerate(), wav.getnframes()
        samples = array("h", wav.readframes(frames))
    if sys.byteorder != "little":
        samples.byteswap()
    peak = max(abs(s) for s in samples) / 32768
    rms = math.sqrt(sum(float(s) * s for s in samples) / len(samples)) / 32768
    if rms < 1e-5 or peak >= 0.999:
        raise RuntimeError(f"Silent or clipped example: {path}, peak={peak}, rms={rms}")
    return dict(rate=rate, frames=frames, seconds=frames / rate, peak=peak,
                rms=rms, sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--count", type=int, default=6)
    parser.add_argument("--seed", type=int, default=20261103)
    parser.add_argument("--min-free-gib", type=float, default=20)
    parser.add_argument("--max-output-gib", type=float, default=2)
    args = parser.parse_args()
    if args.count < 1 or args.min_free_gib < 0 or args.max_output_gib <= 0:
        parser.error("Invalid count or disk limits")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    binary = ROOT / "zig-out/bin/slab"
    start_free = shutil.disk_usage(out).free
    metadata = dict(seed=args.seed, count=args.count, controls=CONTROLS,
                    commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                    binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                    free_start_gib=start_free / GIB,
                    scope="Known notes; cream + comp2 + delay2 + cutoff automation; fixed topology")
    (out / "run.json").write_text(json.dumps(metadata, indent=2))
    started = time.perf_counter()
    times, render_times = [], []
    for i in range(args.count):
        pair_start = time.perf_counter()
        rng = random.Random(args.seed + i)
        target = {k: rng.uniform(0.1, 0.9) for k in CONTROLS}
        current = dict(target)
        changed = rng.sample(list(CONTROLS), 1 + i % 3)
        for key in changed:
            current[key] = max(0, min(1, target[key] + rng.choice([-1, 1]) * rng.uniform(0.15, 0.4)))
        root = rng.choice([45, 48, 50, 52, 55, 57])
        notes = [[root + rng.choice([0, 3, 5, 7, 12]), j, rng.uniform(0.3, 0.8), rng.randrange(75, 111)]
                 for j in range(7)]
        pair = out / f"{i:05d}"
        pair.mkdir()
        audio = {}
        for label, state in [("target", target), ("current", current)]:
            used = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
            free = shutil.disk_usage(out).free
            # Reserve 16 MiB for the next short render and its metadata/log.
            if free < args.min_free_gib * GIB + 16 * 1024 ** 2 or used + 16 * 1024 ** 2 > args.max_output_gib * GIB:
                raise RuntimeError(f"Disk guard stopped generation: free={free/GIB:.2f} GiB, output={used/GIB:.3f} GiB")
            project = pair / f"{label}.slab"
            make_project(project, state, notes, args.seed + i)
            cmd = [str(binary), str(project), "--render", str(pair / f"{label}.wav"),
                   "--bits", "16", "--no-dither", "--rate", "48000", "--tail", "0.5", "--threads", "1"]
            t = time.perf_counter()
            with (pair / f"{label}.log").open("w") as log:
                subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
            render_times.append(time.perf_counter() - t)
            audio[label] = inspect_wav(pair / f"{label}.wav")
        if audio["target"]["sha256"] == audio["current"]["sha256"]:
            raise RuntimeError(f"Perturbation produced identical audio: {i}")
        record = dict(id=i, seed=args.seed + i, notes=notes, target=target, current=current,
                      correction={k: target[k] - current[k] for k in CONTROLS},
                      changed=changed, audio=audio,
                      split="validation" if i % 5 == 0 else "train")
        (pair / "labels.json").write_text(json.dumps(record, indent=2))
        times.append(time.perf_counter() - pair_start)
        if i == 0 or (i + 1) % 10 == 0 or i + 1 == args.count:
            print(f"{i+1}/{args.count}: {statistics.mean(times):.3f}s/pair; free={shutil.disk_usage(out).free/GIB:.2f} GiB", flush=True)
    used = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
    report = dict(completed=len(times), wall_seconds=time.perf_counter()-started,
                  mean_pair_seconds=statistics.mean(times), median_render_seconds=statistics.median(render_times),
                  projected_200_seconds=statistics.mean(times)*200,
                  projected_10000_hours=statistics.mean(times)*10000/3600,
                  output_bytes=used, bytes_per_pair=used/len(times),
                  free_end_gib=shutil.disk_usage(out).free/GIB,
                  free_start_gib=start_free/GIB)
    (out / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
