# 02 — Machines

A machine is the unit of extension. Everything that makes sound,
transforms notes, analyses audio, or draws a custom panel is a
machine. The host provides the frame; machines provide the content.

## On disk

A machine is a directory. Minimum contents:

```
machines/instrument/tal-u-no/
├── machine.fy          manifest + wiring (required)
├── params.struct       params struct layout (required)
├── panel.fy            UI words (required)
├── dsp.fy              process word + kernels (required)
├── presets/            *.preset files (optional)
└── assets/             wavetables, samples, IRs (optional)
```

**Presets (implemented):** one file per preset at
`machines/<name>/presets/<preset>.preset` — plain `id|value` lines keyed
by the manifest's stable control ids, values in real units (Hz, seconds;
switches store the option index) so retuning a knob range never moves a
saved sound. Factory presets are checked-in files; "Save preset" in the
titlebar chip writes `user-N.preset` to the same directory. The picker
menus and apply-by-index share one contract: the directory scan is
sorted by name.

Kind is inferred from the parent directory: `instrument/`,
`effect/`, `note/` (transformers / generators), `utility/`
(meters, analyzers). Kind controls the default port configuration
and where the machine appears in the browser.

## The manifest

`machine.fy` is fy source that, when loaded, registers the machine
with the host. It uses a `machine:` compile-time directive analogous
to `struct:`/`callback:`:

```forth
( tal-u-no — brutalist recreation of a classic Juno-ish synth )

include "params.struct"        ( defines UnoParams struct )
include "panel.fy"             ( defines uno-draw, uno-events )
include "dsp.fy"               ( defines uno-process )

machine: tal-u-no
  category:    instrument
  version:     1

  params:      UnoParams          ( extern struct layout )
  voice-count: 8
  voice-state: UnoVoice           ( extern struct, per voice )

  persistent-scratch: 4096        ( bytes — delay lines, etc. )
  block-scratch:      2048        ( bytes — intermediate bufs )

  ports:
    audio-in:   0
    audio-out:  2                 ( stereo )
    note-in:    1
    note-out:   0
    cv-in:      0
    cv-out:     0

  latency:     0                  ( samples — for PDC )
  oversample:  2                  ( host wraps process in 2× )

  panel:       \uno-draw \uno-events
  dsp:         \uno-process
;
```

The `machine:` directive:

1. Reads the manifest fields into a Zig `MachineDecl` struct.
2. Registers the declaration with the host's machine registry.
3. Emits nothing to the code stream — it's purely declarative.

Declarations are keyed by `category:name` (e.g. `instrument:tal-u-no`).
Loading a manifest twice with the same key replaces the declaration
and hot-re-instantiates existing instances where possible.

## Authoring DSL direction

Machine authors should not juggle raw cells for ordinary machine
structure. The DSL should let a machine declare its host-visible
surfaces once:

- Params and defaults.
- UI control hints.
- Smoothing policy.
- Persistent buffers and state.
- Voice state.
- Assets.
- Ports, latency, and oversampling.
- Test fixture scaffolds for the DSP workbench.

Sketch:

```forth
params: TapeParams
  knob input      f32 default 0.0  range -24.0 24.0 unit "dB" smooth 5ms
  knob drive      f32 default 0.4  range 0.0 1.0
  knob tone       f32 default 0.5  range 0.0 1.0
  knob wow        f32 default 0.1  range 0.0 1.0
  knob flutter    f32 default 0.05 range 0.0 1.0
  toggle hiss     bool default false raw
;

buffers: TapeBuffers
  delay wow-delay samples 4096 interp cubic
  state hf-loss-state f32 2
;

machine: tape-sat
  category: effect
  params: TapeParams
  buffers: TapeBuffers
  audio-in: 1
  audio-out: 1
  oversample: 4
  panel: auto-panel
  dsp: tape-process
;
```

The generated host metadata should include extern layout, default
values, UI binding, smoothing tables, modulation eligibility,
persistent/block scratch sizing, and a starting test fixture. Custom
panels remain important, but an `auto-panel` path makes a new kernel
playable and testable immediately.

## Lifecycle

```
    (host scans machines/)
            │
            ▼
    ┌─────────────────┐
    │   DECLARED      │   manifest parsed, params struct known,
    │                 │   assets validated; no memory yet
    └─────────────────┘
            │
            │  user adds an instance to a track
            ▼
    ┌─────────────────┐
    │   INSTANTIATED  │   persistent arena allocated, params
    │                 │   initialized to defaults, panel ready
    └─────────────────┘
            │
            │  audio start
            ▼
    ┌─────────────────┐
    │   RUNNING       │   receiving ctx every block,
    │                 │   process called on audio thread
    └─────────────────┘
            │
            │  user removes / project closes
            ▼
    ┌─────────────────┐
    │   RETIRED       │   arena returned to host pool,
    │                 │   voice pool slots freed
    └─────────────────┘
```

