# Session 01 — 2026-04-22 / 23

First real coding session. Project went from `src/main.zig` being a
stub + some design docs to a runnable Zig-only DAW prototype: you
can draw notes in a piano roll and hear the sine machine play them
back through arranged clips.

## What was built

Listed in rough dependency order, not order of writing.

### Audio & machine layer

- `src/audio.zig` — miniaudio wrapper. f32 stereo, 48 kHz, 64-frame
  target block. Device callback dispatches to a Zig render function.
  No allocation on the audio thread; render fn set via atomic
  pointer with release/acquire.
- `src/transport.zig` — audio-clock-authoritative. Atomic sample
  counter, play/stop/toggle, rewind, `seekToSample`, `seekToBeats`,
  `samplesToBeats`, `samplesPerBeat`. BPM stored as milli-BPM u32 for
  atomicity.
- `src/machine.zig` — ABI-shaped. `NoteEvent` and `MachineCtx` are
  `extern struct` with the field layout from
  [../04-block-contract.md](../04-block-contract.md). Service fields
  (voice_pool, block_arena, services, assets, persistent) exist in
  the struct but are null/zero stubs. `Machine` vtable adds `reset`
  fn beside `render` and `draw_panel`.
- `src/track.zig` — `Track` with heap-allocated `ArrayList(Clip)`.
  Volume/mute/solo/meter atomics.
- `src/clip.zig` — `Clip` owns `ArrayList(Note)`. `Note` has pitch
  (u8 MIDI), start/length beats, velocity, transient `selected: bool`
  for the piano-roll UI.
- `src/engine.zig` — gathers events from in-range clips per block,
  sorts by `sample_offset`, fills `ctx.note_in`, calls
  `machine.render`, sums tracks into interleaved stereo output.
  Detects play→stop transition and calls `machine.reset` on each.
- `src/machines/sine.zig` — monophonic reference machine. Gate +
  pitch + phase state. Processes events in sorted order with
  sub-block rendering for sample accuracy. `midiToHz` with fractional
  pitch. Panel exposes GAIN only + live pitch readout.

### UI framework

- `src/ui/theme.zig` — brutalist palette, compact OpenTTD-style
  sizes (TOP_BAR_H=22, STATUS_BAR_H=16, LANE_H=44, PANE_HEADER_H=16,
  SPLITTER_W=1, TRACK_HEADER_W=170). Font-size buckets
  FS_TINY/FS_BODY/FS_TITLE.
- `src/ui/fonts.zig` — SFNS body + large rasters at 24/36 px (~2×
  target size) with bilinear. SFNSMono for readouts. Phosphor-Bold
  icon font (glyphs limited to our enum). Loaded under
  `vendor/phosphor/` (MIT).
- `src/ui/icons.zig` — Phosphor codepoint enum + draw/measure.
- `src/ui/widgets.zig` — `Mouse` sample (2-axis wheel via
  `GetMouseWheelMoveV`, double-click detection, right-click,
  wheel x/y). Bevel primitives, panel frame, button, icon button,
  knob, horizontal fader, vertical meter, LED, display field (double
  bevel), pane header with left-tool slot + minimize + close. Single
  module-scope active-drag slot; widgets claim by passing a unique
  u64 key. `keyFromIds`, `tryStartDrag`, `isDraggingKey`,
  `cancelDrag`.
- `src/ui/layout.zig` — 5-pane tiling with 1 px splitters and ±3 px
  invisible hit-pads. Collapsible browser + machine bay; toggleable
  clip-editor middle pane. Splitter drag disabled for the pane that
  sits next to a collapsed neighbour.
- `src/ui/top_bar.zig` — OpenTTD-packed: every element its own
  bevel, no outer toolbar bevel. Play/stop + record icons,
  BPM display field with pulsing metronome LED (red on downbeat,
  green on 2/3/4), TAP tempo button (4-tap averaging ring),
  bar.beat.16th position field.
- `src/ui/browser.zig` — left stub pane with category list, icon +
  label rows. Collapses to a thin vertical strip with vertical
  "BROWSER" letters.
- `src/ui/arrangement.zig` — track lanes × time. Horizontal
  scroll/zoom (wheel + shift+wheel), vertical scroll, minimap
  overview strip with draggable viewport window + playhead tick,
  lazy vertical scrollbar on the right edge (fades on
  hover/activity), scissor-clipping for timeline + header columns,
  ruler scrub drag. Clip create (double-click) / select (click) /
  move (drag) / resize-right (edge drag).
