# 01 — Architecture

## The split

```
┌──────────────────────────────────────────────────────────────┐
│                      Slab (single binary)                    │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Zig host                                              │  │
│  │                                                        │  │
│  │  • Window, rendering (raylib), event loop              │  │
│  │  • Audio I/O (miniaudio), transport, mixer             │  │
│  │  • Timeline, piano roll, automation, mixer UI          │  │
│  │  • Widget library (1px bevel, knobs, meters, etc.)     │  │
│  │  • Services: voice pool, oversampler, param smoother,  │  │
│  │    mod matrix, preset system, PDC                      │  │
│  │  • Project save/load                                   │  │
│  │  • Arena allocators (block/persistent/voice/asset)     │  │
│  │  • Hot-patch TCP bridge (for VSCode)                   │  │
│  └────────────────────────────────────────────────────────┘  │
│                            │                                 │
│                            │ ctx (per block)                 │
│                            ▼                                 │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  fy runtime (linked in from ../fy/src)                 │  │
│  │                                                        │  │
│  │  • JIT compiler → ARM64 + NEON                         │  │
│  │  • Trampoline indirection for hot-patch                │  │
│  │  • GC heap (UI thread only)                            │  │
│  │  • dsp: mode (no heap, NEON, inlined combinators)      │  │
│  └────────────────────────────────────────────────────────┘  │
│                            │                                 │
│                            │ calls machine words             │
│                            ▼                                 │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Machines (fy source, loaded at runtime)               │  │
│  │                                                        │  │
│  │  instrument/tal-u-no/   effect/comp-basic/             │  │
│  │  effect/overdrive/      note/arp-basic/                │  │
│  │  generator/euclidean/   ...                            │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

Single process, single binary, one address space. Machines are
hot-loaded fy files, not plugins.

## Why embed fy rather than spawn it

fy is ~4k lines of Zig. The `Fy` struct in `../fy/src/main.zig` is
self-contained; the heap, JIT image, and userWords table are all
fields of one struct. Linking it into the host as a library gives us:

- Shared address space → machine memory and host buffers are already
  in the same process, no IPC, no copies.
- Direct Zig function calls → host services reachable from fy via
  `bind:`, fy words callable from Zig via cached trampoline pointers.
- One hot-patch TCP port → VSCode sees one thing.
- Native debugger covers both.

The cost is a sub-dependency: `build.zig` pulls in fy's source and
compiles it into the slab binary. fy's build would need a library
target added; manageable.

## Threads

Three threads, well-defined ownership:

| thread | owns | touches fy heap? |
|---|---|---|
| **main/UI** | window, events, UI state, transport commands, project | yes |
| **audio** | audio callback, machine `process` calls, final mix | **no** |
| **hot-patch** | TCP listener, compiling incoming word definitions | yes (under mutex) |

The audio thread never allocates on fy's heap. It calls `dsp:` words
which, by construction, cannot reach the heap. It calls non-`dsp:`
words *never* — no rendering from audio, no control-rate decisions,
no MIDI parsing.

The hot-patch thread compiles under a mutex shared with the main
thread. When a `dsp:` word's trampoline target is patched, the audio
thread picks up the new target on its next block (the
`pthread_jit_write_protect_np` dance plus `__clear_cache` handles the
W^X and icache invalidation — fy already does this).

## Control flow per block

1. Audio callback fires (miniaudio): `n` frames requested.
2. Host computes `block_start_sample`, resets the block arena.
3. Host walks the active graph in topo order. For each machine:
   a. Swap params double-buffer if a new pending copy is ready.
   b. Advance param smoothers toward pending values.
   c. Build a `MachineCtx` for this machine (see
      [04-block-contract.md](04-block-contract.md)).
   d. Call the machine's compiled `process` trampoline. Pointer in,
      nothing out — the machine writes audio to its output ports via
      pointers in ctx.
4. Host sums/routes outputs through sends and master.
5. Host writes final mix to the miniaudio callback buffer.
6. Host advances the transport clock (sample-accurate).
7. Host runs any scheduled note events that fired inside this block
   *before* the next block (UI-thread visible).

No allocation in steps 1–6. All buffers come from preallocated arenas.

## Embedding contract with fy

Slab imports fy as a **Zig module** (`@import("fy")`) via a path
dependency in `build.zig.zon`. No C-ABI, no opaque handles, no error-
code translation: both sides are Zig, both live in the same workspace,
and a narrow C surface buys nothing until fy has outside consumers.

Surface slab uses today:

- `fy.Fy.init(allocator) → Fy` — create a runtime
- `Fy.deinit(self)` — tear it down
- `Fy.run(self, src) → !Value` — compile + execute source (covers
  both file-loading and hot-patching — a hot-patch is just re-running
  a fresh `: name … ;` definition; the trampoline pointer previously
  taken stays valid)
- `Fy.findWord(self, name) → ?Word` — look up a word; `Word.trampoline_addr`
  is the stable pointer to cache for hot-patch-survivable dispatch

`dsp:` mode, hot-patch TCP integration, and the audio-call-path helpers
will be added to fy's `lib.zig` surface as they become needed. The
principle is: expose just what slab imports, no ceremonial layers.

If fy ever grows outside consumers, a C-ABI can live in a separate
`fy/src/capi.zig` without disturbing slab's Zig-native path.

## Why a single binary (not plugin loading)

Users edit machine source, not machine binaries. There's nothing to
"load" in the .dylib sense — a machine is a `.fy` file that fy
compiles to ARM64 in the shared address space. Hot-patching a `.fy`
file is identical to the livecoding flow fy already ships.

The one thing that resembles plugin loading is **machine discovery**:
scanning a machines directory, parsing manifests, presenting them in
a "new machine" menu. That's a file listing plus manifest parse, not a
runtime loader.

## Where the lines blur (and stay drawn)

These are places where "just put it in fy" would be tempting but
shouldn't:

| thing | stays in | why |
|---|---|---|
| audio I/O | Zig | libminiaudio, latency-critical, once |
| transport clock | Zig | atomic on the audio thread, read everywhere |
| FFT | Zig | pffft or own NEON, battle-hardened, never changes |
| piano roll widget | Zig | data-heavy, stable semantics, shared by all machines |
| file I/O | Zig | hot-patch protocol, presets, project files |
| windowing | Zig | raylib hook-in, one place |
| **DSP kernels** | fy (`dsp:`) | livecodable, user-authorable, hot-patchable |
| **synth voices** | fy | where sonic personality lives |
| **panels** | fy | where each machine's identity lives |
| **note transformers** | fy | same runtime as DSP, same liveness |

The line is **liveness**. Things users want to edit live live in fy.
Things that are infrastructure live in Zig.
