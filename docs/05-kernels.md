# 05 — Kernels and `dsp:` mode

Where the sonic character of the product lives. Kernels are fy
words compiled in a restricted `dsp:` mode, with a NEON extension
to fy's assembler and a set of combinators that let authors write
readable DSP that compiles to tight ARM64+NEON.

> **As built:** this doc is the original design. The language as it
> actually works today (frames, typed fields, memory order, spilling,
> the word set) is in [18-fy-dsp-language.md](18-fy-dsp-language.md).

## The philosophy

- Kernels are fy, not Zig. One language, one hot-patch model, one
  mental surface. The kernel library *is* example code for machine
  authors.
- Kernels are small and sharp. A filter is a filter; it doesn't
  also do amp modulation or mixing. Compose via combinators.
- Kernels are livecodable. Every kernel's source is readable; every
  kernel is hot-patchable. Users fork the stock Moog ladder and keep
  a weird one.
- The bottleneck is **instruction scheduling and allocation**, not
  kernel abstraction. The NEON extension gives us the instructions;
  `dsp:` inlining fuses composition; macros unroll loops.

## `dsp:` mode — language subset

A word declared with `dsp:` instead of `:` compiles with:

- **No heap access.** Disallowed primitives:
  - `qnil`, `qpush`, `qpop`, `qlen`, `qnth`, quote literals `[ ... ]`
    as data (quotes as inline control-flow blocks are fine)
  - `map`, `reduce`, `filter`, `each`
  - String literals and string operations
  - `alloc` (no new heap buffers at runtime)
  - Anything that calls into `Builtins` with a heap side effect

- **No ambient I/O.** No `print`, `.`, `.nl`, `raylib:...`, any FFI.

- **Default inlining.** Every call from one `dsp:` word to another
  `dsp:` word is inlined at compile time rather than emitted as a
  `BL`. Inlining is transitive. Breaks only at marked `noinline:`
  kernels (e.g. a big FFT you keep as a call).

- **NEON instruction set available** (see below).

- **Frame-pinned locals.** The existing fy locals mechanism (`| a b |`)
  already frame-allocates; `dsp:` mode additionally pins hot pointer
  locals to callee-saved GPRs where register pressure allows.

- **Stack-effect snapshot.** On first compile, `dsp:` records the
  stack effect of the word. Hot-patches must match it exactly or
  the patch is refused (see [09-hot-reload.md](09-hot-reload.md)).

What stays from base fy: integer and float arithmetic, float
comparisons, conditionals (`ifte`/`then`), `dotimes`, `do` on
inline-constant quotes (for control flow, not data), locals, pointer
load/store at typed widths (`@64`/`!64`/`@32`/`!32`/`@f32`/`!f32`/etc),
struct field accessors, params accessors.

## `dsp:` compiler contract

`dsp:` source may look like normal concatenative Fy. The emitted kernel
must not behave like a literal runtime stack program in the hot loop.
The stack is the source-level notation; the compiler lowers it to a
typed value graph and keeps values in registers.

Expected lowering path:

```
fy tokens / AST
  -> static stack-effect + type-effect check
  -> inline eligible `dsp:` callees
  -> macro expansion and quote fusion
  -> typed stack IR
  -> stack-to-SSA / value graph
  -> register allocation + spill plan
  -> AArch64 scalar or NEON codegen
  -> code metadata + disassembly
```

Compiler invariants for sample/lane loops:

- Hot stack values live in GPR/FPR/NEON registers, not in memory.
- Adjacent float operations fuse without untagging and retagging after
  every primitive.
- Pointer locals such as input/output buffers, phase/state pointers,
  and coefficient pointers are pinned where register pressure allows.
- Calls inside the inner loop are absent unless the word explicitly
  opts into a `noinline:` call.
- Stack spills, scalar tag operations, and calls inside loops are
  counted and reported.

The benchmark history in
[sessions/mono1-benchmarks.md](sessions/mono1-benchmarks.md) is the
evidence for this direction: peepholes and naive machine-code body
copying were weak, while source-level fused DSP words helped. The real
compiler win is pre-lowering fusion and register planning.

