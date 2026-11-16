# 51 — Modular: modules on rails, patched with cables

**Status: proposal.** Nothing here is built. This doc designs a modular
mode for Slab in the shape of VCV Rack: modules sit on rails, cables
patch them, and the patch plays as a device on a track, so notes,
audio, automation and routing reach it the way they reach any other
machine. It builds on racks ([42-racks.md](42-racks.md)), the kernel
ABI ([04-block-contract.md](04-block-contract.md)) and routing
([23-routing.md](23-routing.md)). Phases are at the end.

## Why it fits Slab

The pieces a modular needs are mostly here already.

- **The kernels are modules already.** `kernels/` holds oscillators,
  filters, envelopes, shapers, drums and effects as separate fy words:
  `tpt_svf.fy`, `ladder.fy`, `ms20_lpf.fy`, `adsr_cap.fy`,
  `primitives/vco.fy`, `folder.fy`, `delay.fy`. A VCF module is a short
  manifest around `tpt_svf.fy`.
- **The ports are in the ABI.** `MachineCtx` (`src/machine.zig`)
  declares several audio ports, note ports and `cv_in` / `cv_out`, and
  docs/04 §Port model describes kinded ports. Only one stereo audio
  pair and one note stream are wired today.
- **Racks did the host work.** `src/machines/rack.zig` is a container
  machine that nests, aligns latency, skips idle parts, and retires
  machines safely. It also added `set_mod(control, norm)` to every fy
  machine, which is the way an existing machine takes CV.
- **fy is the substrate.** A patch is a small program. In the last phase
  the patch compiles to one `dsp:` kernel, and editing a module's
  source while the patch plays is the livecoding goal in
  [00-vision.md](00-vision.md) at its smallest grain.

## Model

```
Modular
  kind      instrument | effect         (from the slot it sits in)
  voices    1..16                       poly channels for the voice section
  macros    [8] Macro                   as a rack's: name, value, mappings
  modules   [≤128] Module
    uid, type, rail, x (in HP), params, state blob (for sequencer steps etc.)
  cables    [≤512] Cable
    from (module uid, output port), to (module uid, input port), color
```

**One machine, two registry entries,** as with racks:

- **Modular** (`modular`): an instrument. It takes the track's notes
  through its NOTES IN and MIDI→CV modules.
- **Modular FX** (`fxmodular`): an effect. It takes the track's audio
  through AUDIO IN, and the sidechain key through KEY IN.

Both are `src/machines/modular.zig` with a `Kind`, beside `rack.zig`.
A Modular can sit in a rack lane, and a rack can't sit in a Modular
(a machine module wraps one machine, not a container; see §Machine modules).

**The patch is a device.** Because it's a machine in a slot, a
Modular gets with no new code:

- note routing, the arpeggiator slot, MIDI input and recording;
- automation of its macros and the controls of its modules (§Automation);
- PDC, idle skipping, freeze, bounce and the render pool;
- presets, rigs and the browser;
- slabkit, through `describe` and the saved form.

A project-wide patch that taps several tracks is phase 5.

## Signals

Every cable carries one kind of signal. Jacks and cables show the kind
by shape: audio and CV jacks are round, note jacks are square.

| kind | what it carries | range |
|---|---|---|
| **signal** | f32 per sample, per channel. Audio, CV, gates and triggers alike, as in VCV. | audio full scale ±1; bipolar CV ±1; unipolar CV 0..1 |
| **note** | a stream of `NoteEvent`s with sample offsets, as on a track | — |

Plain floats instead of volts:

- **Pitch** is 1.0 per octave, with 0.0 at C4 (MIDI 60, 261.63 Hz).
  A pitch input adds to its knob, so a VCO tuned to 0 follows MIDI→CV
  exactly.
- **Gates and triggers** are high at ≥ 0.5. A trigger is high for one
  sample at least; modules detect the rising edge.
- **A CV input** adds `cv × depth` to its knob's norm (0..1) and
  clamps. Depth is an attenuverter (−1..1) beside the jack, or
  hidden at 1 on small modules. This is the same arithmetic as rack
  macros, so a knob's curve applies: CV on an exponential CUTOFF sweeps
  in octaves.

