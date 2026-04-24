# AGENTS.md

Orientation for AI coding agents working in this repo.

## What this project is

**Slab Audio Workstation (SAW).** An open-source macOS DAW where the
frame is Zig and every "machine" inside the frame (synths, effects,
note transformers, panels) is authored in [fy](../fy) — a
concatenative, JIT-to-ARM64 language with word-level hot-patch.

The signature capability: users edit a machine's source (filter, osc,
panel code) while audio plays and the next block runs the new code.
Everything else about the product follows from making that promise hold.

**Status: pre-code.** Design documents only. `src/main.zig` is a
stub. The plan is in `docs/`; read those before writing code.

## Where to start

Read in order on your first session:

1. [docs/README.md](docs/README.md) — doc index + terminology
2. [docs/00-vision.md](docs/00-vision.md) — what and why
3. [docs/01-architecture.md](docs/01-architecture.md) — Zig/fy split
4. [docs/02-machines.md](docs/02-machines.md) — the machine abstraction
5. [docs/03-memory-model.md](docs/03-memory-model.md) — arenas, NoGC
6. [docs/04-block-contract.md](docs/04-block-contract.md) — MachineCtx
7. [docs/05-kernels.md](docs/05-kernels.md) — `dsp:` mode + NEON
8. [docs/06-ui-widgets.md](docs/06-ui-widgets.md) — UI style
9. [docs/07-transport.md](docs/07-transport.md) — audio clock + graph
10. [docs/08-services.md](docs/08-services.md) — voice pool, smoothing, etc.
11. [docs/09-hot-reload.md](docs/09-hot-reload.md) — livecoding model
12. [docs/10-roadmap.md](docs/10-roadmap.md) — phased build plan

Everything else in this file assumes you've read at least the vision,
architecture, and memory-model docs.

## Sibling repositories

### `../fy` — language runtime (WE LINK TO THIS)

Slab embeds fy's runtime as a library. Read this when:

- Looking at `dsp:` mode implementation (`src/main.zig` in fy — the
  `Compiler` struct)
