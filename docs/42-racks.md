# 42 — Racks: chains in lanes, macros, rigs

**Status: built (phases 1–6).** This is the reference for racks.
Rack lanes hold chains, the FX Rack plays lanes of inserts, racks nest
three deep and align their lanes' latency. Macros map to controls inside
through ranges and formulas. The panel has the macro block, MAP mode,
KEY/VEL/CHAIN zone tabs, the collapsed face and insert reordering; ⌘G
groups devices into a rack and ⌘⇧G ungroups. Factory rigs ship under
RACKS in the picker, slabkit builds racks, and automation reaches
controls inside a rack by path. "Where we start" describes the first
Rack, which the second form replaced; its files still load.

A rack packages machines into one device. Each of its lanes holds a
chain, an instrument and its effects or just effects, and the lanes play
in parallel. Up to eight macro knobs on the rack's face drive any
controls inside it, each through a range and an optional formula. Saved
as a preset, a rack becomes a device you can drop on a track: a
"Fretwire Clean Rig" that loads Fretwire Guitar, Ampstack, a delay and a
room, with PICKUP, DRIVE, TONE and ROOM on its face. This is the shape
of Ableton Live's Instrument and Audio Effect Racks, with Slab's
hardware look.

## Where we start

The first Rack was an instrument rack only:

- Up to 8 parts. Each is one instrument with a key range, a velocity
  range, transpose, level, pan, a polyphony cap and mute.
- Parts render serially and are summed.
- Rack presets and projects store the parts as `{"parts":[…]}`
  (`rack.zig:507-558`, `document.zig` instrument `state`).

What it lacks:

- Effects in a part.
- A use in an effect slot.
- Nesting (`rack.zig:292` skips natives).
- Automatable controls (docs/22 says so).
- Latency, tail and wake handling for its parts.
- Any form slabkit can see (`describe.zig` walks fy machines only).

Racks extend this machine rather than adding a second container. Old
rack presets and projects load and sound as they do today.

## Model

```
Rack
  kind      instrument | effect       (from the slot it sits in)
  macros    [8] Macro                 name, value 0..1, color index
  chain     0..127                    the CHAIN selector, itself a control
  lanes     [≤8] Lane
    name, on, solo, level dB, pan
    zones   key lo..hi, vel lo..hi, chain lo..hi     (instrument rack: all three;
                                                     effect rack: chain only)
    transpose, poly                                  (instrument racks, as today)
    chain   instrument? + effects[≤16]               the same Chain a track has
  maps      [≤64] Mapping
    macro index, target (lane, slot uid, control id), min, max, formula?
```

**One machine, two registry entries.**
- **Rack** (`rack`): an instrument. It routes notes to the lanes whose
  key and velocity ranges hold them, as parts did. Each lane renders its
  instrument, then its inserts.
- **FX Rack** (`fxrack`): an effect. Every lane gets the rack's input.
  A lane with no inserts is a dry path, which is how a parallel-compression
  rack or a DI-plus-amp bass rig is built.

Both are `src/machines/rack.zig` with a `Kind`; being two entries, the
picker offers each in its own slot with no new rules, and each has its
own presets folder.

**MUTE and SOLO close a lane's input.** A muted lane, or one another
lane's SOLO leaves out, takes no new notes (an effect lane, no input);
what it already holds rings out and is heard, as a muted part did.

**Lanes reuse the track's chain.** The `Effect` slot type (uid, bypass,
sidechain key, PDC dry line, idle skip, wet crossfade) and its
UI→audio handoff live in `src/chain.zig` (`chain.State`). A track
and a rack lane share that one implementation: adopting by uid and
version, retiring replaced machines, latency, and the quiet state. It
also means what works on a track's effects works inside a lane, but two
things: sidechain keys don't reach lane inserts yet, and a lane's chain
changes at once, without the track's one-chunk crossfade.

**Nesting.** A rack can sit inside a lane, up to three levels deep. The
`rack.zig:292` guard becomes a depth check. A rack's latency, tail and
wake are its lanes', so a nested rack behaves like any machine.

**Mixing and latency.**
- Lanes sum after their own level, pan, mute and solo.
- Lanes with different latency are aligned to the slowest one, with a
  per-lane delay, before the sum. The rack reports that latency to the
  track's PDC.
