# 04 — Block contract

Every machine's `process` word takes exactly one argument: a pointer
to a `MachineCtx` struct. The host builds this struct once per
machine per block, then calls the machine. The machine reads inputs,
writes outputs, reads params, emits events, whatever — all via
pointers in ctx.

## MachineCtx layout

```zig
pub const MachineCtx = extern struct {
    // Block parameters
    sample_rate:       f64,        // 48000.0 typically
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

Machines that hold to this run parallel-safely, render
offline-identically to realtime, unit-test cleanly, and hot-reload
without drama.
