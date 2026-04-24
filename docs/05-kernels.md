# 05 — Kernels and `dsp:` mode

Where the sonic character of the product lives. Kernels are fy
words compiled in a restricted `dsp:` mode, with a NEON extension
to fy's assembler and a set of combinators that let authors write
readable DSP that compiles to tight ARM64+NEON.

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

These are what the core ships with. All `dsp:` words.

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

## Performance notes

- **Instruction scheduling matters.** `fmla.4s` is 3-cycle latency,
  4-per-cycle throughput on M-series. A naive IIR chain will run at
  1/3 speed. Canonical pattern: process two independent chains in
  parallel (e.g. two voices' filters), interleave the fmla's. The
  kernel library authors take this seriously; machine authors don't
  usually need to because combinators hand them parallelism.
- **Cache.** Block arena is sized to fit L1 (128kB M1). At 64-sample
  blocks × stereo f32 that's 512B per buffer — room for dozens of
  intermediates.
- **Branches are cheap per-block, expensive per-sample.** Keep
  conditionals at block rate wherever possible. A shaper that
  branches on sign per-sample is slow; `bsl.16b` with a
  compare-mask is fast.

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
