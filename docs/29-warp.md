# 29 — Warp: audio on the beat axis

How an audio clip stops being a window of seconds and becomes music on
the grid: warp markers, the stretch algorithms that play it at any
tempo and pitch, transients, and audio that follows the tempo map, the
groove and a track's own tempo.

Status: phases 1–4 built (2026-10-05): the model, TAPE, ⌘-stretch, the
band-limited reader; transients and BEATS; the stretch core, MIX,
TRANSPOSE and FINE; VOICE and SMEAR. Before it, an audio clip only played a window of
its source at native rate (docs/28 §The beat axis), and that is still
what an unwarped clip does.

## What musicians expect (and other DAWs do)

- **Loops that just follow the tempo.** Drop a 92 BPM break into a 120
  BPM song and it plays at 120, on the bar, without a dialog. Live's
  Warp, Bitwig's Stretch, Logic's Flex/Smart Tempo, Reaper's stretch
  markers, Pro Tools' Elastic Audio all start here.
- **The right algorithm for the material**, because none is good at
  everything (Live's Beats/Tones/Texture/Re-Pitch/Complex, Logic's
  Slicing/Rhythmic/Monophonic/Polyphonic/Speed, Pro Tools' Rhythmic/
  Monophonic/Polyphonic/Varispeed):
  - drums keep their transients: slicing, not smearing;
  - a voice or a bass stays one clean voice: no phasiness;
  - a full mix or a pad stays whole: a phase vocoder with its phases
    locked;
  - **varispeed** (tape): speed and pitch together, as a sound, not a
    flaw.
- **Pitch apart from time**: transpose a loop to the song's key
  without changing its length.
- **Warp markers**: pin a moment of the audio (a kick, a downbeat) to a
  beat and let the audio between stretch. Drag a transient to the grid
  (Live's pseudo-markers, Logic's flex markers).
- **Tempo detection**: a loop's BPM guessed on import, ×2 / ÷2 to fix
  it; a long recording warped to a drifting tempo automatically.
- **Quantize audio**: move a live drum take's hits onto the grid, or onto
  a groove.
- **Stretch by the edge** (Logic's ⌥-drag, Reaper's ⌥-drag): grab the
  clip's end and the audio fits the new length.
- **The song follows the recording** (Logic's Smart Tempo): a take played
  without a click becomes the tempo map.
- **Extreme stretch as sound design**: ×8, ×50, the Paulstretch smear.
- **Slice to a drum machine**: a break cut at its hits into pads and a
  pattern.

## The model

An audio clip is either **unwarped**, as today (a window
`[start_sec, start_sec + dur_sec)` of the source at native rate, its
length in beats derived from the tempo map), or **warped**: a map from
the clip's own beats to source seconds, its length fixed in beats, so it
follows every tempo change.

```zig
pub const WarpMarker = struct {
    sec: f64,    // a moment of the source, in seconds
    beat: f64,   // the content beat it plays on
};

pub const AudioRef = struct {
    ... // source, gain, window, fades, reversed (unwarped as before)
    warp: bool = false,
    mode: WarpMode = .mix,
    /// Content beat at the clip's start (the trimmed-off head).
    offset_beats: f64 = 0,
    transpose: i8 = 0,      // semitones, −48..+48 (all modes but TAPE)
    fine: i8 = 0,           // cents, −50..+50
};
// Clip.warp_markers: std.ArrayList(WarpMarker), like notes and lanes.
```

**Content beats.** A warped clip's content is the whole source laid on
an axis of beats by its markers: between two markers the source plays
linearly, and before the first or after the last it continues at the
nearest segment's rate. The clip shows `[offset_beats, offset_beats +
length_beats)` of that axis, so trimming is in beats and never moves
the audio against the grid. Markers are kept strictly increasing in
both `sec` and `beat`; there are always at least two.

**Warping a clip on** keeps it sounding the same at the tempo it sits
in: markers at the source's start and end, `beat = sec · bpm / 60` at
the tempo under the clip's start, and `offset_beats` from its window.
**Off** goes back to a window: the seconds its first and last beat map
to. A clip's **SEG BPM** is `60 · Δbeat / Δsec` of the segment under it;
with two markers, the loop's tempo. ×2 and ÷2 halve or double the beats
of every marker.

**Reversed.** A warped clip reverses by mirroring its map: every marker
becomes `(len − sec, 2·offset + length − beat)`, so the same region
plays backwards over the same beats, and the engine reads the source
mirrored.

### The path to the source

The beat axis gains one more map, read backwards:

```
output sample ─► tempo map ─► song beat ─► track ratio ─► content beat ─► warp map ─► source second
                (docs/28)                  (polytempo)    (+offset)       (markers)
