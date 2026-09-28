# 08 — Host services

Things the host provides to machines so every machine author isn't
reimplementing them (badly). Each service lives in Zig, is reachable
from fy via `bind:` or via pointers on `ctx.services`, and is
designed to be trivial to use in the common case.

## HostServices table

A single `*HostServices` pointer is passed to every machine in its
ctx. It's a table of function pointers and singleton handles:

```zig
pub const HostServices = extern struct {
    voice_pool:       *const VoicePoolVtable,
    param_smoother:   *const ParamSmootherVtable,
    oversampler:      *const OversamplerVtable,
    mod_matrix:       *const ModMatrixVtable,
    preset_manager:   *const PresetVtable,
    latency_reporter: *const LatencyVtable,
    stft:             *const STFTVtable,
    logger:           *const LoggerVtable,
    _reserved:        [8]*const anyopaque,
};
```

Vtables not values — keeps the struct stable and allows swapping
implementations (e.g. a debug voice pool vs. a ship voice pool).

## 1. Voice pool

Handles note-on/off matching, voice stealing, release tails,
unison spawning. If a machine declares `voice-count` and
`voice-state` in its manifest, the host pre-allocates the voice
slab and gives the machine a `VoicePool` handle.

### API (fy-facing)

```forth
( inside a dsp: process word )
ctx voice-each [ | vctx |
  ( vctx is a VoiceCtx — see below )
  vctx phase
  vctx freq polyblep-saw
  vctx env f*
] ( voice-each handles note dispatch and accumulation )
```

### VoiceCtx

```zig
pub const VoiceCtx = extern struct {
    voice_id:        u32,
    note_id:         i32,

    // Per-voice values from the note event that spawned this voice
    pitch:           f32,     // MIDI cents / 100
    velocity:        f32,
    channel:         u8,
    _pad0:           [3]u8,

    // MPE continuous expression, updated per-block by voice pool
    pressure:        f32,
    slide:           f32,
    glide:           f32,

    // Envelope phase: the voice pool tracks gate edges
    gate:            u32,     // 1 = note held, 0 = released
    release_time:    u32,     // samples since release; 0 if still held

    // Pointer to the per-voice state slab (the machine's voice struct)
    state:           [*]u8,
    state_len:       u32,

    // Machine's output accumulator for this voice
    out:             [*][*]f32,
    out_count:       u32,
};
```

### Voice stealing

Configurable per machine via manifest:

```
  voice-steal: oldest-release | oldest | quietest | round-robin
```

Default: `oldest-release` (prefer voices already releasing).

### Unison

If the machine's params include a "unison" parameter, the manifest
can declare:

```
  unison-param:      voices         ( field name in params )
  unison-spread:     spread         ( detune amount )
```

The voice pool then spawns N voices per note-on, detunes them, and
distributes them stereo. The machine's voice body runs on each
unison voice like any other — it doesn't know unison exists.

## 2. Param smoother

Every f32 param in the machine's struct gets auto-smoothed unless
annotated `raw`. The smoother state is one f32 per smoothed param,
stored in the machine's persistent arena.

### Smoothing modes (per-field annotation)

- **none / raw:** no smoothing (discrete params)
- **block:** one smoother update per block (default; cheap)
- **sample:** per-sample smoothing (needed for audible fast
  automation)

The host advances smoothers before calling the machine's `process`.
The machine reads `ctx.params_current` which always points at the
smoothed "now" values. For sample-rate smoothed fields, the machine
reads `ctx.params_per_sample` for a per-sample stream of values (a
buffer of `block_size` floats per field).

Smoothing time defaults to 20ms, configurable per field:

```forth
struct: UnoParams
  smooth 5ms   f32 volume
  smooth 50ms  f32 cutoff
  raw          i32 waveform
;
```

### Why double-buffer + smooth

Double-buffer solves torn writes and enables lock-free swap. Smooth
solves zipper noise. Both are needed: double-buffer without smooth
still gets zippers; smooth without double-buffer races on writes.

## 3. Oversampler wrapper

Declared in manifest:

```
  oversample: 2     ( or 4, 8 — must be power of two )
```

When N > 1, the host:

1. Allocates 2× (or N×) sized buffers from the block arena for the
   machine's audio outputs and CV outputs.