**Poly channels.** A signal cable carries 1 to 16 channels, the patch's
VOICES at most. As in VCV:

- A module's channel count is the largest of its inputs' counts.
- A mono input on a poly module reaches every channel.
- SUM (poly → mono) and SPLIT / MERGE change the count on purpose.

Each channel of a module is one state region, the way a voice machine
gives each voice a region today (`FyRawMachine` regions, `ctx.chan`).
Cables of more than one channel are drawn thicker.

## Polyphony

The patch has a **voice section** and a **mono section**, without a
hard line between them: channel counts decide it.

- **MIDI→CV** takes the notes and allocates voices to channels. Its
  outputs (PITCH, GATE, VEL, PRESS, SLIDE, RETRIG) are poly, so
  everything downstream of them is poly.
- **AUDIO OUT** sums its channels to stereo. Whatever sits between a SUM
  and the output, such as a reverb, runs once.
- **Voice freeing.** A channel is free again when its gate is low and
  AUDIO OUT has seen it silent (`IDLE_FLOOR`) for the idle hold. This
  is how release tails survive without the patch saying how long its
  envelopes are. When every channel is busy, the oldest released one
  is stolen, then the oldest held one, as voice machines do now.
- **Voice allocation is shared code.** The allocator inside
  `fy_raw_machine.zig`, with its mono note stack, poly legato and
  unison, moves into its own file, and MIDI→CV and voice machines both
  use it. MIDI→CV's MODE switch (POLY / MONO / LEGATO / UNISON) chooses
  among the behaviors the allocator already has.

## Modules

### Host modules (Zig)

These touch the engine, so they're Zig, in `src/modular/`:

| module | does |
|---|---|
| NOTES IN | the track's note stream as a note cable |
| MIDI→CV | notes to poly PITCH / GATE / VEL / PRESS / SLIDE / RETRIG, voice allocation, MODE, glide |
| CV→NOTES | PITCH + GATE (+ VEL) back to notes, for driving a machine module or a note output |
| AUDIO IN | the effect slot's input, L and R (Modular FX) |
| KEY IN | the sidechain key, L and R |
| AUDIO OUT | sums channels, L and R; the patch's output |
| TRANSPORT | CLOCK (with a division knob), RESET, RUN, BPM as CV, BEAT position |
| MACRO | the eight macros as unipolar CV outputs |
| SCOPE | a two-trace scope on a dot-matrix display |

### DSP modules (fy)

Every other module is an fy machine of a new kind, `module*`, in
`modules/<id>/<id>.fy`, with presets beside it like a machine's. Its
DSP comes from `kernels/`. A first set:

| group | modules | kernels |
|---|---|---|
| sources | VCO (saw, pulse with PWM, tri, sine, sync, linear and expo FM), WAVETABLE, NOISE (white, pink), FM OP | `01-oscillators/primitives/vco.fy`, `wavetable.fy`, `05-drums/noise.fy`, `fm_operator.fy` |
| filters | SVF (LP, BP, HP, notch), LADDER, MS-20 LPF / HPF, SEM, OTA | `04-filters/tpt_svf.fy`, `ladder.fy`, `ms20_lpf.fy`, `ms20_hpf.fy`, `sem_svf.fy`, `ota_cascade.fy` |
| amplitude | VCA (linear and expo), MIXER 4, CROSSFADE | — |
| modulation | ADSR, AD, LFO (with sync), S&H, SLEW, ENV FOLLOWER | `03-envelopes/adsr_cap.fy`, `primitives/env_rc.fy`, `00-primitives/lfo.fy`, `follow.fy` |
| shape | FOLDER, SATURATOR, RECTIFIER | `07-effects/folder.fy`, `02-shapers/shapers.fy` |
| utility | ATTENUVERTER, OFFSET, QUANTIZER (with scale), COMPARATOR, LOGIC, SUM, SPLIT, MERGE | — |
| sequencing | CLOCK DIV, STEP SEQ 16, TURING (random looping), EUCLID | — |
| effects | DELAY, REVERB, CHORUS, PHASER, BUCKET (lo-fi), RESONATOR | `07-effects/delay.fy`, `reverb.fy`, `chorus.fy`, `phaser.fy`, `lofi.fy`, `resonator.fy` |
| drums | KICK, SNARE, HAT, CLAP, each with a TRIG input | `05-drums/` |

