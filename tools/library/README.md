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

## Fairlight CMI disks

`tools/library/cmi.py` imports CMI Series II / IIx voices into
`$SLAB_LIBRARY/cmi/<collection>/<disk>/<VOICE>.vc` and writes an
Unfairlight CIA preset per voice into
`machines/unfairlight/presets/cmi-<collection>/<disk>/` (gitignored; the
preset menu nests collection → disk → voice). It reads ImageDisk `.IMD`
and raw 512,512-byte `.IMG` floppy images, loose `.VC` files with their
`.CO` control files, and 8-bit WAV dumps of voice RAM. Slab ships no Fairlight sounds; bring your own.

```sh
tools/library/cmi.py --list DISK.IMG                  # what's on a disk
tools/library/cmi.py --collection iix LIB_1_4/IMG/    # import a set
tools/library/cmi.py --catalog                        # rewrite CATALOG.md
```

Each voice is stored once, by the hash of its RAM: a disk that repeats a
voice another collection already brought points its preset at the first
copy, so import the set with the most complete files (`.VC` with its
header) first. `index.json` records every import and `CATALOG.md` lists
the collections, disks and voices with their segments, loop, Page 7 and
measured root. Files named `DELETED - …` (recovered from a disk's free
space, often partial) are skipped unless `--deleted`.

What the tool takes from a voice, and how sure it is:

- **RAM** at 0x1500, 16,384 bytes (checked: the IIx library's 843 `.VC`
  files extract byte-exact from their disk images, and WAV conversions
  match from there).
- **Loop** start/end segment at 0x1332/0x1333, on at 0x133B (plausible on
  831 of 843 voices).
- **Page 7** (filter, attack, damping, level, vibrato, loop, start
  segment) from the voice's control file `NAME.CO` on the same disk,
  when there is one (51 factory voices and the tour disks' patches):
  decoded against the Page 7 screen dumps that come with the tour disks.
  Attack and damping are milliseconds. FILTER → the card's latch as
  96 + 8 x FILTER, vibrato depth/64 semitones and speed/16 Hz: those
  scalings are guesses. Voices without one get the library's usual
  settings: ATTACK 10, DAMPING 50, FILTER 8.
- **Pitch**: the file stores no rate. The CMI's keyboard plays every voice
  from one key table, a 128-sample cycle at A440 on key 52 (MIDI = key +
  17), so ROOT is 54.232 at RATE 24 kHz. Tonal voices are also measured
  (YIN, numpy); one sampled off the CMI's semitones by more than half of
  one gets its measured pitch instead, in the octave nearest 54.232.
