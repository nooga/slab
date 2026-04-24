# 06 — UI and widgets

The frame is brutalist: 1px bevels, grey, chunky, Win95/CDE/NeXT
neighborhood. The aesthetic is not nostalgia — it's *license*.
Machines inside the frame get to look however they want because the
frame absorbs everything.

## Visual language

- **Base palette:** five greys plus three accents.
  - `bg:        #2a2a2a` (panel background)
  - `bg-deep:   #1e1e1e` (frame recess)
  - `face:      #3d3d3d` (widget face)
  - `hi:        #5a5a5a` (bevel highlight)
  - `sh:        #111111` (bevel shadow)
  - `text:      #d0d0d0`
  - `accent:    #ff8800` (primary highlight — selection, meter)
  - `warn:      #ff3040`
  - `cool:      #40a0ff` (secondary — modulation, cv)

- **Bevels:** exactly 1 pixel. A widget face has a 1px highlight on
  top/left, 1px shadow on bottom/right. Inset (pressed, recessed
  fields) inverts. No gradients, no anti-aliasing, no drop shadows.

- **Typography:** one bitmap font for UI, one monospace for source.
  The bitmap font is non-negotiable — vector fonts at 11px look mushy.
  Pick a clean 8–11px bitmap (Cozette, Tamzen, Terminus, or custom).

- **Icons:** 16×16 monochrome. Phosphor at 16px or custom icon font.

## Layout unit: the cell

Every widget snaps to a 4-pixel grid. Text is 11px tall. Standard
row height is 16 or 20. No free-floating dimensions; everything is
multiples of 4.

## Widget library (Zig, exposed to fy)

Immediate-mode. Each widget is a function returning an event outcome
(clicked, changed, etc.), rendering happens immediately.

### Primitives

```zig
pub fn beveledRect(rect: Rect, inset: bool) void;
pub fn inset(rect: Rect) Rect;          // returns rect with 1px bevel subtracted
pub fn fillRect(rect: Rect, color: Color) void;
pub fn line(a: Point, b: Point, color: Color) void;
pub fn text(pos: Point, s: []const u8, color: Color) void;
pub fn icon(pos: Point, id: IconId, color: Color) void;
```

### Controls

```zig
pub fn button(rect: Rect, label: []const u8) ButtonResult;
pub fn toggle(rect: Rect, label: []const u8, state: *bool) bool; // returns changed
pub fn knob(rect: Rect, value: *f32, range: Range, label: ?[]const u8) bool;
pub fn slider(rect: Rect, value: *f32, range: Range, orient: Orient) bool;
pub fn dropdown(rect: Rect, options: []const []const u8, index: *i32) bool;
pub fn textField(rect: Rect, buf: []u8, cursor: *usize) TextFieldResult;
pub fn numberField(rect: Rect, value: *f64, fmt: NumberFormat) bool;
```

### Visualisers

```zig
pub fn meter(rect: Rect, value: f32, kind: MeterKind) void;
pub fn waveform(rect: Rect, samples: []const f32, style: WaveStyle) void;
pub fn spectrumBars(rect: Rect, bins: []const f32) void;
pub fn xyPad(rect: Rect, x: *f32, y: *f32, ranges: XYRanges) bool;
pub fn grid(rect: Rect, cells: *[]bool, cols: u32, rows: u32) bool; // step sequencer
pub fn envView(rect: Rect, points: []const f32) void;
```

### Layout helpers

```zig
pub fn row(parent: Rect, heights: []const i32) []Rect;
pub fn col(parent: Rect, widths: []const i32) []Rect;
pub fn grid_layout(parent: Rect, cols: u32, rows: u32) []Rect;
pub fn tabs(parent: Rect, labels: []const []const u8, active: *u32) Rect;  // returns content rect
```

All of the above are bound to fy words with matching stack effects.
Panels are authored in fy by calling these words.

## The escape hatch: push pixels

Some machines need to draw things the widget library doesn't cover
— a custom spectrum analyzer, a waveshaper curve editor, a synth
visualiser. They ask the host for a client rect with a raw pixel
buffer:

```forth
: visualiser-panel ( ctx rect -- )
  ctx rect custom-pixels [ | pixels w h stride |
    ( pixels: [*]u32 RGBA. machine writes freely. )
    ...
  ] do
;
```

The backing texture is host-managed (a raylib `RenderTexture`),
cleared before the callback, uploaded after. The machine never
allocates or frees it.

## Panel structure

A machine's `panel.fy` defines two words:

```forth
: uno-draw ( ctx rect -- )
  rect beveled-rect-inset
  rect inset rect!
  rect 3 col { 120 120 -1 } { | knobs oscs env |
    knobs "CUTOFF"  ctx params:cutoff@   rect knob
    knobs "RESO"    ctx params:resonance@ rect knob
    ( ... )
  } do
;

: uno-events ( ctx event -- )
  ( optional — most widgets handle their own events )
;
```

Panel authors never call into the rendering API directly (raylib).
Everything goes through the widget library.

## The pop-the-face gesture

