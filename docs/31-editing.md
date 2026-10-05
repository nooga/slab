# 31 — Editing: one way to work across the editors

The arrangement, the piano roll, the audio editor and the automation
lanes were built one at a time and each grew its own wheel, minimap,
box select, ruler, edge grabs and menus. This doc makes them one
instrument: the same gesture means the same thing everywhere, the code
behind it exists once, and three new abilities are built on top: time
selection, better note editing, and editing several clips at once.

Status: planned (2026-10-05). Phase 1 in progress on `feat/editing`.
docs/12 stays the interaction contract; as each phase lands, its rules
move into docs/12 and this doc keeps the plan and the reasons.

## What musicians expect (and other DAWs do)

- **One grammar.** In Live, Bitwig, Logic and Reaper the arrangement and
  the editors share scroll, zoom, select, move, resize and duplicate.
  Learning one teaches the others.
- **⌘-wheel or pinch zooms; the wheel scrolls.** Live: ⌘-scroll zooms,
  ⌥-scroll sizes tracks; Logic: ⌘/⌥ scroll zoom; Bitwig: ⌘/pinch. Shift
  turns a mouse wheel horizontal, as macOS does everywhere.
- **Time selection, not just objects.** Live's arrangement and editors
  select a stretch of time across tracks; ⌘D duplicates it (gaps too),
  ⌘L loops it, ⌘E splits at its edges, Insert/Delete Time works on it.
  Bitwig's time selection and Logic's marquee do the same.
- **Both ends of a note are handles.** Live, Bitwig, Logic: drag either
  end, ⌥-drag duplicates, notes sound when touched and when dragged to a
  new pitch; the keyboard column plays and lights up.
- **Multi-clip editing.** Live 11's MIDI editor shows several clips at
  once, the others dimmed, loop bars for each; Bitwig's layered editing
  does the same. That is where cross-clip tools (fit the bass to the
  chords) start.

## Where we are (2026-10-05)

An inventory of the code (not the docs) found, among others:

- **Wheel:** ⇧-wheel zooms time; ⌥-wheel zooms piano-roll rows, does
  nothing in the arrangement, and pans in the audio editor; a vertical
  wheel pans *time* in the audio editor and *tracks/pitch* elsewhere.
- **Minimap:** three implementations; the audio editor's has no wheel,
  no grab and drops the drag when the pointer leaves the strip.
- **Box select:** three implementations; the arrangement clears on
  release, the piano roll on press; overlap is strict in one, inclusive
  in the other; the lanes have no threshold; the audio editor has none.
- **Edges:** clips 5 px, notes 4 px inside the rect (a tiny note is all
  edge), audio handles ±4 px; left edges only on audio clips; resizing
  changes every selected note but only the dragged clip.
- **Rulers:** the arrangement scrubs and loops; the editors' rulers are
  pictures; the audio editor's ignores the meter.
- **Keys:** focus moves only on a pane press that no Ui widget took, so
  clicking a track header leaves the piano roll focused and Delete
  deletes notes; the audio editor shares the piano roll's focus, so Q,
  H, S, the arrows act on notes it doesn't have; panes check ⌘ as
  Super only while main also takes Ctrl; ⌥-nudge re-snaps to the grid
  and so does nothing.
- **Menus:** each pane hand-builds its own; Paste lands at the playhead
  from the key and at the click from the menu; the menu's Delete and
  the key's Delete delete different things.
- **Audition:** fires when a box select starts, never while dragging to
  a new pitch, never from the keyboard, only while stopped, 200 ms.
- **Code:** view state, beat↔x, wheel, minimap, scrollbar, ruler ticks,
  grid lines, playhead and box select are copied three or four times.

## The grammar

What every timeline (arrangement, piano roll, audio editor, automation
lanes, note expression) does with the same input. "Object" is a clip, a
note, a point, a warp marker.

### View

