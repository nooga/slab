# Comparator listening results

Twelve blind comparisons were chosen where the two metrics rank candidates oppositely. Three distinct examples per family; balanced A/B placement. Existing montage examples were excluded. See `disagreement_test.py` and the experiment protocol.

- Auraloss agrees with the listener: 6.
- Original spectral convergence agrees: 5.
- Ties: 1; skips: 0; unanswered: 0.

Auraloss agrees on 6/11 decisive labels. Exact binomial 95% interval: 23.4%–83.3%, conditional on these selected disagreements and assuming independent trials. This does not establish a better comparator.

| Test family | Auraloss | Original spectral | Tie |
|---|---:|---:|---:|
| familiar | 2 | 0 | 1 |
| patch | 2 | 1 | 0 |
| phrase | 2 | 1 | 0 |
| joint | 0 | 3 | 0 |

Each subgroup has only three examples; subgroup differences are hypotheses, not established effects. Both metrics are useful proxies, and neither is validated as a replacement for listening. A lower optimized loss is not itself evidence of perceptual improvement.

Keep both scores during experiments; agreement can prioritize candidates, but is not proof of perceptual correctness. Retain periodic blind checks, particularly under new instruments, chains or mixtures. These labels may inform development; a comparator tuned on them must be evaluated on fresh examples.

Raw labels: `scratch/soundmatch-comparator-test/web-labels/labels.json`. Decoded results: `scratch/soundmatch-comparator-test/feedback-summary.json`.
