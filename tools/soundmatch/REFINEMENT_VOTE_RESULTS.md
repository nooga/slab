# Refinement acceptance comparison

Forty previously unauditioned test examples; 32 altered and eight identity. Same 5k predictions and 48 proposals per strategy. Both metrics are measured on all final outputs.

| Strategy | Spectral error ↓ | Auraloss ↓ | Spectral worsened / 32 | Auraloss worsened / 32 | Unchanged / 32 |
|---|---:|---:|---:|---:|---:|
| Initial 5k prediction | 0.1833 | 0.6069 | — | — | — |
| spectral | 0.0930 | 0.4756 | 0 | 0 | 1 |
| auraloss | 0.0947 | 0.4757 | 1 | 0 | 0 |
| consensus | 0.0924 | 0.4742 | 0 | 0 | 1 |

Consensus cannot worsen either optimized metric by construction. This table does not establish perceptual superiority or compare training objectives. A model trained on these search results would need fresh evaluation.

| Family | Strategy | Spectral error ↓ | Auraloss ↓ |
|---|---|---:|---:|
| familiar | initial | 0.1938 | 0.6540 |
| familiar | spectral | 0.1000 | 0.5376 |
| familiar | auraloss | 0.0983 | 0.5313 |
| familiar | consensus | 0.0982 | 0.5316 |
| patch | initial | 0.1458 | 0.5223 |
| patch | spectral | 0.0781 | 0.4144 |
| patch | auraloss | 0.0781 | 0.4144 |
| patch | consensus | 0.0781 | 0.4144 |
| phrase | initial | 0.1783 | 0.5987 |
| phrase | spectral | 0.1067 | 0.4925 |
| phrase | auraloss | 0.1157 | 0.5004 |
| phrase | consensus | 0.1066 | 0.4942 |
| joint | initial | 0.2153 | 0.6526 |
| joint | spectral | 0.0871 | 0.4579 |
| joint | auraloss | 0.0868 | 0.4565 |
| joint | consensus | 0.0866 | 0.4566 |

Final parameter states identical to consensus: spectral: 35/40, auraloss: 35/40.

Identity audio changes (out of eight): spectral: 0, auraloss: 0, consensus: 0.

Elapsed: 401.6 seconds. Unique renders: 2128. Free disk: 62.99 GiB.

Prepared 9 blind listening comparisons of distinct strategy outputs. No ratings collected at report generation. Selection and reproducible commands: [REFINEMENT_VOTE.md](REFINEMENT_VOTE.md).

Artifacts: `scratch/soundmatch-refinement-vote/`. Starting predictions, final states, both scores and per-round decisions are retained in `results.json`; `manifest.json` and `blind-key.json` define the listening study.

## Blind listening feedback

| Matchup | Votes |
|---|---|
| consensus vs spectral | tie: 2, spectral: 2 |
| auraloss vs consensus | consensus: 3, tie: 1 |
| auraloss vs spectral | tie: 1 |

One listener on nine selected distinct-output comparisons. Matchups have unequal counts; do not pool them into an overall win rate. Raw labels remain in `web-labels/labels.json`; decoded labels are in `listening-feedback.json` under the experiment directory.
