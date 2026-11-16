# Focused oscillator experiment

Protocol: 2026-11-03. The expanded 26-control experiment overfit heavily, so
this run narrows the task and increases training examples while keeping the
CNN architecture and training schedule family. This is a new task, not a
controlled data-size-only or architecture-only comparison.

## Predict nine controls

- Four continuous: OSC 1 level (0.2–1), OSC 2 level (0.1–1), OSC 3 level
  (0.1–0.7), OSC 2 detune (−0.15–+0.15).
- Five categories, five choices each: OSC 1/2 waveforms (triangle, saw,
  square, wide/narrow pulse), OSC 1/2/3 ranges (32′, 16′, 8′, 4′, 2′).

OSC 3 is free-running, not sub mode. Filter fixed at 12 kHz with resonance
0.05 and zero envelope amount. Amp ADSR: 5 ms / 100 ms / 1 / 150 ms.
Filter ADSR fixed; pitch/filter LFO amounts, noise, drive, sync, pitch envelope,
glide, aging and feedback are off. OSC 3 detune is zero. Machine output level
0.6, track volume 0.18, master 0.7. Existing Comp → Delay routing is retained
with fixed compressor threshold −12 dB, ratio 3, makeup 0, delay feedback 0.2
and zero delay mix. No cutoff automation. Candidate gains are never normalized
for scoring or training; listening uses the existing shared volume control.

Known fixed context contains 44 values, excluding all predicted controls.
Most fixed context entries are constants; the OSC 3 waveform varies by family.
Pitch, timing, velocity and phrase are shared across each target/current pair;
notes are used by the renderer, not transcribed or predicted by the model.

## Data and holdouts

5,000 training pairs, 200 validation, 200 test. Seeds 20600000 onward;
benchmark uses a disjoint +100000 offset. Test and validation each have 50
examples in familiar/patch/phrase/joint groups. Training OSC 3 waveform is
triangle or saw; patch holdout is wide pulse for validation, square for test.
These are oscillator-context families, not the original factory preset
families. Phrase families follow the previous diverse-data recipe, with
syncopated validation and octave-answer test holdouts. Bass/lead registers
and note velocities vary as before. The old spectral input starts at 30 Hz,
so very low fundamentals may be represented mainly by their harmonics.

20% identity; 40% sparse (1–2 controls changed); 40% dense (3–5 changed).
Continuous perturbations have normalized magnitude 0.30–0.65 before clamping;
categories change to another legal option. Every oscillator level has a
positive minimum so each range has an active oscillator, though masking and
parameter equivalence remain possible. No outcome-based data rejection,
except invalid audio or unchanged non-identity waveforms.

## Training and evaluation

Same 18-channel multiresolution audio input and mixed-output gated predictor
as the expanded pilot. Categorical currents are one-hot. AdamW 3e-4, batch32,
60 expected passes, seed42. Validation scoring/loss weights and gate threshold
are unchanged from EXPANDED.md; initial no-change checkpoint remains eligible.
No hand-edited weights, audio-loss training, refinement, or test-set selection.

Report continuous MSE, category accuracy on all and changed categories,
train/test gap, identity edits, and both audio scores on all 200 test renders.
Audio means exclude the 40 identities. Eight balanced blind trials use the
first sparse and dense test example from each group, selected without scores.
The goal is generalization of oscillator character, octave placement and
blend; exact knob recovery may be ambiguous when oscillators are interchangeable.

## Reproduce

```sh
export SLAB_SOUNDMATCH_PROFILE=oscillator
export OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1
scratch/soundmatch-venv/bin/python tools/soundmatch/expanded_data.py bench
scratch/soundmatch-venv/bin/python tools/soundmatch/expanded_data.py generate
scratch/soundmatch-venv/bin/python tools/soundmatch/expanded_data.py prepare
scratch/soundmatch-venv/bin/python tools/soundmatch/expanded_train.py train
scratch/soundmatch-venv/bin/python tools/soundmatch/expanded_train.py render
```

Artifacts: `scratch/soundmatch-oscillator-5k/`; old experiments unchanged.
15 GiB initial reserve with a 25 GiB free-space floor. Eight render workers,
two feature workers. Projected total storage under 14 GiB; existing free space
55 GiB. Benchmark: 24 pairs in 3.4 seconds, projected ~13 minutes generation.

The executed run prepares features concurrently using
`SLAB_SOUNDMATCH_PROFILE=oscillator python tools/soundmatch/stream_expanded_features.py`
in the existing research environment. It waits for completed pair labels,
checks finite features, and writes the same feature array shape and ready
marker as sequential preparation. Do not run both feature preparers on the
same output directory. Training waits for both generation and feature-ready
markers. This reduces elapsed time without changing training examples.
