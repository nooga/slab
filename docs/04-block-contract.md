# 04 — Block contract

## Kernel ABI (implemented, 2026-09-26)

This is how the host calls a machine's fy entry words today; docs/17
Track B. The `MachineCtx` below is the host-side `Machine` interface
contract, and the Zig adapter (`src/machines/fy_raw_machine.zig`)
translates it into this kernel ABI.

**Signatures.** Every entry word takes the same three pointers. Render
words take one more, leading:

| hook | signature | called |
|---|---|---|
| `render` | `( io ctx state params -- )` | per sample, repeated; `io` advances by `Io.size` |
| `note-on` / `note-off` | `( ctx state params -- )` | per event, on the allocated voice |
| `prepare` | `( ctx state params -- )` | every block, once per state region |
| `block-prepare` | `( ctx state params -- )` | every block, once (region 0) |
| `derive` | `( ctx state params -- )` | every block, before block-prepare |
| `render-lite` | `( io ctx state params -- )` | effects and voices: instead of `render`, for a block where the params f64 at its selector offset is exactly 0 |
| `control` | `( ctx state params -- )` | voices: every *period* samples of each voice, counted from its note-on, before the render that follows |

`render-lite` (manifest `"word" offset render-lite!`) lets a stage that
does nothing at one setting skip its cost: the host checks the selector
after block-prepare, so it can be a derived param, and a knob glide
snaps to its target, so turning the knob to 0 gets there. The word must
produce the same output as `render` at that setting; bus2's COLOR 0 is
the case (bit-exact against its goldens). On a voice machine it picks
the word for every voice's pass: FM-86's render is the DX7 chip model,
and its ENGINE 0 (MODERN) selects the msfa word as the lite one.

`control!` (manifest `"word" period control!`) gives a voice machine a
control rate that doesn't depend on the host's block size. The host
slices each voice's render at every *period*-th sample of that voice
and calls the word there; note-on resets the count, so the first call
comes before the note's first sample. The render word then runs only
the per-sample path. FM-86 uses it with period 64, which is msfa's N:
envelopes, LFO and pitch EG step per block, and each operator's gain
ramps linearly across it.

`key-flag!` (manifest `offset key-flag!`) names a params f64 the host
sets each block: 1.0 while a sidechain key is connected, 0.0 otherwise.
With `render-lite!` on the same offset, a machine runs a keyed word only
when keyed: multi2 splits the key through a second crossover then, and
runs its unkeyed word, at its old cost, the rest of the time.

`latency!` (manifest `offset latency!`) names the params f64 holding the
machine's latency in samples, how much later its output is than its
input, which its derive or block-prepare word keeps current. The host
reads it each block for delay compensation (docs/07 §PDC), and a reset
re-derives params so the value holds through one. limiter2 reports its
lookahead (rounded up: its ring reads a whole sample), sat2 and funk
their 4x oversampler's 5 samples (`OS4-LATENCY`, sat2 only while MIX is
up).

**Structs.** Both are defined in `kernels/00-primitives/ctx.fy`, mirrored
by `KernelCtx` / `IoFrame` in the adapter, and checked by the test
"kernel ABI: KernelCtx and IoFrame match ctx.fy".

- `Ctx` has one of each per machine instance, refreshed before each
  call:

  | field | meaning |
  |---|---|
  | `sr`, `inv-sr` | sample rate and its inverse |
  | `tempo` | bpm |
  | `beat` | quarter-note position at block start |
  | `frames` | frames in this block |
  | `chan` | region index: voice index for voice machines, 0 L / 1 R for effects |
  | `hz`, `vel`, `pitch` | note-on data; `hz` is raw MIDI pitch for `note-pitch` machines |
  | `data` | the derive-data pointer; read with `ctx Ctx.data-p p@64` |

- `Io` holds one sample's lanes: `out-l`, `out-r`, `in-l`, `in-r`,
  `det`. `out-l` is at offset 0, so a stage handed `io` can keep writing
  `out f!64`.

