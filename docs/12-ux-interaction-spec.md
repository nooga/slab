# 12 — UX and interaction spec

Slab's UI is immediate-mode, but the user model should feel stable:
the same input should mean the same thing in every pane unless the
pane has a clear reason to differ.

This document is the interaction contract for the frame UI. Widgets can
be implemented as stateless draw calls, but their behavior should follow
these rules.

## Core principles

- **Keep the point of attention stable.** Zooming preserves the thing
  under the cursor when the cursor is inside editable content. If the
  cursor is not in content, zoom around the playhead. If playback is not
  relevant, zoom around the viewport center.
- **Minimap controls navigate, not edit.** Click and drag move the
  viewport window. Wheel zooms the controlled content around the cursor
  beat/time represented by the minimap.
- **Plain wheel scrolls. Modified wheel zooms.**
  - Wheel: pan/scroll the focused pane.
  - Shift-wheel: horizontal time zoom around cursor.
  - Alt-wheel: vertical zoom where the pane has a vertical scale
    (piano-roll pitch rows, future track-height zoom).
  - Wheel over minimap: time zoom around cursor, no modifier required.
- **Selection is cheap, editing is explicit.** A single click selects.
  Drag edits only after the drag owner is claimed. Double-click creates
  or opens. Destructive actions require an explicit key or command.
- **No hidden mode traps.** Active tools must be visible. Escape cancels
  the active drag/tool before it changes selection.
- **Readable beats dense.** The frame can be compact, but status,
  selection, and timing readouts must remain legible at default scale.

## Pointer behavior

### Arrangement

- Click a clip: select clip and its track.
- Shift-click a clip: toggle it in the multi-selection.
- Drag any selected clip: move all selected clips in time.
- Drop selected clips on another lane: move them to the target track,
  preserving their relative track offsets when possible.
- Drag empty lane: box-select clips.
- Click empty lane: select track and clear clip selection.
- Double-click empty lane: create a one-bar clip at the snapped beat,
  select it, and open the piano roll.
- Drag clip body: move the clip, snapped to the grid.
- Drag clip right edge: resize the clip, snapped to the grid.
- Click/drag ruler: scrub the playhead.
- Wheel: horizontal and vertical scroll.
- Shift-wheel: time zoom around cursor beat.
- Wheel over overview strip: time zoom around cursor beat.
- Drag overview viewport: pan time.
- Transport loop button toggles loop playback.
- Arrangement header loop actions:
  - loop selected clips
  - loop entire arrangement
  - clear loop
- Drag loop start/end handles in the ruler to edit loop bounds.
- Click overview outside viewport: center viewport on that beat and
  begin dragging.
- Double-click ruler (no clip under cursor): drop a locator marker at
  the snapped beat; type to name it.
- Right-click ruler: insert a tempo change, signature change, or
  locator marker at the snapped beat.
- Drag a marker: move it along the ruler, snapped to the grid. Moving
  a binding marker edits its tempo/meter map point; moving a locator
  moves only the label.
- Double-click a binding marker: edit its value (BPM, or numerator/
  denominator/grouping).
- Next/prev marker navigation jumps the playhead between markers.

### Piano roll

- Default opening view fits the selected clip horizontally. That
  fit-to-clip scale is the minimum horizontal zoom-out.
- If the clip has notes, default vertical view fits the note pitch range
  with padding. Empty clips center around middle C.
- Click note: select note.
- Drag note body: move note in time and pitch.
- Drag note right edge: resize note.
- Alt-drag note right edge: resize note with snap bypassed and a 1/64-note
  minimum.
- Drag empty grid in draw mode: create a note.
- Drag empty grid in select mode: box select.
- Delete/Backspace: remove selected notes.
- Arrow keys: nudge selected notes by grid step or semitone.
- Shift-Up/Shift-Down: move selected notes up/down one octave.
- Context menu includes Octave up and Octave down for selected notes.
- `Q`: quantize selected notes.
- `H`: humanize selected notes.
- `S`: snap selected notes to the active scale.
- `E`: toggle expression mode (pitch curves on the notes, the converge
  drag; docs/22 §Note expression).
- Wheel: pan time and pitch.
- Shift-wheel: time zoom around cursor beat.
- Alt-wheel: vertical pitch zoom around cursor pitch row.
- Wheel over piano-roll overview: time zoom around cursor beat.
- Drag overview viewport: pan time.

