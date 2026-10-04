# 28 — Time: tempo, sections, groove, polytempo, freeze

How a written beat becomes a played sample, and everything that bends
that path: the tempo map, locators and sections, grooves, polymeter and
polytempo, and the freeze that has to know when any of them changed.

Status: the meter map (docs/07 §Meter map), the tempo map, locators and
sections, and export by section are built (2026-10-05); the rest is
design, built in the order of [Phasing](#phasing).

## The beat axis

Everything placed in a project is placed in **quarter-note beats**:
clips, notes, automation points, loops, markers. Two maps sit over that
axis and nothing else does:

- The **tempo map** turns beats into seconds. It is the only thing that
  decides *when*.
- The **meter map** groups beats into bars. It decides *where the bar
  lines are* and never moves a sound (docs/07 §Meter map).

A note's path from the page to the speaker:

```
written beat ─► track ratio ─► groove ─► tempo map ─► sample
 (the clip)     (polytempo)    (feel)    (the clock)
```

Sections, locators, the export range and the loop are all positions on
the same axis; none of them is a third kind of time. Audio clips are the
one thing measured in seconds (a window of the source at native rate),
so they are placed at a beat and *end* wherever the tempo map says their
duration lands.

## Tempo map

### Points

```zig
pub const TempoPoint = struct {
    beat: f64,      // where it takes effect; points[0].beat == 0
    bpm: f64,       // 20..400
    ramp: bool,     // glide linearly (in beats) to the next point's bpm
};
```

At most 256 points, inline, so a map is plain data the audio thread can
hold a copy of (the meter map's discipline). A point without `ramp`
holds its tempo until the next point: a step. A ramp's tempo is linear
in beats, `bpm(b) = bpm0 + k·(b − b0)`, which keeps the clock in closed
form:

- step: `t = (b − b0) · 60 / bpm0`
- ramp: `t = 60/k · ln(bpm(b) / bpm0)`, inverted as
  `b = b0 + bpm0 · (exp(k·t/60) − 1) / k`

`seconds_at[i]`, the time each point starts, is a prefix sum rebuilt on
every edit, so `secondsAt(beat)` and `beatAt(seconds)` are one segment
lookup and one formula. Samples are `seconds · rate`; everything that
needs the playhead in beats asks the map.

### The engine

- **Blocks split at tempo points**, the way they already split at the
  loop end: a block never spans a step. Inside a chunk, events go at
  `sampleAt(beat) − block_start`, exact for a step and within a
  fraction of a sample over one block of a ramp.
- `MachineCtx.tempo_bpm` is the tempo at the chunk's start and
  `ppq_position` its beat, so tempo-synced machines follow a ramp block
  by block.
- **Audio clips** start at `sampleAt(start_beat)` and play their window
  in seconds. Their `length_beats` (what the arrangement draws and
  what selection and splitting use) is derived:
  `beatAt(secondsAt(start_beat) + dur_sec) − start_beat`.

### Edits while playing

The playhead is a sample counter on the audio thread. A tempo edit
would make that counter mean a different beat, so the engine **rebases
it** when it adopts a new map: `pos = new.sampleAt(old.beatAt(pos))`.
The music keeps its place and only the speed changes. Edits are staged
under a seqlock like the meter map's and adopted at the next block
(tempo can't wait for a bar line the way meter does: a ramp drawn
under the playhead should be heard now).

### Editing

- The transport bar's **BPM** edits the tempo of the segment under the
  playhead (with one point, the song's tempo). TAP sets the same.
- **Tempo changes on the ruler.** Right-click the ruler: *Tempo change
  here* (at the bar under the cursor, starting at the tempo already in
  effect), *Ramp to next change* on/off, *Remove tempo change*. A change
  shows on the ruler as its value (`140`, `→ 140` at the end of a ramp).
  Drag the value up or down to edit it.
- Every edit is one undo step and saves as

  ```json
  "bpm": 120,
  "tempo": [{"beat": 64, "bpm": 140}, {"beat": 96, "bpm": 140, "ramp": true}, {"beat": 128, "bpm": 90}]
  ```

  `bpm` is the first point (so a constant-tempo project is unchanged);
  `tempo` lists the rest and is left out when there are none.

## Locators and sections

Above the ruler (and its tempo and meter changes, which are handles on
their maps, docs/07 §Markers) runs the **section lane**. It holds:

- **Sections** — tabs in their colors, back to back: INTRO, VERSE,
  DROP. A section starts on a bar and lasts until the next one starts;
  the last ends at the **END** marker, or at the last clip without one.
- **Locators** — named flags: *CUE A*, *vocal in*, *fix this*. No
  effect on timing or the grid. Jump targets, and written into WAV
  exports as cue points.
- **END** — the song's end: past it the lane goes dark, and it is the
  Export sheet's PROJECT range (and `--render`'s) when set.

In the lane:

- **Click** a section's tab: the playhead goes to its start.
- **Double-click** a tab or a flag: its dialog (below). On empty lane:
  a new section at that bar.
- **Drag** a section's start edge (to the downbeats between its
  neighbors), a locator's flag (on the grid, ⌥ free) or END (to a
  downbeat).
