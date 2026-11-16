# Single-switch diagnostic

Purpose: separate recognition of a correct waveform/range setting from identification of the control requiring repair. This is a simplified diagnostic, not a replacement for the nine-control correction task.

- Fresh deterministic seeds; 1,000 training, 200 validation and 200 test pairs.
- Switches: wave1, wave2, range1, range2, range3; five settings each.
- Every split balances the 100 directed transitions (five controls × five current settings × four alternative settings). Labels are shuffled independently of phrase/holdout groups.
- Exactly one switch differs. All oscillator levels and detuning match the target and remain audible. Other sound shaping follows the focused oscillator protocol: open filter, static envelopes, no modulation, dry delay and fixed compressor.
- Training uses triangle/saw oscillator 3; validation patch holdouts use wide pulse and test patch holdouts square. Phrase families remain disjoint as in OSCILLATOR_5K.md. Validation and test each contain 50 familiar, patch, phrase and joint examples.
- Same multiresolution magnitude representation (FFT 512/2048/8192, 128 log-frequency bins, 128 times, stereo). The below-30-Hz limitation remains.
- Both networks retain the previous three-convolution encoder and 512-unit hidden layer, approximately 1.2 million weights. The task-specific output has 25 control/setting logits. Current settings are excluded, leaving 20 possible edits. Hinted recognition also masks out other controls, leaving four choices. The hint is never supplied to the unhinted model.
- Separate training from seed 42, AdamW 3e-4, batch 32, 1,875 updates (60 sampled passes). Select by validation cross-entropy every 156 updates. Report exact full repair, control identification, per-control accuracy and train/test gap. No unchanged examples or abstention: one edit is assumed necessary.
- This changes the categorical objective from gated multi-control prediction to direct action classification. Improvement would not isolate data simplification from objective changes.
- Exhaustive test search renders all 20 distinct edits and includes the existing unchanged render. Score each with both the existing spectral metric and auraloss. Hinted search uses the relevant subset. Exact-target candidates must reproduce the reference PCM. The target is guaranteed reachable, so search is an upper-bound pipeline check, not a perceptual validation on approximate matches. Different parameters may also yield indistinguishable sounds.
- No human labels used for training or checkpoint selection.
- Reserve 7 GiB at generation start; enforce a 25-GiB free-space floor during rendering and training. Retain all scores, but retain search WAVs only for original target, neural choices and comparator choices. Earlier experiments remain untouched.

Commands from the repository root, using `scratch/soundmatch-venv/bin/python`:

```sh
export OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1
python tools/soundmatch/single_switch.py bench
python tools/soundmatch/single_switch.py generate
python tools/soundmatch/single_switch.py prepare
python tools/soundmatch/single_switch.py hinted
python tools/soundmatch/single_switch.py unhinted
python tools/soundmatch/single_switch.py search
python tools/soundmatch/single_switch.py report
```

Outputs are isolated in `scratch/soundmatch-single-switch-1k` and `SINGLE_SWITCH_RESULTS.md`. Existing outputs cause generation/training/search to refuse overwriting.
