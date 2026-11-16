# Comparing refinement acceptance rules

Protocol fixed before running, 2026-11-03. Same 5k checkpoint, twelve
controls, known notes, and Cream → Comp → Delay chain. No neural training.

Forty test examples beyond the first forty per family used in previous
render scoring: ten each familiar/patch/phrase/joint. Each group contributes
two identity, two subtle, three medium and three large perturbations.
These examples have not appeared in the listening sessions. They were
previously evaluated for parameter error, so this is not a wholly new dataset.

Three strategies start from identical 5k predictions. Each gets two rounds
of 24 coordinate proposals (±0.10 then ±0.04 normalized units for each of
12 controls), or 48 proposals total. Identical states share cached renders
and scores, saving work without giving any strategy extra proposals.

- Spectral: accept the best original spectral-convergence score.
- Auraloss: accept the best combined convergence/log-magnitude score.
- Consensus: require improvement on both; rank qualifying candidates by
  the mean of their two score ratios relative to the current state.

Each required metric must improve by more than max(1e-6, 0.1% of its current
value). Otherwise keep the current state. This consensus ranking is one
explicit design choice, not a uniquely defined voting method.

Record both metrics, accepted steps, unchanged outputs, and identity audio.
Report altered pairs separately from identity pairs. Consensus monotonicity
is guaranteed by its rule and does not prove better perceptual quality.
Cached spectral scoring is checked against the original implementation on
every initial render. All audio passes existing validity checks. Keep a
25 GiB free-space floor; progress includes disk use. Intermediate renders
are retained for reproducibility; expected storage is under 6 GiB.

Listening candidates are the first distinct-PCM outputs for each matchup:
consensus/spectral, consensus/auraloss, spectral/auraloss, at most four each.
Use distinct example seeds across the listening pack. Do not select by
metric gain. Balance sides within each matchup when its count is even.
Fewer trials are valid if strategies produce the same output. These trials
compare refinement methods, not isolated comparator accuracy.

```sh
OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 \
  scratch/soundmatch-venv/bin/python tools/soundmatch/refinement_vote.py
python3 tools/soundmatch/listener/server.py --port 8768 \
  --manifest scratch/soundmatch-refinement-vote/manifest.json
```

The experiment refuses to overwrite its output directory. It checkpoints
results after each example but does not implement automatic resume.
