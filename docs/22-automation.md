# 22 — Automation

Values that change over time on their own: a fader ride into the
chorus, a filter opening over 16 bars, a chord whose notes bend onto
one pitch. **Status: phases 1 and 2 (curves, track lanes, automated
controls, clip lanes) and the pitch half of phase 3 (note bends,
expression mode, the converge drag) are built; pressure, slide and gain
expression, and recording, are design.**
Code: `src/automation.zig` (curve, lanes), `src/ui/automation_lane.zig`
(the lane editor), the `automation` fields in `track.zig`,
`snapshot.zig`, `engine.zig` and `machines/fy_raw_machine.zig`.

Prior art this follows: Live's clip envelopes and Note Expression tab,
Bitwig's clip automation and per-note expressions, and Reaper's
per-segment point shapes.

## Three layers, one curve

Every kind of automation is the same **curve**, stored in one of three
places:

| Layer | Lives on | Time | Targets |
|---|---|---|---|
| **Track lane** | a track | song beats | any control of the track's instrument or effects, track volume and pan |
| **Clip lane** | a note clip | beats from the clip's start; moves and copies with the clip | the same targets |
| **Note expression** | one note | beats from the note's start | pitch (semitones), pressure, slide, gain |

- **Track lanes** do most of the work: long moves that ignore clip
  boundaries.
- **Clip lanes** are for moves that belong to a part, like a hat
  pattern with its own open/close or a per-bar filter wobble. Copying
  the clip copies the move.
- **Note expression** is per note, so notes in one chord can move
  independently (one bends up while another bends down). A
  channel-wide pitch bend can't do that.

One curve type means one evaluator, one editor, one file form, and one
set of gestures to learn.

## The curve

A curve is a list of points sorted by time. Each point is
`(beat, value, shape, tension)`. `shape` and `tension` describe the
segment from this point to the next one.

| Shape | Segment |
|---|---|
| `hold` | stays at this point's value, then steps at the next point |
| `linear` | straight line (the default) |
| `curve` | power curve bent by `tension` |

**Tension** τ runs from −1 to 1. Over a segment from `v0` to `v1`,
with `u` the fraction of the segment's time elapsed (0..1):

```
k = 2^(−4τ)                    // τ = 0 → k = 1 (a line); k ranges 1/16..16
v = v0 + (v1 − v0) · u^k
```

- τ > 0 puts most of the change early (fast start). τ < 0 puts it late
  (slow start).
- `u^k` and `u^(1/k)` are mirror images, so +τ and −τ are symmetric.
- The curve is monotonic and never overshoots, so it stays inside the
  target's range. It works as well for dB as for pitch.
- An S-curve is two `curve` segments. There are no bezier handles:
  tension covers almost every move, and handles double the editing
  and hit-testing work.

Other rules:

- **Before the first point** the curve holds the first point's value.
  **After the last point** it holds the last point's value.
- **Two points at the same beat** make an instant jump. The earlier
  point's value is where the curve arrives; the later one is where it
  leaves from.
- **Interpolation happens in knob space.** Machine controls interpolate
  in the control's normalized 0..1 position, not in its units. A
  `linear` segment from 400 Hz to 4 kHz on an exponential cutoff knob
  sweeps evenly in pitch, exactly like dragging the knob. Files store
  real units (see §Project format). Note-expression pitch is
  interpolated in semitones.
- **Stepped targets** (switches, `int_range`) only take `hold`
  segments, and values snap to an option index.

The evaluator is one pure function, `automation.eval(points, beat)`,
in `src/automation.zig`. The audio thread and the UI both call it, so
what a control shows and what the audio hears can't disagree.

## Targets

A lane targets one value:

- `volume` or `pan` of the track.
- A control of the track's instrument or of one of its effects, by the
  control's param id.

In memory, a target is (slot, control index), where a slot is the
instrument or a stable id for an effect instance. Reordering effects
therefore keeps each lane attached to its machine. Files write the
effect's position at save time (§Project format).

