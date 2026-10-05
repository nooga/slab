# 30 — Extract: audio into music

How an audio clip becomes what it plays: notes from a hummed or sung
line, a bassline or a melody, the chords and the key, the drums as a
pattern and a kit, the stems of a whole song, and a voice put in tune.
Everything comes out as something you edit in Slab (pattern clips,
groove templates, sampler kits, audio clips), placed on the song's
beats through the clip's warp (docs/29).

Status: phase 1 built (2026-10-05) on `feat/extract`: the pitch
tracker, notes, *Audio to notes* and hum to notes. The rest is designed.

## What musicians expect (and other tools do)

- **Hum it, get notes.** Sing or hum a line into the mic and play it back
  on a synth (Live's *Convert Melody to New MIDI Track*, Logic's Flex
  Pitch → MIDI, Melodyne's MIDI export, Dubler).
- **Take a song apart.** Drop in a track and get drums, bass, vocals and
  the rest as stems (Logic's Stem Splitter, Serato/rekordbox stems,
  Ultimate Vocal Remover, all on Demucs-style models).
- **Rebuild it.** From the parts: the drum pattern and a kit cut from
  the hits (*Convert Drums to New MIDI Track*, slicing), the bassline,
  the chords (Logic's Chord Track, Chordify, Capo), the melody, the
  groove.
- **Sound like it.** Bring the parts up on in-house instruments that are
  near the original: the closest kick in the library, a bass preset
  near the original's tone.
- **Put a voice in tune.** Snap a vocal to a key, as hard (the effect) or
  as gently (correction) as wanted (Auto-Tune, Melodyne, Logic's Flex
  Pitch, Waves Tune); draw a note's pitch where it should be.

## The pieces

| Extractor | How | Model | Good on |
|---|---|---|---|
| Pitch (one voice) | pYIN: YIN's dip, candidates under a threshold prior, Viterbi over pitch and voicing | none | voice, hum, whistle, bass, lead |
| Notes (one voice) | the pitch track cut at semitone changes and onsets, tuned to the take | none | same |
| Chords and key | chroma per beat from a constant-Q spectrum, matched to chord templates, smoothed by an HMM; key by Krumhansl profiles | none | pop, electronic, rock |
| Drums | onsets (docs/29 §Transients), each hit classed kick/snare/hat/other by its spectrum; slices to a kit | none (a model on mixes) | loops, drum stems |
| Groove | built (docs/29 §Extract groove) | none | loops, takes |
| Stems | a source-separation network (HTDemucs: drums, bass, vocals, other) | CoreML | whole songs |
| Notes (polyphonic) | Basic Pitch (Spotify): frames, onsets and contours to notes | CoreML | keys, guitar, a stem |
| Sound match | nearest library sample by spectral features; preset and parameter search by headless render | none (search) | drums easily; synths as research |
| Tune | the pitch track snapped to a scale, with retune speed, rendered by a formant-keeping pitch mode | none | voice |

Everything but stems and polyphonic notes is DSP written in Zig. The
models come with phase 4.

## The pitch tracker

`pitch.zig`, on a worker thread like transients (docs/29 §Transients),
never on the audio thread. Unlike transients it runs only when first
asked for (`AudioPool.requestPitch`), and is kept on the source after
that. A three-minute song takes about 1.3 s.

- **In**: the source's mid, read through the band-limited reader
  (`warp.read`) to 16 kHz. A voice's or a bass's fundamental is under
  2 kHz, and at 16 kHz a frame costs a ninth of what it does at 48.
- **Frames**: 1024 samples (64 ms, two periods of 32 Hz), hop 128 (8 ms).
  The difference function comes from autocorrelations by FFT (2048
  points), so a frame costs three transforms, not 1024 × lags.
- **Candidates** (pYIN): YIN's cumulative mean normalized difference
  d′(τ). For each of 100 thresholds weighted by a Beta(2, 18) prior,
  the first dip under it (or the global minimum, at a small weight)
  gets the threshold's weight; each candidate is refined by a parabola
  through its dip. A frame's voicing is the weight its candidates got.
- **The path**: 20-cent bins from 32 Hz (C1) to 2 kHz, each voiced and
  unvoiced. Viterbi over the frames: a voiced bin moves at most 25 bins
  (5 semitones) per frame, cheaper the less it moves; switching
  voicing costs 0.01. Out: per frame, f0 (Hz, 0 unvoiced; the nearest
  dip's own frequency, not the bin's), voicing probability, and the
  level over the frame's middle 20 ms. The path is decoded 4096 frames
  at a time, so a long take's backpointers stay small.
- **Range**: *any*, *bass* (32–400 Hz) or *voice* (65–1600 Hz) narrows the
  bins, which helps most on a mix. *Audio to notes* uses *any*. The
  narrow ranges are for stems (phase 4).

## Notes from the pitch

`pitch.notes`:

1. **Tuning**: a hummer is rarely at A440. The take's reference is the
   weighted circular mean of every voiced frame's distance from the
   nearest semitone. Notes are rounded against it, and the shift is
   reported ("tuned −23 ct"). *A440* turns this off.
2. **Cut**: a note runs while the frames are voiced and the median of
   the last 5 frames stays within ±0.5 semitones of the note's own
   pitch. A pitch held more than 60 ms on another semitone starts a new
   note at the change, unless what came before only passed through
   its pitch (shorter than 150 ms, under half of it within 0.3 of a
   semitone of it). That is a scoop into the note, and it joins the
   note. An onset of strength 0.3 or more (a re-sung syllable, docs/29
   §Transients), or the level rising 6 dB within 40 ms, starts a new
   note too. Unvoiced gaps up to 30 ms are bridged.
3. **Keep**: notes under 60 ms are dropped (glides, consonants).
   Vibrato and scoops stay inside a note because the median follows
   the held pitch, not the wobble.
4. **Pitch and velocity**: the note's pitch is the median of its frames
   (MIDI, against the reference). Velocity maps the note's peak RMS
   from −40..−6 dBFS to 30..120. Frames under −50 dBFS are left out.

## Audio to notes

*Audio to notes* (the arrangement's right-click on an audio clip not
reversed, and the audio clip editor's warp menu; `audioToNotes` in
`main.zig`) works like *Slice to a sampler track* (docs/29):

- the source is tracked once and cached on the source, like its hits.
  While that runs the status line says *Listening for notes…*, and the
  rest happens when it is done. If the clip has moved or gone by then,
  nothing happens;
- the notes inside the clip's played region land on the song's beats
  through its warp map when warped, or through the tempo map from the
  clip's start when not. A warped take's notes follow its markers;
- a track is added under the clip's: Cream with *Cream Lead*, or *Bass
  Mog* when the notes' median is under C3. Same output and groove, a
  pattern clip where the audio was;
- the audio clip is muted and the pattern selected. One undo step. The
  status line gives the count and the take's tuning ("12 notes, tuned
  −23 ct").
  Notes come out unquantized; the piano roll quantizes them.

**Hum to notes**: right-clicking a track's arm button switches it
between **R** (record audio) and **N** (record to notes). A take
recorded on an **N** track becomes notes when recording stops, by the
same path: the take lands, muted, with its notes on a new track under
it. Like arming, the switch is not saved.

## Chords and key

`chords.zig`: a constant-Q spectrum (36 bins an octave, 55 Hz–5 kHz)
folded to a 12-bin chroma, tuned by the same reference as notes,
averaged per beat through the clip's map. Templates: major, minor,
7, maj7, m7, sus2, sus4, dim, aug, on 12 roots, plus no-chord. An HMM
with a strong self-transition (chords change on beats, rarely) and
Viterbi over the beats gives one chord per span. The key comes from the
whole chroma against Krumhansl–Kessler profiles.

Out: a *Chords* pattern clip with the chords voiced close (root in
octave 3, the rest above), on a Juno track with a pad; the chord names
shown on the clip. The key goes into the scale used by tuning.

## Drums to pattern and kit

The clip's hits (docs/29 §Transients) are classed by each hit's first
60 ms: low share (kickness, already found), spectral centroid, and
noisiness (spectral flatness). Kick, snare/clap, closed hat, open hat
and other are found by clustering hits into up to 8 groups in that
space and naming them by their centroids. Each group's cleanest hit
(strongest, least overlapped by the next) becomes its pad. Out: a
sampler track with one pad per group (kick on C1, snare on D1, hats on
F♯1/A♯1, as GM), a pattern with every hit on its group's key, and the
groove extracted along with it.

## Stems (models)

`ml.zig` and `native_ml.m`: a bridge to CoreML (Apple's runtime,
running on the Neural Engine). It is compiled with the app like
`native_app.m` and loads compiled models (`.mlmodelc`) from a pack.

- **The pack**: *Slab Extract* (docs/25 §Packs), downloaded once, about
  100 MB: HTDemucs (MIT) converted with coremltools, and Basic Pitch
  (Apache-2.0). Both licenses allow shipping them with a GPL app; the
  pack's README carries the notices. Without the pack, the
  model-backed extractors are greyed, with a *Get the Extract pack*
  item.
- **Separation**: 44.1 kHz stereo, in overlapping 7.8 s segments
  (HTDemucs' own) crossfaded, on a worker. A song takes seconds on an
  M-series chip. Stems are written as WAVs beside the recordings and
  laid on four new audio tracks under the clip, warped as the clip is,
  in a group.
- **Polyphonic notes**: Basic Pitch on 22.05 kHz mono gives note,
  onset and contour frames; its own note decoding (thresholds on
  onsets, then frames) gives notes. These go through the same placing
  as *Audio to notes*.

## Explode

*Explode…* (the right-click on an audio clip) opens a sheet with
checkboxes: **Stems**, **Drums**, **Bass**, **Chords**, **Melody**,
**Groove**, and **Match sounds**. With the pack:

- Stems lays out the four stems.
- Drums runs on the drum stem, Bass's notes come from the bass stem
  (range *bass*), Melody from vocals (or *other* without vocals), and
  Chords from bass plus other.

Without the pack, each one runs on the clip itself, which is right for
a loop or a solo take. Everything lands under the clip as new tracks
in a group named after it, the clip muted. One undo step.

## Sound matching

- **Drums**: each pad's hit against the library's one-shots (docs/25
  §Library) by a feature vector of band energies over time (8 bands ×
  6 slices of 10 ms), with the nearest by cosine distance offered next
  to the original slice. *Use original* stays the default.
- **Melodic parts**: render each candidate preset of a fitting machine
  (Cream for bass, a lead or pad for melody and chords) on the
  extracted notes headlessly, and rank by the distance between average
  log-mel spectra. The best three are offered. Searching inside a
  preset's parameters (a local search on a few timbral knobs, as the
  FM preset fitter in `scratch/pilot/fm_fit.py` does offline) comes after.

## Tune

A pitch mode for audio clips, beside the warp modes (docs/29 §The
algorithms), set in the audio clip editor:

- **KEY** and **SCALE** (from Chords' key when found), **SPEED** (0 =
  hard, the effect; 200 ms = gentle correction), **HUMANIZE** (let
  held notes drift as sung), **FORMANT** keep on.
- The correction is a pitch curve: per frame, the tracked f0 to the
  nearest scale note, slewed by SPEED. It is rendered as a ratio per
  grain by **TD-PSOLA**: pitch marks from the f0 track, grains two
  periods long re-spaced at the target period. That keeps the formants
  of a single voice, which a phase vocoder doesn't. It runs on the
  Stretcher's grain machinery, under a `tune` stretcher kind, so a
  tuned clip plays live like any warped one.
- Later, **per-note editing** (Melodyne-style): the notes from *Audio to
  notes* drawn over the waveform, each draggable in pitch, with drift
  and vibrato amount per note.
- A **live** tune effect on an input is a separate machine. It needs
  pitch detection inside a `dsp:` kernel, and that waits.

## In the project

- A source's pitch track is a cache, like its hits, and is never
  saved.
- Extracted results are ordinary clips, tracks and files, and save as
  they always do.
- A clip's tune settings save beside its warp: `"tune": {"key": "A",
  "scale": "minor", "speed": 20, …}`.

## Phasing

1. **Pitch and notes**: `pitch.zig` (pYIN), the note cutter and
   tuning, *Audio to notes* on a clip, hum to notes on record, tests on
   synthesized and recorded lines.
2. **Tune**: the scale snapper, PSOLA as a stretcher kind, the editor's
   tune strip.
3. **Chords and key; drums to pattern and kit.**
4. **CoreML and the Extract pack**: stems, then *Explode…* with
   everything.
5. **Polyphonic notes and sound matching.**