```

`content = (song_beat − clip.start_beat) · track_rate + offset_beats`.
Everything on the axis applies to audio the way it applies to notes: a
tempo ramp bends the loop, a track at 3:2 plays its loops at 3:2, and a
groove (phase 6) is one more monotonic map before the markers.

The local **stretch ratio** is d(source seconds)/d(output seconds): the
slope of that composition. TAPE reads at it; the other modes keep pitch
and use it to decide how much audio each output hop consumes.

### Editing

In the arrangement:

- **Edge drag** trims, as today. An unwarped clip can't be dragged past
  its source's end; a warped clip can (the content continues at the
  last segment's rate).
- **⌘-edge drag stretches**: the content scales to the new length (all
  marker beats and `offset_beats` times `new / old`), turning warp on
  first when it was off. ⌥ still bypasses the grid.
- The clip shows its **waveform through the map**, segment by segment,
  and a small mode badge (TAPE, BEATS, VOICE, MIX, SMEAR) when warped.

In the audio clip editor (phase 5):

- **WARP**, **MODE**, **SEG BPM** (drag; ×2 ÷2), **TRANSPOSE**, **FINE**
  in its header, and the mode's own controls.
- **Markers** on a strip above the waveform: double-click to add, drag
  to move one along the beats (the audio around it stretches), ⌘-drag to
  slide the audio under a marker without moving it on the grid,
  right-click to remove, *Warp from here straight*, *Set 1.1.1 here*.
- **Transients** as ticks; dragging one makes it a marker (the
  pseudo-marker) and moves it, snapping to the grid unless ⌥.
- *Quantize to grid* (or to the groove): a marker at every transient,
  moved to the nearest grid line, with a strength.

## Transients

Each source is analyzed once on a worker thread when it enters the pool
(`src/transients.zig`, `AudioPool.loadFile`):

- a spectral-flux onset envelope: Hann window of 1024, hop 128, log
  magnitude `log(1 + 100·|X|)`, rises summed over the bins;
- normalized to its 99th percentile, floored at 0.3 of its strongest
  rise so a file with few hits doesn't magnify its flutter;
- peaks: a local maximum over ±3 frames, at least 0.07 above the median
  of ±8 frames, 30 ms apart; none within 30 ms of the start (the source's
  start is always a slice's) or where the window runs off the end;
- each refined in the sample domain to where the steepest 1 ms rise of
  the rectified signal begins, within ±25 ms: the hit's first sample,
  within a tenth of a millisecond on clean material.

The result, onset seconds and a 0–1 strength, is written once and read
by the UI and the audio thread alike (`Source.onsets()`, null while the
worker runs). It isn't saved; it's cheap to redo. Every render (export,
bounce, freeze, `--render`) first waits for all of them, so what BEATS
plays never depends on how fast they were found; live playback plays
TAPE until they are. Transients drive BEATS slices, MIX's phase resets,
the editor's ticks (taller for stronger), quantize and tempo detection.

**Tempo detection** (phase 5): autocorrelate the onset envelope over
60–200 BPM, weight toward 120 and toward a whole number of bars for the
source's length (a loop of 4 bars at 92.3 BPM, not 3.7 at 85), and pick
the downbeat as the strongest onset whose beat phase best explains the
rest. A long recording is warped piecewise: a marker per bar where the
local tempo estimate moves.

## The algorithms

Five modes, named for what they're for:

| Mode | For | How | Pitch |
| --- | --- | --- | --- |
| **TAPE** | anything, as an effect | varispeed: read at the ratio | follows the speed |
| **BEATS** | drums, percussive loops | slices at transients, each at native speed | kept (TRANSPOSE re-pitches the slices) |
| **VOICE** | vocals, bass, leads: one note at a time | WSOLA: overlapping grains, aligned by correlation | kept |
| **MIX** | full mixes, pads, chords, anything | phase vocoder, phase-locked, transients reset | kept |
| **SMEAR** | extreme stretch, textures | Paulstretch: long windows, random phases | kept |

A clip warps first in BEATS when it's a loop dense with hits (30 s or
less, two or more a second), in MIX otherwise (`warp.defaultMode`).

### The band-limited reader

Every mode ends in reading the source at a fractional position, and
TAPE is nothing else. The reader is a windowed sinc (Kaiser, 8 zero
crossings each side, table of 512 phases, linearly interpolated) whose
cutoff falls to `1/ratio` when reading faster than the source, so
speeding up doesn't alias; at ratio 1 and an integer position it is the
sample itself. Unwarped clips use it too, for their source-rate change
(44.1 → 48 kHz), which today is linear interpolation.

### BEATS

The source is cut at its transients (**PRESERVE** HITS) or on a grid of
content beats (1/16, 1/8, 1/4). Each slice starts at the output time its
first moment maps to and plays at native speed. When the clip is
stretched a slice runs out before the next one starts, and **GAP**
decides what fills it: CUT (2 ms out, then silence) or LOOP (its last
half, at most 50 ms, back and forth). **DECAY** (1–100 %) fades each
slice out over that share of its time on the grid, for tighter drums.
Squeezed, a slice is cut where the next begins. Slices meet in a 1 ms
crossfade that *ends* on the next one's hit, so the hit itself is the
source sample for sample, which is why drums want this. It's stateless:
every sample is computed from the maps (`mixBeats` in the engine), so it
seeks and loops for free. TRANSPOSE (re-pitching the slices with the
reader) comes with phase 3. A reversed clip slices at its transients
mirrored.

### VOICE (WSOLA)

Output is built from Hann grains (**GRAIN** 10–80 ms, 40 by default;
hop half of it, so they sum to one) on a grid anchored at the clip's
start, on the same stretchers as MIX. Each grain is read near the
source position the maps give, at the offset within ±10 ms whose
waveform best matches what would naturally follow the last grain (a
coarse search every 4 samples on a template decimated by 4, then ±3 at
every sample), so periods line up and there is no phasing. Pitch reads
the grains at `step`, like MIX. One pitch at a time: chords smear into a
chorus. Longer grains suit low voices; at 96 kHz the grain is capped at
40 ms (the ring).

### MIX (the phase vocoder)

Built in `src/stretch.zig` on `src/fft.zig` (a fixed-size radix-2 FFT
with compile-time twiddles: no allocation, no trig per transform).

- **Frames.** Window 4096 (Hann), output hop 1024 (4× overlap), on a
  grid of output samples anchored at the clip's start. Each frame reads
  the source around the position the maps give for its center.
- **Instantaneous frequency without history.** Each frame also reads a
  twin one hop back (`pos − hop·step`), packed with it into one complex
  transform, and takes each peak's frequency from the phase difference
  of the two. The source is in memory and random access, so the
  stretcher needs no analysis history: the ratio may change every frame,
  and a jump to anywhere costs a restart, a few frames and a phase reset.
- **Phase locking** (Laroche–Dolson identity locking): peaks are local
  maxima over ±2 bins of the mid's magnitude; a peak's phase advances by
  its frequency times the hop, and every bin keeps its analysis phase
  offset from the peak whose region it's in (regions split halfway
  between peaks).
- **Transients**: a frame whose position passed one of the source's
  transients since the last frame takes the analysis phases as they are
  (a phase reset), so attacks start clean.
- **Stereo**: the phases are worked out on the mid, and both channels
  are turned by the same correction (output phase − mid's analysis
  phase), so the image doesn't wander; their two inverse transforms
  share one.
- **Pitch**: each frame reads the source at `step = source rate /
  engine rate × pitch` per frame sample (through the band-limited
  reader, or straight when the step is 1), so TRANSPOSE, FINE and the
  source's own rate cost nothing extra. Formants move with the pitch for
  now; keeping them in place (PRESERVE FORMANTS) is later.
- At ratio 1 and no transpose it gives the source back: a stereo mix
  through MIX nulls against TAPE to −100 dB.

### SMEAR (Paulstretch)

Windows of 0.34, 0.68, 1.37 or 2.73 s (**SIZE**: 16384 to 131072
samples, a run-time power-of-two FFT), hop a quarter. Each frame keeps
the source's magnitudes and draws every bin's phase at random, both
channels turned alike so the image holds; frames overlap-add with a
gain of 4/3 (unrelated frames add in power), keeping the source's
level. The random phases come from a hash of the clip and the frame
number, so any start renders the same samples. Meant for stretching
×2 and up: the attack and the rhythm dissolve into the sound's color,
by design. A track gets two smearers (about 2.5 MB each) when it first
plays SMEAR.

## On the audio thread

Warped clips stretch **in real time**, in the block, like everything
else the engine plays: a tempo drag or a marker drag is heard on the
next block, and there is no cache to invalidate or go stale.

- **TAPE and BEATS need no state**: each output sample is a read at a
  position computed from the maps.
- **VOICE, MIX and SMEAR** keep state (output phases, the overlap-add
  ring). A track with such clips gets a bank of four **stretchers**
  (about half a megabyte), allocated on the UI thread when its first one
  is published and freed with the track, never by the audio thread. A
  clip that starts sounding takes a free stretcher by its uid; one not
  used in the previous mix call is free again. At most four such clips
  sound at once on one track; a fifth plays TAPE.
- **No latency.** The output frame at time `t` reads the source around
  `s(t)`, which is known ahead from the maps; the overlap-add's half
  window ahead is computed in the same block. Nothing is reported to
  PDC.
- **Seeks.** A stretcher whose next sample isn't the block's first (the
  playhead jumped, the loop wrapped) restarts: the frames that reach the
  new position (four) and a phase reset. Frames only add into positions
  not yet played, so a restart never leaves old output in the ring.
- **Determinism.** Exports and bounces play straight through from their
  start, so they render the same every time and at any `--threads`
  (stretchers are per track). Playback started from a different point
  can differ in phase, inaudibly.
- **Cost.** MIX is two FFT pairs per channel per output hop: about 380
  4096-point transforms a second for a stereo clip, a fraction of a
  percent of a core. SMEAR's long windows are the most expensive and
  only run when chosen.

## In the project and slabkit

Saved per audio clip: `"warp": {"mode": "mix", "offset": 0.0,
"markers": [[sec, beat], …], "transpose": 0, "fine": 0}` (and the
mode's own settings), omitted when unwarped. The bounce and freeze
fingerprints (recipe.zig) hash a clip's warp when it is on.

slabkit: `track.audio(path, at=, warp=bpm | True, mode=, transpose=)`,
with `warp=True` meaning "detect".

## Phasing

1. **The model and TAPE**: warp on/off, markers, content beats, the
   path through the maps (with polytempo), the band-limited reader for
   every clip, ⌘-edge stretch, the waveform through the map, unwarped
   clips stopped at their source's end, saved in the project, slabkit
   (built).
2. **Transients and BEATS**: onset analysis on a worker, ticks on the
   waveform, slices with PRESERVE, GAP and DECAY (built).
3. **The stretch core and MIX**: the FFT, the stretcher bank, the
   phase-locked vocoder with twin frames, transient resets, stereo,
   TRANSPOSE and FINE (built).
4. **VOICE and SMEAR** (built).
5. **Warp editing**: markers and pseudo-markers in the audio clip
   editor, quantize to the grid, tempo detection and auto-warp on
   import.
6. **Audio on the time axis**: warped clips follow the groove (the
   groove's warp before the markers), *Quantize to groove*, *Song
   follows this clip* (a tempo map from a clip's markers).
7. **Slice to drum machine**: a BEATS clip's slices to sampler pads and
   a pattern that plays them.