Not targets for now: the master bus, Rack parts' inner params, and
tempo (no tempo map yet, docs/19).

## Precedence

For each target and each moment, the value comes from the first of
these that applies:

1. **A manual override** (see §Manual changes).
2. **A clip lane**, while a clip holding a lane for that target is
   playing. If clips overlap, the later-starting clip wins.
3. **The track lane.** Because a curve holds its end values, a track
   lane covers the whole song once it has a point.
4. **The control's own value** (the base): what the knob was set to,
   and what presets and project load write.

Clip lanes **override** the track lane. They don't offset it. Relative
clip lanes (scaling or offsetting the track lane) can come later.

When a clip lane ends and the value falls back to the track lane or the
base, the control's normal 20 ms smoothing
([fy_raw_machine.zig](../src/machines/fy_raw_machine.zig), `SMOOTH_TAU_S`)
glides it there, so leaving a clip doesn't click.

## Manual changes: override and recording

**Override.** Changing an automated control by hand overrides its
automation:

- **Drag:** the override lasts while the pointer is held. On release
  the value glides back to the curve. This is "touch" behaviour, and
  it leaves no hidden state behind.
- **Discrete edits** (a typed value, arrow keys, double-click reset, a
  preset load): the override lasts until the transport next starts,
  or until you click the control's automation LED.

While a control is overridden, its LED shows hollow (§Automated
controls). During an override, drags and edits also change the base
value (precedence step 4).

**Recording** (phase 4). An `AUTO` arm latch on the transport, drawn in
`rec`. While it's armed and the transport is playing:

- A drag on any control writes into that target's **track lane** for
  as long as the drag is held (touch-write). Points under the written
  span are replaced.
- A drag on a control that has no lane yet creates the lane.
- Written points are thinned with Ramer–Douglas–Peucker (1 logical px
  tolerance at the current zoom) into `linear` points.
- One pass is one undo step.
- The arm latch lights `accent` while it's on, like any latch.

Recording into clip lanes and note expression isn't planned. Draw
those.

## Automated controls

Automated knobs, sliders and switches **show that they are automated**
and **move with the automation**.

**Movement.** Every control draws its *effective* value (the result of
the precedence rules above), not its stored base:

- a knob's pointer and value arc
- a fader or slider cap
- a lever, latch or radio position
- a display-select's value

Each frame, the UI evaluates the same curves at the transport position.
So controls move during playback, and they jump to the right value when
you scrub or locate while stopped. This covers:

- machine panels,
- the track header's volume and pan minis,
- mixer faders.

Frames are already requested while playing (playhead). While stopped,
a locate or a lane edit requests one.

**Indicator.** The control's legend gets a square 4 px LED in the new
`auto` colour (docs/06 §Palette) at its right end. Panels can't place
it; the control catalogue draws it.

| LED | Meaning |
|---|---|
| lit `auto` | a lane drives this control and it's following the lane |
| hollow `auto` (1px ring, dark centre) | overridden by hand; click to re-enable |
| blinking `rec` | being written (recording armed, drag held) |
| ghost (unlit) | not automated |

A control counts as automated if **any** lane targets it: its track
lane, or a clip lane in any clip on the track. That way, a control
driven by only one clip still tells you it can move.

The LED sits just after the control's centred legend
(`controls.autoLedPos`); on the track header's minis it takes an 8 px
cell at the slider's right end.

**Title-strip display** (not built yet). Hovering an automated control
shows `CUTOFF 1.25 kHz` followed by an `A` cell, so the value channel
also says the value isn't fully yours.

