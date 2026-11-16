# Hybrid oscillator correction results

40 preselected test cases: 32 altered and 8 identity; four holdout groups. Frozen nine-control 5k checkpoint. No new training. Prior eight audition examples excluded. These test examples have previously been scored automatically, so this is exploratory evaluation.

| Method | Spectral mean | Auraloss mean | Spectral improved / same / worse | Identity PCM changes |
|---|---:|---:|---:|---:|
| unchanged | 0.6861 | 1.3332 | 0 / 32 / 0 | 0/8 |
| model | 0.6582 | 1.3011 | 10 / 9 / 13 | 0/8 |
| search | 0.3022 | 0.6391 | 27 / 5 / 0 | 0/8 |
| hybrid | 0.2940 | 0.6430 | 28 / 4 / 0 | 0/8 |

Both search methods start from unchanged settings. Search edits only categories. Hybrid adds gated continuous-only neural proposals before each discrete round; the standalone model predicts all nine controls. Consensus acceptance requires both metrics to fall by more than max(1e-6, 0.001 × current error). Zero score regressions versus the start are therefore expected by construction, not independent evidence of perceptual safety.

| Search method | Mean seconds / altered case | Maximum seconds | Rendered candidates | Logical proposals | Time limits reached |
|---|---:|---:|---:|---:|---:|
| search | 6.67 | 25.58 | 992 | 1080 | 0 |
| hybrid | 7.59 | 36.77 | 1056 | 1140 | 0 |

Hybrid versus search on 32 altered cases: spectral 9 wins / 20 ties / 3 losses; auraloss 9 wins / 20 ties / 3 losses.

Total runtime 468.1s. Free space 62.1 GiB. Same 60-second and 42-proposal ceilings; two rounds. Search spends at most 40 proposals; hybrid at most 42, including neural proposals. Duplicate states cached only within a method. Already exact cases exit immediately.

Scores are the optimization objectives, not independent perceptual measures. Neural proposals after search see modified states outside the original training distribution. One checkpoint, small selected test subset. Protocol: [HYBRID_SEARCH.md](HYBRID_SEARCH.md). Artifacts: `scratch/soundmatch-hybrid-40`.
