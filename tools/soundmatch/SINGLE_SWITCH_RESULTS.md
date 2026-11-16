# Single-switch diagnostic results

1,000 training / 200 validation / 200 test pairs. Exactly one incorrect switch per pair; known MIDI, routing and continuous settings. Each split balances all 100 directed switch transitions. Single training seed.

| Model | Selected step | Train exact | Validation exact | Test exact | Test control identification |
|---|---:|---:|---:|---:|---:|
| hinted | 468 | 78.4% | 62.5% | 56.5% | 100.0% |
| unhinted | 312 | 31.0% | 16.0% | 14.0% | 31.5% |

Random exact recovery is 25% with the changed-control hint and 5% without it. The hint masks the output choices; both models otherwise use the same network and train separately. Checkpoints minimize validation cross-entropy. No identity examples: this diagnostic assumes a correction is required.

| Method | Exact recovery | Spectral mean | Auraloss mean | Spectral improved / same / worse |
|---|---:|---:|---:|---:|
| unchanged | 0.0% | 0.5345 | 1.0672 | 0 / 200 / 0 |
| hinted | 56.5% | 0.2336 | 0.4480 | 155 / 0 / 45 |
| unhinted | 14.0% | 0.5574 | 1.1096 | 81 / 0 / 119 |
| hinted_spectral | 100.0% | 0.0000 | 0.0000 | 200 / 0 / 0 |
| hinted_auraloss | 100.0% | 0.0000 | 0.0000 | 200 / 0 / 0 |
| unhinted_spectral | 100.0% | 0.0000 | 0.0000 | 200 / 0 / 0 |
| unhinted_auraloss | 100.0% | 0.0000 | 0.0000 | 200 / 0 / 0 |

Search enumerates 20 distinct edits plus the unchanged candidate; hinted search restricts this to four edits plus unchanged. Target settings are guaranteed to be in the search space, and their renders were checked sample-identical to the reference. This is an upper-bound pipeline check, not validation of perceptual scoring when the target is unattainable. Search ties use the lowest action index.

Protocol and commands: [SINGLE_SWITCH.md](SINGLE_SWITCH.md). Artifacts: `scratch/soundmatch-single-switch-1k`.
