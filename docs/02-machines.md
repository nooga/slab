# 02 — Machines

A machine is the unit of extension. Everything that makes sound,
transforms notes, analyses audio, or draws a custom panel is a
machine. The host provides the frame; machines provide the content.

## On disk

A machine is a directory under `machines/<id>/` holding one fy file
named after it, plus optional presets and assets:

```
machines/delay2/
├── delay2.fy       manifest word + includes (required)
├── presets/        *.preset files (optional)
└── assets/         samples, IRs, wavetables (optional)
```

The DSP doesn't live in the machine directory. It lives in the kernel
rig under `kernels/NN-layer/` (docs/13 §Kernel library as layers), and
the machine file `include`s it. So `machines/delay2/delay2.fy` includes
`kernels/07-effects/delay.fy` and `machines/lib/manifest.fy`, and holds
only the declaration. A machine is known to the app once its path is in
the list in `src/machine_registry.zig`. The id is the directory name.

**Presets (implemented):** one file per preset at
`machines/<name>/presets/<preset>.preset` — plain `id|value` lines keyed
by the manifest's stable control ids, values in real units (Hz, seconds;
switches store the option index) so retuning a knob range never moves a
saved sound. Factory presets are checked-in files; "Save preset" in the
titlebar chip writes `user-N.preset` to the same directory. The picker
menus and apply-by-index share one contract: the directory scan is
sorted by name.

**Host-allocated buffers (implemented):** a machine requests audio-rate
storage in its manifest instead of growing its state struct:

```forth
"dline" DelayState.buf DelayState.buf-len 1.6 buffer
```

At create, the host allocates `ceil(seconds × sample-rate)` zeroed f64
cells per channel (UI thread — never the audio thread) and writes the
base pointer and element count into that channel's state at the two
introspected offsets. Kernels read them back with `p@64` / `f@64` and
index with `f@i` / `f!i`. Reset memsets state, zeroes the buffers, and
re-injects the pointers. Dual-mono effect machines get per-channel state
regions, so L and R own independent rings. A `stereo` effect runs one
pass on region 0 and gets one copy of each buffer; one that needs a ring
per side declares two (delay2's `dline-l` / `dline-r`). Effects that
decorrelate channels read `ctx.chan` (0.0 L / 1.0 R): chorus2 inverts its
right LFO by it. The stereo-linked detector is `io.det`, the host's
per-sample `max(|L|,|R|)` of the input (or of the key, with `sidechain`).
Both channels reading it is what stereo-links comp2's gain.

**The asset arena (implemented):** the read-only sibling of host buffers.
A machine declares `"name" Params.ptr Params.len Params.sr "file.wav"
asset`; at create the host loads the WAV (src/wav.zig — PCM 8/16/24/32,
float 32/64, folded to f64 mono) from a path relative to the machine
directory and injects the base pointer, sample count, and native sample
rate into **params** (shared and read-only, so one copy serves every
voice — unlike buffers, which are per-channel and writable). Kernels read
it with `p@64` / `f@i`; an unloaded asset points at silence so a clamped
read is never out of bounds. The sampler is the first consumer (voice
pool + resampled playback); wavetable synths and convolution reverb use
the same mechanism. Re-injected after reset. This was the first concrete
instance
of the asset-arena idea in docs/03 — a read-only `asset` sibling for
samples/IRs/wavetables follows the same pointer-injection shape.

**Wavetables (implemented):** `"name" Params.ptr Params.frames "file.wav"
wavetable` loads a WAV in Serum's format: single-cycle frames of 2048
samples, or the size its `clm ` chunk gives; a shorter file is one
frame; up to 256 frames. The host (src/wavetable.zig) splits each frame
into its harmonics and rebuilds it at 11 octave levels, level m keeping
harmonics up to 1024 >> m, stored at 16 cells a harmonic. It writes the
table's pointer and frame count into params.
`kernels/01-oscillators/wavetable.fy` `wt-read` crossfades two frames
(the position) and two levels (picked from the phase increment so that
nothing folds back below ~19 kHz). LOAD on a `waveform-display` of the
asset swaps the file while playing. Concoction is the consumer
(`tools/wavetables/gen.py` writes its built-in bank).

## The manifest

The machine file defines a word called `manifest`. At load the host
compiles the file, calls `manifest`, and walks the `MachineDesc` it
returns (`src/machine_desc.zig`). The vocabulary is in
`machines/lib/manifest.fy`, and its header comment is the reference for
every word. Offsets always come from `ustruct` field introspection
(`GateParams.thresh-db`) and are never written as numbers.

```forth
include "../../kernels/07-effects/gate.fy"
include "../lib/manifest.fy"

: manifest
  "Gate" effect-block machine*          ( or voice-sample )
  "k-gate-tick"        render!          ( per-sample dsp: word )
  "gate-block-prepare" block-prepare!   ( once per block: derived params )
  GateState.size  state-size!
  GateParams.size params-size!
  260.0 panel-w!
  sidechain

  "GATE" "THRESH" "gate-thresh" GateParams.thresh-db -60.0 0.0 -40.0 curve-lin knob
  ( … more controls … )
  "GATE" 5 strip
  machine-desc
;
```

The two modes:

- **`effect-block`.** By default the effect is dual mono: the render word
  runs once per channel against that channel's own state (`ctx.chan` is
  0 for L and 1 for R) and reads `io.in-l`. The host runs both channels
  at once in NEON lanes (docs/05 §Lane mode). `stereo` switches to one
  true-stereo pass that reads `io.in-l`/`io.in-r` and writes both outputs.
