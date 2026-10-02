# 15 — Machine panels (declarative beveled layout)

How a machine's front panel is declared and drawn. The goal: any machine
gets the brutalist beveled look of `mono1` (module strips with 1px bevels,
auto headers, knobs with value readouts, vertical selectors) **without
hand-coding a draw routine**. The author declares strips and controls; a
generic engine lays them out and renders them.

This is the panel system for every fy machine. The old callback path, a
fy UI word drawing through `widget:*` builtins at explicit coordinates,
is gone: no machine used it any more, and it was removed with the legacy
widgets. Machine-drawn graphics come back as the fy display escape hatch
below, on the Ui draw list.

## Why declarative

There used to be two panel paths:

- **Callback machines** (`mono1`, removed): a fy UI word drew the panel by calling
  the beveled widget builtins (`widget:bevel-raised`, `widget:knob`,
  `widget:switch3v`). Looks right, but every machine re-implements layout.
- **Raw machines** (`raw-ms20`): `drawMs20Panel`/`drawMs20Module` in
  `src/machines/fy_raw_machine.zig` hand-code flat `pane_alt` boxes with no
  bevels. The manifest already groups controls by `module` — the *data* for
  a layout exists; only a beveled renderer is missing.

The fix is one generic renderer driven by the control declaration. Authors
write manifest lines; the engine does bevels, placement, and readouts.

## Panel model

```
panel  (body rect)
└─ rows            (stacked top→bottom; each has a height weight)
   └─ cells        (placed left→right within a row; each has a width weight)
      └─ strips    (stacked top→bottom within a cell; each has a height weight)
         └─ cells  (the strip's own knob grid: declared columns × rows)
            ├─ knob     ( label · arc · value readout )   — f32 control
            ├─ switchV / stepped knob — enum control (octave, waveform)
            ├─ blank    ( spacer )
            └─ custom   ( a rect handed to the machine to draw — Escape hatch )
```

This is a small **weighted box layout** — two levels of nesting (rows →
cells → strips), no arbitrary recursion. It is generic and reusable: a
machine only declares the tree and weights; the engine computes every rect.
The per-strip renderer (`drawStrip`) and the knob/switch widgets are
unchanged — the engine just feeds them rects.

- A **row** spans the full body width; its height = `body.h × row_weight /
  Σ row_weights`. Rows stack top→bottom.
- A **cell** is a column within a row; its width = `row.w × cell_weight /
  Σ cell_weights`. A cell holds one *or more* stacked strips — this is how a
  short module (VCA) shares a column with another (so it stops wasting a
  full-height strip).
- A **strip** inside a cell gets height = `cell.h × strip_weight /
  Σ strip_weights`. It is the familiar beveled box (`bevelRaised` header in
  `slab_fill`, sunken body, auto title).
- A **strip's knob grid** is its declared `cols` × `ceil(n/cols)`. A wide,
  short strip (e.g. **MOD** as a full-width bottom row) just uses `cols = N`
  so its knobs flow horizontally — same renderer, no special case.

Weights default to 1, so simple panels stay terse; you add weights only
where proportions matter (e.g. a tall ENV row vs. a short MOD row).

The panel is a pure function of (control declaration, tier, body rect). It
owns no scroll state — see Client rect.

### Tiers and natural size

Weights set **proportions**, not control sizes. Controls come in fixed
sizes (docs/06 §Sizing), so layout runs in two steps:

1. **Measure at a tier (L/M/S):** each strip's minimum size is its header
   plus its control grid at that tier's cell size. Rows, cells and strips
   take the maximum of their children's minimums; this is the panel's
   **natural size** at the tier.
2. **Place:** the container picks the largest tier whose natural size fits
   the body, and applies it to the whole panel, so every knob matches.
   Space beyond the natural size is shared out by weight between strips
   (strips get roomier, controls stay the same size). Below the smallest
   tier the container scrolls or clips; the panel never shrinks a control
   to fit.

## Declaration (machine descriptor)

