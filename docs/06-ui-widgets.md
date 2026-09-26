# 06 — UI system

The frame looks like 2000s pro audio hardware rendered by a computer
that cares about pixels: packed, nothing wasted, never crowded. Chamfered
faceplates, 1px bevels, dot-matrix readouts, one warm accent. It should
feel like an expensive console and behave like a 2026 app.

This doc is the whole UI contract: pixel grid, type, materials, displays,
the control catalogue, sizing, interaction, and the `Ui` core that makes
it cheap to write and cheap to draw. docs/12 covers per-view pointer and
keyboard behaviour; docs/15 covers how machine panels are declared.

## North star

**Look:** 2000s instruments and consoles. Reason 2–4, Pro-53, early Logic,
a Mackie strip, a Juno faceplate, Winamp's display. Hardware is flat
bevelled metal with a naive, sharp skeuomorphism: material you feel more
than see. The logo (flat chamfered slab, brushed finish) sets the tone.

**Behaviour:** none of the era's pain.

- No blocking modal dialogs. Pickers, prompts, file ops are inline,
  non-modal, or context menus.
- Every value is direct-manipulation: drag, fine-drag, type, reset.
- Hover, focus, armed and active state are always visible.
- Keyboard-driven, undoable, no submodes you can't escape.

When a decision is ambiguous, pick the option that serves both: looks
like hardware, acts like a modern instrument. Nothing should surprise a
user who has used any DAW in the last ten years.

## Pixel grid

The UI is laid out in **logical pixels, as `i32`**. There are no
fractional rects anywhere in UI code.

- **Grid:** positions and sizes are multiples of 4. Standard row is 16;
  tall row is 20. A 1px line or bevel is the only thing off the 4-grid.
- **Scale** maps logical to device pixels, chosen once per frame:
  - **Integer (1×, 2×, 3×).** The default and the reference look. Every
    logical pixel becomes an s×s block: bevels, glyphs, sprites, all
    nearest-neighbour exact. Retina runs at 2×.
  - **Fractional (e.g. 1.5×).** Supported for accessibility and odd
    displays. Rect *edges* are rounded to device pixels (so adjacent
    rects never gap or overlap), bevels are `max(1, round(s))` device px,
    text uses the vector face (see Type), and control sprites are
    regenerated at the device size (see Controls: they are procedural,
    so this is free).
- The window uses `FLAG_WINDOW_HIGHDPI`; the renderer owns the logical →
  device transform. UI code never sees device pixels.

Why this matters: the current code scales by 1.15 with `f32` rects and
rounds in ~170 places, so 1px edges land on half pixels. Integer logical
coordinates plus one transform make pixel-perfect the default instead of
a discipline.

## Type

Two modes, one layout.

- **Pixel mode (integer scales): Tamzen.** Loaded from BDF files in
  `vendor/tamzen/` by a small parser at startup (BDF is plain text; no
  build step). Strikes:
  - **Body:** Tamzen 6×12 (12px line, sits in a 16px row with 2px lead).
  - **Legend:** Tamzen 5×9, uppercase only (small-caps effect). Used for
    faceplate labels, strip titles, units.
  - **Title:** Tamzen 8×16, rare (pane titles at most).
  At 2× and 3× the 1× strike is pixel-multiplied, not swapped for a
  bigger strike, so the UI looks identical at every integer scale.
- **Smooth mode (fractional scales): a vector face** (SF Pro / SF Mono from
  the system, Helvetica/Menlo fallback) rasterized **at the exact device
  pixel size** with point sampling. Never rasterize at 2× and filter down:
  that is what makes the current text blurry.
- **Mono / numeric:** Tamzen 6×12 in pixel mode (it is monospaced); SF
  Mono in smooth mode. Numeric readouts use tabular digits so values
  don't jitter while dragging.
- **Baselines:** text is placed by the font's ascent, never by
  eyeballing. In a row, every run shares one baseline: a value and its
  unit ("124.0 BPM") sit on the same line even when the unit is the
  legend face.