## Quotation model

Runtime quote allocation is banned in `dsp:`. A `dsp:` word cannot
construct quote values, push quote refs onto the runtime stack, or call
dynamic quote combinators.

Compile-time quote manipulation remains central:

- Quotes may appear as macro inputs.
- Macros may inspect, transform, fuse, and emit quote bodies.
- Combinators such as `vec-each`, `pipeline`, `stateful:`,
  `voice-each`, and `oversample` consume compile-time quote bodies.
- By codegen time, no runtime quote value remains in the kernel.

This is the key distinction: dynamic quotations are not realtime-safe,
but macro-time quotations are how the kernel DSL stays pleasant while
still compiling to tight code.

## Compiler reports

Every `dsp:` word should be able to emit a machine-readable compiler
report alongside disassembly:

```json
{
  "word": "gain-v",
  "mode": "dsp-ship",
  "instructions": 18,
  "loop_instructions": 5,
  "calls_inside_loop": 0,
  "stack_spills_inside_loop": 0,
  "scalar_float_tag_ops_inside_loop": 0,
  "neon_registers": 3,
  "gpr_registers": 4
}
```

These fields are testable. A kernel that sounds correct but starts
emitting calls or stack spills inside the loop should fail a compiler
ratchet before it becomes part of the library.

## Lane mode (implemented, 2026-09-30)

What actually shipped first. It isn't the NEON words sketched below: the
compiler vectorizes a whole kernel across *instances*, and the kernel
source doesn't change.

A dual-mono effect runs one kernel per channel against its own state. In
lane mode (fy `Dsp2.Builder.emitLanes`, `Fy.compileDsp2RawLanesCaller`)
the same per-sample program runs once with every f64 held in a 2 × f64
NEON register: lane 0 is the left channel's instance and lane 1 the
right's.

- Each entry argument is either one register shared by both lanes
  (params) or a register per lane (io frames, ctx, state).
- A load through a shared pointer is `ld1r`, one value into both lanes. A
  per-lane load is `ldr d` plus `ld1 {v.d}[1]`. A per-lane store is
  `str d` plus `st1 {v.d}[1]`.
- Indexed access (`f@i`, `f!i`) takes each lane's index to its own
  address.
- Every arithmetic, compare, select and exponent-bit op has its `.2d` or
  `.16b` form. There is no `fcsel` across lanes, so `select` is always a
  mask plus `bsl`.

Each lane does the same IEEE operations in the same order as the scalar
body, so the output is **bit-identical** to two scalar passes. The fy test
"dsp lanes: …" and the slab test "NEON lanes: every dual-mono effect …"
check this with different signals on the two channels.

Lane mode refuses a word (and the host falls back to two scalar passes)
when:
- it has stack outputs or f64 arguments;
- it stores through the shared pointer, where which lane wins would
  differ from running the passes in order;
- it is a `call:` composition.

The host (`FyRawMachine.compileLanes`) compiles it for every effect that
isn't `stereo`, beside the scalar word. Stereo effects (comp2, bus2,
multi2, char2, funk) already run one pass, so they gain nothing.

Measured in the ReleaseFast bench, ns per sample, lanes against scalar:
eq2 18/52, sat2 170/272, gate2 14/21, limiter2 24/33, verb2 100/122,
delay2 14/18, chorus2 17/19. (delay2 and verb2 have since become true
stereo: ping-pong and one shared reverb tank can't be two independent
lanes. See docs/20 for their costs.) On the 8-bar songs/sweat_geometry window
(effects alone): 6.06 s → 5.32 s.

**The toggle.** `fy_raw_machine.neon_lanes`, on by default. `slab
--no-neon` and `zig build bench -- --no-neon` render the scalar passes,
for A/B checks.

