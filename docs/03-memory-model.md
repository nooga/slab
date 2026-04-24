# 03 — Memory model

The rule: **no allocation on the audio thread, ever.** The audio
thread sees only pre-allocated memory owned by the host. fy's GC heap
exists (UI thread, panels, compile-time machinery) but is not
reachable from `dsp:` code by construction.

## Four arenas

All host-owned. All allocated up front.

### Block arena

One per audio-processing thread (one, initially).

- **Size:** `sum over machines of block-scratch` × fudge factor (1.5×).
  Sized at project load / graph rebuild time.
- **Allocator:** bump pointer. `alloc(n, align)` returns the next
  aligned slot; `reset()` zeroes the pointer back to base.
- **Reset:** every audio block, before any machine runs.
- **Use:** intermediate buffers, FFT scratch, per-block temporary
  voice sums, any data that doesn't survive the block.

Hot in cache, zero-cost alloc, zero-cost free. The canonical example:
a pipeline stage needs an intermediate buffer for its 64-sample
output — grab a block arena slot at the top of `process`, write
through it, forget about it. The next block starts from a clean
pointer. No fragmentation ever.

### Machine persistent arena

One per machine instance.

- **Size:** `persistent-scratch` from manifest + `sizeof(params) × 2`
  (double buffer) + smoother state + machine registration overhead.
- **Allocator:** user-facing bump with optional sub-allocators;
  host-side this is just a flat region.
- **Reset:** never, unless the machine is retired.
- **Use:** params struct (pending + smoothed), param smoother state,
  delay lines, reverb tails, IIR filter state, any between-block
  memory.