## Params: the ABI contract

`params.struct` defines the machine's control-facing state using fy's
existing `struct:` (C-compatible, matches Zig `extern struct`):

```forth
struct: UnoParams
  f32 cutoff         ( 20..20000 Hz    )
  f32 resonance      ( 0..1            )
  f32 env-amt        ( -1..1           )
  f32 drive          ( 0..1            )
  f32 lfo-rate       ( 0.01..20 Hz    )
  f32 lfo-depth      ( 0..1            )
  f32 glide          ( 0..1 s         )
  f32 volume         ( 0..1            )
  i32 waveform       ( 0=saw 1=pulse ) ( enum )
  i32 voices         ( 1..8, unison    )
;
```

This struct is the versioning surface:

- **Add a field at the end** → compatible hot-reload. Existing
  instances keep their prior values; the new field gets its default.
- **Reorder / rename / change type / remove** → breaking. Existing
  instances cannot hot-reload cleanly. The host refuses and requires
  a cold reinstantiate from the machine's default params.

The version number in the manifest bumps when a breaking change is
made. Presets saved under older versions migrate via per-machine
migration words (optional).

Smoothed reads happen via host-inserted accessors. From fy's side:

```forth
p params:cutoff@        ( returns the smoothed f32 )
0.7 p params:cutoff!    ( writes pending; smoothed-in over ~20ms )
```

The `params:` prefix is generated from the struct name. Accessors
apply smoothing automatically for f32 fields unless the field is
annotated `raw`:

```forth
struct: UnoParams
  f32 cutoff
  raw i32 waveform       ( instant — no crossfade )
;
```

Discrete changes (waveform switch) aren't smoothed; they take effect
at the next block boundary.

## Voice state

If the manifest declares `voice-state: UnoVoice`, the host allocates
`voice-count × sizeof(UnoVoice)` bytes at instantiate time and owns
the slab. The `voice-each` combinator (see [05-kernels.md](05-kernels.md))
hands each voice's slot to the machine's voice body.

```forth
struct: UnoVoice
  f64 phase
  f64 freq
  f64 env
  i32 stage          ( ADSR stage machine )
  f64 glide-target
  f64 glide-cur
  ( ... filter state, lfo phase, etc ... )
;
```

The machine never allocates voice state itself. It receives a pointer.

## Panel

See [06-ui-widgets.md](06-ui-widgets.md) for details. Two words:

```forth
: uno-draw ( ctx rect -- )
  ( draws into the given rect using widget library; reads params )
;

: uno-events ( ctx event -- )
  ( handles pointer/key events; writes pending params )
;
```

`ctx` here is a **UI-thread** context, not the audio ctx. It carries:
a pointer to the machine's instance handle, the current smoothed
params (for display), the pending params (for writes), a widget draw
list, and event routing helpers.

## DSP

```forth
dsp: uno-process ( ctx -- )
  ( see 05-kernels.md for the full pattern )
  [ | vctx | ctx vctx uno-voice ] ctx voice-each
;
```

`ctx` here is the **audio-thread** context
([04-block-contract.md](04-block-contract.md)). It contains
everything the machine needs for one block: input/output buffers,
note events for the block window, smoothed param pointer, block
arena, voice pool handle, tempo/transport state, block size, sample
rate, and a pointer to the machine's persistent arena.

## Asset loading

Assets in `assets/` are memory-mapped read-only at instantiate time
and exposed to the machine as `(ptr, length)` pairs via named
manifest entries:

```
  assets:
    wavetable: assets/tal-wavetable.bin
    ir:        assets/cabinet-ir.wav
```

From fy:

```forth
ctx asset:wavetable@    ( ( ptr len ) — pushes both )
```

Mapped pages are shared across instances of the same machine and
unmapped only when the last instance retires.

## Machine authoring flow

1. `slab new-machine instrument tal-u-no` — scaffolds the
   directory with stub files.
2. Edit `params.struct`, `panel.fy`, `dsp.fy` in VSCode.
3. Slab auto-loads changes: files are watched; any save
   triggers `fy_patch_word` for affected words via the existing
   hot-patch path.
4. Panel redraws on the next frame. Audio picks up DSP changes on the
   next block.
5. Commit to git when happy. The machine is its own source tree.

## Sharing machines

Machines are just directories. Put them in a git repo, zip them, drop
them in `~/Library/Application Support/slab/machines/`. A future
registry could index public machines and let users search/install
from within the app, but the format doesn't need anything fancy — it's
text files plus a few binary assets.