> **Status:** the pipe-delimited `.manifest` text file is gone. A machine's
> `manifest` word (vocabulary in `machines/lib/manifest.fy`, walker in
> `src/machine_desc.zig`) declares the same data in fy, with param offsets
> from ustruct introspection (`MyParams.field`). The pipe syntax below is
> kept as compact documentation of the *data model*; the fy words map 1:1
> (`strip`, `knob`, `switch`/`opt`, `row`/`cell`/`item`, `adsr-display`,
> `const-f64`). See `machines/ms20/ms20.fy` for the live example.

The descriptor carries control grouping; `direct-f64` knob declarations are
plain `knob` words.

**Strip declaration** — names a module and its knob-grid column count:

```
strip|MODULE|cols
strip|VCO1|1
strip|MOD|4        ( 4 knobs in a row → horizontal when placed in a wide cell )
```

**Layout block** — the weighted box tree. `row|` opens a row; `cell|` adds a
cell to the current row. A cell lists one or more modules (stacked); weights
are optional (default 1):

```
# row|<height-weight>
# cell|<width-weight>|MODULE[*hw]/MODULE2[*hw]/...   ( '/' stacks; *hw = strip height weight )
row|4
cell|1|VCO1/MG
cell|1|VCO2
cell|1|MIX*3/VCA*1
cell|1|HPF
cell|1|LPF
cell|1|AMP ENV
cell|1|FLT ENV
row|1
cell|1|MOD
```

