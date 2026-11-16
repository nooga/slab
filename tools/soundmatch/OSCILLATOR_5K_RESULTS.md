# Focused oscillator results

4 continuous controls and 5 categorical controls. 5,000 train / 200 validation / 200 test pairs. Single training seed; known MIDI and routing. No refinement search.

Generation: 729.3s. Training: 241.4s on mps; 1,212,742 weights. Selected update 2346/9375.

| Test group (altered pairs only) | Count | Initial spectral ↓ | Model spectral ↓ | Initial auraloss ↓ | Model auraloss ↓ | Improved / unchanged / worsened (spectral) |
|---|---:|---:|---:|---:|---:|---:|
| all | 160 | 0.6839 | 0.6268 | 1.3670 | 1.2830 | 75 / 26 / 59 |
| familiar | 40 | 0.6864 | 0.6138 | 1.4390 | 1.3360 | 20 / 6 / 14 |
| patch | 40 | 0.7149 | 0.6741 | 1.4718 | 1.3984 | 16 / 7 / 17 |
| phrase | 40 | 0.6495 | 0.5676 | 1.2738 | 1.1530 | 24 / 7 / 9 |
| joint | 40 | 0.6849 | 0.6516 | 1.2834 | 1.2445 | 15 / 6 / 19 |
| sparse | 80 | 0.5126 | 0.5038 | 1.0496 | 1.0516 | 26 / 24 / 30 |
| dense | 80 | 0.8553 | 0.7497 | 1.6844 | 1.5143 | 49 / 2 / 29 |

Identity render changes: 0/40. Matching-audio probes edited: 0/200.

Continuous normalized parameter MSE: 0.05219 → 0.04794.
Category accuracy on all test categories: 75.0% → 74.1%. Changed-category accuracy: 10.0%.

## Per-control diagnostics

| Control | Initial error | Model error |
|---|---:|---:|
| lvl1 | 0.05705 | 0.05492 |
| lvl2 | 0.04366 | 0.03908 |
| lvl3 | 0.04741 | 0.05892 |
| detune2 | 0.06065 | 0.03885 |
| wave1 | 0.27000 | 0.27500 |
| wave2 | 0.24500 | 0.25000 |
| range1 | 0.26000 | 0.29500 |
| range2 | 0.24000 | 0.25500 |
| range3 | 0.23500 | 0.22000 |

## Generalization of the selected checkpoint

| Split | Continuous MSE | Changed-category accuracy |
|---|---:|---:|
| train | 0.02732 | 15.0% |
| validation | 0.04505 | 5.4% |
| test | 0.04794 | 10.0% |

| Categorical control | Changed test cases | Recovery accuracy |
|---|---:|---:|
| wave1 | 54 | 3.7% |
| wave2 | 49 | 0.0% |
| range1 | 52 | 9.6% |
| range2 | 48 | 29.2% |
| range3 | 47 | 8.5% |

Continuous rows use MSE; categorical rows use misclassification rate. These are different units and should not be averaged together.

The harder data distribution prevents a clean numerical comparison with the previous 12-control experiment. Wider control coverage and supervised parameter improvement do not establish perceptual improvement. The categorical objective and validation weighting are first-pilot choices.

Eight balanced blind comparisons (model versus unchanged) are in `manifest.json`; sources chosen before considering scores. Protocol: [OSCILLATOR_5K.md](OSCILLATOR_5K.md). Artifacts: `scratch/soundmatch-oscillator-5k`.

## Blind listening

Model preferred: 3; unchanged preferred: 2; ties: 3; skipped: 0.
Agreement on the 5 decisive choices: spectral 3/5; auraloss 2/5. Metric preferences use raw error direction; human ties are excluded from these agreement counts.

| Trial | Group | Changes | Human | Spectral | Auraloss |
|---|---|---|---|---|---|
| expanded-01 | familiar | sparse | unchanged | unchanged | model |
| expanded-02 | familiar | dense | model | model | model |
| expanded-03 | patch | sparse | tie | model | model |
| expanded-04 | patch | dense | unchanged | model | model |
| expanded-05 | phrase | sparse | tie | unchanged | unchanged |
| expanded-06 | phrase | dense | model | unchanged | unchanged |
| expanded-07 | joint | sparse | tie | tie | tie |
| expanded-08 | joint | dense | model | model | model |

One listener and eight selected comparisons are insufficient to establish a reliable advantage or calibrate a perceptual comparator. These labels are evaluation evidence, not training data.
