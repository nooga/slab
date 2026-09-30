# 14 — The MS-20 machine

Turning `raw-ms20` from a two-oscillator test voice into a real MS-20-style
mono synth: fat analog VCOs, dual self-oscillating filters, two analog
envelopes, an MG (LFO), a saturating mixer, and hardwired modulation. The
panel/UI for this lives in [docs/15](15-machine-panels.md); this doc is the
voice architecture, the fy kernels, and the register/fusion strategy.

Scope call: **no full semi-modular patch bay.** We implement the MS-20's
*hardwired* routing (MG/EG→pitch, MG→cutoff, EG→cutoff/VCA, PWM, ring) with
fixed intensity controls. A general routing matrix can come later.

## LPF v3: the June probe's driven SVF, in fy (2026-09-27)

The reference is `scratch/ms20_saw_filter_sweeps_f-hot.wav`, rendered by
`tools/audio_probe/render_ms20_sweeps.py` (profile `f-hot`; its sibling
`g-wet` drove the June machine). The OTA cascade that replaced it on
2026-09-26 was "correct" on paper (peak on the cutoff, no bass cost, clean
self-oscillation). In use it was dark, polite and samey. Swept with the
same stimulus, its resonance was invisible until the top setting and thin
there, while the reference keeps a dense harmonic fan and a broad,
snarling ridge from res 0.45 up. So the probe's topology is back, as
`kernels/04-filters/ms20_lpf.fy`:

```
fbdc   += cdc·(ic2 − fbdc)                    feedback DC tracker
fb      = tanh(fb-amt·(ic2 − fbdc))           lowpass back, clipped: near-square
driven  = tanh(drive·x − fb)                  hot input stage
TPT SVF (g, damping) → hp bp lp; both integrators leak
colored = tanh(out-clip·(lp + 0.2·bp))        a fifth of the bandpass: bark
out     = colored − DC
```

- The integrators stay linear. All the grit is in the input stage and
  the output shaper.
- The SVF's own damping makes the peak.
- The clipped negative feedback thickens the ridge and costs some bass.
  That's the June sound, and the old commit's objection to it.

- **MODE:** HOT is `f-hot` (drive 2.10, fb 4.5·2.25, out 1.85, damping
  0.62/(1 + 5.2 r)). WET is `g-wet` (1.90, 5.4·2.70, 2.10, 0.58/(1 + 6.2 r)).
- **Knobs:** DRV scales the mode's drive (0.25–4). PEAK sets
  `r = 0.8·RES`, so the probe's range (0.45–1.38) is most of the knob.
  From r ≈ 1 the loop turns partly chaotic, as the reference does (−5 to
  −15 dB non-harmonic at a steady cutoff): the snarl lives at the top of
  PEAK.
- **Rate:** 4× with the input held, then `dec4`.
- **Parity:** a C3 saw at 0.62, cutoff 700 Hz, matches the Python probe
  within about 1 dB per harmonic for H1–H12 (r 0.45 and 1.38).

## Voice v3 (2026-09-27)

What was wrong, from listening, and the fix:

| complaint | cause | fix |
|---|---|---|
| "overdriven, unpleasantly"; low notes clash | mixer `tanh(1.3·sum)` clipped two detuned saws into IMD before the filter | clean mixer, 0.62 per unit level; the LPF input stage is the only drive |
| zero-crossing clicks | note-on reset both VCO phases and restarted the age-based ADSR from 0; an early release snapped to the sustain level | free-running VCOs; RC envelopes (`env_rc.fy`) that keep their level, retrigger from it, release from it |
| envelopes weird | `adsr-cap` segments were functions of note age | RC: attack chases 1.2 until it crosses 1, decay/release cover 99% in their time |
| HPF not resonant | its bandpass state was clipped at ±1, under the input level | clip `2.5·tanh(x/2.5)`; damping `1.4·(1 − RES/2)²`: flat at 0, Q 3 at 1, Q 18 at 1.6 |
| octave ranges borked | the bass presets sat both VCOs at 16', so a bass line at A1 played 27.5 Hz | presets rebuilt with the lowest VCO at 8' |
| every preset the same | the dark filter, plus presets converted from the old one | 16 presets voiced for v3 across both modes, HPF and MG; centroids 250 Hz–4 kHz; each at −16 dBFS RMS (bench notes case) |