Analog character modules from the voices come next: the MS-20 filter
pair with its drive, the Juno chorus, the CS-80 IL / AL filters, the
Jupiter-8 IR3109 with its taps. Each is a split of a voice that's
already in a machine, so the module and the machine share the kernel.

### The module kernel ABI

A module keeps the entry words a machine has (`derive`,
`block-prepare`, `prepare`, `render`) and changes one thing: its `io`
frame is its own port struct, not the shared `Io`.

```
ustruct: VcfIo
  f64 in          ( audio in )
  f64 cutoff-cv   ( CV inputs come before outputs )
  f64 res-cv
  f64 lp          ( outputs )
  f64 bp
  f64 hp
;

: manifest
  "SVF" module*
  "k-vcf-render" render!
  VcfIo.size io-size!
  VcfState.size state-size!
  VcfParams.size params-size!
  6 hp!                                     ( width on the rail )

  ( port label offset )
  "IN"  VcfIo.in        audio-in
  "CUT" VcfIo.cutoff-cv cv-in  "cutoff" mods
  "RES" VcfIo.res-cv    cv-in  "resonance" mods
  "LP"  VcfIo.lp        audio-out
  "BP"  VcfIo.bp        audio-out
  "HP"  VcfIo.hp        audio-out

  "VCF" "CUT" "cutoff" VcfParams.cutoff 20.0 20000.0 1000.0 curve-exp knob
  …
  machine-desc
;
```

- **`cv-in … "control" mods`** makes the jack modulate that knob: the
  host adds `cv × depth` to the knob's norm per sample and maps it
  through the knob's curve into a per-sample param the render word
  reads. A jack with no `mods` is a plain input the kernel reads from
  `io`; that's what audio inputs, FM inputs and trigger inputs are.
