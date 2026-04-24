# 10 — Roadmap

The product is years of work. The architecture is designed so that
each milestone yields something usable and each subsequent
milestone compounds on working foundations. This doc is a bet on
order, not a schedule.

## Current status (2026-04-24)

Slab now has a working DAW-frame prototype with real fy machine
instances. You can create tracks, assign fy machines from the browser,
draw/box-select/move/resize/delete clips and notes, drag clips between
tracks, loop selected clips or the whole arrangement, and hear multiple
tracks play through miniaudio. The arrangement document can now be
saved/loaded and edited with snapshot undo/redo.

**Order of build was reversed vs the plan below.** We went
outside-in — built the DAW shell first, then added fy machine hosting
inside that shell. Rationale and details are in
[sessions/session-01.md](sessions/session-01.md) and
[sessions/session-02.md](sessions/session-02.md).

Rough phase mapping of what exists:

- **Phase 0 substrate** — *partial and inverted.* Slab embeds fy as a
  Zig module and can compile/call fy machine audio and UI words through
  C callbacks. There is a hot-patch server attached to the catalog
  host, but not yet propagated cleanly to all live per-track instances.
  No `dsp:` mode or heap blacklist yet.
- **Phase 1 kernels** — *not started.* No NEON, no `vec-each`, no
  combinators.
- **Phase 2 machines + panels** — *partial.* fy-authored machine audio
  and panels ✓, panel protocol ✓, widget library ✓, note event protocol
  ✓ (ABI shape complete; MPE + `note_hold` unused); voice pool ✗,
  param smoothing ✗, block arena ✗, double-buffered params ✗. Current
  fy examples include `sine`, `square`, and `mono1`.
- **Phase 3 DAW frame** — *partial.* Transport ✓, loop toggle/range ✓,
  tracks ✓, add tracks ✓, clips + piano roll ✓, arrangement ✓,
  multi-select/box-select/delete clips ✓, drag clips between tracks ✓,
  inline per-lane mixer ✓, machine browser ✓, project save/load ✓
  (arrangement + machine assignment state), undo/redo ✓.

**Known sharp edges** carried forward:

- Loop wrapping happens after each callback/block, not by splitting
  render at the exact loop boundary. This is usable but not
  sample-tight yet.
- Live hot-patch currently targets the registry/catalog host rather
  than all per-track fy instances.
- fy machine callbacks rely on global/thread-local fy runtime pointers;
  this works for the current single audio thread + UI thread shape but
  needs a cleaner instance dispatch model before parallel graph render.
- Scrubbing during playback clicks (no anti-click on seek).
- Font rasterization is SFNS bilinear, not the bitmap font the
  UI-widgets doc calls for.
- Project save/load and undo/redo do not serialize fy panel parameter
  state yet; that needs a host-visible param model rather than anonymous
  fy cells.
- `*_KEY: u64` magic hex constants in module-scope drag state are
  cosmetic debt — `@intFromPtr(&tag)` would replace them.

## Phase 0 — Substrate (no DAW yet)

**Goal:** prove the livecoding-through-to-audio loop works at
kernel level with one synth voice.

1. **fy library target.** Add to fy's `build.zig` a library output
   plus a small C-ABI header exposing init/load/lookup/call/patch.
   Embed in Slab. Build the hot-patch TCP listener into Slab
   (move from fy CLI).
2. **Audio I/O.** miniaudio, stereo f32 out, 48k, 64-sample block.
   Simple callback that calls into a single hardcoded fy `dsp:`
   word.
3. **ctx struct minimal.** Just `sample_rate`, `block_size`,
   `audio_out`, `persistent`. No notes yet.
4. **`dsp:` mode minimum.** Enforce the heap-access blacklist; don't
   bother with NEON or inlining. Compile a scalar per-sample loop
   in fy.
5. **Smoke test:** write a `dsp:` sine-gen, play it, change the
   frequency via hot-patch from VSCode, hear the change.

**Exit criteria:** a developer can open a sine.fy, tweak a number,
save, and hear the pitch shift within a block. Single-file, no UI.

