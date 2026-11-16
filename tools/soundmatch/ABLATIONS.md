# Selective-edit and representation ablations

Completed measurements: [ABLATION_RESULTS.md](ABLATION_RESULTS.md).

Protocol fixed before test evaluation, 2026-11-03. Same 1,000 development
pairs as the scale-up: 800 train / 200 validation. A new 100-pair test
set uses seeds 20280000–20280099; prior test examples are excluded.
All tasks remain known-note, single Cream/Comp/Delay reconstruction.

Four arms, one training seed (42), batch 16, 3,000 updates, AdamW at 3e-4:

1. `dense`: original dense regression architecture and old features.
2. `dense_zero`: identical, with 25% of training inputs converted to
   matching current/current audio and zero correction targets.
3. `selective_zero`: same identity augmentation, with an additional
   supervised per-control edit gate and conditional correction amount.
4. `selective_multires`: same selective model/loss/augmentation, replacing
   only the input representation with multiresolution spectra.

The third comparison tests a package of gate architecture and its losses,
not just the gate at inference. Training minimizes soft-gated delta MSE,
plus 0.25 times changed-control amount MSE and 0.02 times binary gate
cross-entropy. Inference applies a fixed probability threshold of 0.5;
it is not tuned on test results. Gate biases start at the expected 12.5%
edit rate with identity augmentation. Exact-match bypass is not used:
identity results measure what the model learned, not a hard-coded rule.

All arms draw the same phrase indices and augmentation random numbers.
Dense discards the identity mask; the others apply it. Pair families stay
inside their original split. Normalization uses training examples only.
Every 200 steps choose the checkpoint minimizing 0.75 times validation
correction MSE plus 0.25 times validation identity MSE. The initial
no-change checkpoint is eligible. Test data never selects checkpoints.
This is still parameter-supervised training, not differentiable Slab or
audio-reward training. Rendered validation results can inform subsequent
experiments without using test outcomes to tune these runs.

## Representations

Old features are unchanged from `train_smoke.py`. New features preserve
stereo magnitudes from FFT windows of 512, 2048 and 8192 samples, at 48 kHz.
Each is interpolated onto 128 logarithmic frequencies from 30 to 20,000 Hz
and 128 aligned time centers across the clip. The long window's native
bin spacing is 5.86 Hz. Interpolation does not create frequency resolution
absent in the underlying FFT. Temporal sampling is still limited to
128 positions; this is not a full-resolution transient representation.
No phase is supplied. Target/current/difference inputs use 18 channels
instead of 6. The trunk and pooled embedding dimensions stay the same;
the first convolution and gate head add a small number of parameters.

Feature caches are memory-mapped; four CPU workers preprocess recordings.
A 20 GiB free-space floor is checked throughout preparation, training,
and rendering. All generated data and checkpoints stay under `scratch/`.

## Evaluation

Report parameter MSE, edit precision/recall, edits to correct controls,
and behavior on current/current audio. Render all 100 fresh correction
predictions, the first 20 validation predictions and the first 10 test
identity predictions for each arm. Use the unchanged multiresolution
spectral-convergence metric from earlier experiments. Distinguish improved,
unchanged and worsened cases; abstention alone is not an improvement.

Prepare listening comparisons from the first three fresh test examples,
without choosing examples by scores. The reference comes first; candidate
order is randomized and the mapping saved separately. These are materials
for a human listening test, not completed listener ratings.

## Commands

```sh
scratch/soundmatch-venv/bin/python tools/soundmatch/ablations.py prepare
scratch/soundmatch-venv/bin/python tools/soundmatch/ablations.py train --variant dense
scratch/soundmatch-venv/bin/python tools/soundmatch/ablations.py train --variant dense_zero
scratch/soundmatch-venv/bin/python tools/soundmatch/ablations.py train --variant selective_zero
scratch/soundmatch-venv/bin/python tools/soundmatch/ablations.py train --variant selective_multires
scratch/soundmatch-venv/bin/python tools/soundmatch/ablations.py render
scratch/soundmatch-venv/bin/python tools/soundmatch/summarize_ablations.py
scratch/soundmatch-venv/bin/python tools/soundmatch/listening_pack.py
```

Use an execution context with MPS access for GPU training. The prepared
directory and each training output must be new; render reruns overwrite
only their own experiment renders. Machine-readable plan, predictions,
learning curves, checkpoints and reports are under
`scratch/soundmatch-ablations/`.
