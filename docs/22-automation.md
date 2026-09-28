# 22 — Automation

Values that change over time on their own: a fader ride into the
chorus, a filter opening over 16 bars, a chord whose notes bend onto
one pitch. **Status: design. Nothing here is built yet.** Until it is,
[21-production-guide.md](21-production-guide.md) §"Without automation"
still applies.

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

**Title-strip display.** Hovering an automated control shows
`CUTOFF 1.25 kHz` followed by an `A` cell, so the value channel also
says the value isn't fully yours.

**Context menu** on any automatable control (and on the header volume
and pan minis):

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
| right-click a point | menu: Hold / Linear / Curve, Reset tension, Enter value… |
| draw tool + drag | freehand: writes points along the drag, thinned as in recording, replacing points in the dragged span |

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

- An `AUTO` latch on the track header shows or hides the track's
  lanes. Each lane is a 28 px row under the track (docs/06 already
  reserves this), with a header that holds:
  - a target dropdown (machine › control, or VOL / PAN),
  - a remove button.
- A track can have several lanes. New ones come from **Show automation**
  on a control or the lane header's `+` menu.
- **Clip lanes seen from the track.** Where a clip holds a clip lane
  for the same target, the track lane draws the track curve muted and
  the clip's curve over it in full, so the lane always shows what will
  actually play.
- Moving and copying clips carries their clip lanes. Track-lane points
  stay put.

### Clip lanes (clip editor)

An envelope strip under the piano roll's velocity lane, with a target
dropdown and the same gestures. Only points in `[0, len)` of the clip
matter. Resizing a clip shorter keeps the points past its end (they
come back if the clip grows) but they don't play.

### Note expression (piano roll)

**Pitch curves are drawn on the note grid itself.** A bend starts at
the note's own row and runs across the pitch rows, so you can see
exactly where it lands:

- **Expression mode:** the key `E` (and a piano-roll header latch)
  toggles it. In expression mode:
  - every note's pitch curve draws in the note's highlight tint,
  - the curves of selected notes get handles and take the gestures
    above.
- **Outside expression mode**, curves draw faintly on notes that have
  them, and aren't editable.
- **Pitch values snap to semitone rows.** Alt drags free, in cents.
  The range is fixed at ±48 semitones, and the vertical view is the
  piano roll's own, so a bend reads in real pitch.
- **Time:** a point's time is from the note's start. Points belong in
  `[0, len]` of the note. After the note ends, the curve holds its
  last value, so the release keeps the bent pitch.
- **Converge gesture:** in expression mode, drag from a selected note's
  body to a target row and time. Every selected note gets a curve:
  it holds 0 until the drag's start time, then runs a `curve` segment
  to *(target pitch − its own pitch)* at the drag's end time.
  One drag makes a chord fold onto one note or spread from a unison.
  Alt-dragging one note's segment afterwards bends that segment on
  every selected note together.
- **Pressure, slide and gain** edit in the envelope strip, which
  switches to per-note mode for the selected note. With several notes
  selected, it draws all their curves and edits them together.

## Engine

### Snapshot

Lanes publish with the track, in the existing double-buffered
`TrackSnapshot` (`src/snapshot.zig`). The UI writes the idle slot and
flips; the audio thread reads the published one for the block.
New fixed arrays:

```zig
pub const MAX_LANES_PER_TRACK: usize = 32;          // track + clip lanes
pub const MAX_AUTO_POINTS_PER_TRACK: usize = 4096;
pub const MAX_EXPR_POINTS_PER_TRACK: usize = 4096;

pub const AutoPoint = struct {
    beat: f64,        // track lane: song beat; clip lane / expression: relative
    value: f32,       // knob norm 0..1, option index, or semitones / dB for expression
    shape: u8,        // hold, linear, curve
    tension: f32,
};

pub const LaneSnap = struct {
    slot: u16,        // instrument, effect instance, or track vol/pan
    control: u16,
    clip: i16,        // -1 = track lane, else index into `clips`
    points_start: u32,
    points_count: u32,
};
```

`NoteSnap` gains `expr_start`/`expr_count` into the expression-point
pool, plus a per-dimension count. The snapshot stores values already
converted to knob norm, so the audio thread never touches units.

**Cursors.** Per lane, the audio thread keeps a last-segment index
(engine-owned, not in the snapshot), so an evaluation usually costs a
comparison, not a search. A seek, a loop wrap or a new snapshot resets
the cursors and falls back to binary search.

### Machine controls

`MachineCtx` gains `automation: ?*const AutoView`. That's the slice of
lanes targeting this machine instance plus a pointer to the track
snapshot's points, in the block arena. In `FyRawMachine.renderImpl`:

