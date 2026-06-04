# 13 - DSP workbench and kernel ratchet

This is the current refocus: pause feature work on the DAW frame and
build the tooling that lets us co-develop Fy DSP code, optimized kernel
libraries, and complete machines with evidence.

The product goal has not changed. Slab should still become a serious
livecodable DAW. The shortest path there is now the inner loop:

```
fy dsp source
  -> compiler analysis + registerized codegen
  -> deterministic render harness
  -> WAV/control output + plots + metrics + disassembly + perf report
  -> regression ratchet
  -> larger kernels
  -> great sounding machines
```

The DAW UI already exists far enough to host machines. The next
important question is whether those machines can sound excellent and
run fast enough.

## Why this comes before more DAW UI

The signature promise is live-editable machines with no audio quality
ceiling. That promise depends on three things:

- `dsp:` words compile to tight AArch64/NEON, not runtime stack-machine
  soup.
- Kernels compose into bigger sound structures without losing
  performance or testability.
- Every change can be rendered, plotted, measured, disassembled,
  benchmarked, and ratcheted.

If those are true, the DAW frame becomes a powerful shell around a real
instrument workshop. If they are false, more piano-roll and mixer polish
will not save the product.

## Compiler work in `../fy`

Slab links Fy from the sibling checkout `../fy`. The DSP compiler work
belongs mostly there, behind generic modes and flags where possible so
Fy remains a standalone language.

### Modes

Use a layered model:

| mode | purpose |
|---|---|
| `noalloc:` | Generic realtime-safe Fy word. No heap, no ambient I/O, no calls to allocating words. Useful beyond Slab. |
| `dsp:` | `noalloc:` plus typed stack effects, audio-safe primitive set, compile-time quotations, inlining/fusion metadata, and optional NEON. |
| `dsp-dev` | Hot-patch-friendly. May preserve trampoline calls at word boundaries when needed. Emits debug metadata. |
| `dsp-ship` | Fully optimized. Inline registry required so hot-patching an inlined word re-emits dependent callers. |

`noalloc:` answers "can this run in realtime?" `dsp:` answers "can this
compile like a kernel?"

### Runtime quotations are banned

Runtime quote allocation is not part of `dsp:`. A `dsp:` word cannot
create quote values, push quote refs onto the runtime stack, or call
dynamic quote combinators.

Compile-time quotation manipulation is essential and should be beefed
up:

- Quotes may appear as macro inputs.
- Macros may inspect, transform, fuse, and emit code from quotes.
- Combinators such as `vec-each`, `pipeline`, `stateful:`,
  `voice-each`, and `oversample` operate on compile-time quote bodies.
- By the time codegen runs, there are no runtime quote values left in
  the kernel.

This preserves Fy ergonomics without allowing hidden heap access or
dynamic dispatch inside sample loops.

### Registerized lowering

The source language can look concatenative, but the generated kernel
must not be a literal runtime stack interpreter.

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

Compiler invariants for hot loops:

- Top stack values live in registers.
- Locals for hot pointers, phase, coefficients, and state live in
  registers when possible.
- Adjacent float operations fuse without untag/retag between every
  primitive.
- Calls inside the per-sample or per-lane loop are either absent or
  explicitly marked as accepted.
- Stack spills inside the loop are counted and reported.
- The emitted code can be disassembled and associated back to the Fy
  word and, eventually, source spans.

Existing benchmark evidence in
[sessions/mono1-benchmarks.md](sessions/mono1-benchmarks.md) matters:
peepholes helped little, naive machine-code body inlining regressed,
and source-level fused DSP words helped. That points toward pre-lowering
fusion and register planning, not blind copying of already-lowered code.

### Compiler reports

Every compiled `dsp:` word should optionally emit a report:

```json
{
  "word": "kernel:gain-v",
  "mode": "dsp-ship",
  "instructions": 18,
  "loop_instructions": 5,
  "calls_inside_loop": 0,
  "stack_spills_inside_loop": 0,
  "scalar_float_tag_ops_inside_loop": 0,
  "neon_registers": 3,
  "gpr_registers": 4,
  "estimated_bytes": 72
}
```