**Headroom.** The adapter hands kernel output to the host unclamped, as
f64 converted to f32 (D5). Only the master bus soft-clips.

**Lanes.**

- *Voices* accumulate into `io.out-l`; the host sums all voices and
  copies L to R.
- *Effects* run dual-mono: one pass per channel against that channel's
  state region. Each pass sees its own input in `in-l` and writes
  `out-l`. `det` is `max(|L|, |R|)` of the input, the stereo-linked
  detector for dynamics.

**Replaces.**

- The `channel-cell`, `tempo-cell`, and `detector-cell` manifest words
  (now `ctx.chan`, `ctx.tempo`, `io.det`).
- The note-on `hz velocity` arguments.
- The per-sample `effect-sample` mode, which called from Zig into fy
  twice per sample.

**Voice service (partial).**

- Voices start idle and wake on note-on.
- A released voice goes idle once its whole-block contribution to the
  out lane stays under −120 dBFS. Idle voices are not rendered at all.
- The host measures contribution by snapshotting `out-l` around each
  voice's pass, so it works for any machine without kernel changes.
- Allocation order: an idle voice, else the oldest released one, else
  steal the oldest held one.

Idle voices freeze their free-running state (oscillator phases, noise,
LFOs) rather than advancing it.

**Knob smoothing.**

- Each knob's *normalized* position glides to its target with a 20 ms
  one-pole, so exp-curve knobs sweep perceptually evenly.
- While any knob glides, the block renders in 32-sample sub-blocks, with
  params (and derive/block-prepare coefficients) re-synced between them.
  `prepare` still runs once per block. Steady knobs keep the single-pass
  path.
- UI drags glide (`setControlNorm`). Presets, project load, and host
  param sets snap (`setControlNormSnap`, via an atomic request the audio
  thread honors).
- A per-control time from the manifest (`smooth 10ms`) comes with the
  manifest DSL.

**Stereo.** The manifest word `stereo` changes both lanes:

- *Voices* accumulate into both `out-l` and `out-r`, and the host uses
  both.
- *Effects* get one true-stereo pass: region 0, both inputs in `in-l`
  and `in-r`, both outputs written.

Without the flag, the mono and dual-mono behavior above is unchanged.
The fixtures are `machines/raw_fixtures/stereo_voice.fy` and
`stereo_swap.fy`.

**Mono note stack.** Single-voice melodic machines keep a held-note
stack with last-note priority:

- Releasing a note that isn't sounding just forgets it.
- Releasing the sounding note falls back to the newest still-held note,
  as a note-on with `ctx.legato = 1`.

`ctx.legato` is also 1 for any note-on that arrives while the voice is
held, so a kernel can slide instead of retriggering. Before this, the
first note-off of any pitch released the voice.

**Still to do (docs/17 step 3):**

- the rest of the voice service (D6): glide and unison, which land
  with the mono bass synth and stereo pads (G4) that use them
- host buffers and tables addressed through ctx instead of injected into
  state

Every machine's `process` word takes exactly one argument: a pointer
to a `MachineCtx` struct. The host builds this struct once per
machine per block, then calls the machine. The machine reads inputs,
writes outputs, reads params, emits events, whatever — all via
pointers in ctx.

## MachineCtx layout

