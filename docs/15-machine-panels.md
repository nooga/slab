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

These visualizers are **drawn in Zig today** (selected by the manifest kind).
They are the visual reference for the planned fy-drawn displays.

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
| `as-button` | LED latch: option 0 off, 1 on | two options |
| `as-display` | VFD value with ‹ › steppers | options, integer ranges ≤ 128 |

Without one the panel picks from the kind (`Control.widgetFor`): knobs
for values and integer ranges, an LED latch for an `OFF`/`ON` pair, a
lever for other pairs, a list for 3–6 options, a stepped knob beyond. A
centred range (`-x..x`) draws bipolar. A widget that can't edit its
control (a fader on a switch) is a descriptor error.

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