The report is part of the test surface. "It sounds right but compiled
into junk" should fail a compiler/perf test before it becomes a habit.

## Kernel library as layers

Build kernels in layers. Lower layers should be small, sharp, heavily
tested, and reusable. Higher layers should be compositions that sound
like musical building blocks.

Suggested repository layout:

```
kernels/
  00-primitives/
  01-control/
  02-shapers/
  03-state/
  04-filters/
  05-time/
  06-voices/
  07-effects/
  08-machines/
```

Current first fixture:

```
kernels/00-primitives/v2.fy
  k-v2-add     ( dst a b -- )
  k-v2-mul     ( dst a b -- )
  k-v2-fmadd   ( dst acc a b -- )
```

These are intentionally raw f64x2 buffer kernels backed by Fy NEON
words. They are not the final audio-rate authoring API; they prove the
compiler/ABI/reporting path that higher-level kernels will use.

Run them through:

```sh
zig build kernel-probe -- \
  --kernel=kernels/00-primitives/v2.fy \
  --word=k-v2-add \
  --case=v2-add \
  --iters=1000000 \
  --out=scratch/kernel_v2_add
```

The probe writes metrics JSON, disassembly text, and lane CSV. Numeric
mismatch or non-finite output fails the process, so the command can be
used directly as a ratchet.

Current shaper fixture:

```
kernels/02-shapers/tanh_table.fy
  k-tanh-table  ( out in table span drive -- )
```

This is the first device-flavored kernel: a single-sample tanh
saturator backed by a precomputed f64 table over `[-4, 4]`. The probe
samples off-grid points so the ratchet checks linear interpolation
between table cells, not just exact table addresses.

Run it through:

```sh
zig build kernel-probe -- \
  --kernel=kernels/02-shapers/tanh_table.fy \
  --word=k-tanh-table \
  --case=tanh-table-sweep \
  --iters=1000000 \
  --out=scratch/kernel_tanh_table
```

### Layer 0: primitives

Arithmetic, interpolation, clamps, wrapping, min/max, FMA, reciprocal
approximations, vector load/store, lane shuffles, typed pointer access.

Examples:

```
fma
fmadd
fclamp
fclamp01
fwrap01
lerp
mix2
db->amp
amp->db
```

### Layer 1: control signals

Control-rate and audio-rate modulation building blocks.

Examples:

```
one-pole
slew
adsr
dahdsr
env-follower
lfo-sine
lfo-triangle
lfo-sh
gate-edge
sample-hold
drift
```

These must be plottable as control signals, not only listened to as
audio. Envelope timing bugs should show up as curves.

### Layer 2: shapers and nonlinear cells

Memoryless and memory-bearing nonlinear units.

Examples:

```
tanh-approx
softclip
hardclip
asymm-sat
chebyshev
fold
diode-stage
hysteresis-lite
colored-saturator
dynamic-hf-loss
```

These get THD, harmonic balance, alias-energy, DC-offset, and
level-sweep tests.

### Layer 3: state and time primitives

Reusable stateful blocks.

Examples:

```
delay-line
frac-delay
allpass
comb
wow-flutter-delay
noise-white
noise-pink
noise-colored
dc-block
```

These need impulse, step, stability, interpolation, and latency tests.

### Layer 4: filters

Musical filter cores and supporting pieces.

Examples:

```
one-pole-lp
svf
biquad
ladder-tpt
diode-ladder
ms20-filter
formant-bank
linkwitz-riley-4
```

Filter tests should include frequency response, cutoff accuracy,
resonance behavior, self-oscillation threshold where relevant,
nonlinear drive harmonics, stability, NaN/Inf counts, and modulation
sweeps.

### Layer 5: voice abstractions

Reusable voice chunks that are still machine-agnostic.

Examples:

```
subtractive-voice
dx-operator
dx-algorithm
string-voice
supersaw-bank
wavetable-voice
drum-voice
```

These are where smaller kernels start clumping into instruments.
They should still be testable outside the DAW frame.

### Layer 6: machines and mastering chains

Complete instruments/effects that users select in the DAW.

