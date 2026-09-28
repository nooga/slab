# 13 - DSP workbench and kernel ratchet

> **Superseded ordering:** the active plan is [17-direction.md](17-direction.md).

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

Current scalar voice-building fixtures:

```
kernels/00-primitives/control.fy
  k-hz-step        ( out hz inv-sample-rate -- )
  k-slew-onepole   ( out current target coeff -- )
  k-vca            ( out input amp level -- )
  k-osc-mix2       ( out osc-a osc-b gain-a gain-b -- )

kernels/04-filters/dc_block.fy
  k-dc-block       ( out prev-x prev-y input coeff -- )
```

These are the first reusable pieces for a subtractive voice. They use
explicit raw pointers for state cells so the same shape can later map to
a per-voice slab in `MachineCtx.voice_pool` or a dedicated voice-state
pointer. Run them through:

```sh
zig build kernel-probe -- \
  --kernel=kernels/00-primitives/control.fy \
  --word=k-osc-mix2 \
  --case=osc-mix2-render \
  --iters=100000 \
  --out=scratch/kernel_osc_mix2

zig build kernel-probe -- \
  --kernel=kernels/04-filters/dc_block.fy \
  --word=k-dc-block \
  --case=dc-block-render \
  --iters=100000 \
  --out=scratch/kernel_dc_block
```

The cases currently covered are `hz-step-render`,
`slew-onepole-render`, `vca-render`, `osc-mix2-render`, and
`dc-block-render`. Each writes metrics JSON, disassembly text, and lane
CSV. The stateful words are intentionally not hidden behind a struct yet
because the current raw `dsp:` ABI has no pointer-offset primitive; the
eventual compiler IR should turn the explicit cells into a real voice
state layout without changing the mathematical tests.

Current perf read: tiny stateless adapters such as VCA and oscillator
mix are sub-nanosecond to about one nanosecond in the probe, while
stateful pointer-heavy words such as one-pole smoothing and DC block
land around 6-7 ns/sample. That is not the math being expensive; it is
the current raw ABI and stack-shaped expression forcing extra loads,
stores, and pointer traffic. The right compiler work is lower-level
stateful primitives, pointer-offset/state-field support, and IR
optimization that keeps loaded state in registers across adjacent
operations.

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

Current filter prototype:

```
kernels/04-filters/ms20_lpf.fy
  k-ms20-lpf4  ( out ic1 ic2 input g damping drive -- )
  k-ms20-lpf4-cubic  ( out ic1 ic2 input g damping drive -- )

kernels/04-filters/ms20_lpf_probe.fy
  ms20-lpf-zig-prototype  ( rendered by the Zig oracle for now )
```

`k-ms20-lpf4` is the first real fy MS-20-style lowpass kernel. It wraps
the low-level fy `dsp:` primitive `fms20-lpf4`, which performs four
nonlinear integrator substeps, clipped feedback/state update, and
output clipping while updating two f64 state cells. Coefficients are
passed in as `g` and `damping`; the host/probe still computes cutoff to
coefficient because `dsp:` does not yet have `tan`, exponential cutoff
mapping, or a dedicated coefficient primitive.

Run the fy kernel ratchet through:

```sh
zig build -Doptimize=ReleaseFast kernel-probe -- \
  --kernel=kernels/04-filters/ms20_lpf.fy \
  --word=k-ms20-lpf4 \
  --case=ms20-lpf4-render \
  --iters=100000 \
  --out=scratch/kernel_ms20_lpf4
```

The rational profile is intentionally gnarly but division-heavy: after
hoisting invariant work it still emits about 157 instructions with 138
scalar float ops. The current ReleaseFast ratchet puts it in the same
range as native Zig for the same math (`fy` around 75 ns/sample, Zig
reference around 80 ns/sample on the measured run), so the remaining
cost is mostly the clipper/filter algorithm, not a giant fy tax. The
main cost centers are scalar `fdiv` in the rational clipper and the
filter denominator.

