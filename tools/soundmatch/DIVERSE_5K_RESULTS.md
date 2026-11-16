# Diverse 5k results — 2026-11-03

5,000 training pairs, 200 validation pairs and 400 test pairs. The three new models use nested training subsets, identical architecture/loss and 60 expected passes per example. Larger sets therefore receive more optimization steps. All runs use one training seed.

| Model | Updates | Selected update | Training seconds | Test parameter MSE (400 pairs) | Spectral error (128 changed pairs) ↓ | Improved / unchanged / worsened |
|---|---:|---:|---:|---:|---:|---:|
| No correction | — | — | — | 0.014363 | 0.2148 | — |
| previous-model | — | — | — | 0.011728 | 0.1738 | 64 / 34 / 30 |
| model-1000 | 1875 | 1570 | 43.5 | 0.010402 | 0.1615 | 53 / 53 / 22 |
| model-2000 | 3750 | 3750 | 82.1 | 0.008972 | 0.1528 | 81 / 26 / 21 |
| model-5000 | 9375 | 6256 | 220.2 | 0.007494 | 0.1378 | 87 / 18 / 23 |

Audio evaluation uses the first 40 examples per test group (160 pairs): 128 altered sounds plus 32 exact matches. Exact matches are excluded from the spectral-error means above and checked separately. This avoids crediting abstention on already-correct audio as an improvement. Parameter metrics cover all 400 test pairs.

| Family test | No correction | Prior model | 1k | 2k | 5k |
|---|---:|---:|---:|---:|---:|
| familiar | 0.1910 | 0.1614 | 0.1317 | 0.1287 | 0.1111 |
| patch | 0.2268 | 0.1588 | 0.1600 | 0.1356 | 0.1166 |
| phrase | 0.2213 | 0.1699 | 0.1594 | 0.1514 | 0.1296 |
| joint | 0.2200 | 0.2052 | 0.1948 | 0.1954 | 0.1937 |

Familiar = new examples from training families; patch = held-out Growl; phrase = held-out octave-answer family; joint = both. Validation used different held-out families. Known fixed settings are supplied to new models but unavailable to the old architecture. The prior-model comparison changes distribution, data, context and training, and is not an isolated architectural ablation.

| Model | Actual identity audio changed / 32 | Matching-audio probes with >5% edit / 400 | Correct-control drift |
|---|---:|---:|---:|
| previous-model | 1 | 9 | 0.00794 |
| model-1000 | 0 | 0 | 0.00547 |
| model-2000 | 0 | 0 | 0.00455 |
| model-5000 | 0 | 0 | 0.00497 |

## Severity

| Model | Subtle error | Medium error | Large error |
|---|---:|---:|---:|
| No correction | 0.0853 | 0.2237 | 0.3336 |
| previous-model | 0.0974 | 0.1768 | 0.2467 |
| model-1000 | 0.0852 | 0.1742 | 0.2224 |
| model-2000 | 0.0867 | 0.1593 | 0.2111 |
| model-5000 | 0.0760 | 0.1496 | 0.1853 |

## Paired uncertainty

- model-2000-minus-model-1000: mean spectral difference -0.00869; paired example-bootstrap 95% interval [-0.02287, 0.00431]. Negative favors the larger set.
- model-5000-minus-model-2000: mean spectral difference -0.01501; paired example-bootstrap 95% interval [-0.03030, 0.00035]. Negative favors the larger set.

These intervals resample examples, not training seeds. They do not establish reproducibility across training runs. Spectral metrics are not human listening ratings. Large denotes parameter change size, not a verified perceptual difference. No hand-edited weights, oracle masks, frozen detune, or audio-loss training.

The prior single-preset model is evaluated unchanged. The three new checkpoints are trained from scratch. Gates remain at 0.5; final test data does not choose checkpoints or thresholds.

Listening materials are prepared from the first large-mismatch example in each family-test group, chosen without reference to model scores. Target first, then five randomized candidates (unchanged, prior model, 1k, 2k, 5k).

Blind listening feedback for joint holdout 20305515: the user ranked B (2k model) closest, followed by E (previous model), before identities were revealed. Remaining candidates were not ranked; no numeric ratings were assigned. The user subsequently expressed uncertainty about this ranking and preferred pairwise tests; treat it as tentative, not established evidence of model preference. Feedback is saved in `scratch/soundmatch-diverse-5k/listening/user-feedback.json`.

Disk remaining at report time: 63.43 GiB. Full protocol: [DIVERSE_5K.md](DIVERSE_5K.md).

Artifacts: `scratch/soundmatch-diverse-5k/`, including `comparison.json`, `model-*/checkpoint.pt`, `model-*/predictions.json`, `renders.json` and `listening/`.