Stacked modules in a cell are separated by `/` (module names may contain
spaces, e.g. `AMP ENV`, so space can't be the separator). Here VCO1 stacks
over MG in one column; MIX (weight 3) over VCA (weight 1) in another; the
bottom row is MOD spanning full width with horizontal knobs.
Controls attach to a strip by their existing `module` field. If no `row|`
lines are present, the engine falls back to the legacy single flat row (so
existing fixtures are unaffected).

Switch (enum) control kind (new) — for octave/waveform selectors:

```
# control|module|label|id|switch|offset|-|-|default|-|opt0,opt1,opt2,opt3
control|VCO1|RNG|vco1-oct|switch|16|-|-|2|-|32,16,8,4
control|VCO1|WAV|vco1-wave|switch|24|-|-|1|-|tri,saw,pulse,noise
```

A `switch` control stores the selected **index** at `offset` (or a mapped
value; the kernel reads the index and maps it — e.g. octave → frequency
multiplier). Rendered as a `switchV` cell.

Knobs stay as today (`direct-f64`), now drawn with a value readout by the
engine. Optional `unit`/format can be added later for the readout text.

> Parity note: this landed — machines declare the strip/control spec in
> their fy `manifest` word; the renderer is unchanged.

## The renderer

One generic routine (`drawPanelImpl` in `src/machines/fy_raw_machine.zig`):

1. **Measure**: walk the layout tree — split body height across rows by
   weight, each row's width across cells by weight, each cell's height across
   its stacked strips by weight — yielding one rect per strip.
2. **Draw strip**: `ctl.strip(rect, title)` — faceplate + engraved title.
3. **Lay the table**: the strip's controls fill `cols` per row. Each column
   is as wide as its widest control and each row as tall as its tallest,
   at the tier's natural sizes, so knobs, faders and switches pack without
   a uniform grid. Horizontal slack is shared evenly between columns;
   rows stack from the top at their natural pitch (4px apart), so rows
   line up across strips and spare height is plain faceplate below. A
   control sits at its natural size, centred across its column.
4. **Draw the control** as its widget (§Controls and interaction).

## Displays (built-in visualizers)

Beyond knobs/switches, a **display** cell shows a built-in visualizer in a
shared sunken-black field. Declared like a strip and placed in the layout:

```
display|NAME|kind|source[,source2...]
display|EG|adsr|FLT ENV,AMP ENV       # one field, two overlaid labelled curves
...
cell|1.6|HPF*4/EG*1                    # short display under a taller HPF
```

- `kind` selects a built-in renderer (`adsr` today; `lfo`, `scope`,
  `schematic`, `vu` are the obvious next ones — each is a new `switch` arm).
- `source` names the module(s) the renderer reads. Comma-separated sources
  are **overlaid** in the one field, one accent pen each, labelled inline.
- `adsr` reads the source module's ATK/DEC/SUS/REL (or A/D/S/R) knob norms and draws the
  cap-discharge envelope shape, reacting live as the knobs move.
- `eg4-display ( name module -- )` draws a DX-style four-rate / four-level
  envelope from the module's R1..R4 (level per sample) and L1..L4 controls;
  segment widths follow each segment's duration on a log scale.
- `algo-display ( name selector ops stride matrix carriers feedback -- )`
  draws an operator-routing graph from the machine's derive-data table: the
  row is the `selector` int-step's value, and the row holds a modulation
  matrix `m[carrier][modulator]`, carrier flags and feedback flags at the
  given element offsets. Carriers sit lit on the output bus, each modulator
  above the first operator it feeds (a tidy tree; extra targets draw as
  diagonals), feedback as a loop over the box. The routing stays the
  machine's data: FM-86's table lives in `fm86_algo.fy`.

- `segment-display ( name asset -- )` draws a CMI voice's RAM: the
  selected zone as the Unfairlight stores it (16,384 samples at
  `cmi-rate`) across 128 segments, a grid every 16, the unused tail
  dimmed, the loop span (`cmi-loop-start`..`cmi-loop-end`, lit while
  `cmi-loop` is on) and the START segment (`cmi-start`). The three
  markers drag in whole segments; the title row is a waveform-display's.

- `dyn-display ( name prefix gr lvl -- )` draws a compressor's transfer
  curve: the static curve of the `<prefix>-thresh` / `-ratio` / `-knee`
  controls (input dB across, output dB up, −48…0 on both, unity dim,
  THRESH marked), the detector level (state f64 at `lvl`, linear) as a
  dot at the gain actually applied, so attack and release show as the
  dot leaving and rejoining the curve, and a GR bar (state f64 at `gr`,
  dB) down the right edge with a `GR x.x` readout. comp2 puts it beside
  THRESH / RATIO / KNEE.

- `taps-display ( name prefix -- )` draws a delay's repeat train for one
  hit: left taps up from a centre line, right taps down, each bar the
  repeat's gain, over the host tempo's beat grid (bars brighter), with an
  `L x  R y ms` readout. It follows `<prefix>-mode`: STEREO two trains,
  PING alternating sides, WIDE a right tap offset on one ring. delay2 puts
  it over its TIME strip.
- `decay-display ( name prefix -- )` draws a reverb's level against time
  on a square-root time axis (so the predelay gap and the early taps get
  room): the dry hit, the early reflections when `<prefix>-early` is up,
  then from the predelay the low band (DECAY × BASS), the mid band
  (DECAY) and 8 kHz (faster by the loop's damping lowpass per pass), and
  the gate's hold as a line when GATED. verb2 puts it beside SPACE.

- `graphic-display ( name sources wpos -- )` draws an EQ Eight style
  face: a live spectrum analyser under the response of the machine's
  eight bands, 20 Hz to 20 kHz. `sources` is `"prefix,buffer"`: the band
  controls are `<prefix>-t1..8` (type), `-f`, `-q`, `-b` (gain), `-on`,
  plus `-adapt` and `-out`, and the kernel writes its output into host
  buffer `buffer` as a ring with its write head at state f64 `wpos`. The
  panel FFTs the newest 2048 samples of both channels each frame (Hann,
  +3 dB/oct tilt so a mix reads level, falling at 30 dB/s), and falls to
  silence once the write head stops. Each band has a numbered handle:
  drag it across for FREQ and up and down for GAIN, click it to turn the
  band on or off. geq8 puts it over its band columns.

Synth displays follow the machine's **newest sounding voice** (a voice
machine's displays read that voice's state; with nothing sounding they
show the knobs alone). Their drawing lives in `src/ui/synth_views.zig`,
shared with the gallery's CONCOCTION page:

- `wavetable-display ( name sources pos-off warp-off frames -- )` draws an
  oscillator's table: every frame stacked in depth (the nearer hiding the
  farther, at most 24 shown), the played frame lit at its depth with its
  warp, the knob's position as a blue ghost when modulation moves it, and
  beside it the played cycle over its first 32 harmonics. `sources` is
  `"prefix,bank,user"`: `<prefix>-table` picks a `frames`-frame table of
  wavetable asset `bank`, or its USER option the whole of asset `user`;
  `-pos`, `-warp` (OFF SYNC PWM BEND FM), `-wamt` and `-on` if present.
  The voice's position and warp amount are the state f64s at `pos-off`
  and `warp-off`.