- If any lane targets the machine, the block renders in
  `SMOOTH_CHUNK` (32-sample) sub-blocks, like a glide does today.
- At each chunk start, the machine evaluates every lane that applies
  at that chunk's beat, per §Precedence, and writes the result straight
  into `smooth_norm[i]`. The curve is already continuous, so it skips
  the 20 ms glide, which would otherwise delay every move by 20 ms.
- The UI thread stores overrides in per-control atomic bits. An
  overridden control reads its target the normal way (glide included).
- A `hold` step or jump lands on a chunk boundary: at most 0.67 ms
  late at 48 kHz. On gain-like targets a step clicks, the same as it
  would on hardware. Draw a short ramp to avoid it.

Automation keeps working while stopped: the audio callback still runs
(live input, tails), and lanes are evaluated at the stopped playhead.
Locating while stopped moves the audio along with the controls.

The evaluator works in beats, so automation stays locked to the music
when a tempo map arrives.

### Track volume and pan

The engine evaluates the lane at the block's first and last beat and
ramps gain per sample across the block. That's cheap, and there's no
zipper even at large block sizes.

### Note expression

Three changes, all needed before a note can bend:

1. **Real note ids.** Today the sequencer sends `note_id = -1`
   (`engine.zig`), and `FyRawMachine` matches note-offs by pitch
   (`voice_pitch`). A bent note's pitch no longer matches, and
   converging notes end up sharing one. The sequencer will assign
   `note_id` = the note's snapshot index, with a per-trigger generation
   in the high bits, so a looped note never matches its own release
   tail. Voices record the id and note-off matches by id. Pitch
   matching stays as a fallback for `-1` sources (the computer keyboard,
   future MIDI).
2. **An expression event.** A new `NoteKind.expression` carries, for
   one `note_id`:
   - `pitch`: absolute MIDI float (base + bend),
   - `pressure`,
   - `slide`,
   - `value`: gain in dB.

   While a note with expression is held or releasing, the sequencer
   evaluates its curves at each 32-sample chunk and sends an event when
   any value changed. A track with active expression renders in chunks,
   like a machine with lanes.
3. **A machine hook.** A new optional manifest entry `note-expr`
   (`( ctx state params -- )`, like `note-on`). The host finds the
   voice holding the id, sets `kctx.pitch`, the Hz value, `kctx.pressure`,
   `kctx.slide` and `kctx.gain`, and calls the word for that voice's
   region. The word updates the voice's phase increment, playback rate
   or level. Machines without the hook ignore expression, and the piano
   roll draws their curves in `text_mute`, with the tooltip "machine
   takes no pitch expression".

   Each machine needs its own small change:
   - the sampler and Unfairlight: playback rate,
   - the synths: oscillator increments,
   - drum2: none.

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

docs/19 gets these fields when phase 1 lands.

## slabkit

- `track.automate(target, *points)`: `target` resolves like
  `track.set(**params)` (param id or alias; `"volume"`, `"pan"`;
  `"fx0:comp-thresh"`). Points are `(beat, value[, shape, tension])`.
  `song.bar(n)` and section starts work for beats.
- `track.ramp(target, frm, to, v0, v1, tension=0)`: a single-segment
  sweep from `v0` to `v1`, added into the lane.
- `clip.automate(...)` / `clip.ramp(...)`: the same, with clip-relative
  beats.
- `clip.bend(note_or_filter, points, dim="pitch")`: expression on
  matching notes.
- `clip.converge(to, start, end, tension=0)`: the converge gesture as a
  call. Every note sounding over `[start, end]` bends to pitch `to` by
  `end`.

slabkit checks targets and ranges against `slab --describe` like it
checks params. `--render` runs the same engine, so scripted automation
renders exactly as it plays.

## Phasing

1. **Curves + track lanes.**
   - `automation.zig`, the snapshot lanes, `MachineCtx.automation`,
     and track vol/pan ramps.
   - The arrangement lane UI and all editing gestures.
   - The automated-control LED and movement.
   - Project format, slabkit `automate`/`ramp`, and a bench case: a
     cutoff sweep matching a knob-drag render.
   - Exit: a song rides a fader and opens a filter from a script and
     from the UI.
2. **Clip lanes.** The clip editor's envelope strip, precedence,
   copy/move with clips, and the overlay on track lanes.
3. **Note expression.**
   - Note ids and voice matching by id; this can land earlier on its
     own.
   - The `expression` event and the `note-expr` hook, starting with the
     sampler and Unfairlight (rate is easy), then the synths.
   - The piano-roll expression mode, the converge gesture, and
     `bend`/`converge`.
   - Pitch first, then pressure, slide and gain.
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
