# Expanded Cream correction pilot

This document describes the completed 26-control pilot. To reproduce it with
the current scripts, set `SLAB_SOUNDMATCH_PROFILE=legacy26` for each command.
The default profile now includes oscillator ranges (29 controls); it uses
`scratch/soundmatch-expanded-ranges/` and seed base 20500000, keeping the
completed data, checkpoints and listening labels separate. The ranges profile
has been configured and checked but has not generated data or trained.
See [PREDICTION_TARGETS.md](PREDICTION_TARGETS.md) for its complete control list.

The next milestone expands the sound-matching task, not the instrument count
or note transcription. Known notes, timing, velocities, fixed Cream settings,
and Cream → Comp → Delay routing remain supplied. One training seed (42),
roughly the previous network size, 60 expected passes over 2,000 training
pairs. Validation has 200 pairs and test 200, including familiar, unseen patch,
unseen phrase and joint holdouts (50 each). Family definitions come from the
previous diverse-data protocol. Each split uses disjoint seeds.

## Controls and data

23 continuous outputs: the original twelve plus oscillator 1/2/3 levels,
filter attack/sustain/release, amp attack/decay/sustain, LFO rate and LFO pitch
amount. Three categorical outputs: oscillator 1 waveform (5 options),
oscillator 2 waveform (5), LFO waveform (4). Live manifests validate option
counts. Bounded physical ranges are explicit in `expanded_data.py`.

20% exact matches, 40% new-control-only changes, 40% combined changes. Each
non-identity example changes 3–6 new controls (at least one categorical).
Combined cases also change 3–4 original controls. Continuous changes have
normalized magnitude 0.35–0.70 before clipping to bounds; categories always
change to a different legal value. Large parameter changes are not guaranteed
to create a large audible difference, particularly for inactive modulation.
Target/current pairs share the same notes and fixed state. No labels are
selected by spectral difference or listener preference. Non-identity renders
must differ and all renders must pass finite/silence/clipping checks.

The 40-dimensional fixed context excludes every tunable control. Current
waveforms enter as one-hot values; output waveform predictions use separate
categorical heads, not scalar regression. Continuous outputs use gated deltas;
categorical outputs use a gate plus argmax, or retain the current category.
All gates initialize off. On-the-fly 10% identity augmentation supplements the
20% exact-match data. No hand-edited weights or identity bypass.

Training: continuous gated MSE + 0.25 changed-only amount MSE + 0.02 gate BCE
+ 0.05 changed-only categorical cross-entropy. Validation selection uses
0.8 continuous MSE + 0.05 category error + 0.2 identity continuous MSE + 0.05
identity category edit rate. This is a first mixed-output baseline, not a
validated optimal weighting. Test data never selects thresholds/checkpoints.

## Evaluation and limitations

Render all 200 test predictions; report original spectral and auraloss means
on the 160 altered pairs, independently of 40 identity checks. Separate
family and new-only/combined results. Report categorical accuracy on changed
categories as well as all categories so copying unchanged values is visible.
This task and data distribution differ from the 12-control experiment;
absolute errors are not a clean before/after comparison of model quality.

Eight listening pairs use the first new-only and combined example per family,
without selection by model score. Compare unchanged and model output; model
is A four times and B four times. No refinement search is applied yet, so we
can evaluate the expanded model itself. No human ratings are assumed.

## Reproduce

```sh
scratch/soundmatch-venv/bin/python tools/soundmatch/expanded_data.py bench
scratch/soundmatch-venv/bin/python tools/soundmatch/expanded_data.py generate
scratch/soundmatch-venv/bin/python tools/soundmatch/expanded_data.py prepare
scratch/soundmatch-venv/bin/python tools/soundmatch/expanded_train.py train
scratch/soundmatch-venv/bin/python tools/soundmatch/expanded_train.py render
```

Artifacts: `scratch/soundmatch-expanded/`; disjoint benchmark seeds in
`scratch/soundmatch-expanded-bench/`. Eight render workers, two feature workers,
25 GiB free-space floor, 8 GiB reserved before generation. Features use ~1.76
GiB; expected total under 7 GiB. Generation benchmark: 24 pairs in 3.6 seconds,
about six minutes projected for 2,400. MPS training needs host GPU access.
Existing experiments and user labels are preserved.

Completed run: [results and generalization diagnosis](EXPANDED_RESULTS.md).
