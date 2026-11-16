# Local listening room

Run from the repository root with Python 3 (standard library only):

```sh
python3 tools/soundmatch/listener/server.py
```

Open http://127.0.0.1:8765. The app loads the six model-start before/after
pairs from the completed auraloss trial. It uses that trial's stable blind
A/B assignment. Audio is served through neutral IDs; candidate identities,
source paths, and scores are never sent to the browser.

- R: reference; 1/2: candidates A/B; Space: stop.
- A/B: choose closer candidate; T: no audible difference; S: skip.
- Choices save immediately and advance. Previous and the numbered strip
  revisit answers. Reload resumes at the first unanswered pair.
- The completion screen offers review and return to skipped pairs.
- Export downloads blind JSON labels. Labels are also saved atomically to
  `scratch/soundmatch-auraloss/listening/web-labels/labels.json`.
- The `heard` field records which clips were started, not whether the whole
  clip was heard. Labels are allowed without forced playback.
- Each playback starts from zero; no loudness normalization or overlapping
  players. The sequence button plays reference/A/reference/B.

The server binds only to loopback, serves an explicit file allowlist, and
rejects cross-origin label writes. There is one local listener/session;
multiple browser tabs share labels. Keep the server running while labeling.
Use `--port` and `--state-dir` for a separate session; test labels must never
be mixed into user feedback.

Checks: `python3 -m unittest discover -s tools/soundmatch/listener -p 'test_*.py'`.
Tests use a temporary state directory. Browser verification covered playback,
keyboard labels, ties, skips, revising, reload/resume, completion and narrow
layout. This app gathers listening evidence; it does not train a model.

Visual direction follows Slab's `docs/06-ui-widgets.md`: dark wells, flat
hardware panels, sharp borders, amber only for active controls. This is an
Operate surface; the comparison and label actions take priority over decoration.

Listening volume uses a shared Web Audio gain (-12 to +24 dB, default +12),
remembered in the browser. Each pair is decoded to find the maximum sample
peak across reference/A/B; shared gain is capped to leave 1 dB sample-peak
headroom. Relative levels are preserved, with no compression or independent
loudness normalization. This is sample-peak protection, not a true-peak limiter.

Additional studies can supply a local manifest with `experiment`, `title`,
and `trials` (each containing `id` and `sources.reference/A/B` absolute WAV
paths). The manifest stays server-side. Example:

```sh
python3 tools/soundmatch/disagreement_test.py
python3 tools/soundmatch/listener/server.py --port 8767 \
  --manifest scratch/soundmatch-comparator-test/manifest.json
```

With a custom manifest, labels default to `web-labels/` beside that manifest;
the prior study's labels are preserved. The comparator study uses 12 distinct
examples, three per test family, selected for the strongest opposing metric
preferences (minimum relative gap across the two scores). Each metric prefers
A six times and B six times. Ties/skips remain separate from decisive votes;
results describe these selected disagreements, not universal metric accuracy.