**Context menu** on any automatable control (built for knobs and
faders, whose widget id is the control's own key; switch and radio
widgets don't open it yet, nor do the header minis):

- **Show automation**: reveals the track lane, creating an empty one
  if needed, and scrolls the arrangement to it.
- **Clear automation**: removes the track lane. Clip lanes stay; they
  are cleared from the clip editor.
- **Re-enable automation**: shown only while the control is
  overridden.

Clicking a lit LED does the same as **Show automation**.

## Editing curves

The same gestures apply in all three layers, so learning one teaches
all of them. They follow the piano roll's conventions (docs/12
§Piano roll).

| Gesture | Does |
|---|---|
| double-click empty lane | add a point at the snapped beat, value at the cursor |
| drag a point | move it: time snapped to the grid, value free |
| Alt while dragging a point | bypass time snap |
| Shift while dragging | fine value (10×) |
| drag a segment | move both of its points vertically |
| **Alt-drag a segment** | bend it. The segment's midpoint follows the pointer vertically; τ is solved from where the midpoint lands (`k = ln m / ln ½`, with `m` the midpoint's fraction of the way from `v0` to `v1`). Clamped to ±1. A `linear` segment becomes `curve` on the first bend. |
| double-click a point | delete it |
| drag empty lane | box-select points |
| drag a selected point | move the whole selection (time and value together) |
| Delete / Backspace | delete selected points |
| right-click a point | menu: Hold / Linear / Curve, Reset tension, Delete point (Enter value… is not built yet) |
| ⌘-drag empty lane | freehand: writes points along the drag, thinned to 1 px (Ramer–Douglas–Peucker), replacing points in the dragged span |

- A point can't be dragged past its neighbours in time. Stopping at a
  neighbour's beat makes an instant jump.
- Hovering a point or segment shows its value in real units in a
  tooltip ("1.25 kHz", "−6.0 dB", "+7 st").
- Lanes are drawn in knob space, bottom to top, so an exponential
  lane looks the way its knob feels.
- One gesture is one undo step. Lanes are part of the document, so the
  snapshot undo (`history.zig`) covers them with no extra work.

Drawing follows docs/06 §Working surfaces: a 1 px line in the track
colour, 3×3 hollow point handles, a filled `accent` handle when
selected, and the target's name as a muted legend in the lane.
`hold` segments draw as steps.

### Track lanes (arrangement)

- An `A` latch (lit `auto`) on the track header shows or hides the
  track's lanes. Each lane is a 40 px row under the track, with a
  header that holds:
  - a target button: a menu of VOLUME, PAN, then machine ▸ module ▸
    control; picking retargets the lane (one lane per target),
  - `+`: the same menu, adding a new lane,
  - `×`: remove the lane.
- A shown track with no lanes gets one placeholder row with
  `+ ADD LANE`.
- New lanes also come from **Show automation** on a control (or a
  click on its lit LED).
- **Clip lanes seen from the track.** Where a clip holds a clip lane
  for the same target, the track lane draws the track curve muted and
  the clip's curve over it in full, so the lane always shows what will
  actually play.
- Moving and copying clips carries their clip lanes. Track-lane points
  stay put.

### Clip lanes (clip editor)

An **ENV** strip (44 px) under the piano roll's velocity lane shows one
of the clip's lanes at a time. The ENV label opens the target picker
(existing lanes are marked with a dot): picking a target the clip
already automates switches the strip to it, picking a new one adds a
lane, and "Remove lane" deletes the shown one. The strip scrolls and
zooms with the piano roll; past the clip's end it's shaded. Delete in
the piano roll removes selected envelope points before notes.

Splitting a clip splits its lanes: both halves get a point at the cut
with the curve's value there (a `curve` segment cut in two keeps its
tension on both halves, so its shape shifts slightly).

An envelope strip under the piano roll's velocity lane, with a target
dropdown and the same gestures. Only points in `[0, len)` of the clip
matter. Resizing a clip shorter keeps the points past its end (they
come back if the clip grows) but they don't play.

### Note expression (piano roll)

**Pitch curves are drawn on the note grid itself.** A bend starts at
the note's own row and runs across the pitch rows, so you can see
exactly where it lands:

- **Expression mode:** the key `E` (and the EXPR latch in the piano
  roll's header) toggles it. Drum-lane rolls (folded to a note map)
  have none. In expression mode:
  - every note's pitch curve draws in the track colour, a selected
    note's brighter, and selected notes' points get handles,
  - click a note to select it (Shift toggles), click empty grid to
    deselect; notes don't move or resize,
  - drag a handle to move it: time snaps to the grid within its
    neighbours and the note, pitch snaps to semitones (Alt: free),
  - double-click a selected note's curve to add a point (a note's
    first point also pins beat 0 at its own pitch); double-click a
    handle to delete it,
  - Alt-drag a curve segment to bend it,
  - right-click a handle: Hold / Linear / Curve, Reset tension, Delete
    point, Clear bend.
- **Outside expression mode**, curves draw faintly on notes that have
  them, and aren't editable.
- **Pitch values snap to semitone rows.** Alt drags free, in cents.
  The range is fixed at ±48 semitones, and the vertical view is the
  piano roll's own, so a bend reads in real pitch.
- **Time:** a point's time is from the note's start. Points belong in
  `[0, len]` of the note. After the note ends, the curve holds its
  last value, so the release keeps the bent pitch.
- **Converge gesture:** in expression mode, drag from a selected note's
  body to a target row and time; accent lines preview it. Every selected
  note's bend is replaced by: 0 until the drag's start time, then a
  `curve` segment (tension −0.3, slow start) to *(target pitch − its
  own pitch)* at the drag's end time.
  One drag makes a chord fold onto one note or spread from a unison.
  Alt-dragging one note's segment afterwards bends that segment on
  every selected note together.
- **Pressure, slide and gain** (not built yet) edit in the envelope
  strip, which switches to per-note mode for the selected note. With
  several notes selected, it draws all their curves and edits them
  together.
- A note holds at most 8 bend points (`clip.MAX_BEND`), inline in the
  `Note`, so notes stay plain values that copy through clipboards,
  duplicates and splits.

## Engine

### Snapshot

Lanes publish with the track, in the existing double-buffered
`TrackSnapshot` (`src/snapshot.zig`). The UI writes the idle slot and
flips; the audio thread reads the published one for the block.
New fixed arrays:

```zig
pub const MAX_LANES_PER_TRACK: usize = 32;
pub const MAX_AUTO_POINTS_PER_TRACK: usize = 4096;

pub const LaneSnap = struct {
    kind: automation.TargetKind, // volume, pan, inst, fx
    fx_uid: u16 = 0,             // the effect instance, for `fx`
    control: u16 = 0,            // control index on that machine
    points_start: u32,           // into auto_points (automation.Point)
    points_count: u32,
};
```

