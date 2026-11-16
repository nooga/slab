# Diverse 5k learning curve

Plan established before final test evaluation, 2026-11-03. Same 12
correction outputs as the pilot. This is still a single known instrument
and fixed Cream → Comp → Delay topology, with known notes.

## Dataset

5,000 training pairs, 200 validation pairs and 400 test pairs. Seeds
20300000–20305599. The benchmark uses a disjoint seed offset. Each example
is four seconds plus a half-second tail at 48 kHz stereo, 16-bit PCM.

- Training patches: `cream-lead`, `synthwave-bass`, `outstanding-funk-bass`.
- Training phrase families: staccato, pluck, legato, sustain.
- Validation: 100 familiar-family examples, 50 with held-out `bass-mog`,
  50 with held-out syncopated phrasing.
- Test: 100 familiar-family examples, 100 with held-out `growl`, 100 with
  held-out octave-answer phrasing, 100 with both held-out families.
- Bass/lead registers, velocities, and note intervals vary. Fixed amp
  attack/decay/sustain and glide vary with articulation. They are supplied
  to the model as known context, not additional correction targets.
- Exactly 20% identity pairs, 25% subtle, 30% medium and 25% large
  parameter perturbations. Non-identity pairs change 1–3 controls. Sizes
  in normalized units: 0.03–0.10, 0.15–0.30 and 0.40–0.70 (bounded at
  parameter limits). Large parameter changes are not guaranteed to sound
  obvious; no subjective ratings are asserted.

The 65-element context vector contains all untuned Cream settings, using
one-hot switches and range-normalized continuous values (log where the
manifest specifies an exponential range). Preset/family names, severity
labels and changed-control labels are not inference inputs. Effect
settings outside the three predicted effect controls remain fixed.
Held-out patches can contain fixed values outside training support; this
is deliberately a harder transfer test, not proof of broad generalization.

## Training and comparisons

Train from scratch on nested random subsets of 1,000, 2,000 and 5,000
examples, selected with seed 12345. Training seed 42. Use the selective
multiresolution model plus fixed-setting context, with the same gate and
amount losses as the preceding ablation. Gate threshold remains 0.5.

Batch 32, 60 expected passes per example: 1,875 / 3,750 / 9,375 updates.
This controls exposures per example, not total compute. Larger datasets
receive more optimization steps; this is not an equal-compute study.
An additional 10% of training batches' examples become current/current
zero-edit probes, including parameter values near perturbation limits.
This supplements the dataset's explicit identity pairs.

Every approximately five passes select by 0.8 validation parameter MSE
plus 0.2 validation identity-probe MSE; include the initial no-change
checkpoint. Compute feature normalization from each training subset only.
Do not tune on the final test set. Supply all fixed settings at inference.
No hand editing, oracle masking, detune freezing or audio-loss training.

Evaluate parameter/identity/edit metrics on all 400 test examples. Render
the first 40 per test group (two complete severity cycles), plus two
identity probes per group: 168 renders per model. Compare the three
learning-curve models and the prior single-preset multiresolution model.
The prior model cannot consume fixed-setting context; that comparison is
distribution transfer, not a clean context-only ablation.

Keep per-group and severity results, not only pooled means. Prepare blind
listening montages for one large-mismatch example per group without
selecting by outcome. Human ratings remain a separate step.

## Generation, disk and reproducibility

Eight serial-render workers generate pairs; identity WAVs are hardlinked
within each pair to avoid duplicate rendering/storage. Both editable
projects are retained. Vectorized audio validation was checked against
the original implementation. Nonfinite, silent, clipped, or unchanged
non-identity outputs fail generation. Labels are written atomically after
both renders complete. Completed pairs can resume only with matching
generator, renderer, preset and plan provenance.

25 GiB free-space floor; 24 GiB audio/project payload ceiling, with feature
storage reserved before generation. Actual planned total is under 20 GiB.
The byte counter conservatively counts both identity hardlinks. Progress
records include free space. Streaming feature preparation uses two CPU
workers, reading only completed pairs; training waits for the ready marker.

```sh
scratch/soundmatch-venv/bin/python tools/soundmatch/diverse_data.py --workers 8
scratch/soundmatch-venv/bin/python tools/soundmatch/diverse_train.py prepare
scratch/soundmatch-venv/bin/python tools/soundmatch/diverse_train.py train --count 1000
scratch/soundmatch-venv/bin/python tools/soundmatch/diverse_train.py train --count 2000
scratch/soundmatch-venv/bin/python tools/soundmatch/diverse_train.py train --count 5000
scratch/soundmatch-venv/bin/python tools/soundmatch/diverse_train.py legacy
scratch/soundmatch-venv/bin/python tools/soundmatch/diverse_train.py render
scratch/soundmatch-venv/bin/python tools/soundmatch/diverse_report.py
```

GPU training needs MPS access. Data, feature caches, checkpoints and
reports live under `scratch/soundmatch-diverse-5k/`, outside Git.

Completed run: [results and limitations](DIVERSE_5K_RESULTS.md). Generation
took 11m22s; the 5k training run took 3m40s. Final checks covered all 672
evaluation renders, nested training subsets, and four listening montages.
Each new model preserved exact PCM on 32 identity pairs and eight additional
matching-audio renders. The experiment directory occupies about 13 GiB;
63 GiB remained free after evaluation.
