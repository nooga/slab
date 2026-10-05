# 30 — Extract: audio into music

How an audio clip becomes what it plays: notes from a hummed or sung
line, a bassline or a melody, the chords and the key, the drums as a
pattern and a kit, the stems of a whole song, and a voice put in tune.
Everything comes out as something you edit in Slab (pattern clips,
groove templates, sampler kits, audio clips), placed on the song's
beats through the clip's warp (docs/29).

Status: phases 1–4 built and released in 0.0.9 (2026-10-05): the pitch
tracker, notes, *Audio to notes*, hum to notes, Tune, *Chords to notes*,
*Drums to a kit*, stems through CoreML and the Extract pack, and
*Explode…*. Phase 5 (polyphonic notes and sound matching) is parked for
later; its design below stands.

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
| Chords and key | chroma per beat from the spectrum's peaks, matched to chord templates, smoothed by Viterbi; key by Krumhansl profiles | none | pop, electronic, rock |
| Drums | onsets (docs/29 §Transients), each hit classed kick/snare/hat/other by its spectrum; slices to a kit | none (a model on mixes) | loops, drum stems |
| Groove | built (docs/29 §Extract groove) | none | loops, takes |
| Stems | a source-separation network (HTDemucs: drums, bass, other, vocals); Slab does its STFT | CoreML | whole songs |
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

*Audio to notes* (an audio clip's **Extract** submenu, not reversed;
`audioToNotes` in `main.zig`) works like *Slice to a sampler track* (docs/29):

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

*Chords to notes* is in an audio clip's **Extract** submenu (its
right-click in the arrangement, and the audio clip editor's warp menu). The chords are in
`chords.zig` and the command is `chordsToNotesOr` in `main.zig`.

**The chroma**: how much of each pitch class sounds, from the whole
source.

- The source is read at 11.025 kHz through the band-limited reader,
  with 4096-point frames 93 ms apart.
- It uses each frame's spectral peaks from A1 to 5 kHz, each refined
  by a parabola. A peak counts fully at its semitone and not at all a
  quarter tone off.
- Two passes. The first finds the take's tuning, the circular mean of
  every peak's distance from its nearest semitone, so a band 30 cents
  sharp reads right. The second folds the peaks into pitch classes:
  the treble from A2 up, the bass below about E3.
- The bass's upper limit matters. At C4 it took a low-voiced chord's
  A3 for the bass and read an F bar as Am.

**Per beat.** The chroma is averaged over each song beat of the clip
(`extract.sourceSec` maps beats to source seconds, through the warp
when warped).

**Chords.** Templates on 12 roots: major, minor, 7, maj7, m7, sus2,
sus4, dim and aug, plus no chord.

- Each template carries its tones' first harmonics (the octave, the
  twelfth, two octaves). That way a played chord's overtones count as
  the chord and not as other notes.
- A beat's fit to a template is the cosine of the two, times a small
  prior: 0.97 for sevenths and 0.94 for sus, dim and aug, so plain
  triads win ties. The bass adds 0.2 times its share at the template's
  root.
- Each beat counts by how much its best fit stands out from the
  average. A beat full of drums, or a chord's release, where
  everything fits about as well, hardly counts.
- A Viterbi pass over the beats then smooths the sequence:
  - A change costs 4 against 20 times the fit, so a chord that fits
    clearly better takes over within two beats.
  - A beat 2% as loud as the loudest, or where nothing fits better
    than 0.55, is no chord.

**The key** is the whole chroma's best match against the
Krumhansl–Kessler major and minor profiles (`tune.keyOf`, shared with
Tune).

**What it makes:**

- A track under the clip on the Juno with *Lush Pad*.
- A pattern where the clip is: each run of one chord is a chord, its
  root in octave 3 and the rest close in octave 4.
- The clip is named after its first chords ("C Am F G7").
- The source clip gets the key in its Tune settings, if they were
  never set.
- The source clip keeps playing, since the chords are an
  accompaniment. One undo step.
- The status line gives the count and the key.

**Measured.** It gets right:

- a synthesized I–vi–IV–V on every beat;
- m7–7–maj7–m played 30 cents sharp;
- a rendered band, Juno pad and FM e-piano comping over a Cream bass
  and drum2, at C Am F G C Am Dm7 G7: 32 of 32 beats.

## Drums to pattern and kit

*Drums to a kit* is in an audio clip's **Extract** submenu. The
classifier is in `drums.zig` and the command is `drumsToKitOr` in
`main.zig`. It works on the clip as it is, which is right for a drum
loop or a drum stem. For a whole song, *Explode…* runs it on the drum
stem Demucs separates.