### Automation lanes and note expression

Point, segment and tension gestures, the expression mode (`E`) and the
converge drag are specified in
[22-automation.md §Editing curves](22-automation.md#editing-curves).

## Keyboard behavior

- Space: play/stop.
- Home: rewind to start.
- Tab: show/hide the clip editor.
- M: swap the arrangement for the mixer page and back
  ([23-routing.md](23-routing.md) §Mixer page).
- Cmd/Ctrl `+`: increase UI zoom.
- Cmd/Ctrl `-`: decrease UI zoom.
- Cmd/Ctrl `0`: reset UI zoom.
- Escape: cancel active drag or modal tool state.
- Delete/Backspace: delete the active selection in the focused editor.

## Looping

Loop state belongs to transport. Arrangement edits the loop range, but
playback wrapping is transport-owned.

- Loop bounds are stored in beats.
- Loop bounds snap to the active time grid.
- Minimum loop length is one current grid unit.
- Loop selected clips uses the earliest selected clip start and latest
  selected clip end.
- Loop entire arrangement uses beat 0 through the latest clip end.
- Clearing loop disables loop playback but may keep the last bounds for
  later reuse.

## Markers and meter

Markers and the meter map are defined in
[docs/07](07-transport.md#markers). This section is their interaction
contract in the frame.

- **Bar lines come from the meter map**, not `beat % 4`. The ruler
  reads `MeterMap.barStartBeat`; bar spacing varies when the meter
  changes. In-bar subdivision follows the denominator, with brighter
  lines at `groups` boundaries (e.g. 7/8 as 2+2+3). Right-click the
  ruler → **Grouping of N/D** picks the grouping of the meter under the
  cursor (default, or any split into 2s and 3s; the current one is
  bulleted).
- **Snap is meter-aware.** Bar-snap and "one bar" lengths consult the
  meter map at that bar. A "one-bar clip" created on the arrangement
  is as long as the bar it lands in.
- **A meter change re-lays the grid at the next bar boundary**, never
  mid-bar, including when a generator re-materializes after a
  hot-patch. The playhead, loop, and metronome accent stay put until
  the downbeat.
- **Generators are run from the meter editor, not typed inline.** The
  document keeps the materialized map; the chosen generator word and
  its seed are stored alongside so it can be re-run.
- Locator markers are navigation only and never affect the grid,
  snapping, or timing. Tempo changes, sections and grooves are edited
  as [docs/28](28-time.md) describes.

## Zoom rules

### Time zoom

Time zoom always changes `px_per_beat` and then recomputes `scroll_x`
from an anchor:

```text
anchor_beat = beat under cursor, playhead, or viewport center
anchor_px   = cursor x within content, playhead x, or viewport center
scroll_x    = anchor_beat * new_px_per_beat - anchor_px
```

Clamp `scroll_x` after layout knows the content extent.

### Piano-roll minimum zoom

For a selected clip:

```text
min_px_per_beat = grid_width / clip.length_beats
```

The user may zoom in from there, but zooming out stops when the whole
clip length fills the visible grid. Empty space past the clip end is
shown only when the viewport is wider than the clip at that minimum.

### Vertical pitch zoom

Vertical zoom changes `row_h` and preserves the pitch row under the
cursor:

```text
anchor_row = row under cursor
scroll_y   = anchor_row * new_row_h - cursor_y_in_grid
```

On first open, fit the note pitch range with two rows of padding when
there are notes. Empty clips use the default row height and center C4.

## Visual contrast

- Grid lines must be visible at default scale without dominating notes
  or clips.
- Bar lines are brighter than beat lines.
- Clip-end and playhead lines use accent colors and remain 1px. The
  clip editors show the playhead too, while the transport plays inside
  the open clip.
- Black-key piano-roll rows should be distinguishable from white-key
  rows even at low row heights.
- Text and status cells must not rely on tiny muted labels alone; the
  value must be readable first.

## Tooltips

- Tooltips appear after a short hover delay.
- Tooltips name the action and include the shortcut when one exists.
- Tooltips are deferred until the end of the frame so they draw above
  all immediate-mode widgets.
- Tooltips never appear while dragging.