| input | does |
|---|---|
| wheel / two-finger swipe | scroll both axes (an editor with no vertical axis scrolls time with either) |
| ⇧-wheel | scroll time (a mouse wheel's horizontal) |
| ⌘-wheel, pinch | zoom time around the pointer |
| ⌥-wheel | zoom height around the pointer: piano-roll rows, track height |
| wheel over the minimap | zoom time around the beat under the pointer |
| drag the minimap's window | pan; press outside it jumps there and keeps dragging |
| drag the minimap window's edges | zoom by setting the visible range |
| `Z` | zoom to the selection (or the whole clip/song when nothing is) |

Over track headers the wheel scrolls tracks and ⌘-wheel goes to the
knob under the pointer, as docs/06 says controls take the wheel only
with ⌘.

### Pointer

| input | on an object | on empty space |
|---|---|---|
| click | select it (only it) | clear the selection, set the edit cursor |
| ⇧-click, ⌘-click | add to / remove from the selection | — |
| drag (past 3 px) | move the selection, snapped by delta | box select (phase 2: time selection) |
| ⇧-drag | — | box adds to the selection |
| ⌥-drag | duplicate the selection and move the copy | — |
| drag an edge | resize the selection from that end | — |
| ⌘-drag an edge | audio: stretch; notes: scale the selection in time | — |
| ⌘-drag | — | draw: a note (piano roll), a clip (arrangement), points (lanes) |
| double-click | notes, points, markers: delete; clips: rename | create one: note, clip, point, warp marker |
| right-click | select it if it isn't, then the menu | the menu, with the edit cursor here |
| Escape | cancel the drag (everything back), else clear the selection | |
| ⌥ held | bypass snap, for every gesture and the nudge keys | |

- **Edge zones** are the same everywhere: each end is
  `min(6, w/4)` px inside the object plus 2 px outside it, so the
  middle half is always the body and a tiny object can still be
  grabbed and moved; the cursor shows ↔ over an edge.
- **Every object has two ends**, notes and note clips included.
- **Snap:** moving and resizing existing things snaps the *delta* (off-
  grid stays off-grid); creating snaps *absolutely*. ⌥ frees both.
- **DRAW** stays as a latch in the piano roll for people who like a
  pencil; with it on, a plain drag on empty space is ⌘-drag.

### Keys

One command table (below) holds every edit command with its key. The
focused pane decides what it acts on; a command a pane can't do is
greyed in its menu and its key does nothing there.

| key | does |
|---|---|
| ⌘C ⌘X ⌘V | copy, cut, paste at the edit cursor (last click), else the playhead |
| ⌘D | duplicate the selection after itself (phase 2: the time selection) |
| ⌫ | delete the selection; with a lane or expression point selected, that |
| ⌘A, Esc | select all, clear |
| ← → | nudge by the grid; ⇧ by a beat; ⌥ off the grid (1/64) |
| ↑ ↓ | notes: a semitone, ⇧ an octave; clips: to the next track |
| ⌘L | loop the selection |
| ⌘E | split at the edit cursor (phase 2: at the time selection's edges) |
| ⌘J | join (consolidate) the selection |
| ↩ | rename |
| 0 | mute the selection |
| Q H S | quantize, humanize, snap to scale (notes; audio: quantize hits) |
| E | expression mode (notes) |
| Z | zoom to the selection |
| Tab | show/hide the clip editor |

**Focus** follows the last pointer press anywhere in a pane, its head
and track headers included; the audio editor is its own pane.

### Menus

Every object menu is built from the command table in the same order,
so the same item sits in the same place in every editor:

1. **Edit:** Cut, Copy, Paste, Duplicate, Delete
2. **The object's own:** for clips Split, Join, Reverse, Warp, Tune,
   Mute, Extract ▸, Tempo from clip ▸, Bounce; for notes Octave ↑↓,
   Quantize, Humanize, Snap to scale, Groove; for audio Detect tempo,
   Quantize hits, markers
3. **Selection:** Select all, Clear selection, Zoom to selection
4. **Loop:** Loop selection, Loop clip/arrangement, Clear loop
5. **Name:** Rename, Save to Library

Shortcut hints come from the same table.

### Rulers

Every ruler is the same widget: meter-aware ticks from the meter map,
click or drag to scrub (a clip editor's ruler scrubs the song inside
that clip), loop edges drag where the loop is visible, drag across the
ruler with ⇧ to set the loop.

## The shared code

Phase 1 replaces the copies with modules every timeline uses:

- **`ui/timeline.zig` — the view.** `View { px_per_beat, scroll_x,
  scroll_y, row_h, min/max zoom, follow, last_scroll }` with
  `beatToX`, `xToBeat`, `wheel(m, zone, axes)`, `zoomAround`,
  `clamp(content)`, `zoomTo(range)`; the one minimap
  (`overview(ui, r, view, content_beats, drawContent)`, its window,
  grab, jump, wheel and edge-zoom); the vertical scrollbar; ruler ticks
  and grid lines from the meter map; the playhead line.
- **`ui/gesture.zig` — the pointer grammar.** `Mods` (⌘ = Super or
  Ctrl, ⇧, ⌥, read once per frame); `edgeHit(rect, x)` with the zones
  above; a `Press` that classifies a press (body, left edge, right
  edge, empty) and starts a drag after the 3 px threshold; `Box`, the
  one box select (clear on press unless ⇧, inclusive overlap, 3 px
  threshold, drawn the same everywhere).
- **`ui/commands.zig` — the command table.** One entry per command:
  `{ id, label, key, mods, panes, section }`. The key dispatch in main,
  the menus and their shortcut hints all read it; `menu.EditCommand`
  becomes its id enum.

## Time selection (phase 2)

A selection becomes `{ start_beat, end_beat, tracks | pitches }` plus
the objects inside, the way Live's is.

- Dragging empty space draws it; the objects it touches are selected
  with it. A click sets an empty one (the edit cursor).
- **⌘D** duplicates the range (content and gaps) right after it;
  **⌘L** loops it; **⌘E** splits at its edges; **⌘C/⌘V** copy and paste
  the range (pasting a range of tracks onto the same number of tracks
  from the one under the edit cursor); **Insert time** and **Delete
  time** open or close the range across every track and the tempo,
  meter and section maps.
- The piano roll's range is beats × pitches; ⌘D duplicates the bar,
  not just its notes. The audio editor's range is a stretch of the
  clip: split, consolidate, turn into a sampler pad.
- Drawn as a lighter wash over the lanes with its edges in the ruler.

## Note editing (phase 3)

- **Left edge:** drag moves the start, keeps the end; on every selected
  note.
- **⌥-drag duplicates.** ⌘-drag on an edge scales the selection in time
  around its other end.
- **Audition:**
  - pressing a note plays it; moving the selection to a new pitch plays
    the new pitches (the chord when several are selected); a box select
    plays nothing;
  - plays while the transport runs too, through the track, as long as
    the button is held (not a fixed 200 ms);
  - a headphone latch in the editor head turns it off.
- **The keyboard column:**
  - click plays the key while held, drag plays a glissando;
  - ⇧-click selects every note of that pitch;
  - keys that sound right now light up in the track color, from a
    128-bit held-note set per track the engine publishes each block
    (atomics, no allocation; docs/04's discipline);
  - the same lit set marks notes that sound under the playhead.
- New notes come out selected, so a drawn note can be nudged at once.

## Multi-clip editing (phase 4)

- With several clips selected, the editor head shows a tab per clip
  (track color, name); the focused one is edited, the others draw as
  ghosts at their place in the song, dimmed.
- The editor's time axis is the song's when more than one clip is
  shown: each clip's start and loop show as brackets in the ruler.
- Clicking a ghost note focuses its clip; ⌘A selects in the focused
  clip only; box select stays in the focused clip.
- Audio and note clips can be shown together: audio as a dimmed
  waveform band under the notes, to write against.
- Later, on top of it (not designed here): take the chords from one
  clip and arpeggiate them into another, fit a bassline to chords,
  harmonize a melody, copy a groove across.

## Phasing

1. **One grammar.** `timeline.zig`, `gesture.zig`, `commands.zig`;
   all four timelines on them; the wheel, minimap, box select, edges,
   snap and ⌥, focus, menus, rulers and keys of §The grammar (not yet
   ⌘-drag draw on the arrangement, ⌥-drag duplicate, time selection).
   docs/12 rewritten to match. Exit: the inconsistencies listed in
   §Where we are are gone, and each module has unit tests.
2. **Time selection** in the arrangement, then the editors.
3. **Note editing:** left edges, ⌥-drag duplicate, audition, the
   keyboard column, held-note lighting.
4. **Multi-clip editing:** tabs, ghosts, song-time axis.
5. Later: pinch zoom through a native gesture hook, cross-clip tools.

The accessibility tree (docs/32) leans on phase 1: one command table
and one gesture layer give every element a known set of actions.