`k-ms20-lpf4-cubic` is a division-free clipper experiment. It avoids
the rational clipper divisions, but it is not a drop-in replacement:
the current curve saturates much harder in the ratchet. Keep it as a
separate character candidate until listening plots say otherwise.

The older `ms20-lpf-grid` case remains useful as a listening/plotting
workbench: it renders deterministic white noise through logarithmic
cutoff sweeps at several resonance settings, writes a WAV for listening,
and emits a stacked spectrogram with a shared dB scale plus a cutoff
overlay. The noise input is intentional: it makes the resonance ridge
and cutoff movement easier to inspect than a pitched oscillator.

Run it through:

```sh
zig build -Doptimize=ReleaseFast kernel-probe -- \
  --kernel=kernels/04-filters/ms20_lpf_probe.fy \
  --word=ms20-lpf-zig-prototype \
  --case=ms20-lpf-grid \
  --iters=1 \
  --out=scratch/ms20_lpf_grid

python3 tools/audio_probe/plot_kernel_probe.py scratch/ms20_lpf_grid
```

The most promising listening profiles from the early MS-20-ish pass are
kept reproducible in `tools/audio_probe/render_ms20_sweeps.py`:

```sh
python3 tools/audio_probe/render_ms20_sweeps.py --profile=f-hot --source=both
python3 tools/audio_probe/render_ms20_sweeps.py --profile=g-wet --source=both
```

`f-hot` is the balanced candidate: dirty resonance without the obvious
state latch. `g-wet` is the wilder character candidate: more resonant
feedback motion and better for stress-testing. Both use the same design
choice learned from the failed dirty prototype: keep integrator state
mostly linear/leaky, and put the nastiness in a DC-blocked clipped
feedback path instead of hard-clipping the state itself.

Current voice workbench fixture:

```
kernels/06-voices/ms20_voice_probe.fy
  includes k-ms20-lpf4 for filter-kernel availability
```

This renders the first complete subtractive voice sketch: falling
polyBLEP saw plus variable pulse, amp envelope, filter envelope,
smoothed cutoff, driven MS-20-ish lowpass, VCA, and DC blocker. The
rig now sequences Slab-shaped `NoteEvent`s: note-on/off events are
collected into block-local events with `sample_offset`, `kind`, `pitch`,
`velocity`, and `note_id`, mirroring the data the DAW sends through
`MachineCtx.note_in`.

The full voice render uses the same filter math in-process rather than
calling the fy filter across the host/JIT boundary once per sample. The
fy filter itself is ratcheted by `ms20-lpf4-render`; the voice rig is
for sequencing, listening, and whole-signal metrics until we add a fused
voice or buffer ABI.

Run it through:

```sh
zig build kernel-probe -- \
  --kernel=kernels/06-voices/ms20_voice_probe.fy \
  --word=k-ms20-lpf4 \
  --case=ms20-voice-render \
  --iters=1 \
  --out=scratch/ms20_voice_probe
```

The probe writes `scratch/ms20_voice_probe.wav`,
`scratch/ms20_voice_probe_metrics.json`, and
`scratch/ms20_voice_probe_lanes.csv`. The lane CSV includes output,
amp envelope, cutoff, active note Hz, and gate state.

The first DAW-facing bridge for this voice is `raw-ms20`, registered
through `FyRawMachine` rather than the older callback/global-cell machine
style used by `machines/mono1/mono1.fy`. It uses the raw `voice_sample`
ABI plus host-bound raw controls:

```text
prepare(state, params, sample_rate)  -> update sample-rate derived params
host raw controls                    -> write params + filter coefficients
note_on(state, params, hz, velocity) -> set note hz, amp, phase, age
note_off(state, params)              -> latch current age as gate time
render(out, state, params)           -> k-ms20-voice-sample
```

