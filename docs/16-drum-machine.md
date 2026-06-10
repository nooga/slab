# 16 — The drum machine

A synthesized drum machine (`drum2`, working name) built the MS-20 way:
every component is a pure-fy `dsp2:` kernel developed and ratcheted in the
workbench (docs/13) — rendered, plotted, measured, and *listened to* —
before it enters a voice; voices are assembled as `call:` stages; the
machine is declared entirely in fy via the manifest descriptor
(machines/lib/manifest.fy, docs/15). When it lands, the legacy `drum1`
(368 lines of `::` cells and libm `bind:`s, sounds like garbage) is
decommissioned.

**Sound goal:** the classic analog x0x family (808 / 707 / 909) as the
*reference points*, but with a continuously **modifiable character** in the
Vermona DRM1 spirit — each voice is a small analog model with enough knobs
to travel between "808-ish", "909-ish", and places neither box went, rather
than a sample-accurate clone of any one of them.

## Architecture

One machine, multiple independent drum **slots**. Each slot is a one-shot
mono voice with its own params block, triggered by a fixed MIDI note (GM
drum map note numbers), all summed at a master bus inside the machine.

```
note in ─► slot select ─► trigger
   KICK ──┐
   SNARE ─┤
   CLAP ──┤
   HAT(C/O, choke) ─► Σ ─► master drive ─► out
   TOM ───┤
   PERC ──┘
```

- **voice-sample** mode, like `raw-ms20`: render word writes one summed
  mono sample; note-on routes to a slot and (re)triggers it.
- Slots are independent `call:` stages (fresh 32-register budget each),
  composed by the top-level render word — same pattern that made the
  MS-20 voice fit (docs/14 §register/fusion).
- All slots can ring simultaneously; CH/OH share the metallic core and
  **choke** each other (open-hat killed by closed-hat trigger).

### Slot triggering (ABI note)

Raw note-on currently receives `(state params hz velocity)` — the host
converts MIDI pitch to Hz. For a drum machine the *pitch is an address*,
not a frequency. Inverting hz→note in fy is doable but ugly. Decision:
**the manifest grows a flag** (e.g. `note-pitch!`) that makes the host pass
raw MIDI pitch instead of Hz to note-on. The fy word maps pitch→slot with
plain comparisons (36 kick, 38 snare, 39 clap, 42 CH, 46 OH, 45 tom, …).
`raw-ms20` keeps the Hz convention; the flag defaults off.

## The voices

Each voice is deliberately a *synthesis model with character controls*,
not a preset. Reference recipes:

- **KICK** — sine-ish oscillator with a fast exponential **pitch envelope**
  (sweep depth + time = 808↔909 axis), exponential amp decay, a **click**
  transient (short filtered burst, level control), and drive into a soft
  clipper (909 grit). Knobs: TUNE, SWEEP, DECAY, CLICK, DRIVE, LEVEL.
- **SNARE** — two detuned sines (≈180/330 Hz body, tune + interval) with
  their own decay, plus high-passed noise ("snappy") with a separate
  faster decay. Balance = TONE/SNAPPY. Knobs: TUNE, TONE-DEC, SNAPPY,
  SNAP-DEC, LEVEL.
- **CLAP** — noise through a band-pass with the classic **retrigger
  envelope** (3–4 fast repeats ~10 ms apart, then a longer tail). Knobs:
  TONE (BP center), SPREAD (repeat spacing), DECAY, LEVEL.
- **HATS (CH/OH)** — the 808 **metallic core**: six square oscillators at
  inharmonic ratios, summed, band-passed then high-passed. CH = short
  decay; OH = long decay + choked by CH. A TONE control morphs the filter
  tuning (707-ish brightness ↔ 808 clang); optional noise blend for a
  909-ish wash. Knobs: TONE, CH-DEC, OH-DEC, BLEND, LEVEL.
- **TOM/PERC** — kick-family oscillator with milder sweep, tunable over a
  wide range (toms/congas at different default tunes); a noise breath
  control. Knobs: TUNE, SWEEP, DECAY, BREATH, LEVEL. Two instances (LO/HI)
  if the register/param budget allows; one to start.