2. Runs the machine's `process` with a modified ctx: `block_size
   * N`, buffers pointing at the oversized scratch.
3. Downsamples the outputs through a polyphase halfband filter
   cascade into the real output buffers.

Inputs are upsampled symmetrically — if the machine has audio
inputs, they're upsampled before the machine runs.

Latency introduced is reported to PDC automatically.

The machine should not have to manage resampler buffers, but it must be
rate-aware. Inside an oversampled call, oscillator phase increments,
filters, envelopes, LFOs, delay lengths, smoothing, and any time-based
kernel need the effective processing rate.

The ctx should therefore expose both rates:

```zig
base_sample_rate:    f64,  // project/device rate
process_sample_rate: f64,  // rate for this process call
oversample_factor:   u32,
```

`ctx.sample_rate` may remain as a compatibility alias, but its meaning
must be explicit. Prefer making it the effective process rate and using
`base_sample_rate` when a machine needs project-rate decisions. Fully
"transparent" oversampling where the block gets bigger but the reported
sample rate stays at the base rate will make generated oscillators,
modulators, filters, and delay lines wrong.

## 4. Modulation matrix

Any parameter can be modulated by any modulation source:
- Built-in LFOs
- Envelope followers
- CV outputs from other machines
- Velocity / pitch / pressure of the current voice
- External MIDI CC

The mod matrix is a **host** structure, not a per-machine
structure. Machines expose their params (the `params.struct`);
users in the UI drag a source onto a param, creating a mod
connection. The host applies it to the pending params struct
before the machine reads `params_current`.

Automation is not a mod source. It sets the param's value
([22-automation.md](22-automation.md)), and modulation adds on top of
whatever automation produced.

Modulation is **additive** over the param's base value, with a
per-connection amount. Multiple mods on the same param sum.

```
final_param = base_param + sum(source_value * amount for each mod)
```

(A non-linear mod curve is applied before the source_value if the
user configured one.)

Saved with the project; not per-preset (a preset is just the params
struct; mods are structural).

## 5. Preset system

A preset is:

```zig
pub const Preset = extern struct {
    magic:             [8]u8 = "WBPRESET".*,
    machine_key_hash:  u64,        // hash of "category:name@version"
    params_version:    u32,
    params_size:       u32,
    // Followed by params_size bytes of the params struct.
};
```

On save: `memcpy(preset_buf + sizeof(Preset), params_current,
params_size)`, write to disk. That's it.

On load: validate magic + machine_key_hash + version, `memcpy` into
pending, mark dirty. Audio picks up on next block (smoothly, via
smoother).

Version mismatches: machine can declare a migration word:

```forth
dsp: uno-migrate ( old-ptr old-version new-ptr -- )
  ( copy and convert fields; fill new fields with defaults )
;
```

Host calls it on load when version differs.

## 6. Latency reporter

Machine declares its static latency in the manifest. For machines
whose latency changes with params (e.g. a lookahead comp whose
lookahead is user-configurable), it can update dynamically:

```forth
ctx services latency:report ( ctx samples -- )
```

Host marks the graph dirty; on the next block-boundary the graph is
rebuilt with updated PDC.

Machines that never change latency just set it in the manifest and
forget.

## 7. STFT processor

Spectral machines don't write their own FFT loops. Instead:

```forth
dsp: spec-process ( ctx -- )
  ctx
  1024 512                      ( fft size, hop size )
  \hann-window                   ( window word — one of stock set )
  [ | bins nbins |
    ( machine's spectral body runs here, once per STFT frame )
    ( bins is [*]c64, nbins = fft_size/2 )
    0 nbins [ | i |
      bins i c64-nth
      ( modify bin... )
      bins i c64!
    ] dotimes
  ]
  stft-process
;
```

The combinator handles:
- Windowing
- Forward FFT (NEON-backed, pffft-class)
- Calling the user body
- Inverse FFT
- Overlap-add reconstruction
- State storage in persistent arena

Author writes spectral logic; never touches FFT or OLA.

## 8. Logger / debug

```forth
ctx services log: "cutoff: " cutoff f.s
```

UI thread reads an SPSC ring and displays in a console panel.
Audio-safe (lock-free, allocation-free, bounded).

## Service resolution from fy

A machine accesses services via the ctx pointer chain:

```forth
ctx services voice-pool:                     ( -> VoicePool handle )
ctx services param-smoother: cutoff 0.5      ( instant-write override )
ctx services preset-manager: recall 3        ( load preset 3 )
```

The `services:<name>:` prefix is a macro that emits the correct
`@64` chain through the ctx→services→vtable→fn_ptr path. Zero
overhead at runtime — resolves to a `BL` through the vtable slot.

## Things deliberately *not* a host service

- **Reverb/delay/chorus.** These are machines. The host doesn't
  ship them as services because they're not universally needed and
  users will iterate on them.
- **EQ.** Same — EQ is a machine.
- **Metering.** It's a machine (a utility-category one). The
  master meter in the transport bar is a host widget that reads
  from an SPSC ring fed by the final-mix stage, not a service.
- **MIDI I/O.** Handled by the transport + note event system;
  external MIDI sources are "virtual machines" at graph entry
  points.

## The rule

If N ≥ 3 machines would implement the same pattern identically, it
should be a service. If it's machine-specific character or
expression, it stays in the machine. The services above are things
every machine of their class needs; the line is crisp.