**Voices in pairs.** A poly machine's voices are the same kernel against
separate state, so `renderVoiceSegment` renders consecutive sounding
voices two at a time.
- Voice kernels accumulate (`io f@64 o f+ io f!64`). Lane 0 adds onto the
  running sum as it would alone. Lane 1 renders into frames that start at
  −0.0 (x + −0.0 is exactly x), and the host adds that in. The sum is
  (S + ya) + yb, the sequential order.
- Each voice's peak, which idle detection reads, is measured the same way
  as before.
- An odd voice out renders alone.
- fm86's control-rate word splits a pair's pass at whichever voice's
  control point comes first.

The slab test "NEON lanes: voices rendered in pairs …" plays five
staggered notes on Profit-5, Juno, FM-86 and Rhodes and compares both
channels bit for bit.

Bench chord case, ns per sample, lanes against one at a time:
- Profit-5: 884/1475
- Juno: 210/343
- FM-86: 157/262
- Unfairlight: 83/129
- Rhodes: 73/105
- Sampler: 129/174

The sweat_geometry window with effects and voices both paired: 6.03 s →
4.79 s.

## NEON instruction set

Extension to fy's `src/asm.zig`. Concretely ~300–500 lines of
encoder helpers. Minimum viable set:

### Register model

- `v0..v31` — 128-bit NEON registers. 4× f32 (`.4s`) or 2× f64 (`.2d`)
  or 4× i32 (`.4s`) or 2× i64 (`.2d`) lane views.
- Scalar float uses `s0..s31` aliased over `v0..v31[0]`.

### Instructions

| mnemonic | semantics |
|---|---|
| `ld1.4s v, [base]`, `ld1.4s v, [base], #16` | load 4 f32 (optional post-increment) |
| `ld1r.4s v, [base]` | load-and-broadcast one f32 into all lanes |
| `st1.4s v, [base]`, `st1.4s v, [base], #16` | store 4 f32 |
| `ldp.q v1 v2, [base]`, `stp.q v1 v2, [base]` | paired 16B ld/st |
| `fadd.4s`, `fsub.4s`, `fmul.4s`, `fneg.4s`, `fabs.4s` | lane-wise f32 arith |
| `fmla.4s`, `fmls.4s` | fused multiply-add / multiply-sub |
| `fmin.4s`, `fmax.4s` | lane-wise min/max |
| `fdiv.4s` | division (slow on M-series; prefer reciprocal) |
| `frecpe.4s`, `frsqrte.4s` | reciprocal / reciprocal-sqrt estimate |
| `frecps.4s`, `frsqrts.4s` | Newton step for the above |
| `fcmge.4s`, `fcmgt.4s`, `fcmeq.4s` | lane compare → mask |
| `bsl.16b` | bitwise select (mask, a, b) |
| `dup.4s v, Wn` / `dup.4s v, v2.s[i]` | broadcast scalar to all lanes |
| `ext.16b v, va, vb, #n` | extract across two vectors |
| `zip1/zip2.4s`, `trn1/trn2.4s`, `rev64.4s` | shuffles |
| `ins.s v.s[i], Wn` | insert scalar into lane |
| `smov/umov Wn, v.s[i]` | extract lane to scalar |
| `fmov` between scalar GPR/FPR and lanes | scalar↔vector marshal |
| `.2d` variants of the arith instructions | f64 when precision matters |

Later (not MVP): `tbl`/`tbx` for wavetable lookups,
`sdot`/`udot` for fixed-point, `fcvtas`/`fcvtzs` for rounding modes.

### How NEON words look

fy exposes NEON as words, not raw asm. A NEON word takes register
operands from the stack and emits the right instruction. The
programming model is: "signals flow through v-registers; pointers
flow through the data stack."

Sketch (syntax is illustrative; exact form TBD):

```forth
dsp: saw-block ( buf n freq sr -- )
  [ | buf n freq sr |
    freq sr f/ vdup.4s v0         ( v0 = delta per sample broadcast )
    0.25 vdup.4s v1                ( v1 = lane index * delta, to be added )
    0 n 4 / [ | i |
      buf v2 ld1.4s                ( v2 = 4 current phases )
      v0 v2 fadd.4s v2              ( phase += delta )
      v2 frac.4s v3                 ( v3 = fractional part in 0..1 )
      2.0 vdup.4s v4
      v4 v3 fmul.4s v3 1.0 vdup.4s fsub.4s v3
      v3 buf st1.4s
      buf 16 + buf!                 ( advance ptr by 16B )
    ] dotimes
    ( scalar tail for (n mod 4) samples — elided )
  ] do
;
```

