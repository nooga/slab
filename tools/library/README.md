# Sample library

Slab keeps downloaded sample libraries in one place, `$SLAB_LIBRARY`
(default `~/Music/Slab/Library`). Presets and projects name files there
as `lib:<path>`, so the same preset works on every machine that fetched
the library.

## VCSL

The [Versilian Community Sample Library](https://github.com/sgossner/VCSL)
is CC0: pianos, harpsichords, organs, winds, harps, mallets, kalimbas and
a lot of percussion.

```sh
tools/library/vcsl.py --list          # what there is, with sizes
tools/library/vcsl.py                 # all of it: ~6 GB
tools/library/vcsl.py --only marimba --only kits
```

It downloads the library at a pinned commit into `vcsl/samples/`
(resumable: files already there are skipped), then writes one SFZ per
instrument into `vcsl/<bank>/`:

- **melodic** instruments (note names in the files): each sample covers
  the keys half way to its neighbours; velocity layers split the
  velocity range; repeated takes become round robins. With numpy, each
  sample's pitch is measured and tuned to it, and a whole octave the
  file names get wrong (VCSL's marimba and kalimbas) is corrected by an
  instrument-wide vote.
- **percussion** (no note names): each articulation gets a key from C2,
  with its velocity layers and round robins; the hi-hat folder maps to
  the GM hat keys and chokes.
- **kits**: `acoustic-kit` and `latin-kit`, composed from the percussion
  on General MIDI keys, each piece levelled on its own.

Every instrument is levelled to a -6 dBFS peak. Presets go into
`machines/sampler/presets/vcsl-{keys,strings,winds,mallets,perc,kits}/`.
Release samples (pianos, harpsichords, harmonicas, ocarinas, wine
glasses) become `trigger=release` regions of their instrument: the
sampler starts them at note-off in the same voice, beside the body's
release, and a piano's gets 3 dB quieter per second held.
Measurements are cached in `vcsl/analysis.json`.