- **Coverage:** ASCII + Latin-1 + the punctuation and ⌘⇧⌥⌃ set already
  used for menus. Missing glyphs fall back to the vector face.

## Materials

The frame is lit by one light source, **top-left**. Bevels, gradients and
engraving all agree with it.

### Surfaces

| Layer | What | Treatment |
|---|---|---|
| **Chassis** | window background, gaps between panes | darkest grey, noise |
| **Faceplate** | pane headers, machine strips, transport, track headers | raised 1px bevel, noise, faint vertical gradient, optional chamfer |
| **Well** | displays, text fields, meter slots, slider slots | sunken 1px bevel, near-black, **flat** |
| **Working surface** | arrangement grid, piano roll, waveforms | flat, dark, no material |
| **Control** | knobs, caps, levers | drawn hardware (see Controls) |

Rule: **material belongs to hardware, data sits on flat dark glass.**
Anything that shows the user's work (clips, notes, curves, meters) is
flat. That contrast is what reads as "expensive console".

### Bevels

Exactly 1 logical pixel. Raised: highlight top/left, shadow bottom/right.
Sunken inverts. A faceplate edge against the chassis gets a 1px dark
outline outside the bevel. No drop shadows, no rounded corners.

### Chamfer

The one signature shape, taken from the logo: a 45° corner cut of 2 or 4
logical px. Used on faceplate corners (machine panels, the transport
block, pane headers' outer corners). Never on controls, wells or data.
A chamfer is drawn as stepped pixels, so it stays pixel-exact.

### Noise

A single precomputed tile (128×128, seeded, generated at startup)
multiplied into chassis and faceplates.

- Drawn 1:1 and anchored to the screen pixel grid: never scaled, never
  filtered, doesn't scroll with content.
- Amplitude ±2–3 levels (of 255). If you can see it, it's too strong.
- It doubles as dither for gradients, so they never band.

### Gradients

Vertical only, faceplates only, at most 6 levels of brightness over the
full height of the surface, lighter at the top. Implemented as per-vertex
colour on the faceplate quad; no textures.

### Engraving

Faceplate legends get a 1px dark offset (down) under light text, as if
printed into the plate. Legends only: never data, menus or displays.

### Strengths are tokens

Noise amplitude, gradient delta, engrave alpha and chamfer size are named
theme tokens. The gallery has a "materials off" switch. Target: nobody
notices materials are on; everybody notices when they're off.

## Palette

Tokens, not literals. Starting values (from the current theme):

| Token | Value | Use |
|---|---|---|
| `chassis` | `#141416` | window background |
| `face` | `#404044` | faceplate fill |
| `face_hi` | `#646468` | bevel highlight |
| `face_lo` | `#28282a` | bevel shadow |
| `edge` | `#0c0c0e` | outline against chassis |
| `pane` | `#202022` | working-surface background |
| `pane_alt` | `#28282a` | alternating rows, lanes |
| `well` | `#0e0f10` | display / field background |
| `text` | `#e0e0db` | primary text |
| `text_dim` | `#a0a09a` | secondary text, legends |
| `text_mute` | `#747470` | disabled, hints |
| `accent` | `#d7af50` | amber: selection, playhead, focus, "active" |
| `play` | `#50c864` | transport play |
| `rec` | `#d7463c` | record, arm, clip warnings |
| `mod` | `#40a0ff` | modulation, CV |
| `phosphor` | `#3fe0cc` | display segments (VFD teal) |

- **Amber means "active" and nothing else.** Selection, playhead, focus
  ring, lit latch LEDs. Track colours never use amber/yellow hues;
  project colours outside the track set are snapped to the nearest one.
- **Track colours** are the fixed muted set in `theme.track_colors`.
- Machines may override `phosphor` and LED colours for their own panel.
  That is their personality inside the frame's rules.

## Displays

Readouts simulate OLED/VFD glass: Winamp from another dimension. Displays
are the only things that emit light.

- **Well:** sunken bevel into `well` (near-black, very slightly tinted).
- **Face:** a 5×7 dot-matrix font, separate from Tamzen, in the atlas. At
  2× and up each lit pixel is a dot with a 1-device-px gap: the matrix
  texture comes from the grid, not from a filter.
- **Ghost cells:** unlit segments show at 4–6% of `phosphor`. Drawn as an
  all-on glyph under the text.
- **Glow:** each display glyph has a pre-dilated halo variant in the atlas,
  drawn under it at low alpha. Edges stay sharp; nothing blurs at runtime.
- **Afterglow:** scopes, meters and envelope views decay over a few frames
  instead of clearing. One render texture per display, faded each frame;
  it only ticks while something moves. Meter peak-hold is the same
  mechanism.
- **No** CRT scanlines, curvature or flicker: wrong era.

Where displays go: transport (position, BPM, meter), machine title strips,
panel displays (envelope, LFO, scope), meters. Not in menus, the
arrangement or the piano roll: those are working surfaces.

**Title-strip display:** each machine's title strip carries a small
display. It shows the preset name; while a control is touched it shows
`PARAM value unit` ("CUTOFF 1.25 kHz"), then returns to the preset after
~1s. This is the precise-value channel, so per-knob readouts can be
dropped when space is tight.

## Control catalogue

One family per call, variants as options. Every control:

- comes in **fixed sizes** (S / M / L; a panel uses one tier, see Sizing),
- shows **idle, hot, active, focused, disabled** and, where it has a
  modulatable value, **modulated** (a thin `mod`-coloured arc/bar showing
  where modulation currently pushes it),
- follows the **interaction contract** below,
- is hardware: lit top-left, parked on a faceplate. Only LEDs and
  displays glow.

### Knobs

Sizes **L 32 / M 24 / S 16** (square cell, legend above, optional readout
below).

| Variant | Behaviour |
|---|---|
| `plain` | value arc from min |
| `bipolar` | arc from centre, detent at 0 |
| `stepped` | detents; printed legends around the knob (rotary selector) |
| `encoder` | endless, no stops; LED ring shows value |

### Sliders and faders

A fixed-size cap sprite on a sunken slot with printed ticks. The **travel
length** varies (multiples of 4); the cap doesn't.

| Variant | Use |
|---|---|
| `fader` | long-throw channel fader (mixer strips) |
| `slider` | panel slider (Juno/SH-101 envelope banks) |
| `mini` | dense rows |

Vertical or horizontal; any of them can be `bipolar` (centre detent).

### Switches and buttons

| Variant | Behaviour |
|---|---|
| `toggle` | bat-handle lever, 2 or 3 positions |
| `slide` | slide switch, 2 or 3 positions, very compact |
| `latch` | square cap, stays down; LED above or lit cap |
| `momentary` | same cap, no latch |
| `segmented` | row of joined caps, exactly one down (range, mode) |

### Selectors

| Variant | Behaviour |
|---|---|
| `rotary` | the `stepped` knob |
| `list` | vertical option column (octave, waveform); click or drag through |
| `display` | value in a small display with ‹ ›; drag or click to step, click the display to open the list |
| `dropdown` | opens a menu (menus are their own system) |

### LEDs

Shapes: **round** 3 / 5 / 7, **square** 4 / 6, **bar** (rect, any length on
the grid), **triangle** (direction). Mono or bicolour. States: off (ghost),
dim, on; **blink is driven by the host clock** so every blinking LED is in
phase. Composites:

- **ladder** — segmented meter (with peak-hold via afterglow),
- **ring** — around an encoder,
- **step row** — sequencer steps.

### Later

Pads, jacks/patch points, XY pads. Not in the first catalogue.

### How controls are made

Every control image is **drawn procedurally in Zig at startup** into the
atlas, per size and per scale: knob filmstrips (~128 angle frames),
fader caps, lever positions, cap up/down, LED off/dim/on with halos.
No image assets; changing the look is a code change, and fractional
scales get exact sprites because they're simply generated at that size.

Machine manifests (docs/15) use the same catalogue: control kinds are
`knob | slider | switch | button | selector | led | display` plus variant
and size. Authors never draw controls.

## Interaction contract

The same everywhere, so nothing surprises.

- **Drag** vertically to set (horizontal for horizontal sliders). Drag is
  relative (per-frame delta), so switching modifiers mid-drag never jumps.
- **Shift** while dragging = fine (10×).
- **Double-click** = reset to default.
- **Type:** a focused control or a click on its readout accepts a typed
  value (with units: `1.2k`, `-6db`); Enter commits, Esc cancels.
- **Arrow keys** step a focused control; Shift+arrow is fine.
- **Wheel belongs to the viewport.** Controls take the wheel only with ⌘
  held. Panels never capture scroll.
- **Undo** covers every value change; one drag = one undo step.
- **Hover** shows the value in the title-strip display and a tooltip after
  the delay (docs/12 §Tooltips).
- **Focus ring:** 1px `accent` outline, keyboard focus only.
- The cursor changes on hover for every draggable thing (resize for
  splitters, vertical arrows for value drags).

## Sizing

Controls have fixed sizes; containers adapt, controls don't stretch.

- A panel (docs/15) is laid out for a **tier** (L/M/S). Its **natural
  size** at that tier is computed from its declaration: strips size to
  their controls, not to leftover space.
- The container picks the **largest tier at which every control fits**,
  and applies it to the whole panel. All knobs on a panel match.
- Below the smallest tier the panel **stops shrinking**: the container
  scrolls (the machine bay scrolls horizontally) or clips. A 2px knob is
  not a knob.
- The machine bay snaps its height to tier boundaries while the splitter
  is dragged, and packs several machines side by side when they fit.
- Empty panes collapse. An empty clip editor does not keep 160px of
  "no clip selected".

## The `Ui` core

Widgets are functions; state lives in one context. Nothing outside the
renderer calls raylib.

```zig
pub const Ui = struct {
    in: Input,            // snapshot: mouse, wheel, keys, mods, text, time
    scale: Scale,         // integer or fractional; logical → device
    hot: Id, active: Id, focus: Id,
    ids: IdStack,         // bounded scope stack
    dl: *DrawList,
    // overlays (menus, tooltips) queue into a second list drawn last
};

pub fn knob(ui: *Ui, key: anytype, v: *f32, o: KnobOpts) bool;   // changed
pub fn slider(ui: *Ui, key: anytype, v: *f32, o: SliderOpts) bool;
pub fn switch_(ui: *Ui, key: anytype, v: *u8, o: SwitchOpts) bool;
pub fn button(ui: *Ui, key: anytype, o: ButtonOpts) Click;
pub fn selector(ui: *Ui, key: anytype, v: *u8, o: SelectorOpts) bool;
pub fn led(ui: *Ui, r: Rect, s: LedState, o: LedOpts) void;
pub fn display(ui: *Ui, r: Rect, o: DisplayOpts) void;
pub fn field(ui: *Ui, key: anytype, buf: *TextBuf, o: FieldOpts) FieldResult;
```

- **Rects are `i32`**, logical. `Rect` has RectCut-style helpers
  (`cutTop(h)`, `cutLeft(w)`, `grid(cols, rows)`, `inset(n)`) for pane
  layout. Panels use the tiered natural-size layout from docs/15.
- **Ids are explicit.** `Id = hash(scope stack, key)` where `key` is a
  param id, a pointer, or an index. Scopes are pushed per pane, track,
  machine. Never derived from a rect: rect-hash ids break when layout
  moves mid-drag and collide on equal rects. Debug builds assert no
  duplicate id per frame.
- **Input is a snapshot** built once per frame. Widgets read `ui.in`, never
  raylib. The `active` id owns the pointer from press to release, even
  when the pointer leaves its rect.
- **Draw list** of a handful of primitives:
  `rect`, `rect_vgrad`, `bevel`, `chamfer_plate`, `glyphs`, `sprite`,
  `line` (axis-aligned), `polyline` (curves, waveforms), `clip_push` /
  `clip_pop`, `texture` (render textures: afterglow, the custom-pixel
  escape hatch). One renderer flushes it.
- **One atlas:** fonts, the display matrix face, halos, the noise tile and
  every control sprite share one texture. A frame is one texture bind and
  close to one draw call.
- **Redraw on demand.** The frame is rebuilt when there's input, when the
  transport plays, or when something calls `ui.animate()` (afterglow,
  blinking, tooltips pending). Otherwise the loop waits for events
  (raylib `EnableEventWaiting`). A laptop DAW shouldn't redraw an idle
  screen at 120 fps.
- **Budget:** the whole UI builds and draws in < 1 ms per frame at 1×
  with a full machine bay.

## Escape hatch: push pixels

A machine that needs its own visual (spectrum, waveshaper curve) asks the
host for a client rect with a raw pixel buffer (`[*]u32` RGBA, `w`, `h`,
`stride`). The host owns the backing render texture, clears it before
the callback and uploads it after; it enters the draw list as a `texture`
primitive. The machine never allocates or frees it. See docs/15 §Escape
hatch for the fy-side API.

## The gallery

`slab --gallery` opens one screen with every material, palette token,
type strike, display, and every control family × size × state, with a
materials-off switch and a scale selector. The look is tuned there first;
panes adopt it after.

## App layout (current)

```
┌──────────────────────────────────────────────────────────────┐
│ TOP BAR  project · transport · BPM · position · meter · snap │
├───────────────────────────────────────────────┬──────────────┤
│ ARRANGEMENT  (ruler, loop, clip lanes)        │ TRACK HEADERS│
│                                               │ name R M S   │
│                                               │ pan · vol    │
│                                               ├──────────────┤
│                                               │ MASTER       │
├───────────────────────────────────────────────┴──────────────┤
│ CLIP EDITOR  piano roll + velocity / audio clip  (collapsible)│
├──────────────────────────────────────────────────────────────┤
│ MACHINE BAY  instrument + inserts of the selected track       │
└──────────────────────────────────────────────────────────────┘
```

- The clip editor opens when a clip is selected and collapses when empty.
- The machine bay shows the selected track's chain; machines are added
  from its "+" menu. Each machine is a faceplate with a title strip
  (name, title display, preset, bypass) and its declared panel.
- Mixer view (Tab, planned): channel strips per track + master, built
  entirely from the catalogue (fader, bipolar knob for pan, latch buttons
  for S/M/R, ladder meter, sends).
- Piano roll and arrangement behaviour: docs/12.

## Pop the face

`⌥E` over a machine (or its title-strip menu) splits its frame: panel on
top, source below (`panel` and `dsp` words in tabs). Saving hot-patches;
the panel redraws and audio picks up the change next block (docs/09).
`⌘`-click a control to open the source at the word that declared it
(needs manifest source locations from fy).

## Migration from the current UI

1. **Core + gallery** alongside the existing UI: `ui/core.zig` (context,
   ids, input), `ui/draw.zig` (draw list, atlas, renderer, scale),
   `ui/font.zig` (BDF + vector path), `ui/sprites.zig` (procedural
   controls, noise, matrix font). Exit: gallery approved at 1× and 2×,
   under budget.
2. **Panes one per commit:** top bar → track headers → machine bay and
   panels (tiers, horizontal scroll) → arrangement → piano roll → menus and
   tooltips. Each commit deletes the old helpers it replaced; the app
   works after every commit.
3. **Delete** `theme.ui_scale`/`font_scale`, rect-hash ids and direct
   raylib calls outside `ui/draw.zig`. Collapse empty panes, pack the bay,
   enable redraw-on-demand, verify pixel alignment with zoomed captures
   at 1× and 2×.
