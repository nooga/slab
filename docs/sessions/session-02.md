# Session 02 — 2026-04-24

Second coding session. The prototype moved from "Zig DAW shell with a
reference machine" to a small but real fy-hosted workstation: fy
machines can be assigned per track, arrangement and piano-roll
interactions are much closer to a DAW, and basic loop playback exists.

## What changed

### fy machine hosting

- Added `src/fy_host.zig`, a Slab-owned wrapper around fy. It registers
  Slab builtins (`slab:sr`, `slab:block-size`, note-event accessors,
  audio buffer pointers, panel rect/mouse, and basic widget calls).
- Added `src/machines/fy_machine.zig`, a `Machine` vtable adapter that
  calls fy audio/UI callbacks.
- Added `src/machine_registry.zig`, which loads catalog machine sources
  and can now instantiate fresh per-track fy runtimes.
- Fixed a major shared-state bug: assigning `mono1` to two tracks used
  to point both tracks at the same fy runtime, so knobs/voice state were
  shared and simultaneous playback sounded wrong. Track assignment now
  calls `Registry.instantiate()` and each assigned machine gets its own
  `FyHost`.
- Added optional `Machine.deinit` and `Track.replaceMachine()` so owned
  fy instances are released when tracks are replaced or destroyed.

### fy machines

- Added `machines/lib/machine.fy` helper vocabulary.
- Added simple fy machine sources under `machines/`:
  - `sine_v1`
  - `square_v1`
  - `mono1`
- `mono1` is a monophonic subtractive synth with saw oscillators, ADSR,
  one-pole low-pass, and a six-knob fy-authored panel.

### UI scaling and visual polish

- Replaced hard-coded UI constants with runtime metrics in
  `src/ui/theme.zig`: UI scale, font scale, scaled row/header/lane
  sizes, and fixed 1px bevel/splitter behavior.
- Added Cmd/Ctrl `+`, Cmd/Ctrl `-`, Cmd/Ctrl `0` for UI zoom.
- Reworked the status bar into readable labeled cells.
- Added stronger grid colors for beats/bars/subdivisions.
- Piano-roll default view now fits the selected clip horizontally; that
  fit is the minimum zoom-out. If notes exist, the vertical view fits
  the pitch range with padding.

### Tooltips and cursors

- Added deferred immediate-mode tooltips in `widgets.zig`.
- Added tooltip coverage for transport, pane controls, track controls,
  and loop/track actions.
- Centralized cursor requests in `widgets` to avoid flicker from
  multiple panes fighting over `SetMouseCursor`.
- Added move/resize cursor affordances for clips and notes.

### Arrangement editing

- Added clip-owned transient `selected` state.
- Arrangement supports:
  - single select
  - Shift-click multi-select
  - box-select clips
  - Delete/Backspace selected clips
  - drag selected clips together in time
  - drag/drop selected clips to another track
  - add tracks from a `+` button in the track header
- Selecting a clip opens the piano roll.

### Piano roll editing

- Fixed note draw behavior: clicking creates a stable default-length
  note in the current grid cell; dragging changes length only after a
  small threshold.
- Added visible sixteenth grid lines when zoomed in.
- Delete/Backspace removes selected notes first; if no selected notes
  are consumed, arrangement clip deletion can run.

### Looping

- Added loop state to `Transport`: enabled flag and beat-range bounds.
- Added transport loop toggle.
- Added arrangement actions:
  - loop entire arrangement
  - loop selected clips
  - clear loop
- Draws loop range over the ruler and lanes.
- Loop start/end handles can be dragged in the ruler.

## Important lessons

1. **Catalog machines are not instances.** The browser/registry should
   describe machines and provide factory data. Tracks need fresh runtime
   instances. fy's `alloc`-backed cells make this non-negotiable.

2. **Immediate-mode needs deferred global affordances.** Tooltips and
   cursors should be requested during widget drawing/input and applied
   once at the end of the frame. Direct calls from many panes flicker.

3. **Layout changes must recompute before drawing.** Opening the piano
   roll after selecting a clip crashed once because drawing used stale
   zero-sized rects. Any state change that changes panes must recompute
   rects before drawing dependent panes.

4. **Fit-to-content zoom can exceed arbitrary max zoom.** Short clips can
   require `min_px_per_beat > old_max_px_per_beat`. Clamp helpers must
   allow the fit minimum to win.

5. **Loop UX is transport-level.** Arrangement provides range editing,
   but the transport owns loop state and playback wrapping.

## Known problems after this session

- **Looping is block-boundary only.** `Transport.advance()` wraps the
  sample counter after a callback chunk. Correct behavior should split
  rendering at loop end so event gathering and machine rendering do not
  straddle the wrap.
- **Hot-patch does not update live instances.** The TCP server attaches
  to a catalog host. Live per-track fy instances need a recompile/update
  strategy.
- **fy runtime pointer is global/thread-local.** Current render is
  serial, but parallel track render would need cleaner per-instance
  callback dispatch.
- **Save/load is first-pass document state only.** `slab-project.slab`
  stores tracks, clip/note data, machine assignment, mixer flags, BPM,
  and loop bounds. fy panel parameter cells are not serialized yet.
- **Undo/redo is snapshot-based.** It reuses the text project format and
  captures coarse UI mutations. A later pane focus/edit transaction
  model should make history less noisy.
- **No focused editor model.** Delete routing is pragmatic: piano roll
  consumes selected-note deletion first, then arrangement clips delete.
  A real focus model should replace this.
- **No sample-accurate anti-click on seek/loop.**
- **No voice pool service.** fy machines are still responsible for their
  own simple voice behavior.

## Next work queue

1. **Sample-tight loop playback.** Split render chunks at loop end,
   gather events against the pre-wrap segment, wrap transport, then
   render the post-wrap segment.
2. **Focused editor/input routing.** Make key commands go to the pane
   with focus instead of relying on ad hoc priority.
3. **Hot-patch propagation to live fy instances.** Decide whether to
   recompile every instance, share code with per-instance data, or add a
   proper machine-definition/instance split.
4. **Param model.** Move fy panel knobs toward host-visible,
   serializable params with smoothing rather than anonymous fy cells.
5. **Bitmap font pass.** Replace SFNS with the intended crisp bitmap UI
   font.
6. **Document the current fy machine API.** The `slab:*` and `widget:*`
   builtins now exist in code but need a reference doc.
