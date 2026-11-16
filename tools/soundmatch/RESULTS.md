# Local pilot — 2026-11-03

Base: freshly fetched `origin/master`, `8e9529b` (0.0.22).
Branch: `codex/audio-correction-pilot`. ReleaseFast build succeeded.
Hardware: M1 Pro, 10 CPU / 16 GPU cores, 32 GB unified memory.
Python 3.14.0, NumPy 2.5.4, PyTorch 2.15.0. MPS was unavailable inside
the execution sandbox; the authorized training run outside it used MPS.

## Generation

| Run | Pairs | Wall time | Mean seconds/pair | Output |
|---|---:|---:|---:|---:|
| Initial benchmark | 6 | 5.84 s | 0.973 | 9.95 MiB |
| Pilot | 200 | 203.02 s | 1.015 | 331.49 MiB |

Each pair has two four-second phrases plus 0.5-second tails, two editable
projects, labels and logs. Extrapolation from the pilot: 10,000 pairs
would take about 2.82 hours and 16.19 GiB, excluding dependencies and
training artifacts. This is serial, one renderer thread, warm-build
throughput; it excludes the initial release build.

All 200 pairs passed the audio and label audit: stereo 48 kHz PCM,
non-silent/non-clipped audio, differing target/current hashes, matching
dimensions, valid parameter corrections, unique pair seeds. Split:
160 training / 40 validation pairs. A repeated target render was
byte-identical. Disk-floor, output-budget and overwrite guards were
exercised successfully. No subjective listening evaluation was performed.

Available disk space began near 93.7 GiB and ended near 92.66 GiB,
including installation of the isolated NumPy/PyTorch environment and cache.
Dataset generation never approached the 20 GiB free-space floor or its
2 GiB output ceiling. Failed setup/guard-check directories remain tiny
and are not included as training data.

## Training smoke test

1,158,572-parameter CNN; 100 AdamW steps, batch 16. Features took 9.30 s
to prepare. GPU training took 3.40 s (29.4 steps/s), excluding feature
preparation, validation and rendering. Sampled MPS driver allocation
peaked at about 116.7 MiB; this is not peak process/system memory.

Held-out normalized parameter MSE:

- Leave settings unchanged: 0.0115772.
- Predicted corrections: 0.0100927 (12.8% reduction).

Only 3 of the first 8 held-out rendered corrections improved the measured
multi-resolution spectral convergence. Average spectral error worsened
from about 0.299 to 0.397. Lower parameter error did not establish better
audio. The model may exploit the synthetic parameter distribution; this
run does not establish that it learned to listen. A current-settings-only
ablation and perceptually grounded correction training are next controls.

This proves local execution is practical at this small scale. It does
not demonstrate useful sound matching, mixed-track transcription, or
generalization beyond this fixed machine/preset family. The audio metric
is a diagnostic, not a perceptual verdict. Do not extrapolate this small
CNN's throughput to a large encoder or adversarial rendering loop.

## Artifacts (repository-relative; ignored by Git)

- `scratch/soundmatch-bench-02/report.json`
- `scratch/soundmatch-pilot-01/{run,report,audit}.json`
- `scratch/soundmatch-pilot-01/00000/` through `00199/`
- `scratch/soundmatch-training-01/report.json`
- `scratch/soundmatch-training-01/checkpoint.pt`
- `scratch/soundmatch-training-01/00000.wav` etc.: eight corrected renders

The target and unchanged current audio for corrected example `00000` are
in `scratch/soundmatch-pilot-01/00000/`. All related versions of a phrase
stay in the same split. Benchmark and pilot use disjoint seed ranges.


# Scale-up — 2026-11-03

Generated 800 additional pairs in four parallel 200-pair shards in
211.79 seconds, plus a separate 100-pair test set. All five shards passed
label/audio audits. Unique-seed checks prevent cross-shard duplicates.
Development data totals 1,000 pairs: 800 train / 200 validation. All 100
fresh test pairs are reserved, overriding their generator split labels.
Neither test labels nor test audio affect optimization, feature scaling
or checkpoint selection. No hyperparameters were changed based on test scores.

First, extending the original 200-pair experiment to 2,000 steps took
27.00 seconds including periodic evaluation. Best validation MSE occurred
at step 300 (0.009367); further training memorized the training set while
validation deteriorated. That checkpoint improved spectral error in only
13/40 validation renders, with mean error 0.253 → 0.403.

The two larger runs used identical architecture, seed, batches, 3,000-step
budgets and validation-based checkpoint selection. The settings-only
control received zero audio features in both training and evaluation.

| Fresh-test metric | Unchanged | Settings only | Audio + settings |
|---|---:|---:|---:|
| Normalized parameter MSE | 0.010356 | 0.009103 | 0.005566 |
| Mean spectral error | 0.270 | 0.481 | 0.448 |
| Spectrally improved examples | — | 8/100 | 27/100 |
| Selected step | — | 2000 | 1000 |
| Training + periodic evaluation | — | 41.26 s | 40.88 s |

Preprocessing took about 51 seconds per larger run; test rendering and
spectral comparison were additional. Sampled MPS driver allocation was
about 116.7 MiB; CPU feature arrays and OS memory are not included.

The audio model reduced test parameter MSE by
46.3% versus no correction and
38.9% versus settings-only. Permuting
its test target features while retaining current audio/settings increased
parameter MSE to 0.024305. Together these are
evidence of target-audio use on this synthetic task, not evidence of
reliable perceptual improvement.

All 100 predicted projects were rendered for both models. The audio
model's mean spectral error worsened by
66.1% relative to no
correction. It does better than the settings-only baseline on this metric,
but still damages many already-close examples. No subjective listening
evaluation was performed. Lower parameter loss should not be presented
as better sound.

Per-control test parameter MSE reductions for the audio model include
cutoff 88.2%, compression threshold 83.6%, delay feedback 76.9%, and delay
mix 62.2%; detune worsens 1.5%. Mean absolute edit on controls that were
already correct is 0.038 in normalized units. This suggests testing sparse
edit selection and an audio-sensitive objective, and checking the spectral
metric against listening, before spending compute on a much larger model.
These follow-ups have not been tested here. All runs are single-seed and
restricted to the same machine/preset family with known notes.

Disk ended at about 89.94 GiB free. Guards stayed enabled;
no user files were removed. New data uses about 1.46 GiB of file payload,
plus predicted renders, checkpoints and metadata.

Artifacts:

- `scratch/soundmatch-scale-summary.json`: compact comparison.
- `scratch/soundmatch-long-200/`: extended small-data experiment.
- `scratch/soundmatch-scale-0/` through `soundmatch-scale-3/`: new development pairs.
- `scratch/soundmatch-scale-test/`: 100 independent test pairs.
- `scratch/soundmatch-large-audio/`: checkpoint, learning curve, report,
  and 100 predicted WAVs/projects named by seed.
- `scratch/soundmatch-large-settings/`: corresponding no-audio control.

Reproduce the larger run:

```sh
scratch/soundmatch-venv/bin/python tools/soundmatch/train_smoke.py \
  scratch/soundmatch-pilot-01 \
  --extra-dataset scratch/soundmatch-scale-0 \
  --extra-dataset scratch/soundmatch-scale-1 \
  --extra-dataset scratch/soundmatch-scale-2 \
  --extra-dataset scratch/soundmatch-scale-3 \
  --test-dataset scratch/soundmatch-scale-test \
  --out scratch/new-audio-run --steps 3000 --eval-every 200 --render-count 100
```

Add `--settings-only` and choose another output directory for the control.
The MPS GPU must be visible to the process; the script reports its device.