- **Right-click**: *Add section here* (at the bar), *Add locator here*
  (on the grid), *Edit section…*, *Loop section*, *Remove section*,
  *Edit locator…*, *Remove locator*, *Set end here*, *Remove end*.
- **⌘← / ⌘→** jump to the previous / next section, locator or END.

Every edit is one undo step.

```zig
pub const Locator = struct { beat: f64, name: Name };
pub const Section = struct { beat: f64, name: Name, color: u8 };
// src/markers.zig, on the Document: locators [256], sections [128], end: ?f64
```

A section has no tempo or meter of its own to keep in sync. Its dialog
(NAME, COLOR, TEMPO, METER) shows **TEMPO** and **METER** fields that
*edit the maps at the section's start*: setting VERSE to 7/8 at 140
puts a meter change and a tempo change on its first bar; turning TEMPO
off or METER to FOLLOW removes the change, and the section carries on
from the one before it. The maps stay the only truth; the section is
how you reach them. A locator's dialog has its NAME; both have DELETE.

What sections give:

- Loop a section, jump between them, and the song's end for export.
- **Export SECTIONS**: a file per section (below).
- Later, **arranging by section**: duplicate, move or delete a section
  and its clips, automation, tempo and meter changes come with it
  (clips crossing a boundary split there).

Saved at the project's top level, each only when there are any (slabkit
writes its `Song.section`s and END):

```json
"locators": [{"beat": 32, "name": "VOCAL IN"}],
"sections": [{"beat": 0, "name": "INTRO"}, {"beat": 32, "name": "VERSE", "color": 2}],
"end": 192
```

## Export by section

The Export sheet's RANGE has **SECTIONS** (and the SECTIONS preset, a
WAV per section; `--sections` on the command line):

- One render from the first section's start to the last one's end;
  every output (the mix, each stem) is then **cut at the section
  bounds**. Each file stops where the next section starts, the last
  keeps the tail, and the files laid end to end are the song, sample for
  sample. Normalize measures the whole song and applies one gain to
  every piece. (A section with its own tail would need a render per
  section; not built.)
- Names: `{section}` is its name and `{sn}` its place (two digits). A
  template that names neither gets them: the mix as `{project} {sn}
  {section}`, a stem in a `{sn} {section}` folder (`Song stems/02 verse/01
  KICK.wav`), so the files sort in song order and two CHORUSes don't
  collide.
- Every WAV export, sectioned or not, carries the section starts and
  locators that fall in it as **cue points**.
- A section whose tempo holds still (one segment, no ramp) gets an
  **`acid` chunk**: its tempo, meter, and length in the meter's units
  (eighths in 7/8). So does a LOOP export.

## Groove

The tempo map moves the grid; a **groove** moves notes against it.
Swing, push and drag, a drummer's feel taken from a clip, a samba's
uneven sixteenths: the notes stay where they were written and are played
where the groove says.

### What musicians expect (and other DAWs do)

- **Swing they tune while it plays**: the MPC's 50–75 % on 1/16 or
  1/8, applied at playback, adjusted by ear.
