# Auraloss trial

This experiment uses `auraloss==0.4.0` to score existing model renders and
guide derivative-free parameter refinement through the real Slab renderer.
It does not retrain the network. Slab's external renderer does not expose
an autograd path; merely replacing the parameter loss with an audio loss
would not propagate gradients to the correction model.

## Protocol

- Channel-preserving stereo, 48 kHz, 4.5 seconds; no gain normalization.
- `MultiResolutionSTFTLoss`: FFT/window sizes 512/2048/8192, hops
  128/512/2048, Hann windows, spectral convergence weight 1 and log-magnitude
  weight 1. No phase, mel scaling, perceptual filtering or scale invariance.
- Score all 160 previously rendered test pairs, with four trained-model
  candidates and unchanged input. Report changed-pair means on 128 cases;
  check target-versus-itself equals zero on all 160.
- Refine six validation examples: first medium and first large perturbation
  in each familiar, held-out-patch and held-out-phrase group. The validation
  families differ from test holdouts. This is a feasibility trial, not a
  fresh held-out estimate of generalization.
- Compare unchanged and 5k-model starts. Each receives one initial render
  and 48 proposals: two best-neighbor rounds over 12 controls, both
  directions, normalized steps 0.10 and 0.04. Accept only lower loss.
  Target parameter labels are not used by the search.
- The objective decreases by construction. That alone does not demonstrate
  better perception. Preserve before/after audio and editable projects;
  prepare randomized reference/A/reference/B listening files for model starts.
- Keep the existing 25 GiB free-space guard; run six serial-render workers.
  No changes to existing datasets or checkpoints. No human ratings assumed.

## Reproduce

Requires the completed diverse-5k experiment and its existing Python environment:

```sh
uv pip install --python scratch/soundmatch-venv/bin/python auraloss==0.4.0
scratch/soundmatch-venv/bin/python tools/soundmatch/auraloss_trial.py
```

The script creates `scratch/soundmatch-auraloss` and refuses to overwrite an
existing run. `report.json` records loss settings, versions, source hash,
elapsed time and disk space. Per-example scores and refinement records live
alongside it. Listen using `listening/README.md`; identities are separate in
`listening/blind-key.json`.

Reference: [auraloss implementation and documentation](https://github.com/csteinmetz1/auraloss).

## Results

| Starting candidate | Mean auraloss before | After 48 proposals |
|---|---:|---:|
| unchanged | 0.9933 | 0.8710 |
| model-5000 | 0.7728 | 0.6013 |

All six examples improved the optimized objective from both starts. This
is expected for an accept-only-if-better search, not proof of perceptual
improvement. Six blind listening pairs are saved; no ratings collected.

| Existing candidate | Auraloss mean (128 changed test pairs) | Improved / unchanged / worsened |
|---|---:|---:|
| unchanged | 0.7050 | 0 / 128 / 0 |
| previous-model | 0.6224 | 66 / 34 / 28 |
| model-1000 | 0.5934 | 58 / 53 / 17 |
| model-2000 | 0.5852 | 86 / 26 / 16 |
| model-5000 | 0.5608 | 95 / 18 / 15 |

The 5k model remains best overall. On the joint patch/phrase holdout,
1k scores 0.6390, 2k 0.6429 and 5k 0.6491; lower is better. These are
descriptive comparisons, not statistically established differences. All 32
identity pairs score exactly zero for each new model. Auraloss values are
on a different scale from the earlier spectral metric.

Total scoring/refinement runtime: 131.6 seconds. Remaining disk: 63.93 GiB.

For 20305515, auraloss ranks 5k, 2k, 1k, unchanged, previous-model.
It therefore does not reproduce the tentative B/E listening preference.

Verification: 160 self-comparisons equal zero; 12 bounded refinement
results; six 21-second stereo listening files; finite nonzero autograd
gradient to a test waveform; Python compilation and diff whitespace checks.

## Fast labeling app

Use the [local listening room](listener/README.md) for reference/A/B playback,
keyboard labeling, automatic save/advance, and resumable blind comparisons.

## Pairwise listening feedback

The user labeled all six web comparisons: refined preferred twice, four
ties, and no preference for the original 5k prediction. Both preferences
were large-perturbation cases (20305015 familiar and 20305155 phrase holdout).
All six comparisons lowered auraloss, but four were labeled indistinguishable.
This is one listener on six validation examples, not evidence of a reliable
win rate. Refined happened to be B in five of six assignments; future trials
should balance sides and use fresh examples. Original labels remain in
`listening/web-labels/labels.json`; decoded results in
`listening/feedback-summary.json` under the experiment directory.