- Extending the assembler with NEON (`src/asm.zig` in fy, currently
  ~365 lines — needs ~300-500 lines added for the NEON subset in
  [docs/05-kernels.md](docs/05-kernels.md#neon-instruction-set))
- Understanding the hot-patch trampoline model (see `fy/docs/editor.md`
  and the `userWords` + trampoline machinery in `Fy`)
- Wiring in new C-ABI entry points for the host to call

**We will modify fy** to add things Slab needs:

- `dsp:` compile mode (parallel to `macro:`, `callback:`): heap-access
  blacklist, default inlining, stack-effect snapshot, NEON available
- NEON instruction set in `asm.zig`
- Library target in `build.zig` plus a C-ABI header (`init`, `load`,
  `lookup`, `call`, `patch`, `is_dsp_word`)
- Stack-effect verification on hot-patch
- Possibly: inline-site registry for ship-mode kernel hot-patch

Coordinate fy changes carefully — fy stands alone as a project, so
Slab-specific additions should land behind opt-in flags or as clean
extensions that don't destabilize the existing language.

fy's relevant docs:
- `fy/AGENTS.md` — architecture + dev guidelines
- `fy/docs/builtins.md` — word reference
- `fy/docs/macros.md` — compile-time execution (basis for combinators)
- `fy/docs/ffi.md` — `bind:` + `callback:` (how Zig↔fy calls happen)
- `fy/examples/funky.fy` and `funky_demo.fy` — existing DSP patterns
  in fy; the block-rate/combinator work in Slab generalizes this

### `../fuvid` — video editor (INSPIRATION ONLY, NOT LINKED)

fuvid is a separate Zig + raylib video editor by the same author. We
**do not link to it** and don't share code. Read it for patterns:

- **Transport / audio clock** (`fuvid/src/core/transport.zig`) — the
  audio-thread-authoritative clock model is exactly what Slab needs.
  Study `advanceAudioClock` + atomic sample counter + `currentTime()`.
- **miniaudio integration** (`fuvid/src/core/audio_engine.zig` +
  `fuvid/vendor/miniaudio.c`) — the callback setup, device
  configuration, and interaction with transport.
- **Timeline UI** (`fuvid/src/ui/timeline_ui.zig`, ~2000 lines) —
  track rows, clip rendering, snapping, drag/drop, zoom. Slab's
  arrangement view will have the same shape for audio/pattern clips.
- **Immediate-mode UI patterns** — retained-free widget style,
  bounded arrays for selection, `drawTextClipRotated` stroke trick.
  The Slab widget library will be similarly immediate-mode but with
  a different aesthetic (1px bevel brutalist vs fuvid's cleaner look).
- **Document model + undo** (`fuvid/src/core/document.zig`,
  `history.zig`) — snapshot-based undo is a good default.
- **Bounded-array discipline** — `selected_clips: [256]ClipId +
  selected_count: usize` over ArrayList in hot paths. Follow this.

Copy *ideas*, not code. fuvid is MIT-or-whatever-license independent
of Slab; keep the codebases disjoint.

Reference docs in fuvid:
- `fuvid/AGENTS.md` — architecture summary (short and good)

## Build and run

```sh
zig build              # build
zig build run          # build and run the stub
zig build test         # run unit tests
```

Requires zig >= 0.16 (see `build.zig.zon`). macOS on Apple Silicon only
— fy's JIT uses `MAP_JIT` + `pthread_jit_write_protect_np`.

## Coding conventions

### General Zig style

- Zig >= 0.16 idioms. Use `std.Build.Module` / `createModule` for
  build targets (already done in `build.zig`).
- Avoid allocations in hot paths. Use bounded arrays where size is
  known (`[256]ClipId` over `ArrayList(ClipId)`).
- Prefer `extern struct` for any layout that crosses the Zig↔fy
  boundary or gets serialized.
- Stick to standard zig naming: `snake_case` fields, `PascalCase`
  types, `camelCase` functions. No Hungarian.

### Audio-thread discipline (the one that matters most)

**Nothing on the audio thread allocates.** No `std.heap`, no
`ArrayList.append`, no fy heap operations, no `malloc`. Read
[docs/03-memory-model.md](docs/03-memory-model.md) and internalize
the four-arena model (block, persistent, voice, asset).

- All audio-thread code must be reachable only from the miniaudio
  callback or from a `dsp:` fy word. Use Zig's type system (phantom
  types, module boundaries, or a naming convention like `audio_*`
  functions) to keep this honest.
- Never call into fy's non-`dsp:` words from the audio thread.
- If you touch a mutex on the audio thread, you're almost certainly
  wrong — use atomics and lock-free SPSC rings.

### UI / widget style

Brutalist grey, 1px bevels, bitmap fonts. Don't soften this. See
[docs/06-ui-widgets.md](docs/06-ui-widgets.md). Concretely:

- No anti-aliasing on rectangles or lines.
- No gradients, drop shadows, or rounded corners.
- Grid snap at 4px. Standard row height 16 or 20.
- Palette is fixed: five greys + three accents (in the doc).
- Bitmap fonts only — vector fonts at 11px look wrong.

### fy-side style (when we start writing fy)

Follow the conventions in `fy/AGENTS.md` and look at
`fy/examples/funky.fy` for idiomatic DSP. For Slab-specific fy:

- `dsp:` words always — never `:` — for anything on the audio path.
- Use combinators (`vec-each`, `pipeline`, `voice-each`,
  `stateful:`, `oversample`) over hand-written loops. See
  [docs/05-kernels.md](docs/05-kernels.md#combinators).
- One concept per kernel. A filter is a filter; a shaper is a shaper.
  Compose.
- Machines live in `machines/<category>/<name>/` directories
  (planned layout; see [docs/02-machines.md](docs/02-machines.md)).

## What not to do

- **Don't write a plugin host.** Not VST, not AU, not AAX. The value
  is the livecoding substrate, which binary plugins break.
- **Don't target non-macOS.** fy's JIT is aarch64 + `MAP_JIT`. Cross-
  platform is a separate project for a separate year.
- **Don't merge code between fuvid and slab.** Shared ideas only.
- **Don't build a free-node-graph editor** (Reaktor-style) before the
  Live-style graph works end-to-end. Later, on top of the same
  scheduler, fine.
- **Don't add backward-compatibility cruft** while the project is
  pre-1.0. Breaking a design doc is free; breaking a user's project
  file becomes expensive fast — but we have no users yet, so keep
  the design fluid.
- **Don't invent a new language for machines.** It's fy. The reason
  for that is in [docs/00-vision.md](docs/00-vision.md).

## When to modify docs vs code

Right now: **docs only** until Phase 0 begins. If you find a design
contradiction or a better approach while reading, update the relevant
doc before writing code against the old design. The docs are the
plan; keep them tight.

Once code lands, docs follow code: when behavior changes, the
relevant doc is part of the change.

## Commit style

Pre-code. When code lands:
- Conventional-ish: `area: short imperative summary`
- `area` examples: `fy-embed`, `audio`, `arena`, `ui`, `machine`,
  `kernel`, `docs`
- One logical change per commit
- No "WIP", "fix typo", "more stuff" — squash before merging
- Reference doc sections when a commit implements them:
  `kernel: implement vec-each combinator (docs/05 §combinators)`

## Things that will change as we learn

Some design decisions in the docs are bets. Flag honestly if:

- fy's `dsp:` inlining doesn't hit perf targets (see roadmap Phase 1
  exit criteria)
- Zig-embedding of fy's `Fy` struct turns out harder than expected
- A combinator compile-time fusion approach produces bad code
- The arena model needs adjustment under a real load
- NEON authoring is harder than projected and needs more Zig-side
  help

These are the foundational bets — everything above them (UI,
machines, services) is replaceable. Protect the foundations; iterate
freely above.