```zig
pub const MachineCtx = extern struct {
    // Block parameters
    sample_rate:       f64,        // effective processing rate for this call
    block_size:        u32,        // samples in this block (64..1024)
    block_start:       u64,        // global sample count at block start
    tempo_bpm:         f64,        // host tempo (automatable)
    ppq_position:      f64,        // pulses-per-quarter position at block_start
    transport_state:   u32,        // 0=stopped 1=playing 2=recording
    _pad0:             u32,

    // Audio ports (pointers to stereo-interleaved f32 in block arena)
    audio_in:          [*]const [*]const f32,   // audio_in[port_idx][channel_idx][sample_idx]
    audio_in_count:    u32,
    audio_out:         [*][*]f32,
    audio_out_count:   u32,
    _pad1:             u32,

    // Note ports
    note_in:           [*]const NoteEvent,
    note_in_count:     u32,
    note_out:          [*]NoteEvent,             // writable, bounded
    note_out_cap:      u32,                      // max events machine may emit
    note_out_count:    *u32,                     // machine writes this

    // CV (control-voltage / modulation) ports
    cv_in:             [*]const [*]const f32,
    cv_in_count:       u32,
    cv_out:            [*][*]f32,
    cv_out_count:      u32,

    // Params
    params_current:    *anyopaque,   // smoothed, stable over block
    params_per_sample: ?*anyopaque,  // optional sample-rate smoothed stream (null unless smooth-fast)

    // Persistent state (between blocks)
    persistent:        [*]u8,
    persistent_len:    u32,

    // Voice dispatch (null for non-poly machines)
    voice_pool:        ?*VoicePool,

    // Block-scoped scratch
    block_arena:       *BlockArena,

    // Asset pointers (stable, machine-specific)
    assets:            [*]const AssetSlot,
    assets_count:      u32,

    // Services
    services:          *HostServices,

    // Reserved for future expansion without breaking ABI
    _reserved:         [8]u64,
};
```

Stable `extern struct`. Matches fy's `struct:` so fy reads it directly.

`sample_rate` means the effective processing rate seen by this machine
call. At base rate this is usually 48000.0. Inside an oversampled
machine or island, it is `base_sample_rate * oversample_factor`.
Before the oversampler service lands, the ABI should promote reserved
space into explicit rate fields:

```zig
base_sample_rate:    f64,  // project/device rate
process_sample_rate: f64,  // effective rate for this process call
oversample_factor:   u32,
```

Do not design kernels that assume `sample_rate` remains the project
rate under oversampling. Oscillators, filters, envelopes, LFOs, delay
lines, and smoothing all need the effective processing rate.

Rules:

- The machine **reads** every input and **writes** every output it
  was asked to produce (by port count). Ports the machine didn't
  request aren't passed.
