# 44 — MIDI input, learn and the MPK mini map

A USB or Bluetooth MIDI keyboard plays the selected track and records into
clips. Knobs and pads can be learned onto controls and transport actions.

Source: `src/native_midi.c` (CoreMIDI), `src/midi_in.zig` (messages and live
state), `src/midi_map.zig` (bindings, learn, the factory map),
`applyMidi` in `src/main.zig`, the LEARN tile in `src/ui/transport_bar.zig`.

## Input

Slab opens every MIDI source at start and follows devices as they come and
go (the status line says `MIDI in: <device>`). CoreMIDI's callback frames
the bytes and queues them in a lock-free ring; the UI thread drains it once
a frame, the way it reads the computer keyboard. Nothing on the audio
thread is involved, and nothing allocates.

Played notes join what KEYS holds (docs/40) and go to the same track: the
clip open in the piano roll, else the selected track. They keep their own
velocity. Notes work with KEYS off. The sustain pedal (CC 64) holds
released notes on its channel; all-notes-off (CC 123) and all-sound-off
(CC 120) release its channel's notes. Pitch bend and the other
controllers are tracked and available to mappings; no machine reads bend
yet.

## Sources

A track can listen to one MIDI source: right-click its R, then
**MIDI in** and pick a connected device by name. Notes from that source,
on any channel, play the track whether or not it is selected, and every
track set to the source plays them. Sources no track claims go to the
selected track as above, so the default, **When selected**, changes
nothing. The setting is saved with the project by the device's name
(docs/19 `midi_in`), and the R button's tooltip names it.

A source that isn't connected keeps its tracks set to it: the menu lists
it as not connected, and they play again when it's plugged back in.
When a source goes away, the notes it held let go; other sources' notes
play on.

This lets a program that publishes one source per part play several
tracks at once: `undertone -midi-live -midi-split` publishes
`undertone drone`, `undertone lead`, `undertone drums` and so on, one
track each.

Stopped, several tracks holding notes ring out through the whole graph
(the engine's audition path, as when a track feeds a bus).

Timing is frame-quantized: a note lands in the block after the frame that
saw it.

## Recording

REC records what a connected device plays, with or without KEYS on, as it
does for KEYS (docs/40 §Recording): one pass, notes closing into the clip
under the playhead or a new one, one undo step per pass.

A track set to a source records that source into its own clip in the
same pass: the note clip under the playhead on that track, else a new
one. The selection stays where it was, and the pass is still one undo
step.

## Mappings

A binding ties a source (a CC or a note, on a channel or any) to a
destination:

- **ACTION**: PLAY/STOP, STOP, REC, LOOP, PREV TRACK, NEXT TRACK, PAGE -,
  PAGE +. A note-on fires it; a button that sends a CC fires crossing
  halfway. A note bound to an action never plays.
- **KNOB 1–8**: control `page × 8 + n` of the selected track's
  instrument, in the machine's control order. PG on the transport bar is
  the page; the PAGE actions step it, and changing track resets it.
- **CONTROL**: one control a mouse touch picked in LEARN (a track's
  volume or pan, or any machine control). It points at its track by
  position, so it lasts for the session and is not saved.

Actions and knob slots save to `~/Library/Application Support/Slab/midi-map.json`
(beside settings.json). Delete the file for the factory map.

### The factory map (Akai MPK mini 3)

| control | sends | does |
|---|---|---|
| keys | notes, channel 1 | play |
| K1–K8 | CC 70–77 | KNOB 1–8 |
| pad bank A | notes 36–43, channel 10 | play (drums) |
| pad bank B | notes 44–51, channel 10 | PLAY/STOP, STOP, REC, LOOP, PREV TRACK, NEXT TRACK, PAGE -, PAGE + |
| joystick | pitch bend; CC 1 | tracked |

Bank A and the keys, knobs and joystick were read from the device. The
note numbers of bank B are the layout's usual ones, not yet seen on the
unit; rebind with LEARN if they differ.

## LEARN

**LEARN** arms the next controller; **BIND** says what it binds.

- `CONTROL`: touch the control with the mouse first, then LEARN and move a
  knob or fader. A pad can't drive a control.
- an action: LEARN, then hit the pad (or press a button that sends a CC).
- a knob slot: LEARN, then move the knob that should become it.

A source has one binding, so a rebind replaces the old; a knob slot or
control has one source. LEARN consumes the message (a pad learned doesn't
play) and disarms after one binding. The pedal can't be learned.

## Finding out what a device sends

`SLAB_MIDI_LOG=1 zig build run` prints every message (source, channel,
kind, data bytes) to the log.

## Known limits

- Messages are timed to the UI frame; sample-accurate placement would need
  CoreMIDI timestamps carried to the engine.
- CONTROL bindings are not saved (projects don't carry MIDI mappings).
- One map for all devices.
- Knobs move a control's hand-set value; they don't record automation yet.