The v0 panel is generated from
`machines/raw_ms20/raw-ms20.manifest`: VCO detune, oscillator mix/pulse
width, LPF cutoff/peak/drive/env amount, VCA level, amp ADSR, and filter
ADSR. The registry loads `raw-ms20` from that manifest, including source
path, entry words, state/param sizes, panel width, and control metadata.
Direct controls write raw params by byte offset. Value controls feed
manifest `derive` rows; the MS-20 cutoff/peak/env mapping is now declared
as `derive|ms20-lpf|cutoff|resonance|env-peak|32|40|112`, which writes
`g`, `damping`, and `g-env` for the DSP2 voice.

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

## Bench v2 — `zig build bench` (implemented, 2026-09-26)

The machine-level workbench from [17-direction.md](17-direction.md)
Track C, step 1. It loads machines through the **same adapter the DAW
uses** (`FyRawMachine` via the manifest, rendered through the `Machine`
interface with a real `MachineCtx`), so a bench render and a DAW render
are the same code path.

```sh
zig build bench -- machines/ms20              # default suite for its kind
zig build bench -- --all --check --no-sheets  # every machine vs goldens (~10 s)
zig build bench -- --all --record             # re-record goldens after review
zig build bench -- ms20 --sweep=all           # knob-response curves, every knob
zig build bench -- juno2 --case=held --preset=NAME -p jn-cutoff=900
```

**Suites** (chosen by machine kind, `src/bench/cases.zig`):

| kind | cases |
|---|---|
| melodic voice | `notes` (C2..C5), `velocity` (4 levels), `held` (C3 2 s + release), `high` (C6, aliasing), `chord` (poly only) |
| drum voice (`note-pitch`) | `hits`: one hit per labeled note |
| effect | `impulse`, `sine` (1 kHz −6 dBFS), `sweep` (20 Hz–20 kHz log), `ladder` (200 Hz at −42..0 dBFS), `burst` (100 ms noise) |

**Output** in `scratch/bench/<machine>/`:

- `report.md`: about 30 lines per machine. Per case:
  - peak, rms, DC, mono/stereo, ns/sample
  - NaN, denormal, and clipped-sample counts
  - a focus table: per-note pitch/cents/level/non-harmonic energy/centroid,
    envelope shape and release, per-hit decay, gain at 100/1k/10k,
    Schroeder T60, THD and non-harmonic energy, level along the sweep,
    and the static transfer curve
- `<case>.png`: one 1280×940 contact sheet:
  - full waveform with note markers
  - log-frequency spectrogram
  - attack, steady, and tail zooms
  - spectrum with harmonic ticks, or the impulse magnitude response
  - the measurement table and a curve
- `<case>.wav`: for listening.

**CPU budget.**

- Each case reports ns/sample and the percentage of one core at 48 kHz
  (20.8 µs per sample).
- The `## cost` section gives the worst case, the per-voice-slot cost,
  and how many instances fit one core.
- `--all` prints a cost table across machines.
- The DSP itself is JIT'd, but the host adapter is Zig, so use
  `zig build bench -Doptimize=ReleaseFast` for real numbers.
- Baseline (ReleaseFast, 2026-09-26):
  - FM-86: 2136 ns (10.3%), because all 8 voices always render
  - Juno: 459 ns (2.2%)
  - Rhodes: 252 ns
  - MS-20: 175 ns
  - Verb: 134 ns
  - every other machine: under 100 ns

- After idle-voice skipping (2026-09-26, ReleaseFast):
  - FM-86: 1079 ns
  - Juno: 160 ns
  - Rhodes: 127 ns
  - sampler: 24 ns

**Goldens depend on the build mode.** The stimulus generators use `@sin`
and `@exp`, which differ at the ~1e-8 level between Debug and ReleaseFast.
Record and check goldens in the default (Debug) build.

**Knob sweeps** (`--sweep=ID|all`).

- 21 knob positions × 0.4 s. Voices get C3 retriggered per step;
  effects get a 110 Hz saw at −12 dBFS.
- Per step it measures level (dB), brightness (log2 spectral centroid),
  and pitch (semitones).
- A no-movement baseline render sets the noise floor.
- Per knob it reports:
  - total change on each axis
  - **dead**: share of the travel doing under 10% of an even share
  - **uneven**: 0 = change spread evenly, 0.5 = all at one end
