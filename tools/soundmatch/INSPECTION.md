# Weight-guided inspection — 2026-11-03

Method inspiration: https://rikiyat.github.io/blog/weight-space-programming/
This adapts weight inspection plus bounded, gradient-free interventions.
It is not a blind replication: the model architecture, training data,
purpose and previous failures were already known. No training occurred.
Weight norms alone are not proof of a neuron's semantic function.

Checkpoint: `scratch/soundmatch-large-audio/checkpoint.pt`, SHA-256
`d3ce87dc05467afc482a2ab32546a7c966457e59ba04bdaa135049e4e48159d0`.
Original weights remain unchanged; edits were made only to in-memory copies.

## Evidence from weights

Inputs are target T, current C, and D=T−C, each stereo. Consequently the
first convolution has effective filters Wt+Wd for T and Wc−Wd for C.
Their cosine similarity is −0.636: the filters favor opposing responses,
consistent with a learned comparison. Their sum has norm 2.901, versus
6.142 for their difference: common content still has a nonzero path.
This observation concerns the first linear operation, not the semantics
of the entire nonlinear network.

The exact local derivative through the direct current-settings pathway
was computed from the two head matrices and the analytic GELU derivative,
holding encoded audio fixed. Every mean self-derivative was negative,
from −0.031 for compression threshold to −0.158 for filter LFO amount.
For detune it was −0.147. This is consistent with a restoring/shrinkage
prior: increasing a current setting makes its proposed correction more
negative. It does not by itself establish attraction specifically to 0.5.

Output biases are small (mean absolute contribution 0.00382). Zeroing
them worsens parameter MSE slightly, 0.005566 → 0.005636, and does not
remove unwanted edits. The problem is distributed in learned paths,
not simply one erroneous output bias.

## Behavioral probes

On all 100 existing test examples, replace target features with the current
features, making the difference channels zero. These recordings now match
exactly, so the appropriate output is zero correction.

- Mean absolute proposed correction: 0.03083 normalized units.
- 99/100 examples have at least one correction above 0.05 in magnitude.
- Largest mean identity errors include filter LFO 0.0482, amp release
  0.0436, detune 0.0432, drive 0.0418 and filter decay 0.0412.
- Cutoff is relatively better at 0.00844; compression threshold 0.01333.

The generator always perturbs 1–3 controls. It never supplies an explicit
zero-edit example. The architecture also does not enforce f(C,C,c)=0.
Thus both data and architecture permit the observed failure. The probe
uses the current parameter state even where a perturbation put it outside
the target sampling interval; those cases may amplify distribution priors.

## Causal diagnostic interventions

Hypotheses were stated before running these renders. Use the first 24
existing test examples, without selecting by outcome:

| Variant | Mean spectral error | Better than unchanged |
|---|---:|---:|
| Keep current settings | 0.23697 | — |
| Full trained model | 0.43760 | — |
| Zero detune output row and bias | 0.21706 | 15/24 |
| Oracle: change only actually perturbed controls | 0.14691 | 22/24 |

The detune intervention changes only 512 weights plus one bias in a
copied network. Its output is a correction delta, so zero means preserve
current detune, not set oscillator detune to zero. It beats the original
prediction in 19/24 cases and lowers average error by about 50.4% versus
the original prediction, or 8.4% versus no correction. Parameter MSE over
all 100 pairs barely changes: 0.005566 → 0.005557.

The oracle mask retains the network's proposed values only on controls
the generator actually perturbed. It beats the original prediction in
20/24 cases. This uses hidden labels and is not a deployable method; it
isolates unnecessary edits as a major source of harm in this diagnostic.

These are interventions on previously examined test data, not a new
independent benchmark or proof of generalization. No listening test was
performed. Spectral error may penalize changes in beating/temporal
alignment that do not correspond equally to perceived timbre changes.

## Working explanation

The model learns useful coarse spectral/dynamic differences and a
parameter-distribution prior, but treats uncertain controls as dense
regression outputs instead of decisions to edit or abstain. Weak detune
estimates are especially harmful to the reconstruction metric. The
feature pipeline has 46.875 Hz STFT bins pooled to 187.5 Hz groups and
42.7 ms time steps, making fine harmonic spacing harder to represent.
Temporal beating could still carry detune information: this is not a
proof that detune is unidentifiable from these features.

The dramatic spectral improvement from freezing detune, with almost no
parameter-MSE change, shows that the training objective underweights this
sonically sensitive failure. It argues for zero-edit training examples,
an explicit identity constraint, sparse/confident edit decisions, and
audio-sensitive objectives before a bigger expert architecture. A fresh
evaluation set and listening comparisons are needed before adopting the
detune intervention as a fix.

## Reproduction and artifacts

```sh
scratch/soundmatch-venv/bin/python tools/soundmatch/inspect_model.py
```

This CPU diagnostic reads the existing checkpoint and 100 test pairs,
then renders 48 short files. It does not train, download, or modify the
checkpoint. It uses a 20 GiB disk floor. Re-running overwrites only its
own diagnostic results under `scratch/soundmatch-inspection/`.

- `weights.json`: static weight statistics from the initial inspection.
- `probes.json`: behavior, direct-setting derivatives, and render scores.
- `<seed>-detune_row_zero.wav`: edited-network diagnostic renders.
- `<seed>-oracle_edit_mask.wav`: label-informed diagnostic renders.
