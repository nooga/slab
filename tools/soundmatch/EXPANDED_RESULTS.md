# Expanded Cream pilot results

23 continuous controls and three categorical waveform controls. 2,000 train / 200 validation / 200 test pairs. Single training seed; known MIDI and routing. No refinement search.

Generation: 295.8s. Training: 95.8s on mps; 1,227,615 weights. Selected update 3750/3750.

| Test group (altered pairs only) | Count | Initial spectral ↓ | Model spectral ↓ | Initial auraloss ↓ | Model auraloss ↓ | Improved / unchanged / worsened (spectral) |
|---|---:|---:|---:|---:|---:|---:|
| all | 160 | 0.6748 | 0.6186 | 1.4053 | 1.2776 | 98 / 2 / 60 |
| familiar | 40 | 0.7126 | 0.6209 | 1.4552 | 1.2882 | 25 / 0 / 15 |
| patch | 40 | 0.6841 | 0.6231 | 1.4415 | 1.2916 | 26 / 0 / 14 |
| phrase | 40 | 0.6770 | 0.6022 | 1.3837 | 1.2664 | 28 / 0 / 12 |
| joint | 40 | 0.6255 | 0.6282 | 1.3407 | 1.2642 | 19 / 2 / 19 |
| new-only | 80 | 0.6005 | 0.5699 | 1.2002 | 1.1677 | 47 / 2 / 31 |
| combined | 80 | 0.7491 | 0.6673 | 1.6103 | 1.3875 | 51 / 0 / 29 |

Identity render changes: 0/40. Matching-audio probes edited: 0/200.

Continuous normalized parameter MSE: 0.04732 → 0.04637.
Category accuracy on all test categories: 65.5% → 60.7%. Changed-category accuracy: 13.5%.

## Per-control diagnostics

| Control | Initial error | Model error |
|---|---:|---:|
| cutoff | 0.03794 | 0.01734 |
| contour | 0.02388 | 0.03349 |
| emphasis | 0.02970 | 0.03544 |
| f_dec | 0.02918 | 0.03805 |
| a_rel | 0.03148 | 0.02942 |
| drive | 0.04017 | 0.04461 |
| detune2 | 0.02850 | 0.03148 |
| lfo_cut | 0.04556 | 0.05309 |
| delay_mix | 0.02237 | 0.02184 |
| delay_fb | 0.02835 | 0.02005 |
| comp_thresh | 0.02764 | 0.02270 |
| sweep | 0.03491 | 0.04066 |
| lvl1 | 0.07248 | 0.07115 |
| lvl2 | 0.05959 | 0.07084 |
| lvl3 | 0.07897 | 0.05079 |
| f_atk | 0.05430 | 0.06432 |
| f_sus | 0.06934 | 0.07284 |
| f_rel | 0.04873 | 0.06527 |
| a_atk | 0.06851 | 0.03184 |
| a_dec | 0.05916 | 0.07760 |
| a_sus | 0.06668 | 0.05614 |
| lfo_rate | 0.06433 | 0.04764 |
| lfo_pitch | 0.06663 | 0.07000 |
| wave1 | 0.34500 | 0.38000 |
| wave2 | 0.33500 | 0.40500 |
| lfo_wave | 0.35500 | 0.39500 |

Continuous rows use MSE; categorical rows use misclassification rate. These are different units and should not be averaged together.

The harder data distribution prevents a clean numerical comparison with the previous 12-control experiment. Wider control coverage and supervised parameter improvement do not establish perceptual improvement. The categorical objective and validation weighting are first-pilot choices. No human listening scores have been collected for these new examples.

Eight balanced blind comparisons (model versus unchanged) are in `manifest.json`; sources chosen before considering scores. Protocol and commands: [EXPANDED.md](EXPANDED.md). Artifacts: `scratch/soundmatch-expanded/`.

## Generalization diagnosis

Training continuous MSE fell from 0.04776 to 0.00271, versus test 0.04732 to 0.04637. Changed-category accuracy was 71.1% on training data versus 13.5% on test data. This large gap is evidence of overfitting in this pilot, not evidence that more network capacity is needed. The known-family test also performs much worse than the training set, so family holdouts alone do not explain it.