- An idle lane (silent instrument, every effect quiet) is skipped like
  an idle track.
- Lanes render serially on their track's worker. Lanes on the render
  pool are a later step, only if a heavy rig needs it.

**Capacities** are bounded arrays: 8 lanes, 16 effects per lane, 8
macros, 64 mappings in all, depth 3. A rack with every lane full is 136
machines, so the retirement queue grows to match.

## Macros

A macro is a rack control like any other: `MACRO 1`…`MACRO 8` (ids
`rk-m1`…`rk-m8`), plus `CHAIN` (`rk-chain`). Because they're ordinary
controls they automate, take presets, show on the panel and slabkit
addresses them with no new code (`inst:rk-m2`, `fx1:rk-m4`). Each macro
has a name the panel shows in place of `MACRO n`.

### Mappings

A mapping ties one macro to one control inside the rack:

- the target: lane, slot uid, control id. It can also be a lane's own
  level or pan, or a nested rack's macro, which is how macros reach down
  a level.
- `min` and `max`, in the target's real units, so a mapping reads
  "AMP GAIN 2 → 7.5" or "DELAY MIX 0 % → 35 %". With `min > max` the
  knob turns the target down.
- an optional **formula** that shapes the macro before the range.

The macro's value `x` (0..1) passes through the formula, which gives `t`
(clamped to 0..1). The target then moves to `lerp(norm(min), norm(max), t)`
in its own knob space. A target with an exponential curve stays
exponential, so a cutoff mapped 200 Hz → 8 kHz sweeps the way its own
knob does. With no formula, `t = x`.

**Formulas** are short expressions:

```
x            the macro
m1 … m8      the other macros, for cross-coupling ("x * (1 - m3)")
+ - * / ^    and parentheses
min max clamp lerp abs   exp log sqrt   sin cos
step(x, n)   snap to n steps (a 4-way PICKUP macro on a 3-way switch)
```

Examples:

| formula | effect |
|---|---|
| `x^2` | slow start |
| `1 - x` | turns the target down as the macro goes up |
| `clamp(2*x - 1, 0, 1)` | does nothing for the first half of the turn |
| `x * (1 - m4)` | DRIVE fades out as macro 4 (CLEAN) comes up |

The UI parses a formula into at most 32 postfix ops over fixed
registers. A typo stays in the field marked in red and the old formula
keeps running. The audio thread evaluates the program once per 32-sample
sub-block, the same rate automation uses. Evaluating it allocates
nothing and can't fail: division by zero gives 0, and NaN becomes 0.

### Reaching the target

Inner machines take macro values through a new audio-side **mod input**
on the host machine interface: `set_mod(control_index, norm)` and
`clear_mod(control_index)`. They are called only from the audio thread,
between sub-blocks.

- `fy_raw_machine.zig` keeps a bit per control and a norm per control.
- After automation it applies mod values, so a macro wins over the
  inner control's own automation and the knob.
- The usual 20 ms smoothing applies, so turning a macro is as smooth as
  turning the knob.

This is generic host plumbing, with no knowledge of any instrument. The
UI reads the same value back and draws a mapped knob at the macro's
position, with a mapped mark. Hand moves on a mapped knob pass through
to the macro.

A switch target (Fretwire SELECT, Ampstack CAB) gets the norm snapped to
its option, so a stepped macro changes a switch the same way clicking it
would.

## UI

The rack draws in the bay like other devices, wider. It has three parts,
left to right:

```
┌ GUITAR RIG ───────────────────────────── [▾][MAP][ON] ┐
│ ┌MACROS──────────────┐ ┌LANES──────────────┐ ┌LANE 1: CLEAN ─────── … ┐
│ │ PICKUP DRIVE TONE  │ │▣ CLEAN    S ▮▮▮▯ C│ │ [FRETWIRE][AMPSTACK]   │
│ │  (o)    (o)   (o)  │ │▣ DIRTY    S ▮▮▯▯ C│ │ [DELAY]  [VERB]        │
│ │ ROOM  …            │ │ + LANE           │ │  (the chain's devices) │
│ │  (o)               │ ├ZONES KEY|VEL|CHN─┤ │                        │
│ └────────────────────┘ │  ▬▬▬▬▬▬     ▬▬▬▬  │ └────────────────────────┘
└────────────────────────┴───────────────────┘
```