- `filter-display ( name prefix cut-off res-off -- )` draws the response
  of `<prefix>-mode` (LP24 LP18 LP12 BP HP12 HP24 NOTCH by option name)
  at `-cut` / `-res`, and lit where the voice has them (cutoff Hz,
  resonance in `-res` units); the knobs' curve stays in blue while the
  two differ.
- `lfo-display ( name prefix ph-off val-off -- )` draws one cycle of
  `<prefix>-shape` (`-uni` sits it on the floor), `-sync` or `-rate` and
  `-mode` in its caption, and the voice's phase and value riding it.
- `env-display ( name module level-off stage-off -- )` is an
  adsr-display of one module with the voice riding the curve, placed by
  its env_dig level and stage.
- `mod-dock ( name -- )` is the modulation dock (§Modulation).
- `matrix-display ( name -- )` is the mod matrix on one display
  (§Modulation).
- `scope-display ( name -- )` draws the machine's output: the engine
  appends each block, mono, to a ring, and the display shows two cycles
  of the newest voice's note from a rising zero crossing, scaled to fit.

These compute from the machine's controls on the UI thread, as the kernel's
block-prepare would, not from derived params: the engine renders nothing
while the transport is stopped, so derived params would show the last
played settings.

These visualizers are **drawn in Zig today** (selected by the manifest kind).
They are the visual reference for the planned fy-drawn displays.

## Modulation

A machine with a mod matrix declares it, its sources and the knobs they
reach, and the panel does the rest (Concoction is the reference):

```
"LFO1" 3 MyState.l1-v 1 mod-source     ( label, SRC option, live value, bipolar )
"cn-f-cut" 12 MyState.cut-hz mod-dest  ( control id, DEST option, live value )
"cn-f-env" 1 12 mod-fixed              ( built-in route: amount knob, SRC, DEST )
"cn-m" 8 mod-matrix                    ( slots: cn-m1-src / -dst / -amt ... )
```

- Each `mod-source` is a chip in the dock (`mod-dock`) with a live meter
  of the newest voice's value.
- A `mod-dest` knob shows a modulation ring (blue) at the value the
  newest voice has it at, in the control's units, while a slot routes to
  it or the two differ. The kernel stores those values in its state at
  control rate; they cost nothing at audio rate.
- Drag a chip onto a ringed knob: the slot that already joins the two is
  kept, else the first free slot (SRC or DEST OFF) takes the source, the
  destination and half the amount. Drop it on a slot's SRC to set only
  that. The drop writes the slot's switches and knob through the normal
  control path, so presets, projects and automation see an ordinary edit.
