( ms20_voice_probe.fy - fused fy MS-20-style mono voice fixture.

  The rig calls `k-ms20-voice-sample` with auto-advancing output pointer for
  contiguous note-event segments. Zig updates note params at event boundaries;
  fy owns the per-sample oscillator/filter/VCA/DC composition. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../01-oscillators/primitives/phase.fy"
include "../01-oscillators/primitives/blep.fy"
include "../01-oscillators/primitives/shapes.fy"
include "../02-shapers/tanh_table.fy"
include "../03-envelopes/primitives/segments.fy"
include "../04-filters/coeffs.fy"   ( svf-g, svf-damping, svf-dc-coeff )
include "../04-filters/ms20_hpf.fy"
include "../00-primitives/pow2.fy"   ( exp2-approx: octave-domain filter modulation )
include "../04-filters/ms20_ota.fy"   ( the LPF: OTA cascade + diode resonance, in fy )

ustruct: Ms20VoiceState
  f64 phase1
  f64 phase2
  f64 ic1
  f64 ic2
  f64 dc-prev-x
  f64 dc-prev-y
  f64 amp-smooth
  f64 age
  f64 osc-out          ( scratch: VCO mix, written by v-osc-stage )
  f64 filt-out         ( scratch: filter out, written by v-filt-stage )
  f64 noise-rng        ( float-LCG noise state, reseeded on note-on )
  f64 hpf-lp           ( HPF Chamberlin lowpass state )
  f64 hpf-bp           ( HPF Chamberlin bandpass state )
  f64 mg-phase         ( free-running MG/LFO phase )
  f64 mg-out           ( scratch: MG bipolar value, written by v-mod-stage )
  f64 flt-env          ( scratch: filter ADSR value, written by v-mod-stage )
  f64 pitch-mod        ( scratch: VCO frequency multiplier from MG+EG routing )
  f64 pw-eff           ( scratch: effective pulse width after PWM routing )
  f64 filt-g           ( scratch: modulated filter g, written by v-cut-stage )
  f64 ota-y1           ( Ms20OtaState - the LPF, must stay contiguous )
  f64 ota-y2
  f64 ota-fb
;

ustruct: Ms20VoiceParams
  f64 note-hz
  f64 target-amp
  f64 inv-sample-rate
  f64 detune
  f64 cutoff           ( base filter cutoff Hz - control @32 )
  f64 resonance        ( filter resonance - control @40 )
  f64 drive            ( LPF input drive - DRV knob )
  f64 level
  f64 amp-coeff
  f64 gate-time
  f64 amp-attack
  f64 amp-decay
  f64 amp-sustain
  f64 amp-release
  f64 env-amount       ( filter EG -> cutoff, octaves at full envelope )
  f64 filter-attack
  f64 filter-decay
  f64 filter-sustain
  f64 filter-release
  f64 saw-level
  f64 pulse-level
  f64 pulse-width
  ( derived per block by ms20-block-prepare )
  f64 ota-k            ( LPF resonance loop gain; self-oscillates past 2 )
  f64 ota-drive        ( LPF input drive )
  f64 os-inv           ( 1 / [4 * sample rate]: the LPF runs 4x )
  f64 vco-octave       ( VCO1 octave/SCALE frequency multiplier - switch )
  f64 vco2-octave      ( VCO2 octave/SCALE frequency multiplier - switch )
  f64 vco1-wave        ( VCO1 waveform index 0=tri 1=saw 2=pulse - switch )
  f64 vco2-wave        ( VCO2 waveform index 0=saw 1=square 2=pulse - switch )
  f64 noise-level      ( white-noise amount mixed into the VCO sum )
  f64 hpf-cutoff       ( series HPF cutoff Hz )
  f64 hpf-resonance    ( series HPF resonance/peak )
  f64 mg-freq          ( MG/LFO frequency Hz )
  f64 mg-wave          ( MG waveform morph 0=ramp-down .. 0.5=tri .. 1=ramp-up )
  f64 mg-cutoff        ( MG -> LPF cutoff intensity, octaves )
  f64 mg-pitch         ( MG -> VCO pitch intensity (frequency ratio) )
  f64 mg-pw            ( MG -> pulse width intensity (PWM) )
  f64 eg-pitch         ( filter EG -> VCO pitch intensity )
;

( ctx state params -- : update sample-rate derived params. )
dsp: ms20-voice-prepare
  | ctx state params |
  ctx Ctx.sr@ | sample-rate |
  1.0
  sample-rate
  f/
  params Ms20VoiceParams.inv-sample-rate-p
  f!64
  drop2 drop drop
;

( ctx state params -- : start a mono note and reset oscillator age. )
dsp: ms20-voice-note-on
  | ctx state params |
  ctx Ctx.hz@ ctx Ctx.vel@ | hz velocity |
  hz
  params Ms20VoiceParams.note-hz-p
  f!64
  velocity
  params Ms20VoiceParams.target-amp-p
  f!64
  1000000000.0
  params Ms20VoiceParams.gate-time-p
  f!64
  0.0
  state Ms20VoiceState.phase1-p
  f!64
  0.37
  state Ms20VoiceState.phase2-p
  f!64
  0.0
  state Ms20VoiceState.age-p
  f!64
  drop2 drop2 drop
;

( ctx state params -- : release the amp/filter envelopes from current age. )
dsp: ms20-voice-note-off
  | ctx state params |
  state Ms20VoiceState.age@
  params Ms20VoiceParams.gate-time-p
  f!64
  drop2 drop
;

( state params -- value : advance note age and return the new age in seconds. )
dsp: v-age-next
  | state params |
  Ms20VoiceState@: age ;
  Ms20VoiceParams@: inv-sample-rate ;
  f+
  dup
  state Ms20VoiceState.age-p
  f!64
  nip
  nip
;

( state params -- value : capacitor ADSR amplitude multiplied by note velocity. )
dsp: v-amp-env
  | state params |
  Ms20VoiceState@: age ;
  Ms20VoiceParams@: amp-attack amp-decay amp-sustain gate-time amp-release ;
  adsr-cap
  params Ms20VoiceParams.target-amp@
  f*
  nip
  nip
;

( state params -- value : VCO1 with waveform select (tri/saw/pulse), octave
  scaled, phase advanced. The three candidates are computed and fsel-picked —
  no branches in dsp2; the spine keeps the register budget per-stage. )
dsp: v-vco1
  | state params |
  Ms20VoiceState@: phase1 ;
  Ms20VoiceParams@: note-hz vco-octave inv-sample-rate ;
  f*
  f*
  state Ms20VoiceState.pitch-mod@ f*
  | phase dt |
  phase dt phase-advance01
  state Ms20VoiceState.phase1-p
  f!64
  params Ms20VoiceParams.vco1-wave@
  phase tri-raw
  phase dt saw-falling-polyblep
  phase dt state Ms20VoiceState.pw-eff@ pulse-polyblep
  wave-sel3
  nip
  nip
  nip
  nip
;

( state params -- value : render oscillator 2 pulse and advance phase. )
( state params -- value : VCO2 with waveform select (saw/square/pulse),
  detuned and octave-scaled. )
dsp: v-vco2
  | state params |
  Ms20VoiceState@: phase2 ;
  Ms20VoiceParams@: note-hz detune vco2-octave inv-sample-rate ;
  f*
  f*
  f*
  state Ms20VoiceState.pitch-mod@ f*
  | phase dt |
  phase dt phase-advance01
  state Ms20VoiceState.phase2-p
  f!64
  params Ms20VoiceParams.vco2-wave@
  phase dt saw-falling-polyblep
  phase dt 0.5 pulse-polyblep
  phase dt state Ms20VoiceState.pw-eff@ pulse-polyblep
  wave-sel3
  nip
  nip
  nip
  nip
;

( state -- value : float-LCG white-ish noise in -1..1, advancing rng state. )
dsp: v-noise-raw
  | state |
  state Ms20VoiceState.noise-rng@
  1103515245.0 f*
  0.31337 f+
  ffrac
  dup
  state Ms20VoiceState.noise-rng-p
  f!64
  2.0 f* 1.0 f-
  nip
;

( state params -- value : VCO1*lvl + VCO2*lvl + noise*lvl, gently saturated. )
dsp: v-osc-mix
  | state params |
  state params v-vco1
  params Ms20VoiceParams.saw-level@
  f*
  state params v-vco2
  params Ms20VoiceParams.pulse-level@
  f*
  f+
  state v-noise-raw
  params Ms20VoiceParams.noise-level@
  f*
  f+
  ( gentle analog mixer saturation: drive into the rational-tanh shaper
    so a hot sum rounds over instead of clipping hard. )
  1.3 f*
  k-tanh-rational-shape-dsp2
  nip
  nip
;

( state params -- g : modulated cutoff -> filter g.  Modulation sums in
  OCTAVES, like control voltage on the real filter:
    cutoff * 2^[env * env-amount + mg * mg-cutoff]
  so an envelope sweep spends equal time in every octave instead of racing
  through the top and snapping at the end.  ms20-ota-g clamps to [20, 20000]. )
dsp: v-filter-g ( state params -- g )
  | state params |
  state Ms20VoiceState.flt-env@ params Ms20VoiceParams.env-amount@ f*
  state Ms20VoiceState.mg-out@  params Ms20VoiceParams.mg-cutoff@  f*  f+
  exp2-approx
  params Ms20VoiceParams.cutoff@ f*
  params Ms20VoiceParams.os-inv@ ms20-ota-g
  nip nip
;


( out state input -- : DC block input and write it to out. )
dsp: v-dc-out
  | out state input |
  input
  state Ms20VoiceState.dc-prev-x@
  f-
  state Ms20VoiceState.dc-prev-y@
  0.995
  f*
  f+

  input
  state Ms20VoiceState.dc-prev-x-p
  f!64
  dup
  state Ms20VoiceState.dc-prev-y-p
  f!64
  dup
  out
  f!64

  drop2 drop2
;

( out state params -- : probe only the oscillator mix. )
dsp: k-ms20-voice-osc-probe
  | out state params |
  state params v-osc-mix
  out
  f!64
  drop2 drop
;


( out state params -- : probe only the smoothed amp envelope. )
dsp: k-ms20-voice-amp-probe
  | out state params |
  state params v-age-next
  drop
  state params v-amp-env
  out
  f!64
  drop2 drop
;


( out state params -- : probe DC/output with a constant input. )
dsp: k-ms20-voice-dc-probe
  | out state params |
  out state 0.5 v-dc-out
  drop2 drop
;

( ── Voice stages (composed via dsp2 `call:`) ───────────────────────────
  Each stage is a separate compiled word with its own 32-register budget;
  they hand off through state-scratch (osc-out @64, filt-out @72) instead of
  the data stack, so the full voice no longer fights the register ceiling.
  See docs/14 §register strategy. )

( state params -- : advance age, render the saturating VCO mix, store osc-out. )
dsp: v-osc-stage
  | state params |
  state params v-osc-mix
  state Ms20VoiceState.osc-out-p
  f!64
  drop2
;

( phase skew -- bipolar : variable-slope LFO shape. skew picks the peak
  position: ~0 falling ramp, 0.5 triangle, ~1 rising ramp. )
dsp: mg-shape
  | phase skew |
  phase skew
  phase skew f/
  1.0 phase f- 1.0 skew f- f/
  fsel-lt
  2.0 f* 1.0 f-
  nip
  nip
;

( state params -- : modulation hub. Runs first: advances note age and the
  MG/LFO, computes the filter envelope once, and derives the pitch (FM) and
  pulse-width (PWM) modulations the VCOs read. All written to state scratch
  so later stages (osc, filt) just read them. )
dsp: v-mod-stage
  | state params |
  state params v-age-next
  drop
  ( MG: advance phase, store bipolar value, keep it on the stack )
  state Ms20VoiceState.mg-phase@
  params Ms20VoiceParams.mg-freq@ params Ms20VoiceParams.inv-sample-rate@ f*
  phase-advance01
  dup state Ms20VoiceState.mg-phase-p f!64
  params Ms20VoiceParams.mg-wave@ 0.02 0.98 fclamp mg-shape
  dup state Ms20VoiceState.mg-out-p f!64
  | mg |
  ( filter ADSR, stored for both cutoff and pitch routing. Use explicit
    per-field accessors: the grouped @: form assumes [state params] on top,
    which is not the case here (mg is on the stack). )
  state Ms20VoiceState.age@
  params Ms20VoiceParams.filter-attack@
  params Ms20VoiceParams.filter-decay@
  params Ms20VoiceParams.filter-sustain@
  params Ms20VoiceParams.gate-time@
  params Ms20VoiceParams.filter-release@
  adsr-cap
  dup state Ms20VoiceState.flt-env-p f!64
  | fenv |
  ( pitch-mod = 1 + mg*mg-pitch + fenv*eg-pitch )
  1.0
  mg params Ms20VoiceParams.mg-pitch@ f* f+
  fenv params Ms20VoiceParams.eg-pitch@ f* f+
  state Ms20VoiceState.pitch-mod-p f!64
  ( pw-eff = clamp(pulse-width + mg*mg-pw, 0.02, 0.98) )
  params Ms20VoiceParams.pulse-width@
  mg params Ms20VoiceParams.mg-pw@ f* f+
  0.02 0.98 fclamp
  state Ms20VoiceState.pw-eff-p f!64
  drop2 drop2
;

( state params -- : self-oscillating series HPF on osc-out, in place.
  coeffs computed in fy: f = 2*svf-g(hpf-cutoff, fs), q = svf-damping(res).
  HPF state {lp,bp} lives at state+88. )
dsp: v-hpf-stage
  | state params |
  state 88 ptr+
  params Ms20VoiceParams.hpf-cutoff@
  1.0 params Ms20VoiceParams.inv-sample-rate@ f/
  svf-g 2.0 f*
  params Ms20VoiceParams.hpf-resonance@ svf-damping
  state Ms20VoiceState.osc-out@
  k-hpf
  state Ms20VoiceState.osc-out-p
  f!64
  drop2
;

( state params -- : modulated cutoff -> filter g for this sample's LPF
  substeps, and clear filt-out for them to accumulate into. )
dsp: v-cut-stage ( state params -- )
  | state params |
  state params v-filter-g state Ms20VoiceState.filt-g-p f!64
  0.0 state Ms20VoiceState.filt-out-p f!64
  drop2
;

( state params -- : one of the four LPF substeps per sample.  Input is held
  across the four [zero-order upsampling]; filt-out collects the mean. )
dsp: v-ota-sub ( state params -- )
  | state params |
  state Ms20VoiceState.ota-y1-p
  state Ms20VoiceState.osc-out@
  state Ms20VoiceState.filt-g@
  params Ms20VoiceParams.ota-k@
  params Ms20VoiceParams.ota-drive@
  ms20-ota-step
  0.25 f*  state Ms20VoiceState.filt-out@ f+  state Ms20VoiceState.filt-out-p f!64
  drop2
;


( out state params -- : amp env * filt-out * level -> DC block -> out.
  The OTA LPF passes DC [pulse-width asymmetry, drive]; a ~20 Hz one-pole
  highpass [y = x - x1 + 0.9974*y1] removes it. )
dsp: v-vca-stage
  | out state params |
  state params v-amp-env
  state Ms20VoiceState.filt-out@ f*
  params Ms20VoiceParams.level@ f* 2.0 f* | x |  ( +6 dB makeup: LEVEL keeps headroom )
  x state Ms20VoiceState.dc-prev-x@ f-  state Ms20VoiceState.dc-prev-y@ 0.9974 f*  f+ | y |
  x state Ms20VoiceState.dc-prev-x-p f!64
  y state Ms20VoiceState.dc-prev-y-p f!64
  y out f!64
  drop2 drop2 drop
;

( io ctx state params -- : render one mono voice sample by composing the stages.
  A `call:` boundary gives each stage a fresh register budget. )
dsp: k-ms20-voice-sample
  | io ctx state params |
  state params call: v-mod-stage
  state params call: v-osc-stage
  state params call: v-hpf-stage
  state params call: v-cut-stage
  state params call: v-ota-sub
  state params call: v-ota-sub
  state params call: v-ota-sub
  state params call: v-ota-sub
  io state params call: v-vca-stage
;