`Track.publishSnapshot` resolves each lane's param id to a control
index on the machine it targets; lanes that are empty, or whose control
no longer exists, are left out. Phase 2 adds a clip index to
`LaneSnap`; phase 3 adds `MAX_EXPR_POINTS_PER_TRACK` and`

`NoteSnap`'s `expr_start`/`expr_count` into the expression-point
pool. The snapshot stores values already
converted to knob norm, so the audio thread never touches units.

**Cursors.** Per lane, the audio thread keeps a last-segment index
(`Track.auto_cursors`, not in the snapshot), so an evaluation usually
costs a comparison, not a search. `automation.evalCursor` checks the
cursor's segment and the next one, and falls back to binary search on
a seek, a loop wrap or a new snapshot.

### Machine controls

`MachineCtx.automation` (carved from its reserved tail) points at a
`snapshot.AutoView`: the track snapshot, its cursors, and which machine
this is (`inst`, or `fx` plus the effect's uid). The engine builds one
per track per block; `renderEffects` retargets it for each effect. In
`FyRawMachine.renderImpl`:

- If any lane targets the machine, the block renders in
  `SMOOTH_CHUNK` (32-sample) sub-blocks, like a glide does today.
- At each chunk start, the machine evaluates every lane that applies
  at that chunk's beat, per §Precedence. A control glides onto its
  curve with the normal 20 ms smoother, then **locks**: from there it
  writes the curve's value straight into `smooth_norm[i]`, since the
  curve is already continuous and the glide would delay every move by
  20 ms.
- A jump of more than 5% of the knob's range in one chunk (a seek, a
  loop wrap, a `hold` step, two points on one beat) unlocks it and
  glides over 20 ms instead of clicking.
- Stepped controls (switches, integer ranges) take the lane's value
  directly, at chunk boundaries.
- Overrides are per-control atomics (`auto_override`, 0/1/2) the UI
  writes and the audio thread reads. An overridden control plays its
  hand-set base the normal way (glide included).

While stopped, the engine only renders the auditioned track; it gets
the lanes at the playhead, so auditioning a note plays the automated
sound.

The panel's controls read `ui_auto`, which `main.zig` fills every frame
through `Machine.set_auto_ui` with each lane's value at the transport
position, from the same evaluator. Other hooks on `Machine` for
automation: `control_count`/`control_info` (id, label, module, steps),
`control_value`/`control_knob` (knob space ↔ file units),
`format_control` (tooltips), `clear_overrides` (transport start), and
`take_auto_request` (the panel's Show/Clear requests). Machines without
them (the Rack) have no automatable controls yet.

The evaluator works in beats, so automation stays locked to the music
when a tempo map arrives.

### Track volume and pan

The engine evaluates the lane at the block's first and last beat and
ramps gain per sample across the block. That's cheap, and there's no
zipper even at large block sizes.

### Note expression

Three pieces, as built:

1. **Real note ids.** The sequencer sends each note's index in the
   track snapshot as its `note_id` (`engine.gatherEvents`). Voices
   record it (`FyRawMachine.voice_note_id`, and the mono held-note
   stack), and note-offs and expression match by id, so a bent or
   converged note is still found. Pitch matching stays as the fallback
   for `-1` sources (the computer keyboard, future MIDI). A looped note
   can't meet its own tail: a loop wrap resets the machines. The Rack
   matched by id already and now transposes expression per part.
2. **An expression event.** `NoteKind.expression` carries, for one
   `note_id`, `pitch`: the note's current pitch (base + bend, MIDI
   float). While a bent note sounds, the sequencer sends one at its
   onset and every `EXPR_STEP` (32) samples; after note-off the voice
   keeps the last value. Voice machines apply events sample-accurately,
   so there is no extra chunking. `pressure`, `slide` and gain join the
   event with their phase.
3. **A machine hook.** The optional manifest entry `note-expr`
   (`( ctx state params -- )`, like `note-on`; `note-expr!` in
   manifest.fy). The host finds the voice holding the id, sets
   `ctx.pitch` and `ctx.hz`, and calls the word for that voice's region.
   Machines without it ignore expression. Built:
   - **sampler** (`sampler-note-expr`): the note-on keeps its unbent
     advance (`inc0`); the bend rescales it, and the release zone plays
     at the bent pitch. The filter keeps the note's tracking.
   - **Unfairlight** (`cmi-note-expr`): the bent clock lands on the
     card's pitch grid like any note (1024 steps an octave); the filter
     keeps the note's octave.
   - Not yet: the synths (oscillator increments), and the piano roll's
     `text_mute` curves plus "machine takes no pitch expression" tooltip
     for machines without the hook.

Mono machines apply expression to the sounding note. A 32-sample step
on a slow bend is inaudible. If fast bends step audibly, the expression
event can carry a per-sample slope later.

## Project format

Everything in files is in **real units**, like presets (docs/19), so
changing a knob's range doesn't move saved automation. Switches store
option indices.

**A lane:**

```json
{"target": "inst:jn-cutoff",
 "points": [[0, 400], [64, 4000, "curve", 0.5], [96, 4000, "hold"], [96, 900]]}