- **The host's caller** gathers each sample's inputs from the cable
  buffers into a block of frames, calls `render` once per frame with
  `io` advancing by `io-size` as it does today, and scatters the
  outputs. Unconnected inputs read 0 (a jack can declare another
  default, such as 1 for a VCA's CV).
- **Channels.** The caller runs once per channel, on that channel's
  state region, with `ctx.chan` set to the channel index.

**Per-sample modulation is the price of a modular.** Today's knobs
reach kernels through 20 ms smoothing at block rate. A modulated param
here changes every sample, so a module recomputes from it per sample:
an SVF's `g` from its cutoff, not in `block-prepare`. Modules use the
cheap coefficient forms (`coeffs.fy`, tan approximations) and make the
mapped path `render-lite` when nothing is patched into it, so an
unpatched filter costs what a machine's does.

## Machine modules

Any machine in the registry can be dropped on a rail. It becomes a
module that wraps one instance:

- **Jacks.** Its audio input (effects), its note input (instruments),
  its sidechain key, and its stereo output. An instrument takes notes
  from a note cable, from NOTES IN or CV→NOTES.
- **CV in, through `set_mod`.** Each control the user exposes gets a CV
  jack. On every 32-sample sub-block the host reads the jack's last
  value and calls `set_mod(control, knob_norm + cv × depth)`, as rack
  macros do, with the machine's own 20 ms smoothing. That's control
  rate, not audio rate: fine for filter sweeps and LFOs, not for FM.
  A machine module says so with a dotted ring around its CV jacks.
- **Exposing controls.** A machine has up to 40 controls, too many for
  jacks. EXPOSE mode, like a rack's MAP, lights the machine's panel;
  clicking a control adds a jack for it. Saved per module.
- **Mono.** A machine module has one channel. A poly cable into it is
  summed (audio) or takes channel 0 (CV). Its own voices give it its
  polyphony.
- **The face.** A machine module shows its normal panel at the panel's
  smallest tier, with the jacks on a strip down its right side.
  Double-click opens its full panel in the bay.

This makes the whole catalog patchable from day one: an MS-20 voice
through a Modular's folder and back into tape2, an LFO in the patch
modulating verb2's DECAY, Fretwire played by a Turing machine.

## Running the patch

### Order and cable delay

On a patch edit, the UI thread builds a **schedule** and hands it to
the audio thread with the same version-and-retire handoff as
`chain.State`:

1. Find the strongly connected components of the module graph
   (Tarjan). A module not in a cycle is its own component.
2. Order the components topologically.
3. Allocate a buffer per output port: channels × sub-block samples.
4. Lay out each module's frame block and its gather / scatter lists.

Each block, in sub-blocks of 32 samples (automation's rate):

- An **acyclic module** renders its whole sub-block at once. Its inputs
  are already complete for that sub-block, so there's no cable delay.
- **A cycle** (feedback: a filter's output into its own FM, a delay
  through a folder back to the delay) renders one sample at a time across
  its modules, in a fixed order, with a one-sample delay on the edge that
  closes it. That's VCV's model, and it keeps feedback patches sounding
  the same at any block size.

Single-sample stepping costs a call per module per sample. Phase 1
measures it; if it is too slow, cycles fall back to a fixed delay of 4
samples and a cycle's modules get a TIGHT switch that pays for 1.

### Real-time rules

Everything allocates on the UI thread and is retired after the audio
thread lets go, as in racks:

- Module instances, state regions, port buffers and the schedule are
  built off the audio thread.
- A cable edit publishes a new schedule. The old one retires after the
  audio thread has adopted the new one.
- Adding or removing a cable crossfades the patch's output across one
  sub-block, so patching while playing clicks no more than a real one.
- Capacities are bounded: 128 modules, 512 cables, 16 channels, 32
  ports per module.

### Latency, idle and tails

- **Latency.** A Modular reports AUDIO OUT's latency: the longest path
  of declared module latencies (`latency!`) into it. Machine modules
  count theirs. A patch's internal paths aren't aligned. A modular's
  user expects that, and an ALIGN module with a delay knob is there if
  they need it.
- **Idle.** A Modular follows the instrument and effect rules in
  docs/04 §Idle skipping. A patch with a free-running module (a
  TRANSPORT clock, a self-oscillating filter, a sequencer, a noise
  source not behind a VCA) is never idle: those modules declare
  `always-on!`, and the schedule records whether any is present and
  connected to AUDIO OUT.
- **Tail.** The idle hold covers tails, as for any machine.

### Parallelism

A patch renders on its track's worker in the render pool. Spreading
a large patch's modules across workers is not planned: sub-block
synchronization would cost more than it saves at these sizes.

## Automation and control

- **Macros** work exactly as in racks: eight knobs on the Modular's
  face, each mapped to controls on modules through ranges and formulas,
  each automatable (`inst:mod-m1`). A MACRO module also puts them in
  the patch as CV.
- **Any module control** is reachable by path, as inside racks:
  `inst:mod/<uid>/cutoff`. Automation sets the knob; CV still adds on
  top.
- **slabkit** builds patches as data, the way it builds racks:
  ```python
  p = Modular(voices=8)
  vco = p.add("vco", rail=0, x=0, wave="saw")
  vcf = p.add("svf", rail=0, x=10, cutoff=800, res=0.4)
  env = p.add("adsr", rail=1, x=0, a=0.005, d=0.3, s=0.2, r=0.4)
  p.cable(p.midi.pitch, vco.pitch)
  p.cable(p.midi.gate, env.gate)
  p.cable(vco.saw, vcf.input)
  p.cable(env.out, vcf.cutoff, depth=0.6)
  ...
  ```

## UI

### The PATCH page

**P** or a PATCH latch beside MIX swaps the arrangement for the patch
page of the selected track's Modular, the way the mixer page works
(docs/23 §Mixer page). With several Modulars on a track, a tab strip
in the page's header picks one. On a track with none, the page offers
to add one. The bay keeps showing the Modular's collapsed face:
macros, VOICES, and a small view of the rails.

```
┌ PATCH  BASS ▾  [MODULAR 1][MODULAR FX]   VOICES 8   CABLES ▣▣▢   [+ MODULE] ┐
│╞═══════════════════════════════════════════════════════════════════════════╡│
││ MIDI→CV │ VCO      │ VCO      │ SVF       │ VCA  │ ADSR    │ LFO   │ OUT  ││
││ ○PITCH  │ (o)TUNE  │ (o)TUNE  │ (o)CUT    │ (o)  │ ▁▃▆▃▁   │ (o)   │ ○L   ││
││ ○GATE ──┼─╮        │          │ (o)RES    │      │ (o)(o)  │       │ ○R   ││
││ ○VEL    │ ○V/OCT   │ ○V/OCT   │ ○IN ◄─────┼──    │ ○GATE   │ ○OUT ─┼─╮    ││
│╞═══════════════════════════════════════════════════════════════════════════╡│
││ STEP SEQ 16 ▮▯▮▮▯▯▮▯▮▮▯▮▯▯▮▯ │ QUANT │ DELAY │ machine: TAPE ECHO         ││
│╞═══════════════════════════════════════════════════════════════════════════╡│
```

### Rails and faceplates

- **Rails** are horizontal rows across the page, one module height
  each: 192 logical pixels, on the 4 px grid. The page scrolls in both
  directions when the patch outgrows it.
- **Width** is in HP of 16 px. A module declares its width (`hp!`);
  machine modules take their small-tier panel's width rounded up to HP.
- **Faceplates** follow docs/06: chamfered hardware surfaces with 1 px
  bevels and engraving, built from the panel catalogue. A module uses
  the small control tier and fits its controls without shrinking them.
  Module panels are declared like machine panels (`strip`, `row`,
  `cell`), plus a `jacks` strip.
- **Jacks** are a new catalogue control: a 12 px socket, round for
  signal and square for notes, with the port's label engraved above.
  Inputs have a dark collar, outputs a light one, as on most hardware.
- **Rail screws and the rail itself** are drawn in the hardware
  material; the space between modules is the flat dark well.

### Cables

- Drag from a jack to a jack to patch. Dragging from an input that has
  a cable picks that cable up; ⌥-drag from an output adds another cable
  from it (outputs fan out, inputs take one cable).
- A cable is a 2 px polyline with sag that grows with its span, drawn
  pixel-exact without antialiasing so it reads as part of the panel at
  integer scales.
- **Colors** cycle through six cable tokens that are not amber: amber
  still means active. A cable's color can be set from its context menu.
- The CABLES control in the header sets cable opacity in three steps
  (solid, faint, hidden), as in VCV, so the panels can be read.
- **Activity.** A cable's plug glows `vfd` orange while its signal is
  above the idle floor, from levels the audio thread publishes per port
  each frame.

### Editing

- **+ MODULE** or double-click on an empty rail opens the browser
  filtered to modules and machines. A module drops at the clicked
  position, pushing its neighbors right if they overlap.
- Drag a module by its faceplate to move it, along a rail or to another
  one. Its cables follow.
- Select with a box. ⌘D duplicates with the internal cables; ⌘⇧D also
  keeps the cables to the rest of the patch.
- Delete removes a module and its cables. Every edit is one undo step
  through the snapshot history (`src/history.zig`).
- ⌘G on a selection saves it as a **patch snippet** in the browser, the
  module equivalent of a rig.

## Files

A Modular keeps its patch in `instrument.state` (or the effect's
`state`), in the form its presets use (docs/19):

```json
{"modular": 1, "kind": "instrument", "voices": 8,
 "modules": [
   {"uid": 1, "type": "midicv", "rail": 0, "x": 0, "params": {"mode": 0}},
   {"uid": 2, "type": "vco",    "rail": 0, "x": 6, "params": {"tune": 0}},
   {"uid": 3, "type": "svf",    "rail": 0, "x": 16, "params": {"cutoff": 800}},
   {"uid": 4, "type": "machine", "machine": "tape2", "rail": 1, "x": 0,
    "params": {…}, "expose": ["drive", "wow"]},
   {"uid": 5, "type": "out", "rail": 0, "x": 40}],
 "cables": [
   {"from": [1, "pitch"], "to": [2, "voct"], "color": 0},
   {"from": [2, "saw"],   "to": [3, "in"],   "color": 1, "depth": 1.0}],
 "macros": […], "maps": […]}
```

- Ports are saved by name, so a module may add ports without breaking
  older patches. A cable to a port that no longer exists is kept in
  the file, drawn as a broken plug and skipped by the schedule, so a
  renamed port can be reconnected by hand.
- A module's own state beyond its params, such as a sequencer's steps,
  saves as a `state` object the module defines, as machines do.
- Modules version with a `schema` in their manifest, as machines do.

## Livecoding

A module is the smallest unit of fy code that makes sound in Slab, so
it's where hot replacement should land first:

- Editing `modules/<id>/<id>.fy` recompiles that module. If its state,
  params and io layouts are unchanged, every instance adopts the new
  code on the next sub-block, keeping its state. If a layout changed,
  instances are rebuilt and the patch crossfades.
- This is docs/09's model at module scale. Whole machines only take new
  code on a new instance today; modules would be the first place Slab
  replaces code while playing.

## The compiled patch (phase 6)

The graph runner calls each module per sub-block or per sample. The
last phase compiles a patch into one fy `dsp:` kernel:

- Each module's render word becomes a call in the kernel, in schedule
  order; cables become locals; a cycle's closing edge becomes a state
  field holding last sample's value. The voice section becomes the
  kernel's per-voice render and the mono section its post-sum word.
- Cables need no buffers, CV mapping is inlined, and the JIT sees the
  whole patch.
- Recompiling on each edit takes the JIT's time, so the graph runner
  keeps playing while a compile runs, and the compiled patch takes over
  when it's ready.

**The blocker is fy's composition limit.** Large inlined `dsp:` words
have produced wrong results (the DX7 voice fold, the MS-20 noise change
on 2026-10-02), and a compiled patch is exactly such a word. This
phase waits on a fy-side reproduction and fix; until then, compiling
groups of modules into separate `call:` stages is the safe form.
docs/50 collects the related language work.

## Open questions

- **Voice idle per channel.** Rendering only the busy channels of a
  poly module saves a lot on sparse parts, but channel indices would
  then be discontiguous. Start with rendering channels 0 up to the
  highest busy one, and measure.
- **NEON.** Four poly channels map onto a NEON lane group the way
  paired voices do now. That would need the module's render word to
  compile in lane form, which dsp2 can do for effects; worth trying in
  phase 3.
- **Notes out of a patch to other tracks** (a sequencer patch playing
  three synths). This needs note routing between tracks in the engine's
  render order, which tracks don't have today. Phase 5.
- **CV out of existing machines.** A `cv-out!` manifest word would let
  a machine publish internal modulation (an LFO, an envelope) to a jack.
  Useful but not needed first.
- **Units.** Plain floats with 1.0 per octave are simpler than VCV's
  volts and match the kernels. The cost is that VCV patch knowledge
  carries over only after dividing by 5 or 10 in one's head.

## Phasing

1. **Engine.** `src/machines/modular.zig` and `src/modular/`: schedule
   building, SCC ordering, sub-block and per-sample stepping, port
   buffers, the `module*` kind and its io ABI in `fy_raw_machine.zig`,
   the voice allocator moved into its own file. Host modules, and
   VCO, SVF, VCA, ADSR, LFO, MIXER, ATTENUVERTER. Patches built from
   slabkit and saved. Bench goldens for a reference patch, and a cost
   check of per-sample cycles. No UI.
2. **PATCH page.** Rails, faceplates, jacks, cables, dragging, the
   browser, undo, scope, cable activity.
3. **The module set.** The full first set in §DSP modules, sequencing
   modules, quantizer with scales, and NEON lanes for poly modules.
4. **Machine modules.** Wrapping, EXPOSE mode, CV through `set_mod`,
   machine modules in the browser, and the analog-character modules
   split out of the voices.
5. **Beyond the device.** Notes out to other tracks, a project-wide
   patch that taps tracks and buses, machine CV outputs.
6. **The compiled patch,** after the fy composition limit is fixed.

Each phase ends with factory patches as presets (a Moog-style mono, a
West Coast plucked voice, a generative Turing patch, a feedback drone),
documented in this doc and listed in docs/20.