## Phase 1 — First kernel library

**Goal:** enough kernels to build a simple synth, without the DAW
around it yet. Scaffolding for what comes next.

1. **NEON asm extension.** Add the instruction subset from
   [05-kernels.md](05-kernels.md) to `../fy/src/asm.zig`.
2. **`vec-each` macro.** 4-wide unrolled loop + scalar tail. Prove
   it emits sane code; compare a `vec-each`-based gain against a
   hand-written scalar loop.
3. **Baseline kernels:**
   - `polyblep-saw`, `polyblep-pulse`, `sine`
   - `adsr`
   - `svf` (state-variable ZDF)
   - `ladder` (Moog TPT)
   - `tanh` / `softclip`
   - `one-pole` (for smoothing)
4. **Param smoother as a service.** Minimal: one-pole per smooth-annotated field, block-rate updates.
5. **`pipeline` combinator.** Prove compile-time stage fusion works
   for `(x -- y)`-shape stages.

**Exit criteria:** a single-voice mono bass synth with saw + ladder
+ envelope + softclip, rendered with 2× the CPU efficiency of the
Phase-0 scalar baseline. Still no UI frame.

## Phase 2 — Machines and panels

**Goal:** the machine abstraction lands, with a drawable panel.

1. **`machine:` directive in fy.** Manifest parsing, registration.
2. **Persistent arena, voice arena, block arena.** Real
   implementations with the audio-thread discipline enforced.
3. **Double-buffered params + smoother.** Full version (sample-rate
   and block-rate modes).
4. **Widget library — minimal.** `beveledRect`, `knob`, `button`,
   `text`, `meter`, layout helpers. Raylib + bitmap font.
5. **Panel protocol.** `draw-panel` / `event-panel` word pair,
   rendered in a window by the host.
6. **Voice pool service.** Note-on/off, stealing, release tails.
7. **Note event protocol.** Full `NoteEvent` struct with MPE fields.
   Note input from laptop keyboard (ascii → note). MIDI input
   deferred.
8. **First full machine:** a Juno-ish mono synth with its own panel,
   ~5 knobs, runs standalone.

**Exit criteria:** open Slab, see one machine panel in a
window, play with the computer keyboard, tweak a knob, hear sound.
Pop the face off, see the source, edit the filter, hear the
change.

## Phase 3 — DAW frame

**Goal:** the thing starts looking like Live.

1. **Transport.** Audio-clock-authoritative with tempo map.
2. **Tracks, inserts, sends, returns, master.** Graph model with
   topo-sorted scheduler.
3. **Clips on a timeline.** Pattern clips (MIDI/note) and audio
   clips. Draw, move, resize, duplicate.
4. **Piano roll.** Note draw/edit, velocity, quantize, MPE lanes.
5. **Mixer view.** Channel strips, sends, master.
6. **Machine browser.** Scan `machines/`, present in a sidebar.
7. **Project save/load.** Document model with all of the above
   serialized. JSON-ish or a binary format (deferred choice).
8. **Undo/redo.** Snapshot-based on the Document.

**Exit criteria:** you can arrange a short piece with 3–4 tracks,
save it, reopen it, play it back identically.

## Phase 4 — Kernel library breadth and machine breadth

**Goal:** cover the quality bar stated in the vision doc.

1. **Oversampler service.** 2× and 4× via polyphase halfband.
2. **Mod matrix.** Any source → any param, saved with project.
3. **Full ZDF filter set:** ladder, diode-ladder, MS-20, SVF with
   nonlinearities.
4. **Wavetable kernel:** mipmap-aware, cubic interp, warp modes.
5. **Envelope library:** ADSR, AHDSR, DAHDSR, multi-stage.
6. **Shapers with oversampling integrated:** tanh, soft-clip,
   asymm-sat, chebyshev.
7. **Dynamics kernels:** peak/rms detect, ballistics, lookahead.
8. **Delay/reverb primitives:** delay-line, allpass, Schroeder
   reverb building blocks.