1. **Macros:** eight knobs in two rows of four, at the panel's large
   tier. Each knob carries its name and a count of its mappings.
2. **Lanes:** one row per lane, with ON, name, solo, a level bar and pan.
   Under the list sit the zone editor's KEY, VEL and CHAIN tabs, with
   one bar per lane, as in Live.
3. **The selected lane's chain:** its devices are drawn inline as nested
   bay columns, under a bracket header that shows the depth.

**Collapsed face.** The fold button in the title strip collapses the
rack to its named macro knobs. A rack loaded from a preset opens
collapsed. That face is the pseudomachine: on the track it reads as one
device, GUITAR RIG, with four knobs. The fold state saves as
`"collapsed"` in the rack's state.

**MAP mode.** Pick a macro and arm MAP. Every mappable control in the
open lane gets an amber outline, and clicking one adds a mapping. Under the
macros, a table lists the picked macro's mappings: target, MIN, MAX and
the formula as a text field. Dragging MIN or MAX on a row sets the range
the same way dragging the target's knob does. With MAP off, turning a
mapped control by hand moves the macro instead: the macro takes the
value whose mapping lands closest to where the hand put the control.

**Zones.** KEY, VEL and CHAIN tabs under the lane list show one bar per
lane; drag a bar's ends to set its range. CHAIN is also a field beside
the macros (`rk-chain`, 0–127).

**Reordering.** Drag an insert's title strip along the lane's chain to
move it.

The colors and widgets are the existing tokens: amber marks the armed
MAP and the selected lane and nothing else. No new widget kinds are
needed except the zone bars and the mapping table rows.

**Group into a rack.** Shift-click devices in the bay to select a run
(the instrument and some effects, or only effects) and press ⌘G. The
run moves into a new rack's first lane, with its settings and automation
intact (see "Automation inside a rack"); an instrument run makes a Rack,
an effect run an FX Rack. With a rack selected, ⌘⇧G ungroups it when it
has one lane and no mappings. ⌘G groups tracks only while no devices are
selected in the bay.

## Presets: rigs

A rack preset is the rack's whole state: kind, lanes and their chains,
each device's params and assets in its own preset form, zones, mixer
settings, macros and mappings.

- Factory rack presets live in `machines/rack/presets/`, banked by
  folder.
- The machine picker lists Rack and FX Rack under **RACKS**, filtered
  by kind; their preset submenus hold the rigs.
- The bay's preset menu saves User and Project racks as it does for any
  machine.

Existing preset storage carries this with no new item kind (docs/25):
racks are a machine with presets. The one change is that a preset can
hold `state` beside `params`, which the rack already relies on.

**Factory rigs:**

- **Fretwire Clean Rig.** Guitar → amp2 (clean) → delay2 → verb2.
  Macros: PICKUP (SELECT stepped), TONE (TONE pot + amp treble), ECHO,
  ROOM.
- **Fretwire Crunch Rig.** As Clean with the crunch amp. DRIVE couples
  amp gain and output level (`x` and `1 - 0.5*x`) so the level holds.
- **Bass DI + Amp.** Fretwire Bass, then an effect rack: lane 1 is DI
  through comp2, lane 2 is amp2 (vintage 15). Macros: BLEND (the lane
  levels, opposite ways), GROWL, PUNCH.
- **Parallel Squash** (effect rack). Lane 1 is dry, lane 2 is a heavy
  comp2 with sat2. Macro AMOUNT.
- **Split and layer.** The first Rack's presets (`bass-pad-split`,
  `epiano-pad-layer`), rewritten in the second form.

## Automation inside a rack

The macros cover most needs. Inner controls can also be automated
directly, so grouping loses nothing:

- **The target path** extends `automation.Target` with a path of up to
  three steps under the rack's own target. Each step is a lane uid and a
  slot (0 for the lane's instrument, else the insert's uid), so lanes
  and inserts can move without breaking it. Files write positions,
  which load back to uids.
