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
- **The wheel scrolls; ⌘ zooms.** One rule in every timeline
  (`ui/timeline.zig`, docs/31 §View):
  - Wheel / two-finger swipe: scroll both axes. An editor with no
    vertical axis (the audio editor) scrolls time with either.
  - ⇧-wheel: scroll time (a mouse wheel's horizontal).
  - ⌘-wheel: time zoom around the pointer.
  - ⌥-wheel: height zoom around the pointer where rows zoom (the piano
    roll's pitch rows; track height is later).
  - Wheel over a minimap: time zoom around the beat under the pointer.
- **Selection is cheap, editing is explicit.** A single click selects.
  Drag edits only after the drag owner is claimed. Double-click creates
  or opens. Destructive actions require an explicit key or command.
- **No hidden mode traps.** Active tools must be visible. Escape cancels
  the active drag/tool before it changes selection.
- **Readable beats dense.** The frame can be compact, but status,
  selection, and timing readouts must remain legible at default scale.

## Pointer behavior

Every timeline (arrangement, piano roll, audio editor, automation lanes,
note expression) shares one grammar (`ui/gesture.zig`, docs/31
§Pointer). "Object": a clip, a note, a point.

- **Click** an object: select only it. **⇧- or ⌘-click**: add it to or
  take it from the selection (on a track header ⇧ selects a range and ⌘
  toggles).
- **Drag** an object (past 3 px): move the selection, the delta snapped
  so off-grid things stay off-grid. Clips can be dropped on another lane.
- **Edges:** both ends of every clip and note resize, the whole
  selection at once. Each end's zone is `min(6 px, width/4)` inside the
  object, so the middle half is always body; in the piano roll it also
  reaches 2 px outside, so a sliver of a note can still be grabbed. The
  cursor shows ↔ over an edge. The left edge keeps the right one put: on
  a note clip the notes and lane points stay where they sound and what
  ends up before the new start is cut when the drag ends; on audio it
  trims the source window (⌘: stretch).
- **Empty space:** a press clears the selection (unless ⇧) and sets the
  edit cursor; a drag draws a box that selects every object it touches,
  and its stretch of time becomes the **time selection** (below); a
  click within 3 px only clears.
- **⌥-drag** an object: copies stay where the selection was and it
  moves; the grid stays on (⌥ pressed after the drag started frees it).
  Escape takes the copies back.
- **Double-click:** on empty grid, create (a one-bar clip, a note of the
  grid's length, a point, a warp marker); on a note or point, delete it;
  on a clip, rename it.
- **⌘-drag** on empty space draws: a clip on an arrangement lane (a
  click makes one bar), notes in the piano roll, points in a lane. The piano roll's DRAW latch makes a plain drag draw.
- **Right-click:** selects the object if it isn't, sets the edit
  cursor, opens the menu.
- **Escape:** ends a drag with everything back where it started, else
  clears the selection.
- **⌥** bypasses snap for every gesture and for the nudge keys.
- **Rulers** (all of them): click or drag to scrub (a clip editor's
  ruler seeks the song inside that clip); ⇧-drag across one sets the
  loop; the arrangement's loop edges drag where the loop shows. Ticks and
  bar numbers come from the meter map in every editor.
- **Minimaps** (all of them): drag the window to pan, press outside it
  to jump there and keep dragging, drag its edges to zoom, wheel over it
  to zoom.

### Time selection

docs/31 §Time selection. In the arrangement a drag on empty lanes
selects a stretch of time across the tracks it spans (snapped; ⌥ off
the grid), shown as a light wash and a bar along the ruler, and the
clips it touches. ⌘D duplicates it after itself (over what was there;
the selection moves onto the copy), ⌫ empties it, ⌘C/⌘X/⌘V copy, cut
and lay it over the tracks from the edit cursor down, ⌘L loops it, ⌘E
cuts at its edges, Z zooms to it, ⌘I inserts its length of time and
⌘⇧⌫ deletes it, song-wide. In the piano roll the box's stretch is the
selection: ⌘D duplicates the selected notes by its length, ⌘L loops
it.

### Arrangement

- Selecting a clip selects its track and opens it in the clip editor.
- Fades: drag the knees in an audio clip's top corners (unsnapped).
- Double-click the ruler (no clip under the cursor): drop a locator
  marker at the snapped beat; type to name it.
- Right-click the ruler: insert a tempo change, signature change, or
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
- Moving notes changes time and pitch; resizing keeps a 1/64-note
  minimum with ⌥.
- A drawn note comes out selected, alone.
- Pressing a note plays it (while stopped); a box select plays nothing.

### Audio editor

- The clip's window edges and fades are handles on the waveform.
- Warped: drag markers, ⌘-drag to slide the audio under one, drag a
  transient to make it a marker, double-click the strip to add one.
- Its menu (warped or not) ends with the clip's own commands: Extract,
  Tempo from clip, Reverse, Warp, Tune, Zoom, Rename.

### Automation lanes and note expression

Point, segment and tension gestures, the expression mode (`E`) and the
converge drag are specified in
[22-automation.md §Editing curves](22-automation.md#editing-curves).

## Keyboard behavior

Edit keys come from one command table (`ui/commands.zig`, docs/31
§Keys); a menu item and its key run the same command. They act on the
focused pane, and focus follows the last press anywhere in a pane, its
head and track headers included. The clip editor counts as the piano
roll on a note clip and as the audio editor on an audio clip; a key a
pane can't use does nothing there.

| key | does |
|---|---|
| ⌘C ⌘X ⌘V | copy, cut, paste: a key's paste lands at the edit cursor (the last click on empty space), else the playhead; a menu's at the click |
| D, ⌘D | duplicate the time selection, else the selection, after itself |
| ⌫ | delete: selected lane or expression points first, then the selection |
| ⌘A | select all |
| Esc | cancel the drag, else clear the selection |
| ← → | nudge by the grid; ⇧ a beat; ⌥ 1/64 (never rounded back to the grid) |
| ↑ ↓ | notes: a semitone, ⇧ an octave; clips: to the next track |
| ↩ | rename the clip (or the track) |
| 0 | mute the selection |
| Z | zoom to the selection, or the whole clip/song |
| ⌘L | loop the time selection, else the selected clips |
| ⌘E | split at the time selection's edges, else the selected clips at the playhead (arrangement) |
| ⌘J | join the selected note clips on each track |
| ⌘I / ⌘⇧⌫ | insert / delete the time selection's time, song-wide |
| Q H S | quantize, humanize, snap to scale (notes) |
| E | expression mode (notes) |
| [ ] | coarser / finer snap |

Global:

- Space: play/stop. Home: rewind to start.
- ⌘← / ⌘→: previous / next section, locator or END.
- Tab: show/hide the clip editor.
- M: swap the arrangement for the mixer page and back
  ([23-routing.md](23-routing.md) §Mixer page); ⇧M clears solos and
  mutes.
- Cmd/Ctrl `+` / `-` / `0`: UI zoom.

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

Time zoom (`View.zoomTime`) always changes `px_per_beat` and then
recomputes `scroll_x` from an anchor:

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