- `mod-fixed` declares a route the machine hard-wires outside the matrix
  (a filter's ENV amount, KEY tracking, velocity to amp), so the matrix
  display can show everything that moves a ring.
- `matrix-display` shows the slots, then the built-in routes, on one
  display, in up to three columns as the width allows: a row per slot, SOURCE → DEST as display selects and the
  amount as a bipolar bar (drag it; double-click for none) with what the
  row adds right now lit on it. The × clears a row. A built-in route is a fixed row: no number and
  no selects, and its bar is its knob. A row lights while
  its destination knob is hovered, and a dragged chip outlines the row
  it would fill. Rows are drop targets too. The slot controls stay out of
  the pages; the display edits them.
- Right-click a destination knob: under the automation items, one
  "Remove <source> modulation" per slot that routes to it.

## Escape hatch: fy-drawn custom displays (planned)

The durable goal (docs/00, docs/02): a machine draws its own bespoke display
in **fy**, not Zig. The shape: a small immediate-mode gfx API exposed as fy
builtins (`g-pen`, `g-line`, `g-rect`, …), a machine-declared `draw` word the
host calls each frame with the cell rect + params pointer, and a
`display|NAME|fy|<word>` kind to wire it. The current Zig `adsr` renderer is
the reference to match. Hazard to design around: hot-reload recompiling the
fy module while the UI/audio threads run — pre-existing to the livecoding
model, to be handled there, not invented here.

## Client rect + title bar

The host (machine bay) owns the chrome; the machine owns the body.

- **Title strip (auto)**: machine name + preset chip. **No voice/MONO
  select.** A machine declares its own voices (`voices!` in its
  manifest) and allocates them itself. The host-side pool that wrapped N
  copies of a machine is gone: panel edits reached only the first copy.
  A higher-order voice-pool machine for mono machines stays a possible
  later addition.
- **Body rect**: everything below the title — the panel surface the layout
  engine fills.
- **Scroll is the container's concern, not the panel's.** The panel reports
  its natural size and wraps strips into rows to fit the body; it does
  **not** capture the wheel (the wheel belongs to the arrangement/viewport).
  If a machine is wider/taller than the bay, the bay/viewport decides how to
  reveal it (horizontal reveal for wide machines); we add that deliberately,
  not by having panels grab input.

## Controls and interaction

Panels use the control catalogue and interaction contract in docs/06
(§Control catalogue, §Interaction contract). A control declares *what* it
edits (`knob` for a value, `switch` + `opt`s for options, `int-step` for
an integer range); a word after it picks *which* catalogue control the
panel draws:

| Word | Control | Edits |
|---|---|---|
| `as-knob` | rotary (stepped for options) | anything |
| `as-fader` | panel fader | values |
| `as-lever` | toggle lever with marks | two options |
| `as-slide` | slide switch | options |
| `as-list` | LED option column | options |
| `as-radio` | joined LED caps, one down | options |
| `as-vradio` | the same caps stacked top to bottom | options |
| `as-button` | LED latch: option 0 off, 1 on | two options |
| `as-display` | VFD display select: click for the option grid, drag to step | options, integer ranges ≤ 128 |

Without one the panel picks from the kind (`Control.widgetFor`): knobs
for values and integer ranges, an LED latch for an `OFF`/`ON` pair, a
lever for other pairs, a list for 3–6 options, a stepped knob beyond. A
centred range (`-x..x`) draws bipolar. A widget that can't edit its
control (a fader on a switch) is a descriptor error.

An option can carry settings: `"id" value sets` after an `opt` moves
control `id` to `value` (preset units; an option index for a switch)
when that option is picked on the panel. A MODEL switch uses it to set
several knobs at once (the sampler's engine models). Presets, projects
and automation set only the switch itself, so a saved patch keeps its
edited knobs. A switch has up to 16 options.

Values are not labels: panel controls print no readouts. The title
strip's display (docs/06 §Displays) shows `LABEL VALUE` for whichever
control is hovered or dragged, as a hardware unit's display does. The bay
sets `Ui.touch_scope` around the panel, so every control in it reports to
that machine's display however it is scoped (a voice pool draws its first
voice's panel; radio caps scope their segments).
`machines/juno2/juno2.fy` is the reference: a Juno-106 face of faders,
LED buttons and levers.

## Phasing

1. `widgets.strip` + `switchV`; knob fine/reset/readout.
2. Generic declarative renderer driven by the manifest; delete
   `drawMs20Panel`/`drawMs20Module`. `raw-ms20` renders beveled.
3. Manifest: `strip|` lines + `switch` control kind; wire octave/waveform.
4. Title bar: drop the poly dropdown; document the future voice-pool machine.
5. Custom-draw escape hatch (ADSR graph / VU) for one strip as a proof.
6. Then the MS-20 voice expansion (docs/14) populates strips: VCO1, VCO2,
   MIXER, HPF, LPF, MG, EG1, EG2.

## Companion doc edits

- **docs/06-ui-widgets.md** — done: the UI-system rewrite carries the
  catalogue, interaction contract and tiered sizing.
- **docs/02-machines.md** — note that a machine's panel is part of its
  declaration (strips + controls), with the manifest as the interim source
  and the fy descriptor as the target.
