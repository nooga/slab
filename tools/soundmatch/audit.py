#!/usr/bin/env python3
"""Validate complete paired datasets and measure their initial audio mismatch."""
import argparse
import json
from pathlib import Path
import wave

import numpy as np


def read(path):
    with wave.open(str(path), "rb") as f:
        assert f.getframerate() == 48000 and f.getnchannels() == 2 and f.getsampwidth() == 2
        return np.frombuffer(f.readframes(f.getnframes()), dtype="<i2").reshape(-1, 2) / 32768.0


def distance(a, b):
    """Multi-resolution spectral convergence; channel-preserving, phase insensitive."""
    values = []
    for n in (512, 2048, 8192):
        def magnitude(x):
            frames = np.lib.stride_tricks.sliding_window_view(x, n, axis=0)[::n // 4]
            return np.abs(np.fft.rfft(frames * np.hanning(n), axis=-1))
        sa, sb = magnitude(a), magnitude(b)
        values.append(float(np.linalg.norm(sa - sb) / max(np.linalg.norm(sa), 1e-9)))
    return float(np.mean(values))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    args = parser.parse_args()
    run = json.loads((args.dataset / "run.json").read_text())
    report = json.loads((args.dataset / "report.json").read_text())
    labels = sorted(args.dataset.glob("*/labels.json"))
    assert len(labels) == run["count"] == report["completed"]
    rows, seeds = [], set()
    for path in labels:
        label = json.loads(path.read_text())
        assert label["seed"] not in seeds
        seeds.add(label["seed"])
        assert set(label["changed"]) == {k for k in label["target"] if label["target"][k] != label["current"][k]}
        for k in label["target"]:
            assert 0 <= label["target"][k] <= 1 and 0 <= label["current"][k] <= 1
            assert abs(label["target"][k] - label["current"][k] - label["correction"][k]) < 1e-12
        a, b = read(path.parent / "target.wav"), read(path.parent / "current.wav")
        assert a.shape == b.shape and np.isfinite(a).all() and np.isfinite(b).all()
        rows.append(dict(id=label["id"], split=label["split"], changed=label["changed"],
                         spectral_distance=distance(a, b),
                         difference_rms=float(np.sqrt(np.mean((a-b)**2)))))
    scores = [r["spectral_distance"] for r in rows]
    result = dict(pairs=len(rows), train=sum(r["split"] == "train" for r in rows),
                  validation=sum(r["split"] == "validation" for r in rows),
                  spectral_distance_quantiles=dict(zip(["min", "p25", "median", "p75", "max"],
                                                        np.quantile(scores, [0, .25, .5, .75, 1]).tolist())),
                  note="Initial mismatches only; not training results or perceptual quality ratings.", rows=rows)
    (args.dataset / "audit.json").write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k != "rows"}, indent=2))


if __name__ == "__main__":
    main()
