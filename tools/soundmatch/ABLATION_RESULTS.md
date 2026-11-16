# Ablation results — 2026-11-03

All four arms trained for 3,000 updates on the same 800 training phrases. Checkpoints used 200 validation phrases, including identity probes. Test: 100 fresh phrases, plus their matching-audio counterparts. No threshold or hyperparameter was tuned using the new test scores.

| Model | Test parameter MSE | Spectral error ↓ | Improved / unchanged / worsened | Identity probes with >5% edit | Train seconds |
|---|---:|---:|---:|---:|---:|
| Unchanged | 0.010742 | 0.2444 | — | 0 | — |
| dense | 0.006402 | 0.4491 | 21 / 0 / 79 | 89/100 | 28.6 |
| dense_zero | 0.005999 | 0.4213 | 23 / 0 / 77 | 61/100 | 27.2 |
| selective_zero | 0.008238 | 0.1771 | 69 / 12 / 19 | 0/100 | 28.8 |
| selective_multires | 0.006972 | 0.1684 | 79 / 6 / 15 | 0/100 | 46.9 |

Validation-audio winner (first 20 validation examples, chosen independently of test scores): `selective_multires`.

Spectral error uses the same multiresolution convergence metric throughout. Parameter and audio rankings need not agree. Unchanged predictions count separately from improvements. Exact zero actions retain original parameter serialization to avoid roundoff edits.

| Model | Edit precision | Edit recall | False-positive rate on correct controls | Mean identity edit | Test spectral difference 95% interval |
|---|---:|---:|---:|---:|---|
| dense | 16.6% | 100.0% | 100.0% | 0.02944 | [0.1700, 0.2396] |
| dense_zero | 16.5% | 99.5% | 100.0% | 0.01995 | [0.1427, 0.2117] |
| selective_zero | 60.9% | 39.2% | 5.0% | 0.00000 | [-0.0930, -0.0421] |
| selective_multires | 67.8% | 50.8% | 4.8% | 0.00000 | [-0.0933, -0.0583] |

Intervals are paired bootstrap intervals over the 100 examples; they do not account for variation across training seeds. Dense-model false-positive rates count any edit above 1e-6 normalized units.

Multiresolution minus old selective mean spectral difference: -0.00870; paired 95% interval [-0.02803, 0.01042]. Its point estimate is better, but the interval includes zero. The evidence for selective edits is stronger than the evidence for an additional representation benefit.

Both selective models used a fixed 0.5 gate threshold, with generator labels only as training supervision. No oracle mask or detune freeze was used at inference. Identity probes are learned behavior, not a hard-coded bypass.

All 20 selective identity renders (10 per model) have PCM bytes identical to their current recordings. Whole WAV hashes differ because export metadata reflects the newly generated project.

The selective architecture is a package of gating and additional supervised losses. Multiresolution changes spectral sampling and adds 9,600 first-layer parameters. All runs have one training seed, one synth family and known notes. These results do not establish real-recording or mixed-track performance.

No acoustic-loss training was performed in these ablations. This suite tests zero-correction data, selective prediction and input representation; the renderer evaluates predictions. Future audio-loss experiments should remain a separate comparison.

Preparation took 42.8 seconds. Training times include periodic validation; all 520 renders and metric computation are additional.

Listening materials: `scratch/soundmatch-ablations/listening/README.md`, three randomized montages and an empty ratings CSV. No human listening scores have been collected. Examples are the first three fresh test phrases, not selected for favorable results.

Machine-readable reports, checkpoints and learning curves: `scratch/soundmatch-ablations/`. See [ABLATIONS.md](ABLATIONS.md) for protocol and commands.
