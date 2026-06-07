# 14 — The MS-20 machine

Turning `raw-ms20` from a two-oscillator test voice into a real MS-20-style
mono synth: fat analog VCOs, dual self-oscillating filters, two analog
envelopes, an MG (LFO), a saturating mixer, and hardwired modulation. The
panel/UI for this lives in [docs/15](15-machine-panels.md); this doc is the
voice architecture, the fy kernels, and the register/fusion strategy.

Scope call: **no full semi-modular patch bay.** We implement the MS-20's
*hardwired* routing (MG/EG→pitch, MG→cutoff, EG→cutoff/VCA, PWM, ring) with
fixed intensity controls. A general routing matrix can come later.

## Reference architecture

```
VCO1 ─┐
VCO2 ─┤
ring ─┼─► MIXER(sat) ─► HPF ─► LPF ─► VCA ─► out
noise─┘                  ▲      ▲       ▲
                         │      │       │
        MG ─────────────►cut    cut     │   (cutoff mod)
        EG2 ────────────►cut    cut────►amp (filter + amp env)
        MG / EG1 ──► VCO1+VCO2 pitch (FM)   ;   MG/EG ──► PW (PWM)
```

- **VCO1** — waveform: triangle / sawtooth / pulse / white-noise; PW; SCALE
  (octave 32′/16′/8′/4′).
- **VCO2** — waveform: sawtooth / square / narrow-pulse / ring; PITCH
  (interval vs VCO1); SCALE (16′/8′/4′/2′).
- **MIXER** — VCO1 level, VCO2 level; the sum is softly saturated (color).
- **HPF** (6 dB/oct) + **LPF** (12 dB/oct), in series, both self-oscillating
  (the MS-20 "scream"), each with CUTOFF + PEAK(resonance).
- **MG** (LFO) — FREQUENCY + WAVEFORM (morph saw↔tri↔ramp); pulse + sloped
  outputs.
- **EG1** — DELAY / ATTACK / RELEASE (pitch & mod sweeps).
- **EG2** — HOLD / ATTACK / DECAY / SUSTAIN / RELEASE (filter + VCA).

Character sources: analog VCOs (drift/detune, non-ideal waves), the
saturating mixer, and the two resonant filters.

## Have vs. need

We have: polyBLEP saw/pulse/square (+ cap variants), `adsr-cap` (RC-discharge
envelope), `slab:noise`, the g-wet `fms20-svf` low-pass, fy-computed coeffs,
and the generic panel system (docs/15).

Need: triangle VCO + analog character, waveshape/octave selects, an in-fy
noise kernel, a saturating mixer, an MG/LFO kernel, a self-oscillating HPF,
ring mod, and an EG1 (DAR) alongside the existing cap ADSR.

## Kernels (pure-fy `dsp2:`, each ratcheted per docs/13)

Every kernel is built and ratcheted standalone against an oracle before it
enters the voice — same discipline as `fms20-svf`.

- **Triangle polyBLEP** — the missing VCO1 waveform (band-limited).
- **Analog character** — per-VCO slow drift + slight detune + optional sub;
  enough non-ideality for "fat", cheap enough to fuse.
- **Waveshape select** — a switch index picks tri/saw/pulse/noise (VCO1) or
  saw/square/pulse/ring (VCO2) via `fsel-lt`, no per-shape branching cost.
- **Octave/SCALE** — switch index → frequency multiplier (powers of two).
- **Noise kernel** — in-fy white noise (so it composes inside the voice, not
  only the host `slab:noise`).
- **Saturating mixer** — sum VCO1·lvl + VCO2·lvl (+ring +noise) then a gentle
  `tanh_rational` drive (reuse the filter's clip) for color.
- **MG / LFO** — phasor + morphable waveform (saw↔tri↔ramp) + a pulse output;
  frequency control.
- **HPF** — the missing 6 dB/oct high-pass, g-wet-style (nonlinear, resonant)
  so HPF→LPF gives the real MS-20 series tone.
- **Ring mod** — VCO1 × VCO2.
- **EG1 (DAR)** — delay/attack/release; reuse the RC-discharge shape from
  `adsr-cap`. EG2 stays the cap ADSR (already analog).

## Voice routing (fy)

Reassemble per the topology above with hardwired modulation:

- MG (sloped) + EG1 → VCO1/VCO2 pitch (FM), with intensity controls.
- MG / EG → pulse width (PWM).
- MG → HPF + LPF cutoff; EG2 → cutoff; EG2 → VCA. Intensities as controls.
- Ring and noise summed at the mixer.

## Register / fusion strategy

The full voice (2 VCOs + mixer + 2 filters + 2 EGs + MG + mod) **will not fit
in one 32-register dsp2 word** even with the arg-aware pool. Two paths:

1. **Stage decomposition (now).** Split the per-sample voice into a few
   fused words, each well under 32 regs, chained by the host via precompiled
   `Dsp2RawRepeatedCaller`s (no per-call relink):
   - `mod`   — advance phases/age; compute MG, EG1, EG2 → mod values.
   - `osc`   — VCO1, VCO2, ring, noise, PWM/FM → saturating mixer → sample.
   - `filt`  — HPF → LPF with cutoff mod.
   - `vca`   — EG2 × level.
   Each stage is independently ratcheted. This works with today's allocator.

2. **Spilling (durable follow-up).** Add register spilling to the dsp2
   codegen (str/ldr to a body frame + operand pinning) so stages can collapse
   back into one fused word for maximum efficiency. This is the "fuse as much
   as possible" lever; pursue it once the staged voice works.

**Plan: ship staged (1), then collapse with spilling (2).** Either way the
coefficient/mod math stays in fy; nothing computes DSP in Zig.

## Filter call

Add the **self-oscillating HPF** to match the real MS-20 (HPF→LPF series) —
it is a primary character element, not optional. Model it on `fms20-svf`
(reuse the nonlinear-feedback structure as a high-pass tap), ratcheted
against an HPF oracle.

## Panel

See [docs/15](15-machine-panels.md). The MS-20 declares strips: VCO1, VCO2,
MIXER, HPF, LPF, MG, EG1, EG2 — beveled, with octave/waveform `switchV`
selectors and knobs with value readouts. An ADSR-curve custom cell (escape
hatch) is a good early proof.

## Phasing

1. Triangle + analog character + waveshape/octave selects + in-fy noise +
   saturating mixer. Ratchet each.
2. MG / LFO kernel.
3. HPF kernel + HPF→LPF series.
4. EG1 (DAR); confirm EG2 cap ADSR curves.
5. Hardwired routing: FM, PWM, cutoff mod; ring mod.
6. Assemble the voice with stage decomposition (register strategy 1).
7. Panel: declare the strips (docs/15); custom ADSR cell.
8. Spilling (register strategy 2) to collapse stages; polyphony via a
   higher-order voice-pool machine (docs/15).
