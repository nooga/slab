# 42 — Racks: chains in lanes, macros, rigs

**Status: phases 1 and 2 built.** Rack lanes hold chains, the FX Rack
plays lanes of inserts, racks nest and align their lanes' latency, and
rack state is in its second form. Macros, the new panel, rigs and inner
automation are still to build. The Rack that ships today
(`src/machines/rack.zig`) is described under "Where we start".

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

The current Rack is an instrument rack only:

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

**Collapsed face.** The ▾ in the title strip collapses the rack to its
macro knobs. A rack loaded from a preset opens collapsed, showing only
its macros. That face is the pseudomachine: on the track it reads as one
device, GUITAR RIG, with four knobs.

**MAP mode.** Pick a macro and arm MAP. Every mappable control in the
open lane gets an outline, and clicking one adds a mapping. Under the
macros, a table lists the picked macro's mappings: target, MIN, MAX and
the formula as a text field. Dragging MIN or MAX on a row sets the range
the same way dragging the target's knob does.

The colors and widgets are the existing tokens: amber marks the armed
MAP and the selected lane and nothing else. No new widget kinds are
needed except the zone bars and the mapping table rows.

**Group into a rack.** Select a run of devices on a track (the
instrument and some effects, or only effects) and press ⌘G. The run
moves into a new rack's first lane, with its settings and automation
intact (see "Automation inside a rack"). Ungroup does the reverse when
the rack has one lane and no mappings.

## Presets: rigs

A rack preset is the rack's whole state: kind, lanes and their chains,
each device's params and assets in its own preset form, zones, mixer
settings, macros and mappings.

- Factory rack presets live in `machines/rack/presets/`, banked by
  folder.
- The machine picker lists them under **RACKS**, filtered by kind.
  Picking one inserts a rack and loads the preset.
- The bay's preset menu saves User and Project racks as it does for any
  machine.

Existing preset storage carries this with no new item kind (docs/25):
racks are a machine with presets. The one change is that a preset can
hold `state` beside `params`, which the rack already relies on.

**Factory rigs to ship with phase 5:**

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
- **Split and layer.** The current rack presets, rewritten in the new
  form.

## Automation inside a rack

The macros cover most needs. Inner controls can also be automated
directly, so grouping loses nothing:

- **The target path** extends `automation.Target` with a path of up to
  three `(lane, slot uid)` steps under the rack's own target. Files
  write slot positions, which load back to uids.
- **In files** it reads as the rack's target, then the path:
  `fx1/2.1:amp-gain` is the rack in effect slot 1, lane 2, slot 1, control
  `amp-gain`.
- **Resolving lanes.** `publishLanes` resolves the path to the inner
  machine. `AutoView` gains the path, so `matches` stays a cheap compare.
- **Mapped controls.** A mapped control can't hold automation of its
  own: the macro owns it. Grouping moves such lanes onto the macro when
  the mapping is one-to-one, and otherwise keeps the lane and leaves the
  control unmapped.

## Files and compatibility

**Rack state** gains `"rack": 2`:

```json
{"rack": 2, "kind": "instrument",
 "macros": [{"name": "DRIVE", "value": 0.4}, …],
 "chain": 0,
 "lanes": [{"name": "CLEAN", "on": true, "solo": false, "level": 0, "pan": 0,
            "key": [0, 127], "vel": [1, 127], "select": [0, 127],
            "transpose": 0, "poly": 0,
            "instrument": {"machine": "guitar", "params": {…}, "preset": "twin-humbucker"},
            "effects": [{"machine": "amp2", "uid": 1, "params": {…}, "bypass": false}, …]}],
 "maps": [{"macro": 1, "lane": 0, "slot": 1, "control": "amp-gain",
           "min": 2.0, "max": 7.5, "formula": "x^2"}]}
```

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

```python
from slabkit import Song, fx, rack, lane, macro

rig = rack(
    lanes=[lane("CLEAN", "guitar", "twin-humbucker",
                fx=[fx("amp2", "guitar-clean"), fx("delay2", "slapback"), fx("verb2", "chamber")])],
    macros=[macro("DRIVE", 0.3, maps=[("CLEAN.1:amp-gain", 2, 7.5, "x^2"),
                                      ("CLEAN.1:amp-level", 0.8, 0.5)])])
t = song.track("GTR", rig)               # or song.track("GTR", "rack", "fretwire-clean-rig")
t.automate("rk-m1", {"chorus": (0.3, 0.8)})
```

`describe.zig` lists the rack, its controls and its presets, so
`slab --describe` and the machine database see it.

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
   - The panel lists a lane's inserts (ON, remove, + FX) and shows the
     picked machine's panel, until phase 4's.
   - Tests: a first-form project renders byte-identical; a one-lane FX
     Rack equals its insert sample for sample; a dry lane is held to a
     latent one.
3. **Macros.**
   - Rack controls `rk-m1..8` and `rk-chain`; mappings, the formula
     compiler and its VM; the `set_mod` host input in `fy_raw_machine`.
   - Tests cover formula parsing and evaluation, and a macro sweep
     matching the same sweep made with automation.
4. **UI.** The macro block, the lane list and zones, the inline lane
   chain, collapse, MAP mode and the mapping table, and ⌘G group and
   ungroup.
5. **Rigs.**
   - Factory rack presets, the RACKS section of the picker, and the
     slabkit `rack/lane/macro` builders with `describe`.
   - Docs: this file moves from proposal to reference, plus docs/19,
     docs/20, docs/22 and CHANGELOG.
6. **Inner automation.** Target paths, AutoView paths, and moving lanes
   on group.

## Open choices

These are my defaults. Each is worth a word before phase 3.

- **8 macros.** Live 12 allows up to 16. Eight fits two rows at the large
  tier and has been enough for Live rigs for a decade.
- **Formulas stay this small.** There are no conditionals or state, so
  there are no LFOs inside formulas. Modulation sources belong in their
  own machines.
- **Lanes render serially.** Lanes on the render pool can come later, if
  a rig needs it.
