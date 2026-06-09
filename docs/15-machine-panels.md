# 15 — Machine panels (declarative beveled layout)

How a machine's front panel is declared and drawn. The goal: any machine
gets the brutalist beveled look of `mono1` (module strips with 1px bevels,
auto headers, knobs with value readouts, vertical selectors) **without
hand-coding a draw routine**. The author declares strips and controls; a
generic engine lays them out and renders them.

This is the panel system for the **next-generation machines** — `raw-ms20`
is the first and current focus. Existing callback machines (`mono1`, etc.)
keep their bespoke fy UI words; we do **not** migrate them.

## Why declarative

Today there are two panel paths:

- **Callback machines** (`mono1`): a fy UI word draws the panel by calling
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

The panel is a pure function of (control declaration, body rect). It owns
no scroll state — see Client rect.

## Declaration (manifest extension)

The raw manifest already carries control grouping. We extend it minimally;
`direct-f64` knob lines are unchanged.

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

> Parity note: when machines move to a fy `machine:` descriptor (docs/02),
> the descriptor emits this same strip/control spec — the renderer is the
> same. The manifest is the interim source.

## The renderer

A single generic routine (replacing `drawMs20Panel`):

1. **Measure**: walk the layout tree — split body height across rows by
   weight, each row's width across cells by weight, each cell's height across
   its stacked strips by weight — yielding one rect per strip.
2. **Draw strip**: `widgets.strip(rect, title)` — beveled frame + header.
3. **Lay cells**: split the strip body into `cols` columns × `ceil(n/cols)`
   rows; place each control's cell on the 4px grid.
4. **Draw cell** by kind:
   - `knob` → `widgets.knob` + label + value readout.
   - `switchV` → `widgets.switchV` (octave/waveform vertical select).
   - `custom` → call the machine's draw hook with the cell rect.

`raw-ms20` (and any declarative machine) gets the `mono1` aesthetic for
free; the flat `drawMs20Panel`/`drawMs20Module` are deleted.

## Escape hatch: custom draw

Generic covers knobs/switches. For richer widgets — an **ADSR curve**, a
**VU meter**, a scope — a machine marks a strip or cell `custom` and the
engine hands it the rect to draw into. Raw machines draw via a fy UI word
using the existing panel builtins (`slab:panel-x/y/w/h`, `widget:*`); the
engine sets the UI context to the cell rect before the call. This keeps the
common case declarative while leaving room for bespoke visuals.

## Client rect + title bar

The host (machine bay) owns the chrome; the machine owns the body.

- **Title strip (auto)**: machine name + preset chip. **No voice/MONO
  select.** Polyphony is *not* a leaf-machine concern — it becomes a
  higher-order **voice-pool machine** that wraps a mono machine and owns
  voice allocation. So the leaf's title bar drops the poly dropdown
  (`drawPolyDropdown` in `machine_bay.zig`).
- **Body rect**: everything below the title — the panel surface the layout
  engine fills.
- **Scroll is the container's concern, not the panel's.** The panel reports
  its natural size and wraps strips into rows to fit the body; it does
  **not** capture the wheel (the wheel belongs to the arrangement/viewport).
  If a machine is wider/taller than the bay, the bay/viewport decides how to
  reveal it (horizontal reveal for wide machines); we add that deliberately,
  not by having panels grab input.

## Knob / switch interaction

Keep the current knob feel (vertical drag to adjust, immediate response) and
standardize the modern affordances:

- Vertical drag = adjust; value readout under the knob.
- **Shift = fine**; **double-click = reset to default**.
- Knobs do **not** consume the scroll wheel (reserved for the viewport).
- `switchV`: click an option, or click-drag through the column; snappy,
  no animation.

## Widget additions (companion: docs/06)

- `strip(rect, title)` — beveled module box + header (the `mono1` frame).
- `switchV(rect, label, options, *index, mouse)` — vertical enum selector
  (generalizes `switch3Vertical` to N options).
- `knob` — add fine (Shift) + reset (double-click) + the standard value
  readout; tighten the response curve.

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

- **docs/06-ui-widgets.md** — add `strip`, `switchV`, the knob interaction
  spec.
- **docs/02-machines.md** — note that a machine's panel is part of its
  declaration (strips + controls), with the manifest as the interim source
  and the fy descriptor as the target.