Verbose, but this is the **floor**; real code goes through
combinators. See below.

## Combinators — making DSP palatable

Combinators are `macro:` words that expand at compile time. They
accept quote bodies and emit fused, unrolled loop code. Because they
run at compile time, they have full access to the AST and can reason
about which v-registers are free, inline callees, etc.

### `sample-each` — the baseline scalar iterator

```forth
dsp: gain ( in out n g -- )
  [ | x | x g f* ] sample-each
;
```

Expands to a straightforward `0 n [ ... i ... ] dotimes` that loads
`x`, runs the body, stores the result. Worst perf, best portability
(no NEON). Use when vectorization can't apply (irregular
control flow, non-audio rate processing).

### `vec-each` — the workhorse

```forth
dsp: gain-v ( in out n g -- )
  [ | v | v g vdup.4s fmul.4s ] vec-each
;
```

Expands to:

1. A 4-wide unrolled main loop that:
   - Loads 4 f32 from `in` into a fresh vreg (`v` becomes that reg)
   - Splices the body quote (so `v g vdup.4s fmul.4s` becomes
     `v0 v1 fmul.4s`)
   - Stores the result to `out`, post-incrementing both pointers
2. A scalar tail for `n mod 4` samples, using the *same* body quote
   but with scalar substitutions (`v → s`, `.4s` variants → scalar
   instructions). For bodies that only use `.4s` arithmetic this
   works automatically.

If the body uses an instruction that has no scalar form, the author
provides a separate tail quote:

```forth
dsp: fancy-shape ( in out n -- )
  [ | v | v tanh-approx.4s ]     ( vector body )
  [ | s | s libm:tanh ]          ( scalar tail body )
  vec-each-with-tail
;
```

### `pipeline` — stage fusion

```forth
dsp: voice-tone ( in out n -- )
  in out n {
    [ | x | x drive f*         ]
    [ | x | x 0.5 softclip      ]
    [ | x | x cutoff reso svf-lp ]
  } pipeline
;
```

Expands to a **single** `vec-each` loop where all three bodies are
inlined sequentially in the same loop iteration. No intermediate
buffers. No cache round-trip. One read from `in`, one write to
`out`, everything between in v-registers.

Requirements for fusion:

- All stages are `(x -- y)` shape (scalar in, scalar out), possibly
  consuming additional stack inputs for per-block constants.
- Stateless between samples (stateful stages use `stateful:` form
  instead — below).

Stages that *can't* fuse (resampler, STFT) use `buffer-pipeline`
(below), which does use intermediate buffers but allocates them from
the block arena.

### `stateful:` — IIR / state-machine stages

```forth
dsp: svf-lp stateful: ( f32 ic1 f32 ic2 ) ( in out n fc q -- )
  [ | x fc q |
    ( reads and writes ic1, ic2 as locals in the closure )
    ... svf math ...
  ] vec-each
;
```

The `stateful:` clause:

1. Reserves slots in the machine's persistent arena for the named
   state fields.
2. Loads them into locals before the loop.
3. Stores them back after the loop.
4. Exposes them as mutable locals to the body.

Per-voice state (filter state that lives *inside* a voice) uses
`voice-stateful:` which reads/writes from the voice slab in
`ctx.voice_state` instead of the machine's persistent arena.

### `voice-each` — polyphonic dispatch

```forth
dsp: uno-process ( ctx -- )
  [ | vctx |
    vctx uno-voice
  ] voice-each
;
```

