# Hybrid oscillator correction

Compare the frozen nine-control oscillator model, categorical coordinate search, and hybrid continuous-neural/categorical-search correction. Use the existing 5k dataset, checkpoint and held-out rendered outputs; no generation of new training data or weight updates.

## Selection and protocol

Choose the first two identity, four sparse and four dense test cases in each of the familiar, waveform-family, phrase-family and joint holdout groups. Exclude the eight seeds in the previous oscillator listening manifest. This selects 40 cases (32 altered, eight identity) before inspecting outcomes. These cases were previously scored in aggregate; treat this as exploratory evaluation, not a fresh final test.

All methods start from the original current settings. Standalone model uses its previously saved nine-control prediction. Both search methods use up to two rounds, a 42-proposal ceiling and a 60-second wall-time deadline per case. Each discrete round renders the 20 one-switch alternatives across wave1/wave2/range1/range2/range3. Search freezes continuous controls. Hybrid first proposes the four continuous controls using the existing gated network, retaining the current categorical controls, then performs its discrete round. Recompute current features and the parameter-state input after edits.

Accept a candidate only if both spectral and auraloss scores improve by more than `max(1e-6, 0.001 * current_score)`. Rank accepted candidates by the sum of their new/current score ratios. Stop after two rounds, at the limits, at exact zero loss, or when an entire round accepts nothing. Never use target parameters to propose or select edits.

Both methods have the same caps, not exactly the same expenditure: discrete search uses at most 40 proposals; hybrid can use 42. Wall time includes feature extraction, inference, rendering and scoring. Initial/reference scoring is common setup and excluded. Alternate method execution order across cases. Cache duplicate proposals only within each method, with duplicates still charged to the proposal count; no cross-method cache. Six renderer workers check the deadline before launching; in-flight renders finish, and no further scoring starts after the deadline. Report any deadline overrun.

Spectral scoring caches reference STFTs and must agree with the previous unoptimized implementation. Auraloss configuration is unchanged. Both optimize the same metrics reported, so zero score regressions are guaranteed by the gate and do not establish perceptual safety. Preserve already-correct audio and check PCM equality. Hybrid proposal inputs after edits can differ from its training distribution.

## Outputs and disk

Output: `scratch/soundmatch-hybrid-40`. Refuse overwriting an existing run. Require 4 GiB storage reserve above the shared 25 GiB floor. Remove each method's temporary candidate renders after copying its final WAV and project. Retain per-case states, score traces, proposal counts and timings; original data and checkpoints remain untouched.

Eight optional blind comparisons: first distinct PCM outputs per group, comparing hybrid versus search and hybrid versus standalone model. Choose by group/order and distinct audio, never by score margin. Randomize and balance A/B within each matchup. Use the existing listening app; no mandatory audition.

```sh
OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 \
  scratch/soundmatch-venv/bin/python tools/soundmatch/hybrid_search.py
```

Results: [HYBRID_SEARCH_RESULTS.md](HYBRID_SEARCH_RESULTS.md).