```

- `target`:
  - `volume` or `pan`
  - `inst:<param>`
  - `fx<N>:<param>`: `N` is the effect's 0-based position in the chain
    at save time.
- A point is `[beat, value]` or `[beat, value, shape, tension]`.
  `shape` defaults to `linear` and `tension` to 0.
- Unknown targets and ids are dropped, matching the loader's leniency
  (docs/19 §Where loading fails silently). Values are clamped.

**Where lanes go:**

- A track's lanes: `track.automation` (a list of lanes).
- A note clip's lanes: `clip.automation`, with beats from the clip's
  start.
- A note's expression: `note.expr`. Each dimension is a point list;
  pitch is in semitones relative to the note's pitch, gain in dB:

  ```json
  {"pitch": 60, "start": 0.0, "len": 4.0, "vel": 90,
   "expr": {"pitch": [[0, 0], [1, 0], [3.5, -7, "curve", -0.4]]}}
  ```

Track lanes are in docs/19; clip lanes and `expr` join it with their
phases.

## slabkit

- `track.automate(target, *points)` (built): `target` resolves like
  `track.set(**params)` (param id or alias; `"volume"`, `"pan"`;
  `"fx0:comp-thresh"`). Points are `(beat, value[, shape, tension])`.
  Section starts work for beats.
- `track.ramp(target, frm, to, v0, v1, tension=0)` (built): a
  single-segment sweep from `v0` to `v1`, added into the lane.
- `clip.automate(...)` / `clip.ramp(...)` (built): the same, with
  clip-relative beats; `clip.copy(section)` copies them.
- `clip.bend(points, notes=None)` (built): a pitch bend on the picked
  notes (all, a pitch or pitches, or a predicate on the note dict).
  Points are `(beat from the note's start, semitones[, shape, tension])`,
  at most 8.
- `clip.converge(to, start, end, tension=-0.3, notes=None)` (built): the
  converge gesture as a call. Every note sounding over `[start, end)`
  (clip beats) bends to pitch `to` by `end`.

slabkit checks targets and ranges against `slab --describe` like it
checks params. `--render` runs the same engine, so scripted automation
renders exactly as it plays.

## Phasing

1. **Curves + track lanes.** Built:
   - `automation.zig`, the snapshot lanes, `MachineCtx.automation`,
     and track vol/pan ramps.
   - The arrangement lane UI and the editing gestures.
   - The automated-control LED and movement.
   - Project format and slabkit `automate`/`ramp`.
   - Left over: the title-strip `A` cell, Enter value…, the context
     menu on switch/radio widgets and the header minis, a bench case
     (a cutoff sweep matching a knob-drag render).
2. **Clip lanes.** Built: `Clip.lanes`, precedence in the snapshot
   (track lanes first, clip lanes by clip start, the last lane that
   applies wins, the same rule as `Track.autoValue` on the UI side),
   copy/move/split with clips, the ENV strip, the overlay on track
   lanes, the format, slabkit `clip.automate`/`clip.ramp`.
3. **Note expression.** Built for pitch: note ids and voice matching by
   id, the `expression` event, the `note-expr` hook on the sampler and
   Unfairlight, `Note.bend` in the snapshot and format, the piano-roll
   expression mode and converge drag, slabkit `bend`/`converge`. Left:
   the synths' hooks, the no-hook indication, pressure/slide/gain.
4. **Recording.** The `AUTO` arm, touch-write, and RDP thinning.

## Not planned yet

- relative/offset clip lanes
- bezier handles
- generator shapes (LFO or step shapes drawn into a lane)
- automating Rack part params or the master bus
- tempo automation
- latch/write recording modes

The mod matrix (docs/08 §4) is separate from all of this: automation
sets a control's value, and modulation, once it exists, adds on top of
that value.