- `src/ui/clip_editor.zig` — piano roll with full editing: select +
  draw modes (pencil button in pane header), single/shift/box
  select, move drag (horizontal = ¼-beat, vertical = semitone),
  resize drag, Delete/Backspace to remove, Alt+wheel vertical zoom,
  overview strip with draggable viewport, lazy vertical scrollbar,
  red clip-end line + dim overlay past clip end, semi-transparent
  yellow box-select rectangle. Grid spans MIDI 36..84.
- `src/ui/machine_bay.zig` — bottom pane, shows the selected
  track's `machine.draw_panel`. Collapsible.
- `src/ui/clip_editor.zig` (panel header includes pencil toggle as a
  left-tool slot on the standard pane header — not a separate
  toolbar row).

### Wiring

- `src/main.zig` — DebugAllocator, owns tracks, passes allocator
  through to arrangement (clip create) and clip_editor (note append).
  Separate selection state:
  - `selected_track: ?usize` — drives machine bay + lane highlight
  - `selected_clip: ?ClipRef` — drives the clip editor
  Auto-opens the clip editor when a clip becomes selected.
  Keys: SPACE play/stop, TAB clip-editor visibility, HOME rewind.

### Vendor

- `vendor/phosphor/Phosphor-Bold.ttf` + LICENSE. Shipped MIT.
- `vendor/miniaudio.c` + `miniaudio.h` (already present).

## Design decisions worth remembering

1. **Outside-in instead of inside-out.** Original plan was to wire
   fy's runtime first, author the sine in fy, do hot-patch. Reversed
   it: built the DAW frame + a Zig reference machine first, since
   visible progress unblocked UI-shape decisions faster. The fy
   boundary is locked in the ABI shape (`MachineCtx` /`NoteEvent`
   `extern struct` matching [../04-block-contract.md](../04-block-contract.md))
   — switching the sine from Zig to fy later is a single-file change
   that reads the same struct.

2. **Heap-allocated clips + notes, UI-thread-owned.** We took the
   shortcut of having the audio thread read `ArrayList.items`
   directly from tracks. This is a data race the moment the UI
   thread appends while playback runs. Good enough for solo-editing
   demos; the proper fix (SPSC snapshot ring per the transport doc)
   is intentionally deferred.

3. **`MachineCtx` layout comes from docs, not invented freshly.**
   Even though most fields are null/zero stubs (voice_pool,
   block_arena, services, …), the slots exist in the struct so fy
   machines reading via `struct:` later won't see a layout change.

4. **OpenTTD aesthetic.** Tight packed bevels, 1 px splitters,
   integer-pixel layout, no AA on shapes. Text is AA'd (bilinear
   downscale from ~2× raster). Bitmap pixel fonts per
   [../06-ui-widgets.md](../06-ui-widgets.md) deferred.

5. **Inline per-lane mixer, no separate mixer pane.** Track name +
   meters + vol fader + M/S buttons live in the right 170 px of each
   lane. Master strip is not implemented yet.

6. **fy dep is declared in build.zig.zon and imported as a Zig
   module (`addImport("fy", ...)`), but nothing references it yet.**
   Zig doesn't compile the dependency until it's imported, so the
   cost is zero. When fy integration arrives, no build change.

## Known sharp edges

- **Clip/note race.** Audio thread iterates `track.clips.items` and
  `clip.notes.items`; UI thread can realloc them at any time.
- **No mid-block splits.** Transport play→stop detected on a block
  boundary; same for future tempo changes.
- **Scrubbing clicks.** Seeking mid-playback jumps phase of active
  voices. No anti-click.
- **Sine is monophonic.** Overlapping note-ons steal; no envelope
  / release tail.
- **No undo/redo.**
- **No project save/load.** Every launch starts fresh (2 sine
  tracks, no clips).
- **No second machine.** The machine ABI hasn't been stressed
  against anything that isn't a trivial oscillator.
- **Font fidelity on non-retina.** Acceptable but not crisp — ~2×
  bilinear downscale has some residual soft edges.
- **Magic hex drag keys.** `RULER_KEY`, `OVERVIEW_KEY`, `SBV_KEY`,
  etc. Could collapse to `@intFromPtr(&tag_var)` over a couple of
  modules.

