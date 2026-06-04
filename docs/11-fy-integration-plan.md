# 11 — fy integration plan

Phase 0 of the roadmap ([10-roadmap.md](10-roadmap.md)), expanded into
staged, testable steps. Each stage has a concrete proof-of-life test.
Don't move to stage N+1 until stage N's test passes.

See also: the survey of fy's current capabilities at `/tmp/fy-survey.md`
(what exists, what must be built).

## Design decisions locked in

Established before writing this plan; revisit only if a stage empirically
invalidates one.

- **One `Fy` instance per host process.** Each machine file is `import`ed
  under its own namespace (fy's `file_ns_map` handles this). Slab holds a
  single `Fy` and a table of `*Machine` pointers indexed by namespace.
- **Machine ABI is fy structs, not raw @/! primitives.** A bundled
  `ctx.fy` library declares `struct: MachineCtx`, `struct: NoteEvent`
  matching the Zig ABI byte-for-byte. Machines `import "ctx"` and use
  `ctx MachineCtx.sample-rate@` etc.
- **Manifest is a plain word named `manifest`.** Each machine file
  defines a word `manifest` that pushes a `*Machine` struct. Slab
  compiles the file, looks up `<ns>:manifest` in `userWords`, calls it,
  pops the struct pointer. No new compiler directive.
- **Host builtins extend fy's `words` StaticStringMap.** Added in fy
  source (src/main.zig:2038) behind a `slab` build flag, upstream
  contribution optional. Native Zig functions wrap via `fnToWord`.
- **Safety mode is named `noalloc:`.** Generic upstream name (reusable by
  any fy embedder wanting realtime/interrupt-context words), not
  Slab-specific. NEON and DSP inlining are separate concerns layered on
  top, not part of the mode itself.
- **GC rooting is the one sharp edge.** Quote refs stored in Machine
  structs live in fy's GC heap but the Machine struct sits in C malloc;
  the GC walker does not scan malloc'd memory. Rooting handled
  explicitly in stage 2.

## Stage 0 — Link fy, call a user word from Zig

**Goal:** prove we can embed fy at all. Nothing about audio yet.

**Build:**
- Add a `src/fy_host.zig` module that owns a `*fy.Fy` instance, init/
  deinit, and a `compile(src: []const u8)` method.
- Add a `callWord(name: []const u8) !i64` method that looks up a word in
  `userWords`, reads `image_addr`, calls it, returns the top of the fy
  data stack (untagged).
- Don't invent the calling convention — copy exactly what fy's REPL does
  per line (it compiles each input as `.SessionRet` wrap mode and calls
  the resulting function). Find that path in fy's `src/main.zig` and
  mirror it in Zig.

**Test:** `src/fy_host_test.zig` — compile `": answer 42 ;"`, call
`callWord("answer")`, assert result == 42. Compile `": double dup + ;"`
after, call `callWord("answer")` (should still work, same session),
then do `": use answer double ;"` and `callWord("use")` → assert 84.

**Watch for:**
- Register save/restore mismatch (x21/x22 corrupted across the call)
- Data stack not reset between calls
- Tagged-value encoding confusion (42 vs 42 << 2)

## Stage 1 — fy reads a Zig-allocated buffer via a ctx struct

**Goal:** prove the ABI shape of ctx works both directions.

**Build:**
- New file `machines/lib/ctx.fy` (bundled path). Declares:
  ```forth
  struct: MachineCtx
    f64 sample-rate
    u32 block-size
    u32 _pad0
    u64 block-start
    f64 tempo-bpm
    f64 ppq-position
    ( ... fields matching Zig's MachineCtx byte-for-byte ... )
  ;
  ```
  Match the field layout in `src/machine.zig` exactly. Use `@sizeOf` /
  `@offsetOf` on the Zig side to assert the layout matches (in a Zig
  comptime test).
- Set `base_dir` on the compiler to the bundled-lib directory so
  `import "ctx"` resolves.
- Extend `fy_host.zig.compile()` to accept a base_dir.

**Test:** Zig allocates a `MachineCtx` on the stack, writes
`sample_rate = 48000.0, block_size = 64`, pushes the pointer onto fy's
data stack, calls a fy word `: read-sr MachineCtx.sample-rate@ f. ;`
that reads the field and prints it. Assert stdout contains `48000`.

**Watch for:**
- Field layout mismatch (extra padding, alignment surprises). The
  comptime assertion against Zig's struct offsets catches this at build.
- fy's `f64` field stored as raw bits vs. tagged float — fy floats use
  TAG_FLT, so `@64` reads raw bits and needs untagging vs. `f@64` which
  handles it. Pick one and verify.

## Stage 2 — Manifest word returns a Machine struct Zig can read

**Goal:** prove Slab can extract a machine's entry points and sizes from
a compiled file. This is where GC rooting gets tested for real.

**Build:**
- `machines/lib/machine.fy` declares:
  ```forth
  struct: Machine
    ptr audio        ( quote ref to audio entrypoint )
    ptr ui           ( quote ref to ui entrypoint, may be 0 )
    u32 state-size
    u32 params-size
    u8 in-notes
    u8 out-notes
    u8 in-audio
    u8 out-audio
  ;
  ```
- A tiny test machine `machines/sine_v0.fy`:
  ```forth
  import "machine"

  : my-audio ( ctx -- )  drop ;
  : my-ui    ( ctx rect -- )  drop drop ;

  : manifest
    \my-audio \my-ui
    128 32
    1 0 0 1
    Machine.new
  ;
  ```
- Zig side: compile the file under namespace `sine_v0:`, call
  `sine_v0:manifest`, pop the returned pointer, cast to
  `*extern struct Machine` (mirror of the fy struct), read fields.
- **GC rooting**: after capturing the audio and ui quote refs, call a
  new host builtin `fy-root ( v -- )` that calls `Fy.Heap.addRoot` on
  the tagged value. Do this before returning from the manifest call.
  (Alternative: Slab-side registers each captured quote via a direct
  Zig call into fy's heap roots — cleaner, no new fy builtin needed.)

**Test:**
1. Compile, call manifest, verify struct fields match the expected
   values (state-size == 128, etc.).
2. **Force GC test:** compile, call manifest, capture pointers, call
   `fy.Fy.Heap.collect()` explicitly, then call the captured audio quote
   — must not segfault, must not return garbage. If this test fails, GC
   rooting is broken and we fix it before moving on.

**Watch for:**
- Tagged-value handling when reading the `ptr audio` field from Zig —
  it's a raw i64 holding a tagged heap ref. Slab unwraps it before
  calling.

**Optional polish (do if cheap, skip if not):** let fy accept a declared
struct name as a field type, compiled to `ptr`. Documentation value
only — no layout inlining, no typed accessors, same size and alignment
as `ptr`. `parseFieldType` grows ~20 lines to look up unknown type names
in `struct_layouts` and return the ptr variant with the target name
attached for error messages. Then the Machine struct reads as:
```forth
struct: Machine
  Quote audio        ( instead of: ptr audio )
  Quote ui
  u32 state-size
  ...
;
```
assuming `Quote` is a pre-declared stub struct or just kept as `ptr`.
This is purely about readability of machine files.

## Stage 3 — Audio thread calls fy's audio word each block

**Goal:** audible sine from a fy `dsp:` word, played through Slab's
existing miniaudio callback.

**Build:**
- Replace the Zig `Sine` machine with a thin shim that holds a
  `*FyMachine` (the one captured in stage 2). `machineInterface()`'s
  `render` callback:
  1. Fills the ctx struct in place
  2. Pushes `&ctx` onto fy's data stack
  3. Calls the captured audio word via its `image_addr` as
     `extern "C" fn() callconv(.C) void`
- On the fy side, `sine_v1.fy` writes to `ctx:audio-out[0]` (a
  host-provided builtin — add the minimum set here: `ctx-audio-out@ (
  ctx port -- ptr )` and the memory-write primitives already exist).
- The audio word runs in a loop over `block-size` samples, writing
  `@sin(phase) * gain` to L and R. No `noalloc:` enforcement yet.

**Test:**
1. Unit: render 64 samples from a fy audio word, compare a few values
   against a reference computed in Zig. RMS matches to within float
   precision.
2. End-to-end: launch Slab, select the track with the fy sine machine,
   hit play, hear a tone. No glitches, no crashes over 30 seconds.
3. Load test: 4 tracks with 4 fy machines simultaneously, no dropouts
   at 64-sample blocks on an M-series Mac.

**Watch for:**
- Audio-thread calling into fy's image pages — the JIT pages need to
  be executable from any thread. fy already sets this up; verify.
- Data-stack pressure: each block pushes ctx pointer and the audio word
  must leave the stack balanced. Drift accumulates to catastrophic
  failure over time. Check `depth` before and after each call in a
  debug build.
- GC during audio: **must never happen on audio thread.** fy's `gc` is
  only callable from user words; as long as no audio-path word calls
  `gc`, we're fine. The `noalloc:` check (stage 5) makes this
  structural.

## Stage 4 — Hot-patch

**Goal:** edit sine_v1.fy in the editor, save, hear the change next
block.

**Build:**
- Port fy's hot-patch TCP listener from fy's CLI (src/main.zig:5180
  region) into Slab. The listener accepts file-path strings, recompiles
  them, re-runs the file's `manifest` word, and atomically repoints the
  Slab-side machine's audio/ui pointers under `hot_mutex`.
- VSCode extension already in fy (editors/vscode) speaks this protocol.
  Reuse it unchanged.

**Test:**
1. Launch Slab, load sine_v1.fy, start playing.
2. Edit a constant in the file (e.g., change the gain multiplier).
3. Save. Within one block (~1.3ms), the new gain is audible.
4. Make a syntax error. Save. Old machine keeps playing; error appears
   in Slab's status bar (or stderr). No crash.

**Watch for:**
- Atomic pointer swap: the audio thread reads the machine's audio word
  pointer each block. The UI thread writes the new pointer after a
  successful recompile. Release/Acquire ordering, matching the pattern
  used in track.publishSnapshot.
- Quote ref rooting (stage 2 test again, more aggressively): the old
  quote must survive until no audio thread holds a reference. Simplest:
  retire the old pointer one block after the swap.

## Stage 5 — `noalloc:` safety mode in fy

**Goal:** compile-time rejection of heap-touching primitives inside
words that must be audio-safe. Upstream to fy.

**Build (in fy):**
- New directive in `Compiler.compile()` at the dispatch site
  (src/main.zig:~4105). Modeled after `compileMacro`.
- A Zig `StaticStringMap` of forbidden primitives: `qnil`, `qpush`,
  `cat`, `curry`, `range`, `map`, `reduce`, `filter`, `each`, `s+`,
  `ssub`, `sreplace`, `ssplit`, `slines`, `strim`, `i>s`, `slurp`,
  `spit`, `readln`, `dir-list`, `mkdir-p`, `alloc`, `free`, `gc`, plus
  heap-literal forms (string `"..."`, quote `[ ... ]` — these need
  parser-level interception).
- Also reject calls to non-`noalloc:` user words (transitive safety).
  Requires a `Word.noalloc: bool = false` flag alongside `immediate`.

**Test (in fy):**
1. `noalloc: good 2 3 + ;` compiles; call it, get 5.
2. `noalloc: bad qnil ;` fails with "qnil not allowed in noalloc: mode".
3. `noalloc: also-bad [1 2 3] ;` fails (quote literal allocates).
4. `: normal qnil ;` compiles. `noalloc: caller normal ;` fails ("calls
   non-noalloc word 'normal'").

**Watch for:**
- False positives: primitives that look allocating but aren't (e.g.
  `@64` reads memory, doesn't allocate). Audit the blacklist carefully.
- Transitive check cost: walking every BL target of a word at compile
  time is O(word size). Fine.

## Stage 5b — `dsp:` compiler mode and reports

**Goal:** move from "safe to call on the audio thread" to "compiled as
an audio kernel." `noalloc:` prevents the worst failures; `dsp:` is the
formal compiler mode for fast, inspectable DSP.

**Build (in fy):**
- New `dsp:` directive layered on `noalloc:`.
- Reject runtime quotation allocation and dynamic quote calls. Quote
  bodies are allowed only as compile-time macro inputs or inline
  control-flow bodies that disappear before codegen.
- Record static stack effects and typed effects for every `dsp:` word.
- Inline eligible `dsp:` callees before branch lowering. Avoid the
  already-tested "copy lowered machine code" approach; it did not help
  mono1 and can increase I-cache pressure.
- Add a typed stack IR or equivalent value graph so adjacent float and
  pointer operations can be fused without untag/retag and stack
  materialization between every primitive.
- Add codegen metadata: instruction counts, calls inside loop, stack
  spills inside loop, scalar tag ops inside loop, register counts,
  emitted bytes, and disassembly.

**Test (in fy and Slab):**
1. `dsp: gain ( in out n g -- ) ... ;` compiles under the heap/I/O
   blacklist and emits a report with zero calls/spills inside the
   sample loop.
2. A runtime quote literal or call to a non-`dsp:` helper is refused.
3. A small arithmetic pipeline lowers without repeated scalar
   untag/retag between adjacent float ops.
4. The report and disassembly can be written by a Slab-side workbench
   fixture.
5. Compare scalar Fy, optimized `dsp:` Fy, and a Zig/C reference for
   gain, one-pole, and softclip. Store perf/audio/compiler metrics as
   ratcheted bounds.

**Watch for:**
- Hot-patch vs inlining. Dev mode may preserve trampoline calls; ship
  mode needs an inline-site registry and dependent-caller re-emission.
- Branch relocation correctness. Previous peephole work had to skip
  branchy words until relocation was made safe.
- False confidence from sound-only tests. Compiler reports and disasm
  constraints are part of correctness for this stage.

## Stage 6 — UI from fy

**Goal:** a fy word renders the machine's panel using Slab-provided
widget builtins.

**Build:**
- Slab-side widget builtins: `widget:knob ( rect label value -- changed
  new-value )`, `widget:label ( rect text color -- )`,
  `widget:bevel-raised ( rect -- )`, etc. Implement as Zig functions
  wrapped via `fnToWord`.
- The sine machine's `my-ui` word calls these.
- Note the tricky bit: widget calls like `knob` mutate a value the
  machine needs to read back. Since fy strings/quotes can't be mutated
  safely across the call, pass value cells as raw pointers into fy's
  persistent arena (machine's state slab) and let the widget write to
  them.

**Test:**
1. Machine panel renders in Slab; visually matches the Zig sine panel.
2. Drag the GAIN knob — audio responds.
3. Hot-patch the panel layout (move the knob) — changes visible next
   frame, no restart.

**Watch for:**
- UI thread + audio thread both read/write params: use the existing
  atomic handoff (`gain_bits: atomic.Value(u32)`). The fy widget writes
  via an atomic-store builtin, the fy audio word reads via an
  atomic-load builtin.
- UI thread runs non-`noalloc:` words (panel is free to allocate).
  Audio thread only calls `noalloc:` words. The distinction is per-word,
  not per-file.

## After stage 6

At this point, everything the Phase 0 / Phase 1 roadmap sections called
for is in place in a minimal form:
- fy authoring of machines: ✓
- Hot-patch: ✓
- Compile-time audio safety: ✓
- UI authoring: ✓

The Zig reference Sine machine can then be deleted (or kept as a
benchmark reference). Phase 1 (combinators, NEON, voice pool, param
smoothing) builds on top of this substrate.

## Parallel upstream work

Two changes to `../fy` are candidates for upstream regardless of Slab:

1. **`noalloc:` directive** (stage 5). Generic feature; any embedder
   wanting realtime-safe words benefits.
2. **Struct names as field types** (post-stage 2 nice-to-have).
   Currently `parseFieldType` only accepts primitives. Extending it to
   accept any declared struct name — compiled to `ptr` internally, same
   size and alignment — is a readability win independent of Slab.
   Documentation only: no layout inlining, no typed field access across
   the pointer. A future extension could add typed access or inline
   embedding via distinct syntax (e.g. `&Name` for ptr, `Name` for
   inline), but not now. ~20 lines in fy.

Both ship behind a feature gate in fy's build, or just land directly —
fy is pre-1.0 and breakage is cheap.

## Known unknowns

- **Multi-Fy per process:** not attempted. Plan commits to one Fy per
  host. If a future need appears (e.g., sandboxing a user-loaded
  third-party machine), revisit.
- **Stack-effect verification on hot-patch:** fy AGENTS.md mentions this
  as a future capability. Without it, a bad hot-patch can corrupt the
  data stack and crash the next audio block. Workaround for now: audio
  words have a uniform `( ctx -- )` signature, verified manually in the
  manifest. Stack-effect checks are a stage-7+ upstream addition.
- **Asset maps** (wavetables, samples): deferred past stage 6. Add when
  a reference machine needs them.
