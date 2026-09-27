# 17 — Direction: from fy to the warm sound

Status: **active plan** (2026-09-26). Supersedes the ordering in
[10-roadmap.md](10-roadmap.md) and the near-term milestone in
[13-dsp-workbench.md](13-dsp-workbench.md). Individual tracks below get
their own detailed docs as they start; this one holds the direction and
the order.

## The goal

Slab should sound like a million bucks: Frankie Goes to Hollywood and
Johnny Hates Jazz production, Gap Band basses, synthwave, a good
Rhodes, creamy Moog, lush Juno/Alpha pads, wavetables, punchy drums
with gated reverb, tape delay with wow and flutter, and characterful
samplers.

The machine *designs* are already correct (ZDF ladder, polyBLEP DCOs,
BBD chorus, Dattorro plate, modal Rhodes). What they lack is the stuff
between a correct design and a record: nonlinearity, oversampling,
drift, tape, busses, headroom, musical control scaling, and presets.
Getting there fast depends on the tools: a language that is pleasant
for DSP, one host/machine interface, and a workbench that shows us what
a change did without listening to it.

## Principles

1. **Measure, then listen.** Every DSP change goes through the
   workbench: plots and numbers first, ears last. An agent must be able
   to debug a machine from one PNG and ~30 lines of text.
2. **Everything is kernels.** Filters, shapers, tape, channel strips,
   and the analog imperfection layer are fy kernels composed into
   machines. Nothing DSP-shaped lives in the fy compiler or the host.
3. **One interface.** DAW and workbench run machines through the same
   ctx ABI and the same adapter. If it sounds wrong in the DAW, the
   bench reproduces it exactly.
4. **Controls feel like hardware.** Every knob's full travel is useful,
   modulation sums in octaves and dB, and changes are smoothed.
   "Responsive" is measured with knob-sweep probes, not taste alone.
5. **Imperfection is a dial.** Drift, spread, and noise are shared
   kernels behind one AGE control per machine: 0 is clean and
   deterministic, higher is more vintage.
6. **Headroom everywhere.** f64 through the chain; nothing clips
   between devices. Only the master bus soft-clips.
7. **No compatibility cruft.** Pre-1.0: rename, break, migrate. Golden
   renders are the safety net, not shims.

## Where we are (audit, 2026-09-26)

### fy `dsp2:` ergonomics

Across ~4.4k lines of kernels: 209 `dsp2:` words, **182 lines that only
`drop`/`nip` locals**, **1,154 `Struct.field` accesses**.