- **In files** it reads as the rack's target, then `/L.P` per step:
  lane L counted from 1, place P 0 for the lane's instrument and n for
  its n-th insert. `fx1/2.1:amp-gain` is the rack in effect slot 1,
  lane 2, first insert, control `amp-gain`; `inst/1.1/2.1:amp-gain` goes
  through the track's instrument rack and the FX Rack in its lane 1.
- **Resolving lanes.** `Machine.child` lists a container's machines and
  `Machine.inner(path)` walks it; the track resolves a lane to the inner
  machine when it publishes. `AutoView` gains the path, so `matches`
  stays a cheap compare, and `into(step)` hands a nested rack the view
  one step down.
- **Grouping** retargets the moved machines' lanes (the track's and its
  clips') one step down the new rack, and ungrouping strips that step.
  A lane past three steps is dropped. Ungrouping also drops the lanes on
  the rack's own macros, which go with it. A mapped control's own lane
  still plays, but the macro overrides it while it moves.
- The lane menu names an inner target with the machine first
  (`AMP2 GAIN`).

## Files and compatibility

**Rack state** gains `"rack": 2`:

```json
{"rack": 2, "kind": "instrument",
 "lanes": [{"name": "CLEAN", "lo": 0, "hi": 127, "vlo": 1, "vhi": 127,
            "clo": 0, "chi": 127, "transpose": 0, "level": 0, "pan": 0,
            "poly": 0, "mute": false, "solo": false,
            "instrument": {"machine": "guitar", "params": {…}, "preset": "twin-humbucker"},
            "effects": [{"machine": "amp2", "params": {…}, "bypass": false}, …]}],
 "macros": [{"name": "DRIVE", "value": 0.4}, …],
 "chain": 0,
 "maps": [{"macro": 1, "lane": 1, "insert": 1, "control": "amp-gain",
           "min": 0.2, "max": 0.95, "formula": "x^2"},
          {"macro": 2, "lane": 2, "target": "level", "min": -40, "max": -3}]}
```

- Macros, lanes and inserts count from 1 in `maps`. A mapping with no
  `insert` reaches the lane's instrument; `target` is `level` or `pan`
  for the lane's own mix, absent for a control. `min` and `max` are in
  the target's real units (dB for level).
- `clo`–`chi` is the lane's CHAIN zone: it plays while `chain` is inside.
- The rack's controls also write as `params` (`rk-m1`…`rk-m8`,
  `rk-chain`), which is how slabkit and automation set them; `macros`
  then sets the same values.

- **Old rack state still loads.** State with `"parts"` and no `"rack"`
  key reads as version 1. Each part becomes a lane holding its
  instrument with its key, velocity, transpose, level, pan, poly and
  mute, and no effects or macros. Projects with racks render
  bit-identically, which the bench and a project render check.
- **Effects gain `state` and `assets`** in the project, so an effect slot
  can hold a rack. Files name slots by chain position, as `fx<N>`
  lanes already do; uids stay in memory. Files without them load as
  today. *(Built in phase 1.)*
- **Automation targets:** a target with no path is today's target.
  Older Slab ignores a lane whose target it can't parse and keeps the
  rest (docs/22).
- The project `SCHEMA` stays 1. These are additions that older files
  never contain.

## slabkit

`tools/slabkit/rack.py`:

```python
from slabkit import Song, fx, rack

rig = rack("Guitar")
clean = rig.lane("CLEAN", "guitar", "twin-humbucker",
                 fx=[fx("amp2", "guitar-clean"), fx("delay2", "slapback")])
drive = rig.macro(1, "DRIVE", 0.3)
rig.map(drive, clean, "amp-gain", insert=1, min=0.2, max=0.95, formula="x^2")
rig.map(rig.macro(2, "LEVEL", 1.0), clean, "level", min=-40, max=0)
t = song.track("GTR", rig)               # or song.track("GTR", "rack", "fretwire-clean-rig")
t.automate("rk-m1", (0, 0.3), (32, 0.8))
t.automate("inst/1.1:amp-treble", (0, 0.5), (32, 0.7))
```