**What each hit adds.** Each hit (docs/29 §Transients) is described by
what it adds to what was already sounding. A real drum stem always
carries some low end (the last kick's tail, bass bleeding in) and a
mix carries everything. Measured as plain content, a snare there reads
as all bass; the first version did exactly that.

- **The spectra.** The spectrum over a full-Hann 2048-sample window
  starting 256 samples before the hit, against the most each bin held
  over four windows before it (0–12 ms apart). Per bin, so two notes
  beating in a band don't count. The maximum over four, so a beat or a
  partial's phase can't make a steady sound look like it gained. A bin
  counts what it gained past 125% of that.
- **Its features,** from those gains summed into third-octave bands
  (40 Hz–16 kHz):
  - the low share (under 150 Hz);
  - the body share (150–600 Hz);
  - where it centers (geometric, energy-weighted), and where above
    150 Hz;
  - how evenly it spreads over the top above 1 kHz (computed, but it
    didn't tell drums apart: drum2's hats are metallic);
  - how much louder the band under 150 Hz got.
- **How long it rings**: 5 ms steps until what it added is 20 dB under
  its peak, above the level before it. Cut at the next hit at least
  half as strong, so a flicker in its own tail doesn't cut it. A bright
  hit (center ≥ 2 kHz) is followed in the first difference, a
  high-pass a bass under it hardly shows in.
- **The hits themselves** are placed better too. `transients.refine`
  now looks for the steepest rise both in the signal and in its first
  difference, and takes the one that stands out more over its own
  level. A hat over a loud bass used to land 7–16 ms off, its edge
  lost in the bass's waveform, and now lands within 0.2 ms.

**Naming.** Each hit is named on its own:

- **kick**: low share ≥ 0.4, and the low band got at least 1.5×
  louder (a new kick, not one still ringing with its pitch falling);
- otherwise judged on what it adds above 150 Hz when the low share
  came from a tail:
  - **hat**: centered ≥ 4.5 kHz with little body; **open** if it rings
    90 ms or more;
  - **tom**: centered under 700 Hz;
  - **snare**: body ≥ 0.15, or centered ≥ 900 Hz and ringing 30 ms or
    more;
  - **hat**: anything else centered ≥ 2 kHz;
  - **perc**: the rest.

**Grouping.**

- A hit with onset strength under 0.06 is a flicker, not a drum: no
  group, no note. A kick on a held bass hardly moves the flux and sits
  at 0.08; Demucs' drum stems' flickers sit near 0.03.
- A name's hits are split into two drums by k-means (on low share,
  center, body and ring time) when that leaves a third of their spread
  or less and both halves are played at least three times: a second
  kick, a rim beside a snare. Up to 8 groups.
- Each group gets its General MIDI key: kick 36 then 35, snare
  38/40/39, hat 42/44, open hat 46/49, toms 45 and up, perc 37 and up.
  A key two groups would share goes to the next free one.
- Each group's pad is its strongest hit with 150 ms or more before the
  next.
- A hit is one drum: a hat played with a kick counts as the kick.

**What it makes:**

- Each pad written as a WAV (from 1 ms before its hit, up to the next
  hit or 1.5 s, 5 ms out) into a folder beside the project's
  recordings.
- An SFZ putting each pad on its key, one shot, labeled.
- A sampler track under the clip loading it.
- A pattern where the clip is, with every hit inside the clip on its
  drum's key, at its place through the clip's warp or the tempo map,
  its velocity from the hit's strength.
- The clip is muted, as with *Slice to a sampler track*. One undo step.
- The status line names the drums it found.

**Measured.**

- A synthesized beat sorts every hit right, on 36/38/42/46, both alone
  and over a held 55 Hz bass and a three-note chord.
- Against the drum notes of two rendered songs (30 s each, Demucs' drum
  stem):
  - paper_boulevard: 185 of 212 hits right (87%), up from 138 (65%);
  - voltage_riot: 182 of 211 (86%), up from 126 (59%).
- Junk hits kept in the pattern on voltage_riot went from 83 to 24, at
  the cost of 1 real hit.
- What's still wrong is mostly quiet hats, called kick, snare or perc.

## Stems (models)

*Split into stems* is in an audio clip's **Extract** submenu, and so
is *Explode…*. Stems take a song apart into **drums, bass, other and
vocals** with HTDemucs (Défossez et al., Meta, MIT), run through Apple's
CoreML.

**The model.** CoreML can't run Demucs' STFT and its inverse, so the
model is the network's core (`forward()` in demucs/htdemucs.py between
`_magnitude` and `_mask`, and its time branch):