- Locals (`| a b |`) don't consume, so words end in cleanup tails and
  running sums are impossible ("each source term is bound before
  summing").
- Arity is inferred by trying 0..16 and swallowing every error, so
  mistakes surface as a bare `BadStackEffect`.
- No register spilling, so large words raise `RegisterExhausted` (the
  "deep composition limit"). `call:` stages can't return values, so
  they talk through scratch fields in state (half of `JunoState`) with
  a store, a load, and a `bl` per stage per sample.
- The math set is `+ - * /`, clamp, frac, wrap, 4-arg `fsel-lt`. No
  abs, min, max, sqrt, negate, or compare, so tan, exp, and tanh are
  hand-rolled series scattered through the kernels, each valid on its
  own range (`svf-g` only up to θ≈0.33). *(Fixed in step 6.)*
- DSP primitives are compiled in: `fms20-svf`, `fms20-lpf4`,
  `fadsr-cap`, and `fpolyblep` are Zig ops in `fy/src/dsp2.zig`, so
  they can't be hot-reloaded. *(Fixed in step 6.)*
- Stores are collected and emitted after the value graph, so reading a
  cell back after storing it likely sees the old value (to confirm).
- The macro system can only `peek-quote`, `emit-lit`, and `emit-word`.

### Machine declarations

Each control repeats its module name, an id that copies the field name,
and the struct offset; then a `strip` line per module, a layout that
names everything again, and entry words by string. Every knob field is
also declared a second time in the params `ustruct`.

### Host ↔ machine interface

The implementation drifted from [04-block-contract.md](04-block-contract.md)
and [08-services.md](08-services.md):

- Each hook has its own signature (prepare, note-on, voice render,
  per-sample effect, block effect, block-prepare, derive).
- Each new need adds a special injected cell (`channel-cell`,
  `tempo-cell`, `detector-cell`, buffer pointers written into state).
- The per-sample effect path calls from Zig into fy twice per sample.
- Voices are mono (copied to L/R); effects are dual mono.
- **Every machine's output is hard-clamped to ±1**, a brickwall
  clipper on every device.
- Voice allocation is fixed in Zig: oldest-free only, with no mono,
  legato, glide, or unison.
- Params are written once per block with no smoothing (zipper).

### Workbench

`src/kernel_probe.zig` is 4.3k lines with 34 hardcoded cases, each with
its own Zig driver. It writes JSON, CSV, and WAV, and plots need Python.
It does not load machines through their manifests.

### Sound

- No machine uses oversampling.
- The Juno ladder is linear.
- The delay is clean digital.
- Nothing drifts.
- There is no bus glue (tape, console, bus compressor) and no gated
  reverb.
- The sampler plays back clean.

MS-20 specifics:

- Envelope and LFO → cutoff are summed **linearly in Hz**.
- ENV is an absolute target frequency, not an amount.
- The filter can't open past 8 kHz (cutoff max 5 k, env-peak max 8 k).
- **DRV is a dead knob**: `drive` is unused and the profile hardcodes
  1.90.
- Resonance acts in two places, which probably bunches its useful
  range into the first part of the knob.

## Findings from the first bench run (2026-09-26)

Step 1 is done (`zig build bench`, [13-dsp-workbench.md](13-dsp-workbench.md#bench-v2--zig-build-bench-implemented-2026-09-26)).
The first run over all 15 machines found the following, before any new
DSP work.

**fy: a JIT caller parked a pointer in x18. Fixed** in fy `38f5df4`.

- x18 is Apple's platform register and the kernel zeroes it on context
  switches.
- The raw repeated caller and the composition caller loaded the slots
  base into it, so JIT code faulted at random (`EXC_BAD_ACCESS` at
  address 0x18). About every other long bench run crashed.
- The DAW's audio thread runs the same callers.

**Rhodes: tuning correct, tone wrong.**

- The "40–59 cents sharp" reading was wrong: it was the autocorrelation
  pitch tracker locking onto the tine's inharmonic 6.267× partial. An
  FFT shows the fundamental at +1.5 cents.
- The real problems were a near-sine tone (2nd harmonic at −21.5 dB, 3rd
  at −35 dB, no velocity-dependent bark), a DC offset, and a startup and
  note-on thump.
- Fixed 2026-09-26 with a flux-derivative pickup (docs/17 G4; see
  `kernels/06-voices/rhodes.fy`).

**FM-86 ignores velocity.**

- Every level reads −8.9 dB from velocity 0.25 to 1.0.
- It costs 2.1 µs/sample for a single note, because all 8 voices always
  render (see D6).
- The default chord clips 9k samples.

**MS-20: the knob sweep confirms the scaling complaint.**

- DRV has no effect (within baseline noise).
- Resonance: 40% dead, uneven 0.55; the brightening saturates by about
  40% of travel.
- Cutoff and env-peak only bite in the upper part of their travel.
- hpf-resonance does nothing at the default 20 Hz HPF.
- Filter attack and decay are dead for the first half.

**Clipping and headroom.** fm86, rhodes, and sampler clip at their own
defaults, and effects clip on the 0 dBFS ladder step. This is D5
(remove the per-machine clamp) in practice.

**Gain staging, measured after D5 removed the clamp.**

- FM-86's default chord peaks at +12.8 dBFS, and single notes at +2 dBFS.
- Rhodes peaks at +4 dBFS (chord +7.4 dBFS).
- The sampler chord peaks at +3.3 dBFS.
- The master soft clip is now the only thing catching these. They are
  default-level bugs in the machines, to fix with their presets (G5).

**Idle voices were not silent.** Once idle voices were skipped (D6), the
old Rhodes goldens turned out to contain a startup thump of about 1.3
amplitude, decaying over roughly 50 ms, from its 7 never-played voices.
The pickup bias feeds a constant into a DC blocker that starts at zero.
The same transient likely fires on every note-on, because note-on resets
the blocker. That is a G4 Rhodes fix: seed the blocker at its steady
state.

**Denormals.** delay2 emits denormal samples in its tails (186 in the
impulse case).

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Rename `dsp2:` → **`dsp:`**. The old v1 mode becomes **`dsp1:`**: legacy and probe-only, deleted once `dsp:` has NEON. *(Amended 2026-09-26: v1 holds fy's only NEON path (`v2f+`, `v2fmadd`) and its register-stack optimizer, so deleting it outright would lose the NEON work.)* Done in step 2. | The docs already say `dsp:`. "Kernel" is taken as a noun for a unit of DSP. |
| D2 | `dsp:` syntax (typed locals, dotted fields, consuming locals, stack effects) lives **in the compiler**. | These are tokenizer and SSA concerns; doing them as macros would be fragile. |
| D3 | Manifest/machine DSL lives **in fy**, built on new **parsing-word** macro primitives. | Keeps slab vocabulary out of the compiler; parsing words are generally useful to fy. |
| D4 | One **ctx ABI**: every entry point is `( ctx s:State p:Params -- )`. | Removes special cells and per-hook signatures; it's what docs/04 intended. |
| D5 ✅ | Remove the per-machine ±1 clamp. f64 inter-device; master soft-clip only. | Headroom. Changes existing renders on purpose; goldens get re-recorded after review. |
| D6 | Voice allocation stays a **Zig host service** (poly, mono, legato, glide, unison), configured from the manifest and delivered as voice events in ctx. | It's control logic, not DSP, and nobody needs to livecode it. |
| D7 | Tables are computed in **normal fy at load time** (`table:`) into the asset arena, swapped atomically on reload, and cached on disk by source hash. | Normal fy can allocate and call libm; the audio thread just reads. |
| D8 | The workbench is **host-in-a-box**: same adapter, same ctx, scripted instead of a sound card. It outputs PNG contact sheets drawn with raylib; no Python. | One code path; cheap for agents to read. |
| D9 | The Live-style graph stays: sends/returns, sidechains, racks (parallel chains), and groups. No free node graph yet. | CLAUDE.md non-goal ordering. |

## Track A — fy `dsp:` language

Everything is confined to `dsp:` (which exists for slab) plus generic
macro primitives, so plain fy stays stable. Detailed spec: a new
`docs/18-fy-dsp-language.md` when the track starts.

**A1. Rename + declared stack effects + errors.**

- `dsp: name ( a b -- c )` and the leading `| … |` frame declare arity;
  no more trial builds.
- Errors name the word, token, and line: "`f+` expects 2 f64, stack has
  1 (after `s.cutoff`)".

**A2. Consuming locals, typed bindings, dotted fields.** *(Done
2026-09-26; see docs/18. Bindings live in frames, not in the paren
declaration: a leading `| s:JunoState x -- y |` frame is the
declaration, so point-free words keep `( x -- y )`.)*
```
dsp: jn-hpf ( s:JunoState p:JunoParams x -- y )
  s.hpf-lp  x over f- p.hpf-a f* f+ | lp |
  lp -> s.hpf-lp
  x lp f- ;
```
- `| x |` pops. `s:T` binds the struct type to a local, so `s.field`
  loads, `s.field&` gives the address, and `-> s.field` stores.
- Store/load ordering follows program order (fixes the deferred-store
  trap).
- A migration script rewrites the existing kernels.

**A3. Register spilling + multi-value returns.** *(Done 2026-09-26;
see docs/18 §Registers and spilling.)* Plain word calls
inline as values, so stages return results and the scratch fields go
away:
```
dsp: juno-voice ( ctx s:JunoState p:JunoParams -- )
  s p jn-mod | lfo env |
  s p lfo jn-dco  s p env lfo jn-cutoff  s ladder4  s p jn-hpf
  env s p jn-vca  ctx voice-out ;
```
`call:` remains as an explicit "outline this" choice for code size.

**A4. Math.** *(Done 2026-09-26, docs/18 §Word set and §dsp-std.
Block-rate libm is not needed: dsp-std is accurate enough for
coefficients.)*

- Native ops: `fabs fneg fmin fmax fsqrt floor`, plus compares
  producing masks and `select`, and an expression-form conditional.
- Named compile-time constants.
- A `dsp-std` library with accurate `exp2 log2 tan sin cos tanh`
  (inlined polynomials or table + interp) replaces the scattered
  series.
- Block-rate words may call libm.

**A5. Fused primitives out of the compiler.** *(Done 2026-09-26: the
MS-20 filters went first; `fadsr-*`, `fpolyblep`, `fpulseblep`,
`fcapramp` and `fwrap01` followed as bit-exact fy words.)* Once A3 and A4 land,
`fms20-svf`, `fms20-lpf4`, `fadsr-*`, and `fpolyblep` become fy
kernels. Keep the old ops just long enough to compare speed.

**A6. Parsing words** (generic fy macro primitives, compile time only):

| Primitive | What it does |
|---|---|
| `next-token` / `peek-token` | Read the source token stream. |
| `parse-until` | Collect tokens up to a terminator. |
| `define` | Create a word from a name and a quote. |
| `emit-quote` | Splice a quote's tokens into the code being compiled. |
| `ustruct-begin` / `ustruct-field` / `ustruct-end` | Generate structs. |
| Compile-time variables | State shared across macros. |

**A7. `table:`.** *(Done 2026-09-26 as `table: name len body ;` with
`name`/`name-len` and `tbl-lerp`, docs/18 §Constants and tables. Tables
are addressed directly rather than through ctx; they outlive hot
reloads. First users arrive with step 9.)*

- `table: name len [ i -- x ]` runs in normal fy at load, and
  `dsp:` code reads it through ctx with interpolated-read helpers.
- Uses:
  - saturator curves and their ADAA antiderivatives
  - oversampling filter taps
  - BLEP residuals
  - exp/tan tables
  - DX7 curves
  - windows
  - wavetable mipmaps (needs one FFT builtin)
- fm86's `derive-data` (fy mallocs, Zig frees) migrates to this.

**A9. NEON across voices.** Polyphonic voices run the same straight-line
kernel, with branches already turned into selects, on independent state.
That is the ideal SIMD shape, so SIMD comes without rewriting kernels.

- **Codegen.** Compile each `dsp:` word a second time in a 2-lane mode.
  Every f64 op lowers to its `.2d` NEON twin:
  - `fadd`/`fmul`/`fmla`
  - `fmin`/`fmax`/`fabs`
  - `fcmgt` + `bsl` for select
  d-registers become q-registers (the same register file), so the
  register allocator is unchanged.
- **Memory.**
  - The host interleaves voice pairs' state (field `k` of voices 2n and
    2n+1 are adjacent), so state loads become `ldr q`.
  - Shared params use `ld1r` (broadcast).
  - Runtime-indexed reads (`f@i` into delay lines and samples) differ
    per lane; they stay scalar per lane with a lane insert.
- **Payoff.** 2× on voices in f64. f32 lanes (4-wide) would give 4× but
  need a precision audit of IIR coefficients at low cutoffs, so that's a
  later, opt-in choice per kernel.
- **Prerequisites.** A3 (spilling), and A5, because the fused Zig ops
  (`fms20-svf`, `fpolyblep`, …) would each need hand-written vector
  twins otherwise.
- **The cheaper win comes first.** D6's voice service stops rendering
  idle voices. FM-86 renders all 8 voices always (10% of a core for one
  note), so skipping silent voices is a 4–8× saving at typical
  polyphony before any SIMD.
- **Legacy.** `dsp1:` NEON (`v2f+`, `v2fmadd`) proves the asm encoders
  work; it gets deleted once A9 lands (D1).

**A8 (later). Loop combinators** (`frames-each`, `voice-each`,
`oversample`) so a machine's entry can be a single `block` word that
owns its loops.

## Track B — one host ↔ machine interface

Converge the code on [04-block-contract.md](04-block-contract.md)
(update that doc as part of the change).

- **ctx** is one `extern struct`, generated into fy as a `ustruct`:

| Group | Contents |
|---|---|
| Timing | frames, sr, 1/sr, tempo, beat position, transport flags |
| Audio | planar stereo in/out, sidechain in |
| Events | notes, param ramps, voice events, all sample-stamped |
| Voice | voice index, count, pitch, velocity, gate, glide target |
| Buffers and tables | host buffers and tables by slot |
| Telemetry | out region for meters and plots |

- **Two render shapes.** `voice` (the host loops over voices and event
  segments) and `block` (true stereo in → stereo out). The per-sample
  effect path is deleted.
- **Stereo voices.** A voice writes L and R, with a helper for mono
  kernels.
- **No clamp** (D5).
- **Voice service** (D6), with modes from the manifest.
- **Param smoothing** per control (`knob … smooth 20ms`), delivered as
  ctx ramps ([08-services.md §2](08-services.md)).
- The special cells (`channel-cell`, `tempo-cell`, `detector-cell`,
  injected buffer pointers) are deleted in favor of ctx fields.

## Track C — workbench v2 (`zig build bench`)

Rewrite of [13-dsp-workbench.md](13-dsp-workbench.md)'s harness section.

- **Levels, all through the same adapter and ctx:**
  1. a single `dsp:` word, auto-wrapped as a one-word machine
  2. a machine via its manifest
  3. a track or chain (instrument, inserts, sends, sidechains)
  4. a song (the engine's offline render path)
- **Cases** live next to machines (`machines/ms20/bench.fy`): a
  stimulus, params and automation, analyses, and ratchet thresholds.
- **Stimuli.**
  - impulse, log sine sweep, fixed sine, saw, noise
  - note sequences and velocity ladders
  - knob sweeps over time
- **Analyses.**
  - waveform plots with zoom windows (attack, steady cycles, release)
  - spectrogram and averaged spectrum
  - frequency response
  - distortion (THD+N) and aliasing (non-harmonic energy)
  - RMS/peak/loudness envelopes, decay and RT60
  - pitch tracking (tuning and drift)
  - DC offset, clicks/discontinuities, NaNs and denormals
  - ns per sample
  - **knob-response curves**: a perceptual metric (spectral centroid,
    loudness, decay time) against knob position
- **Output.**
  - `report.md` of about 30 lines with numbers and pass/fail against
    the ratchet
  - `sheet.png`, one contact sheet drawn with raylib
  - WAVs for listening
- **A/B diff mode** against a git rev, a preset, or the saved golden:
  metric deltas plus a difference spectrogram.
- **One analyzer library.** The same code later feeds the in-DAW plot
  displays.

## Track D — machine DSL and controls

- **Manifest DSL** (built on A6):
```
machine: "Ju-Know"  voice 8 voices  prefix: juno
module: VCF
  knob cutoff "FREQ" 30 .. 16k =1.8k oct smooth 10ms
  knob res    "RES"  0 .. 1    =0.1
module: DCO
  switch range "RANGE" { "16'" 0.5  "8'" 1.0  "4'" 2.0 } =8'
```
  - Knobs generate the params struct; derived fields are declared
    separately.
  - The control id defaults to the field name.
  - Modules become strips automatically, with a default flow layout
    unless `layout:` is given.
  - Entry points are found by convention (`juno-render`,
    `juno-note-on`, …).
  - It emits the same `MachineDesc`, so the host walker is unchanged.
- **Curves and units.**
  - Add `oct`, `db`, bipolar with a center detent, and stepped.
  - Readouts show real units (1.2 kHz, 340 ms, −6 dB).
  - Double-click resets to default.
- **Modulation math.** Pitch and cutoff sum in octaves, levels in dB,
  times on a log scale. This is enforced by `dsp-std` helpers
  (`hz*oct`, `db->lin`).
- **Rule: a knob's full travel is useful.** The bench's knob-response
  curve should be roughly straight, with no dead zones.

## Track E — routing and channel strips

In this order:

1. **Sends and returns** (pre/post fader). This finishes `Track.Kind.ret`.
2. **Sidechain inputs.** Declared in the manifest, fed from another
   track's pre-fader audio or its note triggers. Tracks are rendered in
   topological order; if two tracks sidechain each other, one hears the
   other a block late.
3. **Racks.** A device holding parallel chains with per-chain gain.
   Covers layered instruments, parallel compression, and multiband.
4. **Group tracks.**
5. **Plugin delay compensation (PDC)** for latency from lookahead and
   oversampling ([07-transport.md](07-transport.md)).

The gated snare is the acceptance test: snare → send → reverb return →
gate keyed by the snare.

A **channel strip** machine chains HPF → gate → EQ → compressor →
saturation from the existing kernels. SSL, Neve, and API flavours are
kernel profiles, not separate code. There is optionally a fixed
"console" slot on every track.

## Track F — UI

- **Widgets.** Vertical and horizontal sliders (the Juno-106 panel is
  sliders), segmented switches, LED toggles, number boxes, XY pad, and
  S/M/L knobs.
- **Plot display.** One general display kind with two data sources:
  - *computed:* a UI-thread fy word draws from params (filter response,
    EQ, compressor transfer curve, LFO shape, wavetable frame)
  - *live:* the audio thread writes a small telemetry buffer read
    lock-free, like meters (scope, gain reduction, tape wow)

  It replaces the four fixed display kinds. 1px lines and step plots
  keep the brutalist style.
- **Layout.** Titled group frames, fixed-size items alongside weighted
  ones, and 4px snap.

## Track G — the sound

**G1. Primitives.** *(2026-09-26: oversampler, Moog ladder, the
saturating ZDF ladder and the parametric shaper are in; SEM SVF and the
diode ladder are not. ADAA waits: 4x oversampling already holds the
shaper's aliasing at -70 dB.)*

- A block-rate 2×/4× polyphase halfband oversampler.
- Nonlinear filters:
  - Moog ladder (tanh per stage)
  - OTA ladder (IR3109, for Juno and Jupiter)
  - nonlinear SVF (SEM)
  - diode ladder
- A shaper library (tube, transformer, tape, diode), with ADAA from
  `table:`.

**G2. Analog layer.** *(2026-09-26: `kernels/08-analog/analog.fy` —
drift and spread — with an AGE knob on Ju-Know and Mog Passenger. Oscillators
already free-run, so note-start phase is naturally random. Noise floor
and the project default are open.)*

- `kernels/08-analog/`:
  - drift (filtered noise on pitch and cutoff)
  - seeded per-voice component spread
  - envelope timing jitter
  - oscillator phase at note start
  - noise floor
- One **AGE** macro per machine, a detail page, and a project-wide
  default.

**G3. Effects.**

- Tape echo (wow/flutter, feedback-path saturation, bandwidth loss per
  repeat, multi-head).
- Tape/console bus machine.
- Gated reverb.
- Modulated hall.
- Ensemble chorus (Dimension D / Solina).
- Bus compressor (SSL-style).

**G4. Machines.**

| Target | Machine |
|---|---|
| Gap Band bass, creamy Moog | new Mini-style mono: 3 VCOs, overdriven mixer, nonlinear ladder at 4×, legato glide |
| Juno/Alpha, cinematic pads | juno2 upgrade (OTA filter, drift, 16 voices, unison/stereo spread) + 2-VCO poly (Jupiter/OB) |
| Wavetable | PPG-style: mipmapped tables from `table:`, stepped/smooth morph, analog filter |
| Rhodes | more tine modes, tine/tonebar beating, velocity-dependent strike position, suitcase tremolo/pan |
| FGTH/JHJ drums | sampler era modes (Fairlight, Emulator II, SP-1200, LinnDrum: fixed-rate playback, bit depth, post filter) + kit mapping |
| 808/909 | drum2: oversampled drive, transient shaping |
| MS-20 | scaling fix: exponential modulation, ENV as an amount in octaves, full cutoff range, live DRV, resonance re-curved |

**G5. Presets.** 10–20 per machine, made against references with
hot-reload, alongside the DSP work.

## Sequence

Each step has an exit criterion. Steps 2–7 must reproduce the goldens
(bit-exact, or within 1e-12 where math legitimately changes) unless the
step says otherwise.

| # | Step | Exit |
|---|---|---|
| 1 ✅ | **Workbench v2, minimal:** machine loader through the real adapter, impulse/sweep/note stimuli, report + contact sheet, A/B diff. Record goldens for every machine. | `zig build bench -- machines/ms20` produces a readable sheet; goldens committed. |
| 2 ✅ | A1: rename to `dsp:`, stack effects, errors. | Goldens match; a deliberate typo gives a located error. Done: `dsp: name ( a b -- c )`; errors like ``dsp: typo: unsupported word in dsp: at `fplus` (line 1); stack depth 3``. |
| 3 ✅ | Track B: ctx ABI, stereo, no clamp, voice service, smoothing; the bench moves with it. | Goldens re-recorded after A/B review; special cells deleted. Done: ctx/io ABI (bit-exact), D5 no clamp, idle-voice skipping plus allocation, 20 ms knob glide, `stereo` flag, mono note stack with `ctx.legato`. Glide, unison, and ctx-addressed buffers/tables move to G4 and A7. |
| 4 ✅ | A2: locals, typed bindings, dotted fields + migration. | Goldens match; drop/nip-only lines ≈ 0. Done: consuming frames, `\| ins -- outs \|` declarations, `s:T` / `s.f` / `s.f&` / `-> s.f`, program-order stores; 672 cleanup tokens and 1450 accessors migrated by tools/migrate/, all goldens bit-exact but one intended MS-20 change (docs/18 §Migrations). |
| 5 ✅ | A3: spilling, multi-return. | Scratch fields gone from voice state; the juno voice no longer needs `call:` stages. Done: Belady spilling with a dry-pass trace, cheaper constants, `over`/`rot`; Juno, Rhodes and MS-20 are single voice words, faster than the staged versions (Juno 159→148, Rhodes 109→84, MS-20 200→188 ns/smp). |
| 6 ✅ | A4 + A5 + A7: math, `dsp-std`, fused ops out, `table:`. | No DSP ops left in `dsp2.zig`'s op list; no hand-rolled series in kernels. Done: native `fabs fneg fsqrt floor fmin fmax`, compares to masks + `select`, exponent-bit primitives; the fused ops are fy words, bit-exact; `math.fy` (exp2/log2/sin/cos/tan/tanh…, 1e-12..5e-11) replaced pow2/trig/drum-sine/filter series; `::` constants in dsp; `table:`. Goldens moved by ≤ −60 dBFS except Funk's bistable latch. Juno +20 ns/smp for the accurate prewarp. FM-86 `derive-data` stays for now (its builder is imperative, not a function of i). |
| 7 | A6 + D: parsing words, manifest DSL, curves, units. | All machines ported; `ms20.fy` shorter by half. |
| 8 🔶 | G4 MS-20 fix + knob-response probes on every synth. | Knob-response curves roughly straight on the bench. MS-20: an OTA + diode LPF on 2026-09-26 measured well but sounded dark and samey; replaced on 2026-09-27 by the June probe's driven SVF in fy, with a voice rebuild (docs/14 §LPF v3, §Voice v3). The other synths are still to do. |
| 9 🔶 | G1 + G2: oversampler, nonlinear filters, analog layer. | Aliasing and THD numbers on the ratchet. Done: 4x halfband oversampler, Moog ladder at 4x (self-osc within ~1 cent), saturating Juno ladder, `analog.fy` drift/spread with AGE on Juno and the new Cream Mono (Prodigy/Messenger: sync, SUB/OSC 3, sync sweep), sat2 as a 4x five-mode shaper; goldens carry nonharm/THD and flag a dirtier render. Gain staging: Cream's ladder runs its core quiet (drive-g/8) with makeup, so resonance survives real oscillator levels. The MS-20 went back to the June probe's driven SVF (f-hot/g-wet as a MODE switch), with a clean mixer, RC envelopes, free-running VCOs and a resonant HPF (docs/14 v3). Checked against the originals: Cream gained the Prodigy/Messenger LFO (TRI/SQR/SAW/S&H to pitch and cutoff), Messenger pole-mix filter modes (LP24/LP12/BP12/HP24) and its BASS COMP switch, RC contours and 10 s times. The Juno moved its ENV/LFO/KYBD cutoff modulation from Hz to octaves, got an RC envelope with the real 12 s decay and release, the 60's LFO DELAY, PWM from ENV, and the 106's four-step HPF (bass boost, flat, 225 Hz, 720 Hz); presets were converted and level-matched. Cream's ladder input also gets 1 + k/2 of bass compensation (fundamental −3 dB at half emphasis instead of −9). Open: SEM SVF and diode ladder, ADAA (4x covers it for now), noise floor, a project-wide AGE default. |
| 10 | G3: tape, gated verb, hall, ensemble, bus comp. | — |
| 11 | E: sends, sidechain, racks, groups, channel strip. | The gated snare works end to end. |
| 12 | G4 machines, F UI widgets and plots, G5 presets. | Interleaved; ongoing. |
| 13 | A9: NEON 2-lane voices. | Juno and FM-86 ns/smp roughly halved on the bench cost table at unchanged goldens (within 1e-12). |

## Bets and risks

- **Spilling vs speed.** A3's spilling must not regress hot kernels.
  The bench's ns/sample ratchet guards it.
- **Parsing words in a JIT.** Macros run native code at compile time.
  Parsing words add token-stream access, which should be small, but
  error reporting through macros needs care.
- **Stereo voices double voice cost.** A mono-voice fast path (render
  mono, pan in the host) stays available.
- **fy is a standalone project.** Everything lands in `dsp:` or as
  generic macro primitives; the plain-fy test suite must stay green.