- `rack(name, kind="instrument"|"effect", preset=None, chain=0,
  collapsed=False)`; `lane(name, machine, preset, params, fx, keys=,
  vel=, chain= (lo, hi) zones, transpose, level, pan, poly, mute)`; a
  lane's machine may be another `rack()`, an insert `fx(rack(kind=
  "effect"))`.
- `macro(n, name, value)` returns the macro for `map(macro, lane,
  target, insert=0, min, max, formula)`. Targets are `"level"`,
  `"pan"`, or a control id (prefix optional), checked against the
  machine's range.
- `fx("fxrack", "parallel-squash")` and `song.track(name, "rack",
  "<rig>")` load rigs as saved; automation paths into them resolve
  against the preset's state.
- `songs/rack_rigs.py` is the demo.

`slab --describe` lists `rack` and `fxrack` (`"native": true`) with
`rk-m1`…`rk-m8` and `rk-chain` under MACROS.

## Build phases

Each phase lands on its own with tests, and existing goldens stay
bit-exact.

1. **Chain extraction.** *Built.*
   - `chain.State` in `src/chain.zig` holds the handoff, retirement, the
     audio copy and the dry lines; the owner keeps the editable
     instrument and effects. Tracks use it unchanged: songs render
     byte-identical.
   - Projects write effect `state` and `assets`.
2. **Lanes with chains.** *Built.*
   - Rack lanes hold an instrument plus inserts; the FX Rack; nesting
     three deep; per-lane latency alignment; tail, wake and idle skip of
     lane inserts. Lane machines get no automation until phase 6.
   - Rack state v2, with the first form read as lanes.
   - The panel: a packed lane column (lanes with M and S, + and − for
     lanes, the key map, zone and mix fields four to a row) beside the
     selected lane's chain, drawn as the bay draws a track's: each
     machine its own title strip (preset menu, ON/BYP, click the name to
     replace it, × to remove it), inserts with I/O meters, + to add one.
     Preset actions inside go through the bay's (`NestedPreset`), and
     adding, removing or replacing is an undo step.
   - Tests: a first-form project renders byte-identical; a one-lane FX
     Rack equals its insert sample for sample; a dry lane is held to a
     latent one.
3. **Macros.** *Built.*
   - Rack controls `rk-m1..8` and `rk-chain`, automatable; mappings to a
     lane machine's control or the lane's level or pan; the formula
     compiler and its VM (`src/formula.zig`); the `set_mod` host input,
     in `fy_raw_machine` and in the rack itself (a nested rack's macro is
     a target).
   - While a macro moves (a lane, or the hand's 20 ms glide) the rack
     renders its lanes in 32-sample chunks and sets the mapped controls
     between them, which then follow exactly as automation does. Steady
     macros render whole blocks: projects without mappings are
     byte-identical.
   - A mapped control shows the macro's value with its automation LED
     lit; turning it by hand moves its own value, which the macro
     overrides.
   - Lane CHAIN zones (`clo`–`chi`) close a lane outside them.
   - Tests: formula parsing, precedence and run-time safety; mappings and
     macros round-trip; an automated macro sweep equals automating the
     control itself, sample for sample; a formula, a stepped target,
     unmapping; CHAIN zones; a macro reaching a nested rack's macro.
4. **UI.** *Built.* The macro block: eight knobs, NAME, MAP (click a
   control in the open lane, or LV/PN, to map it to the picked macro over
   its whole range), and the picked macro's mappings with × , MIN and
   MAX steps in the target's units and the f(x) field, red until it
   parses. KEY/VEL/CHAIN zone tabs, the collapsed face, MAP outlines,
   hand moves on a mapped knob reaching the macro, insert drag
   reordering, and ⌘G group / ⌘⇧G ungroup from a bay selection.
5. **Rigs.** *Built.* Factory rack presets, the RACKS section of the
   picker, the slabkit builders and `describe`, and these docs.
6. **Inner automation.** *Built.* Target paths, AutoView paths, and
   moving lanes on group and ungroup. Tests: a path lane drives the
   insert inside as a track lane would; `fx0/2.1:` round-trips; group
   and ungroup keep automation.

## Open choices

These were the defaults going in, and are what got built.

- **8 macros.** Live 12 allows up to 16. Eight fits two rows at the large
  tier and has been enough for Live rigs for a decade.
- **Formulas stay this small.** There are no conditionals or state, so
  there are no LFOs inside formulas. Modulation sources belong in their
  own machines.
- **Lanes render serially.** Lanes on the render pool can come later, if
  a rig needs it.