- In: the mix's spectrogram (1, 4, 2048, 336; complex as channels) and
  its waveform (1, 2, 343980; HTDemucs' 7.8 s at 44.1 kHz).
- Out: each stem's spectrogram and waveform.
- It runs in 32-bit floats. In 16-bit the network's normalizations
  overflow to NaN, and 32-bit takes only 0.3 s per segment on the GPU.
- Converted, it matches PyTorch to 119 dB.

**The pack.** *Extract: stems* (`packs/extract.pack.json`, docs/25
§Packs) installs it. Its IMPORT runs `tools/extract/extract.py`:

- It makes its own Python 3.12 with `uv`, in `<home>/Cache/extract-venv`
  (about 1 GB, once), and installs PyTorch, Demucs and coremltools.
- It downloads the weights (80 MB) and converts the core with
  coremltools. Two workarounds are needed: sizes as constants, since a
  traced `int()` of a shape breaks the conversion under NumPy 2, and
  PyTorch's fused attention turned off, since CoreML can't convert it.
- It checks the result against PyTorch on a test signal and refuses to
  install below 25 dB.
- It compiles the model and installs it as
  `<library>/extract/models/htdemucs.mlmodelc` (205 MB), with a README
  carrying the MIT notice.
- The pack shows as installed once `models/` is there. Without it,
  Explode's STEMS is greyed and *Split into stems* says to get the
  pack.
- Slab doesn't ship the weights: each machine fetches its own.

**The bridge.** `native_ml.m` and `ml.zig`:

- `MLModel` loads with all compute units.
- Inputs are wrapped without a copy (`initWithDataPointer`).
- Outputs are copied out whatever their strides, since CoreML pads
  some.
- It runs on the stems worker, never the audio thread.

**Separation** (`stems.zig`) does what demucs' `separate` and
`apply_model` do:

- The source goes to 44.1 kHz stereo (`resample.stereo`) and is
  normalized by its mono mean and deviation.
- It is cut into 7.8 s segments a quarter overlapping. A short last
  chunk is centered in a full segment of what's around it, and its
  middle is kept.
- Each segment's STFT is Demucs' own: 1.5 hops of reflection each
  side, a periodic Hann, `normalized=True`, frames 2–337. Both
  channels go through one complex FFT.
- After the model, each stem's spectrogram goes through the inverse
  (`torch.istft`'s overlap divided out, empty frames at the edges as
  `_ispec` lays them) and is added to its waveform.
- The segments are crossfaded with `apply_model`'s triangle and the
  result denormalized.
- Checked against Python Demucs on 30 s of a rendered song, with no
  random shifts and the same overlap: every stem within 55–57 dB.
  Unit tests pin the STFT's scale and its round trip (to PyTorch's
  values, edges included).
- 30 s takes 2.5 s on an M-series Mac, a three-minute song about 15 s.

**What it makes** (`finishStems`, `placeStems` in `main.zig`):

- The four stems as 44.1 kHz float WAVs in a `<clip>-stems` folder
  beside the recordings.
- Four tracks under the clip, each holding a copy of the clip (its
  place, window, fades and warp) playing its stem. Only the vocals
  keep the clip's Tune.