- **Different amounts per part** (Reason's ReGroove): hats swing hard,
  the kick stays straight, the snare sits late.
- **A feel from a reference** (Ableton's groove pool, Logic's groove
  track): extract the timing and accents of a clip and apply them to
  others.
- **Accents with the timing**, not timing alone.
- **Push or drag a whole track** by milliseconds.
- **Randomness that repeats**: loose, but the same on every play and
  every export.
- **Odd and in-between meters**: swing inside the 2+2+3 of 7/8, aksak,
  samba, the unquantized "drunk" feel. Most DAWs' grooves assume 4/4
  sixteenths.
- **Commit** when they want to edit by hand.

### What a groove is

A groove is a short **cycle** and, for each step of the cycle, how far
that step moves, how much its velocity scales, and how much random
timing it gets:

```zig
pub const Groove = struct {
    name: Name,
    cycle: Cycle,             // beats (0.5, 1, 2, 4) or .group (the meter's groups)
    steps: u8,                // ≤ 32 per cycle (per unit for .group)
    shift: [32]f32,           // fraction of a step, −0.5..+0.5
    velocity: [32]f32,        // scale, 0..2
    random: [32]f32,          // ± fraction of a step, seeded
};
```

The cycle's steps are anchors, and timing between them is interpolated,
so the warp is monotonic: notes never swap order, and a note between
two grid lines moves in proportion. MPC 58 % on 1/16 is a cycle of
half a beat with two steps, the second shifted by 0.16 of a step.

**Following the meter.** With `cycle = .group` the groove is laid over
the meter's groups (docs/07 §Meter map) instead of a fixed length: in
7/8 as 2+2+3 each group is its own cycle, and the groove carries a cell
for a group of 2 and one for a group of 3 (a 4 is two 2s). That is how
aksak and swung odd meters become presets instead of workarounds.

### Who uses which

- The project has a **groove pool**: the built-ins (MPC 54–71 % on
  1/16 and 1/8, triplet, shuffle, samba, aksak cells, laid-back) plus
  any the user made or extracted, saved with the project.
- Each **track** picks a groove (or the project's default, or none), an
  **AMOUNT** 0–100 %, and a **SHIFT** in milliseconds, −50..+50, for
  pushing or dragging. These live on the mixer strip under the fader,
  where ReGroove's per-channel amount sat.
- A **section** can change the project's default groove, so the verse
  swings and the chorus plays straight.

### Playing it

- The engine applies the groove where it schedules notes: a note's on
  and off go through the warp, then the tempo map. Shifts are under half
  a step, so finding a block's notes means widening the search by the
  largest shift, a constant. A groove is a small table; nothing
  allocates.
- **Random** comes from a hash of the note's id, its position and the
  project's seed, never a running generator, so every play, export and
  bounce is identical and Bounce's stale check keeps working.
- **Machines get the groove.** MachineCtx carries the track's resolved
  groove (the table and the amount) and fy gets a word that moves a
  step's position through it, so the drum machine's steps and the
  arpeggiators swing with the track.
- **Audio clips get only SHIFT.** Moving audio onto a groove needs
  time-stretching, which Slab doesn't have.

### Editing

- The piano roll draws the grooved grid and Quantize snaps to it.
  The editor's global SWING slider becomes the track's groove.
- **Extract groove** from a MIDI clip: average each step's timing and
  velocity over the clip into a new pool groove. From audio it needs
  onset detection (later).
- **Commit groove** writes the played positions and velocities into the
  notes and sets the track to no groove. One undo step.

Saved as `"grooves": [...]` (the user's), `"groove": {"default": "MPC 58 1/16", "seed": 1234}`,
and per track `"groove": {"name": "...", "amount": 0.8, "shift_ms": -6}`.

## Polymeter and polytempo

- **Polymeter** — same pulse, different bar lengths (5/4 over 4/4).
  Meter is only a grid, so a track may have **its own meter**: its
  piano-roll grid, one-bar lengths and the bar position its machines
  see follow it; nothing else changes.
- **Polytempo** — a track plays at a **ratio** p:q of the project
  tempo (3:2, 4:3, 5:4; p, q ≤ 16). Its local beat is
  `anchor + (beat − anchor) · p/q`, with the anchor at the start of the
  section it's in (or 0), so it realigns with the project every q bars
  and at every section. Clips sit on the arrangement in project beats;
  their notes are in local beats, and the piano roll shows the local
  grid. The machine gets `tempo · p/q` and its local position. Each
  track already renders on its own, so the engine only needs a beat
  position per track instead of per block.

A free tempo per track is deliberately left out: a ratio covers the
musical cases and keeps every track locked to one clock. A section could
later switch a track's ratio, which is a polyrhythmic arrangement.

## Freeze

Bounce makes new clips from a selection and mutes the originals; it
does not save CPU. **Freeze** does:

- The whole track is rendered through its instrument and inserts, before
  the fader (Bounce's FX tap), over the song plus its tail, into the
  project's package.
- While frozen the engine **plays that audio instead of running the
  machines** (indexed by the transport's sample position). Fader, pan,
  sends and their automation stay live; keys taken from the track still
  work, since its audio exists.
- The track looks the same with a **FROZEN** badge; its instrument and
  inserts are locked. **Unfreeze** brings them back; **Flatten** turns
  the track into an audio track with one clip, for good.
- The frozen audio depends on the track, its machines' state, the tempo
  map, the meter (machines read bar position), the groove, its keys.
  Their hash is the freeze's recipe, as with Bounce; when it no longer
  matches the badge says **STALE** and offers REFREEZE.

## Phasing

1. **Tempo map**: `tempo.zig`, the transport and engine on the map
   (block splits, rebase on edit, audio clip ends), BPM and the ruler's
   tempo changes, saved in the project, slabkit (built).
2. **Locators and sections**: the section lane, the END marker,
   jump/loop/select, TEMPO and METER on a section (built).
3. **Export by section**: SECTIONS, `{section}`, cue points, `acid`
   (built).
4. **Groove**: the pool, per-track groove/AMOUNT/SHIFT, playback,
   the ctx table and the fy word, extract, commit, sections' default.
5. **Freeze**: freeze, unfreeze, flatten, stale.
6. **Arranging by section**: duplicate, move, delete.
7. **Polymeter and polytempo** per track.
