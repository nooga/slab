# 14 — The MS-20 machine

Turning `raw-ms20` from a two-oscillator test voice into a real MS-20-style
mono synth: fat analog VCOs, dual self-oscillating filters, two analog
envelopes, an MG (LFO), a saturating mixer, and hardwired modulation. The
panel/UI for this lives in [docs/15](15-machine-panels.md); this doc is the
voice architecture, the fy kernels, and the register/fusion strategy.

Scope call: **no full semi-modular patch bay.** We implement the MS-20's
*hardwired* routing (MG/EG→pitch, MG→cutoff, EG→cutoff/VCA, PWM, ring) with
fixed intensity controls. A general routing matrix can come later.

## LPF v2: OTA cascade in fy (2026-09-26)

The low-pass filter is now `kernels/04-filters/ms20_ota.fy`, written in fy.
The fused Zig primitives (`fms20-svf`, `fms20-lpf4`) are deleted from the
fy compiler, which removes the main reason the MS-20 couldn't be
livecoded. It follows the mk2 board: OTA → op-amp → OTA → op-amp, with the
resonance returned through an op-amp whose feedback holds a diode clipper.

```
e   = drive·x + fb
y1 += g·tanh(e − y1)            OTA1 → op-amp
y2 += g·tanh(y1 − y2)           OTA2 → op-amp      (output)
fb  = k·diode(y1 − y2)          resonance op-amp, diode-clipped
```

**Linear check.** The loop gain is `k·G·(1−G)`, with `G = 1/(1+s/ωc)`.

- At ω = ωc it equals exactly `k/2`, so the peak sits on the cutoff and
  self-oscillation starts at k = 2.
- At DC it is 0, so resonance costs no bass.
- The diodes clip the resonance signal, not the audio path, and hold the
  oscillation at a stable level.

**Running it.**

- The step runs 4× per sample as four `call:` stages (`v-ota-sub`). The
  input is held across the substeps and the output is their mean.
- `g = 1 − e^(−2π·fc/fs_os)`.
- RES 0..2 maps to k = 1.2·RES, so oscillation starts at about 83% of the
  knob.

**What it fixed.** Measured with the bench, docs/13:

| | old `fms20-svf` (g-wet) | new |
|---|---|---|
| resonance | fed the *lowpass* back negatively | band feedback through diodes |
| resonant pitch at RES max, cutoff 1 kHz | 2.65 kHz (moved up by √(1+k)) | 0.89–0.98 kHz |
| self-oscillation | never (damping clamped, Q ≈ 14) | from RES ≈ 1.6, stable at −15 dB RMS |
| bass (C2 saw, cutoff 300 Hz), RES 0 → 2 | −4.0 → −10.4 dB | −8.9 → −5.3 dB |
| resonance knob sweep | 40% dead, uneven 0.55 | 0% dead, uneven 0.11 |
| DRV | dead (drive hardcoded 1.9) | the OTA input drive |

**Voice changes that went with it.**

- Cutoff modulation sums in octaves: `cutoff·2^(env·env-amount +
  mg·mg-cutoff)`.
- `env-amount` (0..8 oct) replaces the absolute `env-peak` Hz, and
  `mg-cutoff` is now 0..4 oct.
- Ranges: cutoff 20 Hz–18 kHz, HPF 20 Hz–8 kHz.
- PW runs square → thin (0.5–0.95) instead of mirroring around 50%.
- A 20 Hz DC blocker sits after the VCA. The old SVF blocked DC
  internally.
- The 16 presets were converted to the new units, and their resonance was
  scaled by 0.85 so the old high-Q settings land at or just below
  oscillation.

Funk Overload's saturating SVF moved to fy in the same change
(`tpt-svf-lp-sat-step` in `tpt_svf.fy`), bit-exact with the primitive it
replaces. `svf-g`, `svf-damping`, and `svf-dc-coeff` now live in
`coeffs.fy`.

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
