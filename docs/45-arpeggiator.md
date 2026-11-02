# 45 — The note slot and the arpeggiator

Every instrument track has an optional **note slot** that runs ahead of
the instrument in the machine bay. Notes from clips, KEYS and MIDI
(docs/40, docs/44) pass through it on their way to the instrument. The
first occupant is the arpeggiator.

Source: `src/arp.zig` (the algorithm and its state), `src/ui/arp_panel.zig`
(the card), `applyNoteFx` in `src/engine.zig`, `appendNoteFx` and
`applyNoteFx` in `src/document.zig`, the picker entry in
`src/ui/machine_bay.zig`.

## Adding it

Select a track and press "+" in the machine bay, then choose
**ARPEGGIATOR (notes)**. The card appears before the instrument; its ×
removes it, and ON/BYP bypasses it (notes pass through unchanged).
Buses and the master have no note slot. The slot is saved in the project
as `note_fx`; projects without one load exactly as before.

## What it does

Held notes are replayed one at a time on a grid locked to the song's
beat, using the track's own tempo, so it stays in step with the
arrangement. With the transport stopped the grid keeps running from the
last position, so live playing arpeggiates too.

| Control | Meaning |
|---|---|
| MODE | up, down, up-down, down-up, converge, diverge, random, played, chord |
| RATE | 1/4, 1/8., 1/8, 1/8T, 1/16., 1/16 (default), 1/16T, 1/32 |
| OCT | 1 to 4 octaves of the held notes |
| VELOCITY | AS PLAYED, or the fixed VEL knob |
| LATCH | keep the notes after the keys are up; the next keys replace them |
| GATE | note length as a fraction of the step |
| SWING | delays odd steps by up to 75% of a step |
| ACCENT | how much louder accent steps are |
| HUMAN | random timing and velocity wobble |
| STEPS and the 16 buttons | a pattern of 1 to 16 steps; each button cycles rest, note, accent, tie |

A tie holds the previous note through the step instead of retriggering it.

## Implementation notes

The slot is a fixed per-track `Arp` object, not a chain entry. The UI
writes its parameters as atomics and the audio thread reads them, so adding,
removing and editing need no hand-off. `process` merges the incoming
events, step boundaries and gate-off times in sample order into a fixed
output buffer; nothing allocates. Its note ids start at 2^24 so they never
collide with clip or keyboard ids. Removing the slot (or bypassing it)
ends any sounding arp note.

## Limits

- The arp's controls are not machine controls, so MIDI knobs and
  automation cannot reach them yet.
- No presets; the card has no browser entry.
- One arpeggiator per track; other note machines (chord, scale, humanize)
  and the fy side of the slot are future work.