- The clip is muted. One undo step.
- While it works, the status line (or Explode's sheet) counts the
  segments, and CANCEL stops it between segments.
- One separation runs at a time.

## Explode

*Explode…* opens a sheet (`ui/explode_dialog.zig`) with a switch for
each part:

- **STEMS**: the four stem tracks. Greyed without the pack.
- **DRUMS**: *Drums to a kit* on the drum stem.
- **BASS**: *Audio to notes* on the bass stem. Greyed without stems,
  since a whole clip has only one line to give.
- **CHORDS**: *Chords to notes*, hearing the bass and other stems
  summed (`harmony.wav`, written with the stems, never placed): no
  drums, no voice. It lands under the *other* stem's clip.
- **MELODY**: *Audio to notes* on the vocals.

How it runs:

- With stems, the separation runs first and the rest follows when it
  is done.
- Without stems, each part runs on the clip itself, and BASS and MELODY
  are the one line.
- The kit and the chords are made at once. The lines arrive as their
  pitch is found; audio-to-notes jobs wait in a queue and find their
  clip by id, since tracks are added above them meanwhile.
- Each part is its own undo step.
- Measured on a synthesized band (four chords twice, a bass, a beat):
  - the stems sum back to the mix within 29 dB;
  - the kit comes from the drum stem;
  - the chords from bass and other read "C Am F G C Am F G", every one
    right.

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

Puts a voice in key (`tune.zig`; the grains in `stretch.zig`). It works
on any audio clip played forward, warped or not:

- **Turning it on**: the **TUNE** button in the audio clip editor's
  control row, or *Tune* / *Untune* on the arrangement's right-click
  (the selection, or the focused clip). Turning it on asks for the
  source's pitch. Until that is found the tune row shows *LISTENING…*
  and the clip plays as it is. A clip whose key was never set gets the
  take's own key: how long each pitch class is held, against the
  Krumhansl–Kessler major and minor profiles.
- **The tune row**, above the control row while Tune is on:
  - **KEY** (C…B).
  - **SCALE**: CHROM (any semitone), MAJOR, MINOR, HARM (harmonic
    minor), DOR, MIXO, PENT+, PENT−, BLUES.
  - **SPEED**, 0–400 ms: 0 snaps at once (the effect), 100 and up is a
    gentle correction.
  - **HUMAN**, 0–100%.
- **On the waveform**: the sung pitch is drawn dim and the tuned pitch
  bright, on a semitone scale fitted to what's in view. The scale's
  notes are ruled, and the key's root is ruled brighter.

**The correction.** It is computed from the source's pitch with no
state, so a seek or a loop costs nothing. Per 10 ms frame:

1. The frame's held pitch (its five-frame median) goes to the nearest
   note of the scale. The difference from the frame's own pitch is the
   raw correction.
2. **SPEED** smooths it with an exponential look back of SPEED (sung
   frames only). A breath ends the look back, so a phrase starts in
   tune, and a pitch change glides at SPEED.
3. **HUMAN** mixes toward the same correction smoothed over 300 ms of
   *this note only*. That fixes where each note sits at once and keeps
   its vibrato and slides.

**The sound: TD-PSOLA**, a third stretcher kind (`tune`) beside MIX
and VOICE, so a tuned clip plays live like a warped one:

- Output grains are spaced a period apart, at the period the note
  should have.
- Each grain is two source periods long (Hann), centered on the pitch
  mark nearest where the maps put it, and read at the source's own
  speed. That is why the formants stay where they were and the voice
  doesn't turn into a chipmunk.
- Pitch marks are found on the worker with the pitch: one a period,
  each on the waveform's highest peak within a quarter period of where
  the last one's period puts it, refined between samples by a
  parabola. Without that refinement the grains jitter by up to half a
  sample, and the noise between the harmonics rises to −34 dB.
- Unsung frames get 10 ms grains 5 ms apart, at the source's pitch.
- A warped clip's time comes from its map, so Tune replaces its MODE's
  stretching while it is on, and TRANSPOSE and FINE still apply. An
  unwarped clip reads its window at the source's own speed.
- A grain's half is at most 1024 samples (a period of 47 Hz at 48 kHz).
  The pitch is moved by at most an octave either way.

Measured on rendered songs (slabkit, `slab --render`):

- A tone sung 40 cents flat comes out at 0 cents, its level within
  0.1 dB.
- The noise between its harmonics is −68.7 dB, against −70.8 for the
  take untouched.
- On a sung line with notes 30–45 cents off and ±21 cents of vibrato:
  - SPEED 0 puts every note within 1 cent and flattens the vibrato to
    ±1 (the effect);
  - SPEED 120 with HUMAN 60% puts them within 3 cents and keeps ±16 of
    the vibrato.

Later:

- **Per-note editing** (Melodyne-style): the notes from *Audio to notes*
  drawn over the waveform, each draggable in pitch, with drift and
  vibrato amount per note.
- A **live** tune effect on an input, as a separate machine. It needs
  pitch detection inside a `dsp:` kernel, and that waits.
- A reversed clip can't be tuned.

## In the project

- A source's pitch track is a cache, like its hits, and is never
  saved.
- Extracted results are ordinary clips, tracks and files, and save as
  they always do.
- A tuned clip saves `"tune": {"key": "A", "scale": "minor", "speed":
  20, "humanize": 0}` beside its warp (omitted when off). Opening it
  asks for the source's pitch, and a headless render waits for it, like
  hits. slabkit: `audio(…, tune="A", scale="minor", speed=20,
  humanize=0)`.

## Phasing

1. **Pitch and notes**: `pitch.zig` (pYIN), the note cutter and
   tuning, *Audio to notes* on a clip, hum to notes on record, tests on
   synthesized and recorded lines (built).
2. **Tune**: the scale snapper, PSOLA as a stretcher kind, the editor's
   tune row and pitch curves, key detection, slabkit (built).
3. **Chords and key; drums to pattern and kit** (built).
4. **CoreML and the Extract pack**: stems, then *Explode…* with
   everything (built).
5. **Polyphonic notes and sound matching** (parked: future development).
