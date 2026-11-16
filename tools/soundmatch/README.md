# Sound matching pilot

Experimental dataset generation and trained parameter-correction models;
not yet a general audio-to-project reconstruction system.
Measured generation and training smoke-test outcomes: [RESULTS.md](RESULTS.md).
Weight inspection and causal diagnostic probes: [INSPECTION.md](INSPECTION.md).
Selective-edit/identity-data/representation experiments: [ABLATIONS.md](ABLATIONS.md).
Diverse patch/phrase families and 1k/2k/5k learning curve: [DIVERSE_5K.md](DIVERSE_5K.md).
Auraloss scoring and bounded render-based refinement: [AURALOSS.md](AURALOSS.md).
Consensus versus single-metric refinement: [REFINEMENT_VOTE.md](REFINEMENT_VOTE.md).
Expanded 26-control Cream pilot: [EXPANDED.md](EXPANDED.md).
Focused nine-control oscillator experiment: [OSCILLATOR_5K.md](OSCILLATOR_5K.md).
Single-switch recognition, diagnosis and exhaustive search: [SINGLE_SWITCH.md](SINGLE_SWITCH.md).
Discrete search versus neural/search hybrid: [HYBRID_SEARCH.md](HYBRID_SEARCH.md).
`generate.py` creates target/current pairs with known identical notes, a
fixed Cream → Comp → Delay chain, and a cutoff automation ramp. One to
three of twelve normalized controls differ per pair. Labels store the
target-minus-current correction; `run.json` defines physical-unit mappings.
The sweep control multiplies the starting cutoff at beat 8. These are
bounded useful ranges, not the machines' entire parameter spaces.

Build and run from the repository root:

```sh
zig build -Doptimize=ReleaseFast
uv venv scratch/soundmatch-venv
uv pip install --python scratch/soundmatch-venv/bin/python numpy
scratch/soundmatch-venv/bin/python tools/soundmatch/generate.py \
  --out scratch/soundmatch-bench-01 --count 6
scratch/soundmatch-venv/bin/python tools/soundmatch/generate.py \
  --out scratch/soundmatch-pilot-01 --count 200 --seed 20261203
```

Output directories must be new. Each pair retains two `.slab` packages,
48 kHz stereo 16-bit WAVs (four-second phrase plus 0.5-second tail), logs,
and `labels.json`. Outputs under `scratch/` are ignored by Git. The run
records source revision and binary SHA-256. Rebuild before generation;
the binary hash alone does not prove it corresponds to the checkout.

Before each render, generation checks available space (default floor:
20 GiB) and total output size (default ceiling: 2 GiB), reserving another
16 MiB. A render has a 120-second timeout. Partial results survive failure;
only a successfully completed run writes `report.json`. Progress includes
free disk space. The report projects 200/10,000-pair costs from measured
throughput; startup, filesystem caching and thermals affect extrapolation.

Validation checks readable stereo PCM, non-silent/non-clipped output and
different target/current hashes. This is signal validation, not a listening
test or proof that every changed control is perceptually identifiable.
All related renders of a pair share its train/validation assignment; the
benchmark uses a separate seed range from the 200-pair pilot. Both sets
still share a preset family: this does not measure generalization to new
instruments or external recordings. No learning result is claimed.

Audit and run a short supervised correction test:

```sh
uv pip install --python scratch/soundmatch-venv/bin/python torch
scratch/soundmatch-venv/bin/python tools/soundmatch/audit.py scratch/soundmatch-pilot-01
scratch/soundmatch-venv/bin/python tools/soundmatch/train_smoke.py \
  scratch/soundmatch-pilot-01 --out scratch/soundmatch-training-01 --steps 100
```

The compact CNN receives target/current/difference log spectral features
and current normalized settings. It predicts normalized parameter deltas.
Training uses 160 pairs and validation 40 for a 200-pair run. Compare the
validation parameter MSE to the unchanged-settings baseline. Eight held-out
predictions are rendered and compared by multi-resolution spectral
convergence (lower is better); WAVs and projects remain available to audition.
Neither this metric nor parameter MSE establishes perceptual quality.
The script selects MPS when available, otherwise CPU, and reports the
actual device, speed and sampled MPS driver allocation (not whole-system
peak memory). No adversarial judge is trained. The zero-initialized output
starts at the unchanged-settings baseline. The feature scale is fit only
on the training split. The checkpoint is a research artifact, not an app
feature; a short run may worsen validation/audio scores.

Future experiments should compare against simple parameter search too.

## Scaling and controls

`train_smoke.py` also supports longer experiments:

- `--extra-dataset DIR` (repeatable): combine independent generated shards.
  Duplicate pair seeds are rejected; each shard must have a completed report.
- `--eval-every 200`: evaluate on the validation split, retaining the best
  parameter-MSE checkpoint, including the initial no-change model.
  `history.json` records the learning curve. Training time now includes
  these periodic validations and checkpoint copies.
- `--test-dataset DIR`: reserve an entire fresh dataset for testing after
  checkpoint selection. Test audio is never used for optimization,
  normalization or checkpoint selection. It is preprocessed with the other
  audio for convenience. The selected checkpoint is evaluated once on it.
- `--render-count 100`: render this many test predictions (or validation
  predictions when there is no test dataset), preserving seed-based filenames.
- `--settings-only`: zero all audio features during training/evaluation.
  This otherwise identical model tests how much correction can be learned
  from the parameter sampling distribution alone.

For the audio model, the test also reports parameter MSE after permuting
target features between examples while retaining each current recording
and current settings. The difference features are recomputed. This probes
dependence on the target; it does not establish perceptual fidelity.

Checkpoints are selected by validation parameter MSE, not by the rendered
test score. Report both: lower parameter MSE need not improve sound.
The source/seed of each rendered prediction is stored in `report.json`.
Multiple serial generators can run in parallel with disjoint seeds/output
directories; each retains its own storage budget and shared free-space
floor. Sum their budgets when planning a run.
Full transcription, arbitrary effects topology and mixed-track separation
are outside this first generator's scope.
