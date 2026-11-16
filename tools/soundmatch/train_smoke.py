#!/usr/bin/env python3
"""Small supervised correction smoke test; no claim of real-world generalization."""
import argparse
import copy
import json
from pathlib import Path
import shutil
import subprocess
import time

import numpy as np
import torch
from torch import nn

from audit import read, distance
from generate import CONTROLS, ROOT, GIB, make_project, inspect_wav


def features(path):
    x = read(path)
    frames = np.lib.stride_tricks.sliding_window_view(x, 1024, axis=0)[::256]
    mag = np.abs(np.fft.rfft(frames * np.hanning(1024), axis=-1))[..., :512]
    # Preserve stereo; pool adjacent frequency/time bins to bound activations.
    mag = mag.reshape(len(mag), 2, 128, 4).mean(-1)
    n = len(mag) // 8
    mag = mag[:n*8].reshape(n, 8, 2, 128).mean(1)
    out = np.zeros((2, 128, 128), np.float32)
    out[..., :min(n, 128)] = np.log1p(10 * mag[:128]).transpose(1, 2, 0)
    return out


class Corrector(nn.Module):
    def __init__(self, controls):
        super().__init__()
        self.encoder = nn.Sequential(
            nn.Conv2d(6, 32, 5, stride=2, padding=2), nn.GELU(),
            nn.Conv2d(32, 64, 3, stride=2, padding=1), nn.GELU(),
            nn.Conv2d(64, 128, 3, stride=2, padding=1), nn.GELU(),
            nn.AdaptiveAvgPool2d((4, 4)), nn.Flatten())
        self.head = nn.Sequential(nn.Linear(2048 + controls, 512), nn.GELU(),
                                  nn.Linear(512, controls))
        nn.init.zeros_(self.head[-1].weight)
        nn.init.zeros_(self.head[-1].bias)

    def forward(self, audio, current):
        return self.head(torch.cat([self.encoder(audio), current], dim=1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("--steps", type=int, default=100)
    parser.add_argument("--batch", type=int, default=16)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--extra-dataset", type=Path, action="append", default=[])
    parser.add_argument("--test-dataset", type=Path)
    parser.add_argument("--settings-only", action="store_true")
    parser.add_argument("--eval-every", type=int, default=100)
    parser.add_argument("--render-count", type=int, default=40)
    args = parser.parse_args()
    if args.steps < 1 or args.batch < 1 or args.eval_every < 1 or args.render_count < 0:
        parser.error("steps, batch and eval-every must be positive; render-count must be nonnegative")
    if shutil.disk_usage(args.dataset).free < 20 * GIB:
        raise RuntimeError("Below 20 GiB free disk floor")
    args.out.mkdir(parents=True, exist_ok=False)
    torch.manual_seed(42)
    torch.set_num_threads(4)
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    print(f"torch={torch.__version__}; device={device}", flush=True)
    keys = list(CONTROLS)
    labels = []
    for dataset in [args.dataset] + args.extra_dataset + ([args.test_dataset] if args.test_dataset else []):
        rows = [json.loads(p.read_text()) for p in sorted(dataset.glob("*/labels.json"))]
        generation = json.loads((dataset / "report.json").read_text())
        assert len(rows) == generation["completed"]
        for row in rows:
            if dataset == args.test_dataset:
                row["split"] = "test"
            row["folder"] = str((dataset / f'{row["id"]:05d}').resolve())
        labels.extend(rows)
    assert len({r["seed"] for r in labels}) == len(labels), "Overlapping seeds"
    inputs, states, targets = [], [], []
    t = time.perf_counter()
    for row in labels:
        folder = Path(row["folder"])
        a, b = features(folder / "target.wav"), features(folder / "current.wav")
        inputs.append(np.concatenate([a, b, a-b]))
        states.append([row["current"][k] for k in keys])
        targets.append([row["target"][k] for k in keys])
    x = torch.from_numpy(np.stack(inputs))
    c = torch.tensor(states, dtype=torch.float32)
    y = torch.tensor(targets, dtype=torch.float32)
    train = torch.tensor([i for i, r in enumerate(labels) if r["split"] == "train"])
    val = torch.tensor([i for i, r in enumerate(labels) if r["split"] == "validation"])
    assert len(train) and len(val)
    scale = x[train].std().clamp_min(1e-6)
    x = x / scale
    if args.settings_only:
        x.zero_()
    preprocessing_seconds = time.perf_counter() - t
    model = Corrector(len(keys)).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=3e-4)
    def sync():
        if device.type == "mps":
            torch.mps.synchronize()
    def evaluate(indices, feature_tensor=None):
        feature_tensor = x if feature_tensor is None else feature_tensor
        model.eval()
        predictions = []
        with torch.no_grad():
            for chunk in indices.split(args.batch):
                predictions.append((c[chunk].to(device) + model(feature_tensor[chunk].to(device), c[chunk].to(device))).clamp(0, 1).cpu())
        pred = torch.cat(predictions)
        return float(((pred-y[indices])**2).mean()), pred
    baseline = float(((c[val]-y[val])**2).mean())
    sync()
    started = time.perf_counter()
    losses = []
    driver_peak = 0
    history = []
    best_mse, best_step = baseline, 0
    best_state = copy.deepcopy(model.state_dict())
    for step in range(args.steps):
        model.train()
        ix = train[torch.randint(len(train), (args.batch,))]
        prediction = model(x[ix].to(device), c[ix].to(device))
        loss = ((prediction-(y[ix]-c[ix]).to(device))**2).mean()
        optimizer.zero_grad(set_to_none=True)
        loss.backward()
        optimizer.step()
        losses.append(float(loss.detach().cpu()))
        if device.type == "mps":
            driver_peak = max(driver_peak, torch.mps.driver_allocated_memory())
        if (step+1) % args.eval_every == 0 or step+1 == args.steps:
            validation_mse, _ = evaluate(val)
            training_mse, _ = evaluate(train)
            history.append(dict(step=step+1, train_mse=training_mse, validation_mse=validation_mse))
            if validation_mse < best_mse:
                best_mse, best_step = validation_mse, step+1
                best_state = copy.deepcopy(model.state_dict())
            (args.out / "history.json").write_text(json.dumps(history, indent=2))
            print(f"eval {step+1}: train={training_mse:.6f}, validation={validation_mse:.6f}, best={best_step}", flush=True)
        if step == 0 or (step+1) % 100 == 0:
            print(f"step {step+1}/{args.steps}, loss={losses[-1]:.6f}", flush=True)
    sync()
    training_seconds = time.perf_counter()-started
    model.load_state_dict(best_state)
    train_mse, _ = evaluate(train)
    val_mse, pred = evaluate(val)
    test = torch.tensor([i for i, r in enumerate(labels) if r["split"] == "test"], dtype=torch.long)
    test_mse = None
    shuffled_target_test_mse = None
    render_indices = val
    if len(test):
        test_mse, pred = evaluate(test)
        render_indices = test
        if not args.settings_only:
            shuffled = x.clone()
            shuffled[test, :2] = x[test.roll(1), :2]
            shuffled[test, 4:] = shuffled[test, :2] - shuffled[test, 2:4]
            shuffled_target_test_mse, _ = evaluate(test, shuffled)
            del shuffled
    torch.save(dict(model=model.cpu().state_dict(), controls=keys, feature_scale=float(scale),
                    architecture="Corrector-v1", seed=42, settings_only=args.settings_only, best_step=best_step), args.out / "checkpoint.pt")
    # Auditionable, held-out checks: does lower parameter error improve the audio?
    rendered = []
    for n, idx in enumerate(render_indices[:args.render_count]):
        if shutil.disk_usage(args.out).free < 20 * GIB:
            raise RuntimeError("Below 20 GiB free disk floor")
        row = labels[int(idx)]
        state = dict(zip(keys, pred[n].tolist()))
        project = args.out / f'{row["seed"]}.slab'
        wav = args.out / f'{row["seed"]}.wav'
        make_project(project, state, row["notes"], row["seed"])
        cmd = [str(ROOT / "zig-out/bin/slab"), str(project.resolve()), "--render", str(wav.resolve()),
               "--bits", "16", "--no-dither", "--rate", "48000", "--tail", "0.5", "--threads", "1"]
        with (args.out / f'{row["seed"]}.log').open("w") as log:
            subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
        inspect_wav(wav)
        folder = Path(row["folder"])
        target = read(folder / "target.wav")
        rendered.append(dict(id=row["id"], seed=row["seed"], source=row["folder"], before=distance(target, read(folder / "current.wav")),
                             after=distance(target, read(wav)), predicted_state=state))
    result = dict(best_step=best_step, settings_only=args.settings_only, history=history, device=str(device), torch_version=torch.__version__,
                  parameters=sum(p.numel() for p in model.parameters()),
                  train_pairs=len(train), validation_pairs=len(val), test_pairs=len(test), test_mse=test_mse, shuffled_target_test_mse=shuffled_target_test_mse,
                  unchanged_test_mse=float(((c[test]-y[test])**2).mean()) if len(test) else None, steps=args.steps, batch=args.batch,
                  preprocessing_seconds=preprocessing_seconds, training_seconds=training_seconds,
                  steps_per_second=args.steps/training_seconds,
                  unchanged_validation_mse=baseline, validation_mse=val_mse, train_mse=train_mse,
                  sampled_mps_driver_peak_bytes=driver_peak if device.type == "mps" else None,
                  dataset=str(args.dataset.resolve()), extra_datasets=[str(p.resolve()) for p in args.extra_dataset],
                  test_dataset=str(args.test_dataset.resolve()) if args.test_dataset else None,
                  free_end_gib=shutil.disk_usage(args.out).free/GIB,
                  rendered_checks=rendered,
                  note="Validation-selected checkpoint; known notes/fixed machine family. No real-audio generalization claim.")
    (args.out / "report.json").write_text(json.dumps(result, indent=2))
    print(json.dumps({k:v for k,v in result.items() if k not in ("rendered_checks", "history")}, indent=2))
    print("Audio improved:", sum(r["after"] < r["before"] for r in rendered), "/", len(rendered), flush=True)


if __name__ == "__main__":
    main()
