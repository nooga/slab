# 40 — Musical typing, octave echoes and the scale

The computer keyboard plays the selected track and records into clips.
The piano roll shows a pressed note in every octave and marks the key's
scale on the keys and the grid.

Source: `src/ui/musical_keys.zig` (layouts, chords, the recording take),
`src/ui/clip_editor.zig` (echoes, ghost, scale marks), `recordKeys` in
`src/main.zig`, the KEYS tile in `src/ui/transport_bar.zig`.

## KEYS

The transport bar's **KEYS** latch turns musical typing on. Beside it:
the layout (PIANO, GRID, CHORD), the octave of the lowest C (C4 = MIDI
60, the piano roll's naming), the velocity (drag; double-click 100) and,
in CHORD, the chord type.

Notes go to the track of the clip open in the piano roll, or else the
selected track (not a bus or the master), whether or not the clip
editor is open. They start at the KEYS velocity.

While KEYS is on, its keys belong to it: the panes' unmodified
shortcuts on those keys stand down (D, Q, H, S, Z, E, M, 0, `[` `]`, …).
⌘ combinations, Space, Tab, Enter, Esc, Backspace and the arrows keep
working. A text field, a menu, a dialog or the browser's search takes the
keyboard back, and so does holding ⌘.

| keys | PIANO | GRID | CHORD |
|---|---|---|---|
| notes | `A W S E D F T G Y H U J K O L P ; '` = C up to F | four rows, see below | see below |
| octave | `Z` `X`, or `-` `=` | `-` `=` | `-` `=` |
| velocity | `C` `V`, or `[` `]` | `[` `]` | `[` `]` |

Velocity steps through 1, 20, 40, 60, 80, 100, 127.

### GRID

The four letter and number rows are pads, bottom row (`Z`…`/`) lowest,
like a Push in fourths. Each row has ten keys.

- **Scale off:** chromatic, a semitone per key, a fourth (five
  semitones) per row up.
- **Scale on:** in key from the root, a scale step per key, three steps
  per row up. Every key is in the scale.

### CHORD

- **`Z` row:** diatonic chords on degrees 1–10 of the scale, an octave
  under the melody. In C major `Z` is C, `X` Dm, `C` Em, `V` F, `B` G …
- **`A` row:** the melody in key, from the root.
- **`Q` row:** the same melody an octave up.
- **`1`–`6`:** chord type: TRIAD, 7TH, SUS2, SUS4, 9TH, POWER. Chords are
  stacked in scale steps, so every chord stays in key.

Hold a chord with the left hand and play the melody over it. With the
scale off, CHORD uses the major scale on the picker's root.

## Recording

With KEYS on, **REC** starts the transport and records what you play.
If a track is armed, the audio recorder runs too.

- **Where notes go:** into the clip open in the piano roll when it's on
  the played track and the playhead is inside it (overdub). Otherwise a
  new "Take" clip starts at the bar where the first note fell, and the
  editor opens it.
- **Clip length:** the clip grows by whole bars of the meter to hold
  what's played.
- **While you play:** held notes draw growing in the piano roll, outlined
  in red. They're written when you let go.
- **Loops:** when the transport loop wraps, held notes close at the loop
  end and start again at the loop start, so a loop builds up pass after
  pass.
- **Undo:** each pass is one undo step.
- **Stopping:** REC again, or stopping the transport, ends the pass. Keys
  already down when a pass starts aren't recorded.

Notes keep the beat the frame saw them at (no input-latency
compensation). Quantize (Q) afterwards if you want them on the grid.

## Octave echoes and the ghost note

- **Octave echoes:** keys pressed on the keyboard column or the computer
  keyboard, and a note being drawn, light their own key and grid row. The
  same note in every other octave lights faintly on both, in the track's
  color.
- **Ghost note:** in DRAW mode, or with ⌘ held, the note a click would
  add shows under the pointer, snapped to the grid and the scale. Its
  octaves show as outlines. Drawing a note shows the same outlines.
- **Drum lanes:** a drum lane map has no octaves, so it shows neither.

## The scale

With a key and scale picked in the piano roll head:

- **Grid:** in-key rows are tinted faintly toward the track color, the
  root's rows a step more. Out-of-key rows drop slightly below the plain
  glass.
- **Keys:** in-key keys get a track-color stripe on their left edge,
  solid on the root. Out-of-key white keys go grey.