- Legato notes (`ctx.legato`) move the pitch without retriggering.
- Ranges from the MS-20 spec (Korg's MS-20 mini sheet reproduces the
  original):
  - VCO2 PITCH is ±12 semitones; it was −9…+31 cents.
  - VCO2 SCALE is 16'–2'; VCO1 stays 32'–4'.
  - MG runs 0.1–20 Hz.
  - HPF runs 20 Hz–15 kHz.
  - Envelope times go up to 10 s.
  - The LPF keeps 20 Hz–18 kHz, wider than the real 50 Hz–15 kHz.
- **PORTA** (0–10 s) glides every note in octaves, as the MS-20's does.
  The first note starts on pitch.
- **VCO2 RING** is the MS-20's: an XOR of VCO1's pulse (at PW) and VCO2's
  square, i.e. minus their product for ±1 pulses. It keeps both pitches
  and follows PW; a fifth gives the sum and difference series
  (65, 196, 327 Hz … for C3).
- **FLT ENV DLY** (EG1's DELAY, 0–10 s) and **AMP ENV HOLD** (EG2's HOLD,
  0–20 s) are a timed gate in front of the RC stages (`env_rc.fy`). A
  key-down reaches the stages after the delay, and a key-up after the
  hold. Measured: HOLD 0.5 s moves the −60 dB release point from 0.195 s
  to 0.70 s.
- The default PEAK is 0.7, below the chaotic zone, so the init patch
  tracks C2.
- The VCA makeup is ×1.6.

## Analog layer (2026-09-30)

Backported from Profit-5 (docs/17) after the user heard it as more
analog than the SM-24. A new **AGE** knob (VCA section, default 0.4):

- **Drift:** the VCOs wander on a slow drift, mostly common-mode (~6
  cents RMS at 1) with a third of it their own. Fully independent drift
  pushed the default patch's two VCOs 9 cents apart at AGE 0.4, on top
  of the 10-cent detune, and sounded sour. The cutoff wanders 0.07 oct
  RMS at 1.
- **Bowed saws** (`vco.fy`): each VCO's saw bends toward the capacitor
  ramp, VCO1 by 0.3·AGE, VCO2 by 0.22·AGE.
- **Coupling cap:** the mix passes a 15 Hz highpass before the HPF, so
  low pulse tops sag. At 25 Hz it cost the 32' basses 1–2 dB.
- **Envelope bleed:** the filter EG leaks into the audio at 0.05·AGE.
- **Noise floor:** −86 dB at the LPF input.
- **Lopsided diodes:** the LPF feedback clip is `tanh(a + off) −
  tanh(off)` at unit slope, off = 0.1 + 0.2·AGE (`ms20-lpf-set-offs`).
  Funk leaves it at 0 and stays bit-exact.
- **4x upsampler:** the LPF is fed through `up4` rather than holding
  each sample across the substeps. Holding sent the input's images into
  the hot input stage, which folded them back as grit.

The VCA makeup went to ×1.78 to keep the presets where they were: all
16 are within ±1 dB of v3 (bench notes case). A single VCO at AGE 0.4
measures −61 dB nonharm on a held C3 (−67 at 0); the default patch's
number moves more, since its detuned pair's beating depends on the
drift.

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
- **HPF** (12 dB/oct, 2-pole) + **LPF** (12 dB/oct), in series, both self-oscillating
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

## Kernels (pure-fy `dsp:`, each ratcheted per docs/13)

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
- **HPF** — a 2-pole (12 dB/oct) self-oscillating high-pass so HPF→LPF gives
  the real MS-20 series tone. Implemented lean in fy (a Chamberlin SVF, HP tap,
  with a bandpass-state clip for bounded self-oscillation) on its own call:
  stage — not a fused Zig op, since the spine frees the register budget.
  Ear-tuned: no g-wet oracle exists for the HP.
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
in one 32-register dsp2 word** even with the arg-aware pool. dsp2 has no
function calls — a word reference is spliced inline as a flattened token body
(`dsp2_body`) *before* register allocation, so the whole voice is one
straight-line expression competing for 32 float registers. The allocator has
no global spilling; it hard-errors `RegisterExhausted`.

