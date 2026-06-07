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
panel
└─ strips (modules, declared width, packed left→right, wrap into rows)
   └─ cells (declared columns × rows grid)
      ├─ knob     ( label · arc · value readout )   — f32 control
      ├─ switchV  ( label · vertical option list )  — enum control (octave, waveform)
      ├─ blank    ( spacer )
      └─ custom   ( a rect handed to the machine to draw into — see Escape hatch )
```

- A **strip** is a beveled box (`bevelRaised` header bar in `slab_fill`
  with `slab_hi`/`slab_lo` edges; sunken body) with its title auto-drawn.
- **Declared widths**: each strip declares its width in grid units; the
  engine packs strips left→right and **wraps to a new row** when the next
  strip would exceed the body width (so `mono1`'s 2-row layout emerges
  naturally). Row height = body height ÷ row count.
- **Cells** fill the strip body in a declared `columns` grid; knobs flow
  row-major. Standard knob cell = label on top, arc in the middle, value
  readout below (the `mono1` look).

The panel is a pure function of (control declaration, body rect). It owns
no scroll state — see Client rect.

## Declaration (manifest extension)

The raw manifest already carries control grouping. We extend it minimally;
`direct-f64` knob lines are unchanged.

Per-strip layout line (new) — declares order, width, and column count:

```
strip|VCO1|width|cols
strip|VCO1|3|1
strip|MIXER|5|1
strip|LPF|5|2
```

`width` is in strip-grid units; `cols` is the knob columns inside the strip.
Strip order is the order of `strip|` lines. Controls attach to a strip by
their existing `module` field.

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

1. **Measure**: from `strip|` widths, pack into rows that fit the body
   width; compute each strip rect (row height = body ÷ rows).
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
