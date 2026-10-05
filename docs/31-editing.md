# 31 — Editing: one way to work across the editors

The arrangement, the piano roll, the audio editor and the automation
lanes were built one at a time and each grew its own wheel, minimap,
box select, ruler, edge grabs and menus. This doc makes them one
instrument: the same gesture means the same thing everywhere, the code
behind it exists once, and three new abilities are built on top: time
selection, better note editing, and editing several clips at once.

Status: phases 1 and 2 built (2026-10-05) on `feat/editing`: one view,
wheel, minimap, ruler, box select, edges, snap, focus, command table and
menu order across the editors; time selection in the arrangement and the
piano roll, join, insert and delete time, ⌥-drag duplicate, ⌘-drag to
draw a clip; hearing notes as they are pressed and dragged, playing or
not, a playable keyboard column, keys and notes lit while they sound.
docs/12 states those rules. Phase 4 planned. docs/12 stays the interaction contract; as each phase lands,
its rules move there and this doc keeps the plan and the reasons.

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
| ⌥-wheel | zoom height around the pointer: piano-roll rows (track height later) |
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
| ⌘D | duplicate the time selection, else the selection, after itself |
| ⌫ | delete the selection; with a lane or expression point selected, that |
| ⌘A, Esc | select all, clear |
| ← → | nudge by the grid; ⇧ by a beat; ⌥ off the grid (1/64) |
| ↑ ↓ | notes: a semitone, ⇧ an octave; clips: to the next track |
| ⌘L | loop the selection |
| ⌘E | split at the time selection's edges, else the selected clips at the playhead |
| ⌘J | join the selected note clips on each track |
| ⌘I, ⌘⇧⌫ | insert time, delete time (the time selection's, song-wide) |
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

## Time selection (phase 2, built)

A selection is a stretch of time across a run of tracks, plus the clips
it touches, the way Live's is (`arrangement.Range`: beats [a, b) and
the tracks' places lo..hi, buses skipped).

- Dragging empty lanes draws it, its edges on the grid (⌥: off it);
  the clips it touches are selected with it (⇧ adds them to the
  selection). A click clears it; so does clicking a clip, Escape or
  Clear selection. It shows as a light wash over its tracks' stretch
  and a bar along the ruler's top.
- **⌘D** copies what plays in it right after it, over whatever was
  there, and the selection moves onto the copy, so ⌘D again goes on.
- **⌫** empties it (clips cut at its edges, nothing moves); **⌘X**
  copies and empties.
- **⌘C** copies it; **⌘V** lays that stretch over the same length from
  the edit cursor (the selection's start, else the last click) on the
  tracks from that one down, replacing what was there.
- **⌘L** loops it; **⌘E** cuts its tracks' clips at both edges; **Z**
  zooms to it.
- **⌘I Insert time** opens its length of nothing at its start across
  the whole song; **⌘⇧⌫ Delete time** removes it from the whole song
  and closes the gap. Both move clips, track automation, tempo and
  meter changes (whole bars from a downbeat), sections, locators and END,
  through `arrange.zig`'s section machinery.
- **⌘J Join** makes the selected note clips on each track one clip, from
  the first's start to the last's end, notes and clip lanes where they
  played. Audio clips are joined by bouncing.
- In the piano roll the box's stretch of time is the selection: ⌘D
  duplicates the selected notes by its length (the bar, not just the
  notes), ⌘L loops it, Z zooms to it.
- Later: the audio editor's range (split, consolidate, a sampler pad).

Pointer additions with it: **⌥-drag** leaves copies where the clips or
notes were and moves the originals (the grid stays on; ⌥ pressed after
the drag starts frees it), Escape takes the copies back; **⌘-drag** on
an empty lane draws a clip (a click makes one bar).

## Note editing (phase 3, built)

- **Left edge** (built in phase 1): drag moves the start, keeps the end;
  on every selected note.
- **⌥-drag duplicates.** ⌘-drag on an edge scales the selection in time
  around its other end.
- **Hearing notes:**
  - pressing a note holds it (the selection's pitches, up to eight, so
    a chord sounds as one), moving it to a new pitch moves the sound,
    drawing a note holds its pitch; a box select plays nothing;
  - held for as long as the button is, through the track's instrument
    and inserts, while the transport runs too (the held notes go in with
    the track's own events); stopped, the track plays alone until its
    tail has rung out;
  - the **HEAR** latch in the editor head turns it off for notes (the
    keyboard always plays).
  - Main sends the difference between what the editor wants held and
    what is (`Engine.holdNote`, a ring the audio thread drains each
    block), so the editor only states a set of pitches.
- **The keyboard column:**
  - click plays the key while held, drag plays a glissando;
  - ⇧-click selects every note of that pitch;
  - keys that sound right now light up in the track color, from a
    128-bit set per track the audio thread updates from the note events
    it plays (`Track.sounding`, two atomics, no allocation);
  - the same set lights the notes under the playhead.
- New notes come out selected, so a drawn note can be nudged at once
  (built in phase 1).

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

1. **One grammar** (built). `timeline.zig`, `gesture.zig`,
   `commands.zig`; the arrangement, piano roll and audio editor on them,
   the lanes on the same box and modifier rules; the wheel, minimap,
   ruler (scrub, ⇧-drag loop, meter ticks), box select, both edges of
   every clip and note over the whole selection, double-click create
   and delete, ⌘-drag draw in the piano roll, snap and ⌥ (nudge
   included), Escape restoring a drag, focus on any press, the edit
   cursor for pastes, Z, ⌘L, ⌘E, the menus' order, and a menu for
   unwarped audio. docs/12 rewritten to match. Left for later: ⌥-wheel
   track height, the audio editor's handles on the shared edge zones.
2. **Time selection** (built): the arrangement's range and its commands,
   Insert and Delete time, ⌘J, ⌥-drag duplicate, ⌘-drag to draw a clip,
   the piano roll's range. The audio editor's range is later.
3. **Note editing** (built): held notes while pressing and dragging,
   playing or not, the HEAR latch, the keyboard column, lit keys and
   notes.
4. **Multi-clip editing:** tabs, ghosts, song-time axis.
5. Later: pinch zoom through a native gesture hook, cross-clip tools.

The accessibility tree (docs/32) leans on phase 1: one command table
and one gesture layer give every element a known set of actions.