The fix is **composition in fy via a real (non-inlined) call** — a new
`call:` form in dsp2. Stages stay separate compiled words, each with its own
fresh 32-register budget, and the voice composes them in fy (not in the host):

```
dsp: k-ms20-voice-sample
  | out state params |
  state params       call: v-mod    ( advance phases/age; MG, EG1, EG2 → state scratch )
  state params       call: v-osc    ( VCO1, VCO2, ring, noise, PWM/FM → sat mixer → state.osc-out )
  state params       call: v-filt   ( HPF → LPF with cutoff mod → state.filt-out )
  out state params   call: v-vca    ( EG2 × level → out )
;
```

### `call:` semantics

At each `call:` the compiler emits, all from machinery that already exists:

1. **Arg marshal** into the raw-entry ABI the callee already uses: pointers →
   `RAW_X_ARG_REGS` (x0–x7), floats → `RAW_D_ARG_REGS` (d8–d15). The compiler
   knows each arg's ptr-vs-float kind (`argUsedAsPtr`).
2. **Localized spill** of the live caller-saved registers around the call —
   the same `sub_sp_imm` / `str` / `ldr` / `add_sp_imm` frame dance already used
   for deferred stores, but scoped to one call site. dsp2 already tracks
   liveness (`consumeValue` last-use), so it spills exactly the registers live
   across the boundary. In sequential composition that set is tiny (just the
   pointers), so the spill is nearly free — but it is correct even when it is
   not.
3. **Slot-load + `blr`** — load the callee address from a patchable per-call
   slot (the `Dsp2RawRepeatedSlots` + `blr Xn` mechanism the host caller
   already uses) and branch with link.
4. **Reload** the spilled registers; push the d0 result back as a value if the
   callee returns one.

Communication between stages is through **scratch fields in voice state**
(`osc-out`, `filt-out`, MG/EG values), not threaded return values — so each
stage stays at 2–3 pointer/float args and never touches the 6-arg
`compileDsp2RawRepeatedCaller` path (the spun-off segfault).

### Two bonuses

- **The slot is patchable**, so every `call:` boundary is a **word-level
  hot-patch point**: edit `v-filt` while audio plays, repatch its slot, the
  composed voice runs the new filter next block. The signature livecoding
  capability falls out of the composition mechanism.
- **It generalizes** beyond the MS-20 — any machine composes fused kernels the
  same way. It is the missing "compose without re-fusing into one
  register-starved blob" primitive.

### Rule & follow-up

Anything live across a `call:` is either pinned in a callee-saved register or
auto-spilled. Pointers reused across several calls want pinning (x19–x21) to
avoid repeated save/restore — an optimization, not correctness.

Full global spilling (str/ldr to a body frame + operand pinning so a *single*
word can exceed 32 live regs) remains a durable follow-up — the "fuse as much
as possible" lever — but it is **not** the gate. `call:` composition unblocks
the entire voice with only call-site-local spilling. The coefficient/mod math
stays in fy regardless; nothing computes DSP in Zig.

## Filter call

The **self-oscillating HPF** matches the real MS-20 (HPF→LPF series) — a
primary character element. Implemented as a lean Chamberlin SVF in fy
(`kernels/04-filters/ms20_hpf.fy`, `k-hpf`) on its own `v-hpf-stage`, reusing
`svf-g`/`svf-damping` for coeffs. Ear-tuned (no oracle); fuse or add an oracle
later only if needed.

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
6. Add `call:` composition to dsp2; assemble the voice from fused stages
   (v-mod/v-osc/v-filt/v-vca) via state-scratch handoff.
7. Panel: declare the strips (docs/15); custom ADSR cell.
8. Global spilling (durable follow-up) to optionally collapse hot stages back
   inline; polyphony via a higher-order voice-pool machine (docs/15).