## Next session — practical steps

In rough priority order:

1. **Thread-safe clip/note handoff.** Before adding more editing
   features, fix the data race. Two reasonable shapes:
   - An SPSC snapshot ring: UI thread writes a frozen `ClipSnapshot`
     array per track; audio thread drains at the top of each block.
     Per [../07-transport.md](../07-transport.md).
   - Or: atomic-swap pointer to a shared immutable clip/note tree.
     UI edits build a new tree; audio reads the current one.
   First is simpler; second scales better to larger projects. Either
   one removes the "don't edit while playing" footgun.

2. **A second machine.** Real stress test for the ABI. Pick one:
   - `DetunedSaw` — still mono, but introduces `unison`/detune
     (multiple phases), a filter, and more panel surface. Tests the
     knob widget and reveals param-smoothing needs.
   - `Drum` — a simple sampler that loads a pitched sample. Tests
     the asset-slot stub and note velocity mapping.

3. **Voice pool service.** Sine-mono is frustrating. Per
   [../08-services.md](../08-services.md): host-owned voice pool,
   machine declares `voice-count` + `voice-state`, `voice-each`
   combinator dispatches notes. Can prototype without fy by having a
   Zig-side `voice_pool` struct the machine opts into.

4. **Project save/load + undo/redo.** Both become painful to add
   later if data structures grow. Undo via document snapshots
   (fuvid-style) is cheap; project save can be JSON-ish or
   little-endian-binary — whichever feels less cute.

5. **fy integration, for real.** This is the whole project's reason
   to exist. Shape:
   - Add `dsp:` compile mode to fy (heap-access blacklist, inlining
     defaults).
   - `Fy.lookup(word)` returns a function pointer matching
     `machine.RenderFn` signature.
   - Rewrite `sine.machineInterface` to return either the Zig render
     fn or (when fy is wired) the fy-loaded fn. Prove pitch-driven
     playback works through fy.
   - Hot-patch comes after that — file-watch or TCP listener.

6. **Bitmap font / OpenTTD text fidelity.** If non-retina legibility
   is still annoying, swap SFNS for a pixel font. Several MIT-ish
   options (Monogram, Cozette, Commit Mono bitmap, etc.). Replace
   `fonts.ui` with a fixed-size bitmap raster + point filter.

7. **Small polish that piles up otherwise:**
   - Scrollbar for the arrangement overview when total content >
     screen width.
   - Seek-click on the clip editor ruler (similar to arrangement).
   - Anti-click on scrub seeks.
   - Home in clip editor rewinds to the clip's start.
   - Cmd+Z / Cmd+Shift+Z placeholders so the keybindings exist.
   - Replace magic hex drag keys with `&tag`-derived ones.
   - Master track / strip.

## Open architectural questions for next session

- **Do we keep Zig machines as first-class** or is every machine fy
  eventually? Both layers of the roadmap seem to assume fy for
  machines. But the Zig sine is real code now, and a Zig machine is
  *nicer* to write (tooling, editor, debugger) than fy for some
  tasks. Worth deciding explicitly: is Zig-authored machines an
  officially supported path, or just a bootstrap thing that gets
  replaced by fy equivalents later?

- **Where do params live?** `machine.zig` declares
  `params_current: ?*anyopaque` per the doc, but right now sine just
  has `gain_bits: atomic u32`. When we add the voice pool and proper
  smoothing, this needs a home. The doc describes a smoothed params
  pointer updated per block — we should sketch the concrete struct
  for a real machine and see if the shape holds.

- **Tempo map vs fixed BPM.** The doc specifies a tempo map
  (piecewise linear). We have one atomic BPM number. How soon does
  that matter? Probably only when we add Ableton-style warp or tap
  tempo sync to recorded audio.

## What to read before next session

- Skim [../04-block-contract.md](../04-block-contract.md) and
  [../07-transport.md](../07-transport.md) once more — the fields we
  stubbed will want implementations, and the SPSC note-event ring is
  spec'd there.
- [../08-services.md](../08-services.md) for the voice pool and
  service-table shape, if we pursue that.
- [../03-memory-model.md](../03-memory-model.md) for the four-arena
  model; we haven't implemented any of it yet but it'll land with
  the voice pool.