Each panel is rendered into a "panel frame" owned by the host. The
frame has a title bar (machine name, preset dropdown, menu), a body
(the machine's panel), and — crucially — an edit mode.

**Keyboard shortcut:** `⌥ E` while hovering a panel, or click the
panel's menu icon.

**What happens:**
1. The frame splits vertically: panel on top, source code on bottom.
2. Source code shows `panel.fy` and `dsp.fy` in tabs.
3. Edits save to disk; file watcher triggers hot-patch; the top
   half redraws / the audio picks up changes on the next block.
4. `⌥ E` again to collapse back.

Alternative flow: `⌘-click` a specific widget within a panel → the
source opens scrolled to the word that drew that widget. This
requires the widget library to tag rendered elements with
source locations (fy's compiler can record this; extension
possible).

## The Slab layout

```
┌────────────────────────────────────────────────────────────────┐
│ TRANSPORT BAR       [⏮][▶][⏺][●] 120.00bpm  4/4  [bar.beat] │
├─────────────────────────────────────────┬──────────────────────┤
│ TRACK LIST      │                       │ PROPS PANEL          │
│ ▸ Drums          │                       │ (current selection)  │
│ ▸ Bass            │    CLIP VIEW         │                      │
│ ▸ Lead            │    (arrangement)     │                      │
│ ▸ Pad             │                       │                      │
│                   │                       │                      │
│ MACHINE BROWSER   │                       │                      │
│ ▸ instrument/    │                       │                      │
│ ▸ effect/        ├──────────────────────┴──────────────────────┤
│ ▸ note/          │                 MACHINE PANELS               │
│                   │  ┌──────────┐ ┌──────────┐ ┌──────────┐    │
│                   │  │ tal-u-no │ │ comp     │ │ delay    │    │
│                   │  │  [knobs] │ │  [knobs] │ │  [knobs] │    │
│                   │  └──────────┘ └──────────┘ └──────────┘    │
│                   │  (inserts for the selected track)          │
└──────────────────┴────────────────────────────────────────────┘
```

Top bar: transport + tempo + master meter.
Left: track list + machine browser (collapsible).
Center: clip arrangement (timeline with clips), same semantics as
Live — a track is a row, clips are blocks, playback follows
transport. Piano roll opens below by double-clicking a clip; takes
the bottom half when active.
Right: properties for the current selection (clip, widget, track
mixer strip).
Bottom strip: the insert chain for the currently-selected track,
each machine rendered as its compact panel. Click a panel to open
its detail view (larger, full panel).

## Mixer view

`Tab` key toggles between arrangement view and mixer view.

Mixer is classical: channel strips per track + return + master. Each
strip has:
- Volume slider (0–+6dB), pan knob
- Solo/mute/record-arm buttons
- Insert chain (same panels as in the arrangement view bottom strip)
- Send knobs (pre/post-fade)
- Meter
- Name

All Zig widgets. No customization per-machine at the mixer-strip
level.

## Piano roll view

Opens below the arrangement when a clip is double-clicked. Standard
features:
- Note drawing, dragging, resizing
- Velocity lane
- Automation lanes (one per automated param)
- Quantize (configurable)
- Grid (triplet/dotted toggles)
- MPE editing: per-note pressure, slide, glide curves
- Pen tool / select tool modes
- Play from cursor, loop region

All Zig. Machines don't author piano roll views. Machines *consume*
notes (via `ctx.note_in`) and produce them (`ctx.note_out`) —
piano roll is just one of several note sources.

## Fonts

Two fonts loaded at startup:
- **UI font:** bitmap, ~11px, for everything
- **Mono font:** monospace, ~12px, for the source-edit split and
  numeric displays

Shipped in the repo as `.bdf`-converted PNG atlases. Non-negotiable:
bitmaps only. Vector fonts at these sizes do not look right for this
design language.

## Rendering under the hood

raylib for windowing and primitive drawing (reusing what fy already
binds). No custom OpenGL — raylib's immediate-mode APIs are enough.
Custom bitmap font renderer (raylib's default does vectors). All
text goes through the bitmap renderer.

The render loop is 60fps, immediate-mode: every frame the host calls
panel draw words, which call widget draw words, which call raylib.
No retained widget tree. UI state lives in the host: widget rects,
drag state, focus, text-field cursors. Widgets are functions, not
objects.

Exception: text input. Text editing is ugly as a pure IM widget
(cursor tracking, selection, clipboard). The `textField` widget
keeps per-id state in a host-owned hash map (id = hash of source
location + data pointer). Standard trick in IM GUIs.

## What the brutalist choice buys

- Every panel renders in well under 1ms. Hundreds of machines on
  screen = still 60fps.
- Simple rendering → simple debugging.
- 1px bevel is recognizable at a glance. You know where a widget
  ends and the frame begins. No mystery.
- Machine authors can break the aesthetic — their panels can be
  hot pink and curved and 60s-psychedelic — and it still *works*,
  because the frame is explicitly not trying to be pretty. The
  contrast amplifies each panel's character.