Examples:

```
juno-ish
dx7-ish
wavetable-poly
tr-808-ish
tape-sat
colored-compressor
plate-reverb
synthwave-master
```

The long-term fidelity target is a complete synthwave track rendered
inside Slab using bundled machines: solid oscillators, virtual analog
filters, saturation, chorus/delay/reverb, compression, limiting, and a
master chain that can stand up outside the toy category.

## The DSP workbench

The workbench is a deterministic offline runner for Fy kernels and
machines. It should be usable from tests, from Codex, and by a human
author trying to understand a sound.

Potential command shape:

```sh
slab-dsp run tests/dsp/filters/ms20_sweep.toml
slab-dsp plot out/dsp/filters/ms20_sweep/
slab-dsp bench tests/dsp/compiler/gain_vec.toml
zig build test-dsp
zig build bench-dsp
```

### Fixture input

A fixture should be able to specify:

- Fy source file or inline program.
- Entry word to call.
- Sample rate, block size, render length, and oversample factor.
- Audio input files or generated input signals.
- Note/gate event streams.
- Param constants, envelopes, automation lanes, and sweeps.
- Initial persistent/voice state where needed.
- Expected output bounds, reference files, and perf budgets.

Example shape:

```toml
[program]
file = "kernels/04-filters/ms20.fy"
entry = "ms20-test-render"

[render]
sample_rate = 48000
block_size = 64
seconds = 4

[[params]]
name = "cutoff"
sweep = { from = 80, to = 12000, curve = "exp" }

[[params]]
name = "resonance"
value = 0.72

[[signals]]
name = "gate"
kind = "control"
events = [
  { t = 0.00, value = 1 },
  { t = 1.50, value = 0 },
]

[expect]
nan_count = 0
alias_energy_db_max = -70
dc_offset_abs_max = 0.0005
```

### Output artifact folder

Each run writes one artifact directory:

```
out/dsp/filters/ms20_sweep/
  render.wav
  control_cutoff.wav
  control_env.wav
  waveform.png
  spectrogram.png
  spectrum.png
  control_stack.png
  metrics.json
  perf.json
  disasm.txt
  report.md
```

Audio plots:

- Oscillogram / waveform.
- Spectrogram.
- Static spectrum.
- Harmonic table.
- Difference plot against reference.
- Optional stereo correlation or Lissajous plot.

Control plots:

- Envelope/LFO/gate oscillograms.
- Param sweep curves.
- Stacked audio + control view, time-aligned.
- Gate/event markers overlaid on audio.

The stacked view matters. A compressor envelope, filter cutoff sweep,
gate stream, and audio output should be inspectable on the same time
axis.

### Metrics

The workbench should compute domain-specific metrics, not just "file
changed".

Oscillators:

- Fundamental frequency error.
- Alias energy above valid harmonics.
- Harmonic amplitudes and spectral slope.
- Phase continuity.
- DC offset.
- Click/discontinuity detection.

Filters:

- Impulse and step response.
- Cutoff accuracy.
- Resonance peak.
- Stability and NaN/Inf count.
- Self-oscillation threshold.
- Drive harmonic profile.

Shapers/saturation:

- THD vs input level.
- Even/odd harmonic balance.
- Alias energy.
- DC offset.
- Dynamic high-frequency loss.

Envelopes/control:

- Attack/decay/release timing.
- Sustain level.
- Overshoot.
- Retrigger behavior.
- Sample-accurate gate response.

Dynamics:

- Gain-reduction curve.
- Attack/release timing.
- Overshoot.
- Envelope ripple.
- Latency.
- Null/difference against expected curve.

Compiler/perf:

- ns/sample.
- realtime factor at 48k.
- allocations.
- calls inside loop.
- stack spills inside loop.
- scalar tag/untag operations inside loop.
- disassembly constraints.

## Test ratchet

Tests should support bounds and ratchets, not only exact references.

Exact audio equality is useful for deterministic primitives. It is the
wrong default for musical nonlinear systems. Most tests should use
bounded metrics:

```json
{
  "peak_dbfs": { "max": -0.1 },
  "dc_offset": { "abs_max": 0.0005 },
  "alias_energy_db": { "max": -75 },
  "fundamental_error_cents": { "abs_max": 0.5 },
  "nan_count": 0,
  "calls_inside_loop": 0,
  "stack_spills_inside_loop": 0,
  "ns_per_sample": { "max": 3.5 }
}
```

Ratchet behavior:

- If a metric improves, update the stored bound intentionally.
- If a metric worsens but stays within bound, the report should still
  show the delta.
- If perf gets slower or disassembly grows suspiciously, fail where
  the kernel has a budget.
- Golden plots are review artifacts, not the only oracle.

This is the loop Codex can work with: run a failing fixture, inspect
plots/JSON/disassembly, modify Fy or Slab, rerun, keep the regression
test.

## Oversampling

Oversampling should be a composable island, not a whole-engine default.

Rules:

- Oversample nonlinear chains, not every tiny block independently.
- Upsample once, run the chain, downsample once.
- Keep mixer, clean EQ, delay tails, most reverb, meters, and routing at
  base rate unless there is a measured reason.
- Realtime modes should default lower than offline render modes.

Two surfaces are useful:

1. **Host wrapper:** a manifest-level `oversample: N` for a complete
   machine or effect.
2. **Kernel combinator:** an `oversample` macro for local nonlinear
   chains inside a voice/effect.

The context must be rate-aware. Inside an oversampled island, kernels
need the effective processing rate for oscillator phase increments,
filters, envelopes, LFOs, delay lengths, and smoothing. The host should
expose:

```zig
base_sample_rate:    f64,  // project/device rate
process_sample_rate: f64,  // rate seen by this process call
oversample_factor:   u32,
```

`ctx.sample_rate` may remain as a compatibility alias, but its meaning
must be explicit. Prefer making it the effective process rate and adding
`base_sample_rate` for project-rate decisions.

## Machine DSL tightening

Machine authors should not juggle raw cells for ordinary structure.
The DSL should let them declare the important surfaces once and get
safe host-visible layout, UI binding, smoothing, buffers, and tests.

Desired shape:

```forth
params: TapeParams
  knob input      f32 default 0.0  range -24.0 24.0 unit "dB" smooth 5ms
  knob drive      f32 default 0.4  range 0.0 1.0
  knob tone       f32 default 0.5  range 0.0 1.0
  knob wow        f32 default 0.1  range 0.0 1.0
  knob flutter    f32 default 0.05 range 0.0 1.0
  toggle hiss     bool default false raw
;

buffers: TapeBuffers
  delay wow-delay samples 4096 interp cubic
  state hf-loss-state f32 2
;

machine: tape-sat
  category: effect
  params: TapeParams
  buffers: TapeBuffers
  audio-in: 1
  audio-out: 1
  oversample: 4
  panel: auto-panel
  dsp: tape-process
;
```

The generated host metadata should include:

- `extern struct` layout for params and state.
- Default values.
- UI control hints.
- Smoothing annotations.
- Automation/modulation eligibility.
- Persistent and block scratch sizing.
- Fixture scaffolds for workbench tests.

Auto-panel is not the final UI for great machines, but it should make a
new kernel immediately playable and testable before a custom panel
exists.

## Near-term milestone

The next useful milestone is not "more DAW features". It is:

1. A `dsp:`/`noalloc:` compiler mode in `../fy` with formal forbidden
   operations and static call checks.
2. A minimal workbench runner that renders one Fy word offline and emits
   WAV, metrics JSON, disassembly, and a report.
3. A gain/filter/shaper fixture set that compares scalar Fy, optimized
   Fy, and a Zig/C reference.
4. A ratcheted benchmark for calls/spills/ns-per-sample.
5. The first layered kernels: primitives, one-pole, ADSR, tanh/softclip,
   delay line, SVF, ladder-ish filter.
6. A mono virtual-analog machine built from those kernels and verified
   through the workbench before it is polished in the DAW.

That is the foundation for audio fidelity and virtual analog weight.
The DAW shell becomes compelling when it hosts machines produced by this
loop.