9. **FFT service + STFT combinator.**
10. **Reference machines:**
    - **instrument/** tal-u-no (Juno-ish), dx7 (6-op FM),
      wavetable-poly (Serum-ish), tr-808 (drums)
    - **effect/** comp-basic, multiband-comp, eq-parametric,
      saturator, delay-modulated, reverb-plate, stereo-widener
    - **note/** arp-basic, chord-gen, humanize, euclidean

Reference machines serve as both "proof the architecture works"
and "example code for users."

**Exit criteria:** someone can make a synthwave track or a techno
loop entirely in Slab, using only bundled machines, and it
sounds as good as a commercial DAW session with commercial plugins.
This is where the product becomes real.

## Phase 5 — PDC, recording, performance

1. **Plugin Delay Compensation.** Graph-wide latency alignment.
2. **Automation lanes.** Record + edit.
3. **Audio recording.** Arm a track, record input into a clip.
4. **External MIDI.** CoreMIDI in/out, device mapping.
5. **Performance tuning.** Profile, vectorize, parallelize (start
   multi-threaded graph walk).
6. **Shipping mode.** Inline-registry hot-patch, full kernel
   inlining.

**Exit criteria:** Slab is usable for actual music production
on an M-series Mac at 8ms latency with a realistic project load
(20+ machines).

## Phase 6 — Ecosystem

1. **Machine browser with online registry.** Browse, preview,
   install from a curated list.
2. **In-app machine authoring.** Create a new machine scaffold
   from the UI; edit in built-in editor.
3. **Preset sharing / morphing.**
4. **Session templates.**
5. **Documentation site with livecodable tutorials.**

## Non-goals (explicit and permanent)

- **Hosting VST/AU/AAX.** Breaks the liveness model (binary plugins
  aren't editable). May change if there's overwhelming demand;
  default no.
- **Cross-platform.** fy's JIT is macOS aarch64. Porting to x86-64
  and/or Linux is a separate, very large project.
- **Video.** fuvid exists.
- **Competing with Live feature-for-feature.** Matching Live's UX
  at 100% is a moving target; we pick our battles.

## Non-goals (deferred but not ruled out)

- **Free-node-graph editor.** Live-style covers most of what
  people need; wiring can come later on top of the same scheduler.
- **Parallel track graph execution.** The pure contract makes it
  easy to add later when a real session needs it.
- **GPU DSP.** Some spectral and convolutional tasks benefit; the
  architecture doesn't preclude it, but it's a later add.
- **Theming the frame.** Brutalist grey is the identity.
  Panel-level themability is implicit (machines choose their own
  look).

## What would break this plan

- **fy can't inline `dsp:` calls efficiently.** Benchmarked in
  Phase 1 — if we can't get within 2× of hand C, we rethink.
- **Zig embedding story is painful.** If fy's `Fy` struct is too
  deeply tied to a single-process assumption we need to factor.
  Plausible.
- **NEON authoring is too hard for users.** If only kernel-library
  authors can realistically write `dsp:` code, the "livecodable
  everything" promise weakens. Mitigated by rich combinators; if
  not, we rely more on the kernel library and machines become
  thinner glue.

Each phase has an out: if something structural proves wrong, we
reset that layer only. The arena model, ctx contract, and `dsp:`
subset are the bets that have to be right from the start — the
layers above them (UI, machines, services) are replaceable.

## First code to write

*Stale — superseded by the session-1 work (see
[sessions/session-01.md](sessions/session-01.md)).*

The original plan was fy-first: wire fy's runtime into Slab, write
the sine as a `dsp:` word, hot-patch from VSCode. What actually
happened: the outside-in variant — DAW frame + Zig reference
machine first, fy substrate deferred. The ABI that fy will speak
(`MachineCtx` and `NoteEvent`, docs/04) is locked in and in use on
the Zig side; the fy-side `dsp:` mode, NEON asm, hot-patch listener,
and arena model are still the next big deck to build when the
project turns its attention back to the audio-authoring substrate.