Expands (at compile time, against the host's `VoicePool` service) to:

1. Reset the output buffer (or zero-fill from block arena, depending
   on config).
2. For each active voice in the pool:
   - Build a `VoiceCtx` pointing at that voice's slab, its envelope
     state, its pitch/velocity/release flag.
   - Splice the body.
   - Accumulate the voice's output into the machine's output buffer
     (additive mix).
3. Handle note-on / note-off edges: mark voices as releasing when
   note-off fires; retire voices whose envelope has decayed below
   `-96dB` (or whatever the machine's "retire threshold" is).

The machine author writes **one voice's sound**; poly is free.

### `oversample-N` — clean nonlinear stages

```forth
dsp: uno-voice ( vctx -- )
  [ | vctx |
    ( same code as 1× would be, runs at N× sr internally )
    vctx phase vctx freq polyblep-saw
    drive saturate
    cutoff reso voice-filter
  ] 2 oversample vec-each
;
```

The combinator:

1. Allocates 2 intermediate buffers from the block arena, 2N samples
   each.
2. Upsamples the inputs the machine reads (or, more commonly, the
   generators inside the body run directly at 2N since they don't
   read buffers).
3. Runs the body at 2N rate.
4. Downsamples the output to N.

Up/downsampling kernels are stock (polyphase FIR halfband cascades,
written once as `dsp:` kernels in the core library).

Oversampling should prefer islands/chains over tiny independent
wrappers. Do not upsample/downsample around every stage in a chain:
upsample once, run oscillator/filter/nonlinearity or input/nonlinearity
chain at the higher processing rate, then downsample once.

## Compile-time fusion — how it actually works

fy has `macro:` which runs fy code at compile time. A combinator
like `vec-each` is a macro. It receives its arguments
(the body quote, the `in`/`out`/`n` variables) as compile-time
values, and emits fy code for the final unrolled loop. The emitted
code then goes through the normal `dsp:` compile path with NEON
available.

Key property: if the body is itself a `dsp:` word, its body is
**already inlined** into the caller before the combinator sees it
(because `dsp:` mode default-inlines). So `pipeline` chaining three
stages sees the three bodies directly and splices them into one
loop, not three function-call bodies.

## Kernel library — initial surface

These are what the core ships with. All `dsp:` words. The broader
organization is layered in
[13-dsp-workbench.md](13-dsp-workbench.md#kernel-library-as-layers):
primitives -> control -> shapers -> state/time -> filters -> voices ->
machines.

### Oscillators

```
sine.4s                  ( phase -- sample )
polyblep-saw.4s          ( phase delta -- sample )
polyblep-pulse.4s        ( phase delta width -- sample )
polyblep-tri.4s          ( phase delta -- sample )
wavetable-osc.4s         ( phase wt-ptr wt-size-log2 -- sample )
super-saw.4s             ( phase delta detune mix -- sample )   -- 7-saw
noise-white.4s           ( state-ptr -- sample )                -- xorshift
noise-pink.4s            ( state-ptr -- sample )                -- filtered
```

### Filters (all ZDF where relevant)

```
svf.4s                   ( x fc q state-ptr -- lp bp hp )       -- 3 outs
ladder.4s                ( x fc q state-ptr -- y )              -- Moog 4-pole TPT
diode-ladder.4s          ( x fc q state-ptr -- y )              -- TB-303
ms20.4s                  ( x fc q state-ptr -- y )
one-pole.4s              ( x fc state-ptr -- y )                -- for smoothing
biquad.4s                ( x coefs-ptr state-ptr -- y )         -- EQ only
linkwitz-riley-4.4s      ( x fc state-ptr -- lo hi )            -- multiband crossover
```

### Envelopes

```
adsr.4s                  ( state-ptr a d s r gate -- env )
dahdsr.4s                ( state-ptr d-delay a h d s r gate -- env )
env-follower.4s          ( x state-ptr atk rel -- env )
```

### Modulators

```
lfo-sine.4s              ( state-ptr rate -- y )
lfo-triangle.4s          ( state-ptr rate -- y )
lfo-sh.4s                ( state-ptr rng-ptr rate -- y )
lfo-tempo-sync.4s        ( state-ptr div -- y )                 -- reads ctx tempo
```

### Shapers

```
tanh.4s                  ( x drive -- y )                       -- approx, ~3% THD at unit
softclip.4s              ( x threshold -- y )
hardclip.4s              ( x threshold -- y )
asymm-sat.4s             ( x pos-drive neg-drive -- y )
chebyshev-3.4s           ( x a1 a3 -- y )                       -- cubic shaper
```

### Dynamics

```
peak-detect.4s           ( x state-ptr atk rel -- env )
rms-detect.4s            ( x state-ptr window -- env )
ballistic-gr.4s          ( tgt-gain state-ptr atk rel -- gain )
lookahead-buf.4s         ( x state-ptr samples -- y )           -- reads from block arena
```

### Delay / reverb primitives

```
delay-line.4s            ( x state-ptr delay-samples -- y )
allpass.4s               ( x state-ptr delay g -- y )
comb.4s                  ( x state-ptr delay g -- y )
```

### Stereo / mid-side

```
ms-encode.4s             ( L R -- M S )
ms-decode.4s             ( M S -- L R )
haas.4s                  ( x state-ptr delay-samples side -- L R )
```

### Pitch / sampling

```
glide.4s                 ( x state-ptr rate -- y )
sample-play.4s           ( pos ptr length interp-mode -- y )
```

### Spectral

```
stft-process             ( in out n state-ptr window size hop body-word -- )
                         -- the combinator, not a raw kernel;
                            windows, FFTs, calls body per frame,
                            IFFTs, overlap-adds
```

All of these are **tens of lines each** once the base NEON primitives
exist. See also [10-roadmap.md](10-roadmap.md) for build order.

## Writing fast machines

Tracks render in parallel (docs/07 §Parallel rendering), but one track
renders on one core at a time: its instrument and insert chain have 20.8
µs per sample at 48 kHz, and a heavy track on the critical path sets the
whole block's time. A busy song, like songs/sweat_geometry with 29
tracks, used most of a core before the optimizations below. So cost is
part of a machine's design. These rules
come from measurements, most-effective first.

**1. Do the work at block rate.**
- Anything that depends only on knobs belongs in `block-prepare` or
  `derive`, which write the derived fields of params: coefficients
  (`tan-warp`), `db>lin` gains, `exp` time constants, and table indices.
  The render word then only reads those fields.
- A voice's slow modulation (envelope-to-cutoff and the like) can go in
  `control!` (docs/04), which runs every N samples.
- One `exp` or `tan` in the per-sample path costs tens of ns.

**2. Branch on params with `ifte`, not `select`** (§Branching).
- A mask built from params, ctx or fields the body never stores to is
  versioned. The untaken arm costs nothing, and there's no branch in
  the loop.
- Put every mode, waveform switch, "stage off at 0" knob and oversampler
  that can be bypassed behind one. This was 1.1–2.7× on sat2, Profit-5,
  funk, era and the sampler.
- Keep the guard loop-invariant. If the body stores to a field the guard
  reads, or has an `f!i` into the struct, the `ifte` if-converts and
  saves nothing.
- Use `select` for signal-dependent choices (sign, clip, envelope
  stage). Those if-convert anyway.
- Decide deliberately what a stateful arm does when it switches back:
  hold its state or zero it (§Branching, stateful arms).
- More than 32 bodies falls back to if-conversion. Nest only switches
  that really multiply.

**3. Stay lane-eligible** (§Lane mode).
- A dual-mono effect renders both channels in one NEON pass, and a
  voice pool with `voices! > 1` renders voice pairs. That's 1.1–2.9× in the
  bench, with no source change: eq2 52 → 18 ns, Profit-5 1475 → 884 ns.
- Lane mode refuses a render word that has stack outputs or f64
  arguments, stores through params, or is a `call:` composition. The
  refusal is logged as "renders without NEON lanes".
- A mask on `ctx.chan` if-converts in lane mode. Prefer per-channel
  state that `prepare` seeds from `ctx.chan` (e.g. a tap offset) over
  branching on the channel per sample.
- `stereo` effects get one pass, and there are no lanes to use.

**4. Let the host put you to sleep** (docs/04 §Idle skipping).
- A machine whose output and input both stay under −120 dBFS for its
  hold isn't called at all. A voice goes idle once it is released and
  its block peak drops under the same floor.
- Things that defeat this:
  - noise, hiss or dither that runs without input or envelope;
  - a DC offset;
  - a release that decays to a floor above 1e-6 instead of to zero.
- Gate the machine's own noise by its envelope or input level.
- Declare `tail!` correctly. Too short cuts sound off, and `-1.0` keeps
  the machine awake forever, so use `-1.0` only for machines that really
  do make sound from silence.

**5. Oversample only the nonlinearity.** Wrap just the shaper in
`up4`/`dec4` (00-primitives/oversample.fy), not the filters and the
mix around it. Branch the oversampler away when the stage is clean
(sat2 does this at SAG 0 in the plain modes).

**6. Keep the per-sample graph tight.**
- Spills inside the loop and calls inside the loop are the expensive
  parts (§Compiler reports).
- Inline value-returning stages into one word, and use `call:` only to
  outline.
- For a large voice, compose it from separate kernel calls. Don't chain
  many complex word calls inside one `dsp:` word (a known fy limit).

**7. Voice count is cost.** Profit-5 costs per ringing voice (a 4-voice
stab track about 20% of a core). Size `voices!` to the instrument and
keep releases honest.

**Measuring.**
- `zig build bench -Doptimize=ReleaseFast -- machines/<id>` reports
  ns/sample per case and a `## cost` section (docs/13 §Bench v2). Debug
  builds cost about 1.7× more.
- To A/B an optimization, run with and without `--no-branches` or
  `--no-neon`. The audio must be bit-identical, per `--check` against
  the goldens.
- For a song, `slab song.slab --render out.wav` prints its render-only
  time. `--no-idle-skip --no-neon --no-branches` gives the unoptimized
  baseline.

## Inline vs dev mode

Two compile strategies controlled by a runtime flag:

- **Dev mode (default while authoring):** `dsp:` callees are *not*
  inlined; they stay as `BL`. Hot-patching a kernel works normally
  — the next audio block picks up the new trampoline target. Slower
  (~5–15% depending on kernel density) but essential for livecoding.
- **Ship mode:** full transitive inlining. Hot-patch of an inlined
  kernel requires re-emitting all call sites (host tracks an inline
  registry for this). Faster; normal users ship this way but still
  get hot-patch (just with a ~50ms pause on kernel edit while callers
  recompile).

See [09-hot-reload.md](09-hot-reload.md) for the full story.

## What `dsp:` doesn't yet do (open questions)

- Auto-scheduling of independent chains for latency hiding. Currently
  manual. A later compiler pass could reorder independent `fmla`
  chains for throughput.
- Register allocation under pressure. If a body needs >16 live
  v-regs the generated code will get clumsy. For MVP: document the
  soft limit, trust authors.
- SIMD horizontal reductions (e.g. summing 4 lanes). Available
  instructions but no clean combinator yet.

## Branching (implemented, 2026-09-30)

A `dsp:` body is one straight-line value graph per sample, with no jumps,
and `select` evaluates both of its sides. Before branching, a kernel with
modes paid for every mode. sat2's shaper computed the VALVE and FOLD
curves in all eight modes and multiplied the unused ones by 0.

```forth
params.mode 1.0 f=  [ x 2.0 f* ]  [ x x f* ]  ifte
```

`mask [ then ] [ else ] ifte` takes a mask (a compare, `and`/`or`/`not`)
and two quotes that leave the same stack depth. fy lowers it one of two
ways (`Dsp2.Program.buildVariants`):

- **Versioned.** The mask is loop-invariant. It is built only from
  constants and loads of fields that no store in the body touches (an
  `f!i` store rules out its whole struct), through entry args the sample
  loop doesn't advance (io does advance). In practice that means params,
  ctx and fields the kernel only reads.
  - Each versioned `ifte` splits the word into one straight-line body per
    path of arms.
  - The repeated caller's wrapper evaluates the masks once per call, from
    the params as they stand, and jumps to the matching loop.
  - The untaken arm costs nothing, and the loop has no branch in it.
  - The same test in every inlined copy of a word, or in each `times`
    copy, is one decision (compared structurally), so a shaper inlined
    five times makes 3 bodies, not 3^5.
  - Past `MAX_VARIANTS` (32) bodies, the later `ifte`s if-convert.
- **If-converted.** Any other mask depends on the signal or on state the
  body writes.
  - Both arms are built from the same state, and every stack slot and
    stored field they leave different meets in a `select`. A field only
    one arm stores keeps its old value in the other.
  - The result is correct and bit-identical to a real branch, but it
    saves nothing.
  - An `f!i` store inside a converted arm has no address known at build
    time, so it can't merge through a select. It becomes a conditional
    store: a `cbz` on the arm's mask skips the `str`, the one branch a
    body may hold. Both arms may write the same cell, and nested arms
    AND their masks. A word with one doesn't run in lane mode. (verb2's
    PLATE and ROOM/HALL arms each write their own rings this way under
    `--no-branches`.)
  - A direct call or an inlined stage (one body that must run anywhere)
    if-converts everything.

A NaN mask takes the else arm either way. In lane mode (§Lane mode), a
mask the two lanes can disagree on, such as `ctx.chan`, if-converts, and
the other masks version as usual.

**The toggle.** `Fy.dsp2_versioning`, set from
`fy_raw_machine.dsp_versioning`. `slab --no-branches` and `zig build bench
-- --no-branches` if-convert every `ifte`, for A/B checks. With
`--no-branches --no-neon --no-idle-skip` the sweat_geometry window
renders bit-identical to the engine before any of this work.

**Stateful arms.** A stage that holds state (a filter) stops updating
while its arm isn't taken, where it used to keep tracking the input
unused. At a fixed setting the output is bit-identical to before. It can
differ only after the switch flips. So a switchable stage either:
- holds its state (Profit-5's filters, the sampler's clock: a mode
  change is rare, and holding is what a real switch does), or
- zeroes it in the other arm, so it comes back from rest (funk's MS-20
  below FUNK 0.75, the comp detector's HPF, era's anti-alias filter).

Where it's applied. Every case is bit-identical to the previous kernel,
checked setting by setting (bench, NEON on and off). Measured in ns per
sample, before → after:

| machine | where | ns/sample |
|---|---|---|
| sat2 | SAG at 0 (no rest-point shaper); only the mode's curve (valve, fold, tanh/algebraic knee) | 311 → 170 with SAG, 307 → 169 FOLD, 172 → 160 plain; `render-lite!` retired |
| Profit-5 | FILTER TYPE: one filter and its coefficients; OSC switches PULSE/TRI | 873 → 729 P5, 893 → 550 OB (chord) |
| funk | MS-20 stage below FUNK 0.75 | 610 → 345 |
| cream | waveform switches (12 calls a sample) | 636 → 558 |
| comp2, bus2, char2 | detector HPF off, RMS sqrt only in RMS | 34 → 26, 37 → 27, 157 → 136 |
| era | anti-alias off; one quantizer | 95 → 42 |
| sampler | CLEAN engine; one quantizer (digital.fy) | 129 → 48 CLEAN, 130 → 65 CMI |
| unfairlight | vibrato at depth 0 | 83 → 57 |
| ms20 | VCO waveform switches | 307 → 278 |
| juno2 | PULSE off, SUB at 0 (scalar path) | 344 → 287 |
| verb2 | no gate in PLATE | 99 → 92 |

On the sweat_geometry window: 4.79 s → 3.95 s.

Not done:
- eq2's bands at 0 dB. Their gains are automated through 0, and a
  frozen biquad would click.
- The other `render-lite!` words (bus2, char2, fm86, funk, multi2). An
  `ifte` would only make them simpler, not faster.