- **`voice-sample`.** An instrument. `n voices!` gives a pool of `n`
  voices, and with no `voices!` the machine is mono. Each voice has its
  own state region, and the params are shared. `ctx.chan` is the voice
  index. The render word accumulates into `io.out-l`
  (and into `io.out-r` too, with `stereo`). `note-on!`, `note-off!`,
  `note-expr!` and `control!` hook the voice lifecycle. Pools with more
  than one voice render voices in pairs, one per lane.

The entry words and their stack effects are in docs/04 §Kernel ABI.
`prepare!` runs every block, not once. Other declarations:

| Word | What it declares | Doc |
|---|---|---|
| `knob`, `switch`/`opt`, `as-fader`, … | controls, with a stable id, a range, a default and a taper | docs/15 |
| `strip`, `row`, `cell`, `item`, `page` | the panel layout | docs/15 |
| `buffer` | host-allocated per-channel audio storage | below |
| `asset` | a host-loaded read-only WAV | below |
| `wavetable` | a host-loaded wavetable, band-limited into mip levels | below |
| `sidechain`, `key-flag!` | the detector can be keyed from another track | docs/23 |
| `offset latency!` | latency in samples, read from a params field | docs/04, docs/07 PDC |
| `seconds tail!` | stored sound beyond the buffers (`-1.0` = never idle-skip) | docs/04 §Idle skipping |
| `derive!`, `derive-data!` | a per-block word that computes derived params, and its data | docs/04 |
| `note-pitch`, `note-label` | raw MIDI pitch and named notes (drum machines) | docs/16 |
| `render-lite!` | a cheaper render word for blocks where one params field is 0 | legacy; prefer `ifte` (docs/05 §Branching) |

## Lifecycle

```
    (host loads the registry list)
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

## Params and state

Params and state are `ustruct`s of `f64` fields, declared in the kernel
file. Params are shared by every channel or voice. State belongs to one
channel or voice.

- Params hold the user-facing fields, which knobs write, and then the
  derived fields (coefficients, linear gains), which `block-prepare` or
  `derive` fills once per block from the user fields. Per-sample code
  reads only derived fields.
- The host smooths knob positions itself (20 ms, docs/08, docs/22) before
  mapping them to units and writing the field. The kernel sees a plain
  f64, and switches land at a block boundary.
- The control id (`"gate-thresh"`) is the save format: presets and
  projects store `id|value` in real units (docs/19). Renaming an id
  breaks saved sounds. Reordering struct fields doesn't.
- The machine never allocates. Voice state, channel state, buffers and
  assets are all host-owned regions handed in as pointers.

## DSP

The render word is a `dsp:` word, `( io ctx state params -- )`, called
once per sample by the host's repeated caller. The language is in
docs/18 and the kernel conventions are in docs/05. For a new machine:

- Build from the kernel layers (math.fy for dsp-std, the oscillator and
  filter primitives, `oversample.fy`) and don't hand-roll them.
- For modes and switches, put the code behind
  `params.x 1.0 f= [ … ] [ … ] ifte` so the untaken path costs nothing
  (docs/05 §Branching). Don't compute every mode and `select` between
  them.
- Keep dual-mono effects lane-friendly (docs/05 §Lane mode): no stack
  outputs, no stores into params, and no `call:` composition in the
  render word.
- Declare `tail!` if the machine keeps sound anywhere other than a
  `buffer`, or `-1.0 tail!` if it makes sound from silence
  (docs/04 §Idle skipping).

## Machine authoring flow

1. Write the kernel in `kernels/NN-layer/<name>.fy`, with its params and
   state `ustruct`s and its entry words.
2. Write `machines/<id>/<id>.fy`: includes plus `manifest`. Add the path
   to `src/machine_registry.zig`.
3. Check it headless with `zig build bench -- machines/<id>`. Read
   `scratch/bench/<id>/report.md` and the PNG sheets, run `--sweep=all`
   to check the knob response, and record goldens with `--record` once
   it's right (docs/13 §Bench v2).
4. Run `zig build test`. It covers the registry, the lanes/scalar
   bit-exactness check for effects, and descriptor loading.
5. Add factory presets under `machines/<id>/presets/`, then regenerate
   docs/20 with `tools/slabkit/gen_reference.py`.

Edits to machine sources take effect the next time the machine loads. Hot-patching a machine while it plays is the plan in
docs/09. Today the host's hot-patch server covers fy words, not the
machine files themselves.

## Sharing machines

Machines are just directories. Today they ship in the repo and load from
the registry list. Loading user machines from a folder (e.g.
`~/Library/Application Support/slab/machines/`) is planned. A future
registry could index public machines and let users search/install
from within the app, but the format doesn't need anything fancy — it's
text files plus a few binary assets.