- Every pointer is valid for this block only. Storing any of them
  past `process` return is a bug. (`persistent`, `assets`, and
  `voice_pool` pointers *are* stable across blocks; the others
  aren't.)
- Audio buffers are **channel-planar, contiguous**: `audio_out[0]`
  gives a pointer to a `block_size` run of f32 for port 0 channel L;
  the next pointer is port 0 channel R. This is easier for SIMD than
  interleaved and matches what kernels want.

## Note event format

```zig
pub const NoteEvent = extern struct {
    // When within the block (0..block_size-1)
    sample_offset:     u32,

    // Kind
    kind:              u8,            // see below
    channel:           u8,             // 0..15
    _pad0:             u16,

    // Identity — note-on/note-off and MPE per-note messages
    // match by (channel, note_id). Note_id is assigned by the source.
    note_id:           i32,            // -1 for channel-wide messages

    // Primary value
    pitch:             f32,             // MIDI cents / 100 (fractional notes OK)
    velocity:          f32,             // 0..1

    // MPE expression — always present, default values when not used
    pressure:          f32,             // 0..1 (channel-pressure / aftertouch)
    slide:             f32,             // -1..1 (MPE slide / CC74)
    glide:             f32,             // -1..1 (pitch-bend normalized)

    // Extra payload (CC value, program change, etc.)
    value:             f32,
    param_index:       u32,             // CC number for kind=cc

    _reserved:         [2]u32,
};

pub const NoteKind = enum(u8) {
    note_on          = 0,
    note_off         = 1,
    note_hold        = 2,  // still pressed (rebroadcast for late subscribers)
    pressure         = 3,  // per-note aftertouch
    slide            = 4,  // MPE slide
    glide            = 5,  // per-note pitch bend
    cc               = 6,
    program_change   = 7,
    reset            = 8,  // all-notes-off / panic
};
```

Ten rules:

1. `note_id` is assigned by the source (piano roll, MIDI input,
   note-generator machine). Note-off matches to note-on by
   `(channel, note_id)`.
2. Pitch is **MIDI-cents / 100** — a float. Middle C is 60.0, a
   quarter-tone sharp is 60.5. This supports microtonality and
   bends natively.
3. `sample_offset` is **block-local**. Events cross block
   boundaries by being split at the boundary (host's responsibility)
   or by carrying over — the source decides.
4. Velocity is normalized to 0..1. Convert to dB or midi 0..127 at
   point of use.
5. MPE expression fields are **always present**, with neutral
   defaults (0.5 pressure, 0.0 slide, 0.0 glide) for non-MPE
   sources. Machines that don't care ignore them.
6. `note_hold` lets a machine attached mid-note see currently-held
   notes. The host emits these the first block after a machine is
   inserted into a live chain.
7. `reset` clears any held state. Machines must respect this (ring
   down voices, clear hold).
8. `note_out` is bounded. Machines must not write more than
   `note_out_cap` events. If they try, the host clamps; the warning
   is logged.
9. Events in `note_in` are sorted by `sample_offset` ascending.
   Machines may assume this.
10. Events in `note_out` should be written in sorted order. Host
    re-sorts if not, but it's cheaper for the machine to do it.

## Port model

Machine declares in manifest:

| field | meaning |
|---|---|
| `audio-in: N` | N stereo audio input ports |
| `audio-out: N` | N stereo audio output ports |
| `note-in: N` | N note input streams (typically 0 or 1) |
| `note-out: N` | N note output streams |
| `cv-in: N` | N control-voltage modulation inputs |
| `cv-out: N` | N CV outputs (LFOs, envelope followers, etc.) |

Ports are **kinded**, not positional in some mega-list: host routes
typed ports appropriately. A `note-out` from an arp connects to the
`note-in` of a synth; a `cv-out` from an LFO connects to a
`params:cutoff` modulation slot.

## Sample accuracy

The host computes `block_start = global_sample_counter` before every
block. Transport state is consistent across all machines in a block.
A machine that emits a note event at `ppq = 1.0` computes:

```
target_sample = (ppq - ppq_position) * samples_per_ppq
sample_offset = target_sample if target_sample in [0, block_size)
```

If the event falls in a future block, the machine holds it (in its
persistent state) and emits it then. This is the standard "lookahead
and schedule" pattern.

## Block size

Not fixed. Host may call with any `block_size` in
`[MIN_BLOCK..MAX_BLOCK]` (say 32..1024). Machines must not assume a
specific size. Kernels should handle any size via the `vec-each`
combinator (which does the 4-wide main loop + scalar tail).

Recommendation: target 64–128 as the common case. Smaller = lower
latency but more per-block overhead; larger = higher latency but
less overhead. Configurable project-level.

## Transport interaction

`transport_state` is the state at `block_start`. If the transport
transitions mid-block (play → stop at sample 37), the host splits the
block at 37: one block of 37 samples with `.playing`, one block of
(N-37) samples with `.stopped`. Machines always see a homogeneous
transport state within a block.

`ppq_position` is the beat position at `block_start`. To find the
beat at sample offset `k`:

```
beat_at_k = ppq_position + k * (tempo_bpm / 60.0) / sample_rate
```

Tempo changes: `tempo_bpm` is the tempo at `block_start`. For tempo
ramps the host splits the block at the ramp endpoints, same pattern.

## Idle skipping (implemented, 2026-09-30)

An optimization: the host stops rendering an instrument or effect that
has gone silent and has nothing coming, and feeds the rest of the chain
silence in its place. A track with no notes in a section used to cost
~1.8% of a core, and a sat2 fed silence ~6.5%, because every machine
rendered every block. The same logic as the voice service's idle voices
(docs/17 D6), one level up: whole machines instead of voices.

**The toggle.** `Engine.idle_skip` (src/engine.zig), on by default. Off
renders every machine every block, the way the engine worked before. On
the command line, `slab --no-idle-skip` turns it off for the app and for
`--render` bounces, so you can A/B the timing or the audio. With it off,
renders are bit-exact with the old engine.

**The rules** (`Engine.renderChunk`, `renderEffectsKeyed`):

- *Silence* is a block peak at or under `IDLE_FLOOR`, 1e-6 (−120 dBFS).
- *Instrument.* Skipped when no note event reaches it this block, no
  note sounds in the clips from the block's start to 0.1 s past its end
  (`IDLE_WAKE_AHEAD_S`), and its output has been silent for its hold.
  It wakes 0.1 s ahead of its next note, so its smoothed controls (20 ms,
  docs/22) settle on the automation before the note. It also wakes on any
  event: note-offs after a seek, CCs, expression.
- *Effect.* Skipped when its input, and its sidechain key if it has one,
  is silent and its input and output have both been silent for its hold.
  It wakes on the first block whose input isn't silent, and it renders
  that block. While the track's instrument is awake for a note, every
  effect on the track renders too, so the chain also sees the automation
  before the note arrives.
- *Control edit.* Turning a knob, loading a preset or setting a param
  from a project (`Machine.take_wake`, FyRawMachine's `wake_req`) restarts
  the machine's hold, so a sleeping machine renders on until the edit has
  glided into its params and block-prepare has derived from it.
- *Hold* (`Machine.idleHold`): at least `IDLE_HOLD_S` (0.25 s), or the
  machine's latency plus its tail if that is longer.
- The master chain follows the effect rules. Buses follow them too: a bus
  has no instrument, so its input is the only thing that wakes it.

**Tail.** `Machine.tail` gives the longest the output can stay silent
while the machine still holds sound it will play without new input. A
delay's echo is the obvious case: a long gap, then the repeat. fy
machines get the tail from the manifest automatically: it is the longest
host buffer (`buffer`, e.g. delay2's 3.1 s rings and verb2's 2.37 s tank)
plus `tail!` seconds. Declare `tail!` only for stored sound the buffers
don't already cover. `-1.0 tail!` (`TAIL_FOREVER`) means never skip the
machine: use it for one that makes sound from nothing, like a noise bed
or a self-oscillating drone with no notes. A machine that holds sound
without declaring it gets cut. The engine test "sound an effect keeps
past its silent output" shows this with an echo.

**What a sleeping machine misses.** It isn't called, so time stops for
it. Free-running phases (LFOs, era's sample-and-hold clock) resume
where they stopped, not where they would have been. So a render with
the skip on can differ from one with it off, while both are valid.
For example, era on a drum track shifts its decimation grid after every
gap: −32 dBFS of difference in aliasing on songs/sweat_geometry. With
era excluded, the rest of that song matches to −138 dBFS. Automation
moving while a machine sleeps is picked up when it wakes (the 0.1 s
wake-ahead covers instruments). A hot-patch to a sleeping machine runs
at its next wake. For a new version meant to sound from silence, turn
the toggle off or declare `-1.0 tail!`.

**PDC** (docs/07) is unchanged. A skipped machine's latency still counts
toward its track's, every tap history is written every block (silence
from a skipped chain), and the hold covers latency, so a lookahead line
is empty before its machine sleeps and delays correctly when it wakes.

**Audio thread.** Only plain counters, no allocation or locks:
`Track.inst_quiet`, `Effect.quiet`, and samples of silence (saturating).
Replacing a machine resets its counter.

## Why one ctx pointer and not varargs

- Stable ABI surface. Adding a field at the end (in `_reserved`)
  is backwards compatible.
- fy reads struct fields cheaply (already has `struct:` accessors).
  Stack-shuffling N pointers every block is more overhead than one
  load.
- Machines that need more can add a service via `ctx.services` —
  a pointer to a table of extension functions — without changing
  the call signature.

## Summary of what machines promise

- `process(ctx)` is a pure function of `(ctx, persistent memory)`.
- No hidden global state, no thread-locals, no allocations.
- Respect `block_size`; respect `note_out_cap`.
- Don't store pointers past return.
- Don't touch anything outside `ctx` and the ranges it points to.
- Silent output with no input means nothing is coming, unless the
  machine declares a tail (see Idle skipping).

Machines that hold to this run parallel-safely, render
offline-identically to realtime, unit-test cleanly, and hot-reload
without drama.