- It flags knobs with no effect (within the baseline) and uneven knobs.
- Output is a grid sheet `sweep-<id>.png`.

**Goldens.**

- `bench/golden/<machine>.txt` (committed) holds a SHA-256 of the f32
  output per case.
- `--check` compares bit-exactly and exits non-zero on any change.
- Local golden audio in `scratch/bench-golden/` backs a
  `<case>-diff.png` (new − golden waveform and spectrogram) with
  max/rms difference in dBFS.
- A fresh machine instance per case makes renders deterministic; all 74
  default cases reproduce bit-exactly run to run.
- **Ratchet.** Cases with a steady tone (held, high, sine) store their
  non-harmonic energy and THD after the hash. When such a case changes,
  `--check` prints old → new and flags `NONHARM WORSE` past 3 dB: a
  change that makes a render dirtier (aliasing, noise) is visible before
  it is re-recorded.
- Spectra use a 4-term Blackman-Harris window (−92 dB sidelobes), so a
  saw's strong upper harmonics don't read as aliasing.

**Implementation.**

| File | Role |
|---|---|
| `src/bench_main.zig` | runner |
| `src/bench/analysis.zig` | FFT, spectra, pitch, harmonics, envelopes, Schroeder EDC, hash |
| `src/bench/sheet.zig` | panels |
| `src/bench/plot.zig` | CPU RGBA canvas, 1px lines, PNG via raylib's CPU-side `ExportImage`; no window, no GL, no Python |
| `src/bench/font.zig` | 6×11 pixel font generated once by `tools/bench/gen_font.py` |

**Known limits (v1).**

- Instances are never deinit'd (fy teardown bug).
- Only the f32 clamped machine output is visible; the ±1 clamp shows up
  as a `CLIPPED` count until D5 removes it.
- The pitch tracker is autocorrelation-based. It makes fifth and octave
  errors on resonant or detuned tones, so the sweep only trusts pitch
  when it's stable and uses it as the verdict only for pitch-only knobs.
- LFO-driven knobs (mg-pitch at a random LFO phase) need a
  modulation-depth metric.
- Per-machine `bench.fy` cases, kernel-level auto-wrapping, and
  track/song levels come later (docs/17 Track C).
- `kernel-probe` stays until its 34 cases are migrated.

## The DSP workbench (original design)

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

### Dynamics cases

Compressors (`comp2`, and `bus2`/`multi2` when they land; listed by name
in `bench_main.zig`) also run `curve` (1 kHz, −48 → 0 dBFS in 3 dB
steps), `step` (−40 → −10 → −40 dBFS: attack and release τ63 and 10–90 %
of the gain), `lowsine` (50 Hz THD) and `drums` (a synthetic 110 bpm kit
loop: crest, GR per kick and snare, GR 1 ms in, transient-to-body).
Gain is measured sample by sample as out/in, exact for a compressor
(a memoryless multiply), so no meter cell is needed. docs/24 §Test plan.

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

For raw DSP code, fy now has `ustruct:`. It records an untagged,
host-compatible layout and lets `dsp:` lower field access directly to
pointer-offset IR. Accessors are `Name.field@` for f64 loads,
`Name.field!` for f64 stores, and `Name.field-p` when a kernel needs the
field address. These are IR-expanded, so the generated code keeps the
same zero-call shape as hand-written `ptr+ f@64` accessors.

For repeated f64 loads, `Name@:` groups field reads and emits the
corresponding `pick + field@` sequence before IR construction:

```forth
Ms20VoiceParams@: amp-attack amp-decay amp-sustain gate-time amp-release ;
```

The grouped form assumes the source struct pointer is one stack slot
below the values being accumulated, which matches the common DSP pattern
of preserving state/params pointers below derived arguments.

`dsp:` words can name their entry arguments with compile-time locals:

```forth
dsp: voice-filter
  | state params input |
  state Ms20VoiceState.ic1-p
  state Ms20VoiceState.ic2-p
  input
  params Ms20VoiceParams.g@
  params Ms20VoiceParams.damping@
  params Ms20VoiceParams.drive@
  fms20-lpf4
  nip nip nip
;
```

The locals are IR aliases for the original arguments, not runtime quote
locals. They remove most `pick` noise while preserving the explicit stack
contract: the original arguments still exist until the word drops or nips
them away.

The same form works for computed temporaries:

```forth
state params v-amp-env
| amp |
state params v-osc-mix
| osc |
state params osc v-filter
nip
params Ms20VoiceParams.level@
f*
amp
f*
```

That gives fused DSP code a readable way to reuse intermediate signals
without falling back to manual `pick` ladders.

## Raw DSP2 machine adapter

The DAW host should not grow custom Zig wrappers for each serious
machine. The current bridge experiment is `FyRawMachine`: a generic
adapter driven by a small spec containing source path, storage sizes,
mode, and raw DSP2 word names.

The first supported fast path is `voice_sample`:

```text
prepare(state, params, sample_rate)        optional, block-rate
note_on(state, params, hz, velocity)       optional, event-rate
note_off(state, params)                    optional, event-rate
render(out, state, params)                 sample-rate, raw repeated
```

The host owns state bytes, params bytes, event segmentation, MIDI-note
to Hz conversion, output buffers, and render scheduling. fy owns the
machine-specific behavior in the raw DSP2 words. This is the interface
shape we want for the MS-20 voice path: one generic host adapter, many
fy machines.

Effects use the `effect_block` path:

```text
prepare(state, params, sample_rate)        optional, block-rate
render(out, state, params, input)          sample-rate, raw repeated
```

The render word still describes one sample, but the fy raw-call wrapper
executes it across the whole audio block while auto-advancing `out` and
`input` by one `f64` each iteration. The host converts the DAW's `f32`
input channels into `f64` scratch streams, calls the word once per
channel per block, then copies the saturated/clamped result back to
`f32`. This is the first practical realtime effect ABI; a later stereo
block ABI can fuse left/right into one call.

Current fixtures:

- `machines/raw_fixtures/silence.fy` checks the adapter writes zeros.
- `machines/raw_fixtures/oscillator.fy` checks note-on/off and repeated
  raw sample rendering.
- `machines/raw_fixtures/saturator.fy` checks block audio input to raw
  DSP2 effect processing.
- `machines/raw_ms20/raw-ms20.manifest` exposes the first playable raw
  DSP2 voice machine with host-bound controls, backed by
  `kernels/06-voices/ms20_voice_probe.fy`.

`raw-osc`, `raw-silence`, `raw-sat`, and `raw-ms20` are exposed in the
realtime DAW browser. `raw-sat` is still a fixture-grade effect, but it
uses the block raw ABI and should not stall playback the way the old
sample-callback adapter did.

Raw manifest format is deliberately small and line-oriented:

```text
name|raw-ms20
path|kernels/06-voices/ms20_voice_probe.fy
mode|voice-sample
render|k-ms20-voice-sample
prepare|ms20-voice-prepare
note-on|ms20-voice-note-on
note-off|ms20-voice-note-off
state-size|64
params-size|176
panel-w|680
control|VCO|PW|pulse-width|direct-f64|168|0.05|0.95|0.44|linear
control|LPF|CUT|cutoff|value|-|60.0|5000.0|180.0|exp
control|LPF|DRV|drive|direct-f64|48|0.4|2.2|1.25|linear
const-f64|64|0.0035
derive|ms20-lpf|cutoff|resonance|env-peak|32|40|112
```

Control rows are
`control|module|label|id|kind|offset|min|max|default|curve`. `direct-f64`
controls write `offset` in the raw params struct. `value` controls are
named scalar inputs for derived mappings and do not write params directly.
`const-f64|offset|value` writes fixed params at sync time. `derive` rows
encode small host-side coefficient mappings while keeping the machine
definition in the manifest instead of adding custom Zig wrappers.

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