Serializable: a preset is essentially `memcpy(slice_of_this_arena)`
plus a manifest reference. See [08-services.md](08-services.md#preset-system).

### Voice arena

One per machine instance, when the manifest declares a voice state.

- **Size:** `voice-count × sizeof(voice-state)`, plus a small header
  for voice pool bookkeeping.
- **Allocator:** slab-indexed. Voice `i` is at
  `base + i × sizeof(voice-state)`. The host's `VoicePool` service
  tracks which slots are free/active.
- **Reset:** when a voice is retired (note-off tail completes), its
  slab is zeroed and returned to the free list.
- **Use:** per-voice phase, envelopes, filter state.

The machine doesn't call into this arena directly — it receives a
`vctx.voice_state` pointer from the `voice-each` combinator pointing
at the current voice's slab.

### Asset map

Memory-mapped read-only pages, shared across instances.

- **Size:** whatever the asset file is.
- **Allocator:** `mmap(..., PROT_READ, MAP_PRIVATE | MAP_FILE, ...)`.
- **Reset:** unmapped when the last instance referencing the asset
  retires.
- **Use:** wavetables, samples, IRs. Never written. Auditable.

Same physical page backs every instance referring to the same file.
Loading ten instances of a sampler with the same library costs one
copy of the library.

## Double-buffered params

The params struct lives in the persistent arena **twice**:

```
persistent_arena:
  ┌──────────────────────────┐
  │ params_a (UnoParams)     │   ← UI may be writing here (pending)
  ├──────────────────────────┤
  │ params_b (UnoParams)     │   ← audio is reading here (current)
  ├──────────────────────────┤
  │ smoother_state           │   ← one f32 per smoothed field
  ├──────────────────────────┤
  │ ... delay lines, etc.    │
  └──────────────────────────┘
```

Plus two atomic pointers (`current_ptr`, `pending_ptr`) and a "dirty"
flag.

**Write path (UI thread):**
1. UI reads `pending_ptr`, writes field(s).
2. Marks `dirty = true`.

**Read path (audio thread), start of each block:**
1. If `dirty`, atomically swap `current_ptr` and `pending_ptr`,
   `memcpy` the new "current" into the old "pending" (so pending
   starts from the current state), clear `dirty`.
2. Advance smoother toward `pending_ptr`'s values for the next
   block's worth of samples.

This gives: lock-free, torn-write-tolerant, O(params_size) per block
in the worst case (typically <1kB → irrelevant).

## Smoothing

Every f32 param (unless `raw`) gets a one-pole smoother. The smoother
state is a single f32 per param (the current smoothed value).

At block start, the host computes per-sample or per-block coefficients
based on target time (default 20ms) and either:

- **Block-rate smoothing (cheap):** one update per block; machines
  read a constant over the block. Good enough for low-rate controls
  (volume, pan, static filter cutoff). Some zipper on very fast
  automation.
- **Sample-rate smoothing (thorough):** the smoother runs per sample
  inside the machine via `params:cutoff@` expanding to a per-sample
  read. Needed for anything audible under automation.

Default: block-rate. Fields annotated `smooth-fast` in the struct:

```forth
struct: UnoParams
  smooth-fast f32 cutoff    ( gets per-sample smoothing )
  f32 volume                ( block-rate is fine )
;
```

## Alignment

Audio buffers: **16-byte aligned** minimum (NEON `.4s` width). The
block arena rounds allocations up to 16 bytes.

For cache-line hot data (hot inner-loop voice state), round to **64
bytes**. The voice arena can optionally pad voice slabs to 64 —
modest waste, measurable on heavy polyphony.

## Why not just use `std.heap.ArenaAllocator`?

It's a fine starting point. The audio-thread-safe constraint means
the block arena needs a lock-free bump-pointer (not the multi-thread
wrap std ships with); the voice arena needs slab indexing; the asset
map needs file-backed mmap. All three are 30-line custom allocators.

The std interface (`Allocator`) can still be used for ergonomics — a
thin wrapper exposing the block arena as an `Allocator` whose
`resize`/`free` are no-ops works fine, as long as nothing on the
audio thread ever touches the `Allocator` vtable indirectly (through
`std.ArrayList` or similar). Rule: audio thread uses the bare bump
API, not the `Allocator` interface.

## Fragmentation strategy: none needed

Because arenas don't deallocate inside their lifetime, fragmentation
cannot happen. The only sizes that change at runtime are:

- Voice pool: fixed slab count, bump-free-list within.
- Persistent arena per instance: fixed at instantiation.
- Block arena: reset every block.
- Asset map: mmap, whole-file.

A session can grow (more machines added, bigger graph) — each new
machine gets a new persistent arena allocation from the host's general
allocator. The audio thread never sees this because it happens between
blocks, through a graph-swap protocol (see
[07-transport.md](07-transport.md#graph-swap)).

## The NoGC invariant

The audio thread invariant:

> No code on the audio thread touches fy's GC heap.

Enforced three ways:

1. **Compile-time:** `dsp:` mode forbids any primitive that touches
   the heap. No `qnil`, no string literals, no `map`/`reduce`/
   `filter`/`each`, no quote allocation, no `alloc`. The list of
   allowed primitives is explicit
   (see [05-kernels.md](05-kernels.md#dsp-mode-language-subset)).
2. **Runtime:** `dsp:` words entered with heap lock held (debug
   builds). Any attempt to mutate the heap trips an assert.
3. **Structural:** the audio callback never calls a non-`dsp:` word.
   The host dispatch functions are Zig; they call `dsp:` word
   trampolines only.

Break this invariant and you get audio glitches that are reproducible
only under memory pressure. Don't break it.

## Total session footprint

Back-of-envelope for a busy session:

| thing | size |
|---|---|
| 20 machines × 8kB persistent | 160 kB |
| 10 polyphonic voice arenas × 16 voices × 256B | 40 kB |
| Block arena | 256 kB |
| Asset maps (wavetables, samples) | 10–200 MB mmap'd (shared) |
| fy GC heap (UI thread, panels) | 1–5 MB |
| Host arrays (events, UI state, etc.) | 5 MB |

Low 10s of MB for the moving parts. The sample/wavetable assets
dominate, and they're shared-page mmap — free once loaded.