- **COWBELL/CLAVE (stretch)** — two pulse oscillators (≈540/800 Hz)
  band-passed; clave is one resonant ping. Add after the first six feel
  right.
- **MASTER** — per-machine: accent amount (velocity→level curve), master
  drive (shared tanh), level.

## Kernel inventory (have / need)

Have, ratcheted, in `kernels/`:

- `tanh_rational` + table shaper (02) — drive/clip everywhere.
- SVF (`fms20-svf`, 04) for LP; Chamberlin HPF (04); `dc_block` (04).
- RC-discharge envelope shapes (`adsr_cap`, 03) — the *curve* to reuse.
- polyBLEP squares/pulses (01) — basis for the metallic bank.
- in-fy white noise (from the MS-20 noise work, 06).

Need, each a standalone `dsp2:` kernel with a kernel-probe case, plots,
metrics ratchet, and an audition WAV **before** entering a voice
(`kernels/05-drums/` — the spare layer number):

1. **`k-sine-shape`** — polynomial sine on a phase accumulator (no libm in
   dsp2). Oracle: libm sine; ratchet THD + max error.
2. **`k-decay-exp`** — one-shot retriggerable exponential decay with curve
   control (RC fast↔slow), the drum workhorse. Oracle: closed-form exp.
3. **`k-pitch-sweep-osc`** — sine osc + multiplicative pitch envelope
   (kick/tom body). Probe: oscillogram + instantaneous-frequency plot.
4. **`k-click`** — 1–3 ms transient burst (filtered noise or half-cosine),
   level-controlled. Probe: oscillogram, spectrum.
5. **`k-noise-bp`** — noise → state-variable band-pass with center/Q
   (snare snappy, clap, hat blend). Reuses SVF core at audio rate.
6. **`k-metal6`** — six-square inharmonic bank (808 ratios) + BP + HP.
   The most "by ear" kernel; spectrogram against an 808 hat reference.
7. **`k-retrig-env`** — clap repeat envelope (N repeats, spacing, tail).
8. **`k-drum-voice-*`** — one `call:` stage per slot composing 1–7.

Workbench additions: a drum oracle script
(`tools/audio_probe/render_drum_oracle.py`, sibling of
`render_ms20_sweeps.py`) rendering reference kick/snare/hat recipes for
A/B `compare_probe.py` runs, and kernel-probe cases for the new fixtures.

## Params / state

One `ustruct: DrumParams` with per-slot sections (offsets via
introspection, never hand-written — `DrumParams.kick-tune`, …), one
`ustruct: DrumState` with per-slot phase/env/noise state. Same
`const-f64` mechanism for derived constants; a `block-prepare` word fills
any per-block coefficients (filter tunings from TONE knobs), exactly like
`ms20-block-prepare`.

## Panel

Vertical strips, one per drum slot, in declaration order — the layout
engine already does this:

```
row 1:  KICK │ SNARE │ CLAP │ HATS │ TOM │ PERC      (cols=1 each)
row 2:  MASTER (horizontal, cols=N)
```

Five-ish knobs per strip keeps it honest (DRM1 discipline: few knobs, wide
ranges). Optional later: a **trigger pad** widget per strip header for
mouse audition, and a `scope` display kind showing the last triggered hit
— both are additions to docs/15, not blockers.

## Phasing

1. **Kernels 1–3** (sine, decay, sweep-osc) + probe cases → a kick voice
   in the rig; listen, ratchet, tune the 808↔909 sweep axis.
2. **Kick machine**: `machines/drum2/drum2.fy` manifest with the KICK
   strip only + note-pitch flag; play it in the app.
3. **Kernels 4–5, 7** → snare + clap slots.
4. **Kernel 6** → hats with choke; tom from the kick family.
5. Master accent/drive; cowbell/clave if appetite remains.
6. **Decommission `drum1`**: remove from registry lists in `main.zig` /
   `machine_probe.zig`, delete `machines/drum1/` and the `Drum1Params`
   special case in `src/machines/fy_machine.zig`.

Exit criteria per phase: kernel metrics ratcheted, audition WAV approved
by ear, and a `machine-probe --chain=drum2 --input=note:36` render with
clean stats (no DC creep, no non-finite, peak sane).
