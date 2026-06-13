( juno.fy - Juno-style polyphonic voice: DCO [polyBLEP saw + PWM pulse
  + sub square one octave down + noise], one 4-pole lowpass, one HPF,
  one ADSR shared by VCF and VCA, one triangle LFO for vibrato and PWM.

  Polyphony contract [src/machines/fy_raw_machine.zig]: the host calls
  k-juno-voice once per voice per segment against that voice's state
  region, so ALL note data lives in per-voice STATE - params are shared.
  The VCA stage ACCUMULATES into the host-zeroed out buffer.  Voices are
  never freed; a fully released envelope renders silence.

  voice-idx is the host-injected region index [channel-cell]; DETUNE
  spreads voices a few cents apart off a per-voice golden-ratio offset -
  the analog-drift knob the real DCOs were too stable to need.

  Probe case: juno-voice-render. )

include "../01-oscillators/primitives/phase.fy"
include "../01-oscillators/primitives/blep.fy"
include "../03-envelopes/primitives/segments.fy"
include "../04-filters/ms20_svf.fy"
include "../04-filters/ms20_lpf.fy"

ustruct: JunoState
  f64 voice-idx   ( host-injected region/voice index )
  f64 phase       ( DCO phase, free-running )
  f64 sub-phase   ( sub oscillator phase, half rate )
  f64 lfo-phase
  f64 noise-rng
  f64 age         ( seconds since note-on )
  f64 gate-time   ( age at release; huge while held )
  f64 note-hz
  f64 vel
  f64 ic1         ( lpf4 integrator states )
  f64 ic2
  f64 hpf-lp      ( HPF one-pole lowpass state )
  f64 osc-mix     ( stage scratch )
  f64 lfo-out     ( stage scratch, bipolar triangle )
  f64 env-out     ( stage scratch, shared VCF/VCA envelope )
  f64 vcf-out     ( stage scratch )
;

ustruct: JunoParams
  ( user-facing )
  f64 lfo-rate    ( Hz )
  f64 vibrato     ( LFO -> pitch, 0..1 )
  f64 range       ( DCO octave: 0.5 16' / 1 8' / 2 4' - switch value )
  f64 saw-on      ( switch 0/1 )
  f64 pulse-on    ( switch 0/1 )
  f64 pwm         ( pulse width amount, 0..1 )
  f64 pwm-mode    ( 0 manual / 1 LFO - switch )
  f64 sub-level
  f64 noise-level
  f64 detune      ( per-voice spread, 0..1 )
  f64 hpf-hz
  f64 cutoff-hz
  f64 resonance   ( 0..1 )
  f64 env-amount  ( VCF envelope, bipolar -1..1 )
  f64 lfo-vcf     ( LFO -> cutoff, 0..1 )
  f64 kybd        ( keyboard tracking, 0..1 )
  f64 atk-s
  f64 dec-s
  f64 sus
  f64 rel-s
  f64 vca-mode    ( 0 env / 1 gate - switch )
  f64 level
  ( derived - filled by juno-block-prepare )
  f64 inv-sr
  f64 lfo-inc
  f64 hpf-a
  f64 env-amt-hz  ( env-amount * 8000 )
  f64 lfo-vcf-hz  ( lfo-vcf * 3000 )
  f64 vib-frac    ( vibrato * 0.03 - peak pitch deviation ratio )
;

( params sample-rate -- : derived fills, all idempotent. )
dsp2: juno-block-prepare
  | params sr |
  1.0 sr f/ | inv |
  inv params JunoParams.inv-sr-p f!64
  params JunoParams.lfo-rate@ inv f* params JunoParams.lfo-inc-p f!64
  params JunoParams.hpf-hz@ 6.2831853 f* inv f* 0.0 1.0 fclamp
  params JunoParams.hpf-a-p f!64
  params JunoParams.env-amount@ 8000.0 f* params JunoParams.env-amt-hz-p f!64
  params JunoParams.lfo-vcf@ 3000.0 f* params JunoParams.lfo-vcf-hz-p f!64
  params JunoParams.vibrato@ 0.03 f* params JunoParams.vib-frac-p f!64
  drop2 drop
;

( state params hz velocity -- : start this voice.  DCO phases free-run -
  the digitally-controlled oscillators never reset, the envelope does
  the de-clicking, exactly like the hardware. )
dsp2: juno-note-on
  | state params hz velocity |
  hz state JunoState.note-hz-p f!64
  velocity state JunoState.vel-p f!64
  0.0 state JunoState.age-p f!64
  1000000000.0 state JunoState.gate-time-p f!64
  drop2 drop2
;

( state params -- : release this voice from its current age. )
dsp2: juno-note-off
  | state params |
  state JunoState.age@ state JunoState.gate-time-p f!64
  drop2
;

( state params -- : advance age + LFO, evaluate the shared envelope. )
dsp2: v-jn-mod
  | state params |
  state JunoState.age@ params JunoParams.inv-sr@ f+ | age |
  age state JunoState.age-p f!64
  state JunoState.lfo-phase@ params JunoParams.lfo-inc@ f+ ffrac | ph |
  ph state JunoState.lfo-phase-p f!64
  ph 0.5 f- | u |
  u 0.0  0.0 u f-  u  fsel-lt 4.0 f* 1.0 f-
  state JunoState.lfo-out-p f!64
  age
  params JunoParams.atk-s@ params JunoParams.dec-s@ params JunoParams.sus@
  state JunoState.gate-time@ params JunoParams.rel-s@
  adsr-cap
  state JunoState.env-out-p f!64
  drop2 drop2 drop
;

( state params -- : DCO - saw + PWM pulse + sub + noise into osc-mix. )
dsp2: v-jn-dco
  | state params |
  ( per-voice golden-ratio detune around center, +-0.4% at full knob )
  state JunoState.note-hz@ params JunoParams.range@ f*
  1.0
    state JunoState.voice-idx@ 0.618034 f* ffrac 0.5 f-
    params JunoParams.detune@ f* 0.008 f*
  f+ f*
  1.0  state JunoState.lfo-out@ params JunoParams.vib-frac@ f*  f+ f*
  params JunoParams.inv-sr@ f* | dt |
  state JunoState.phase@ dt phase-advance01 | phs |
  phs state JunoState.phase-p f!64
  ( pulse width: manual narrows from square; LFO mode sweeps it )
  params JunoParams.pwm-mode@ 0.5
    0.5  params JunoParams.pwm@ 0.45 f*  f-
    0.5  params JunoParams.pwm@ 0.225 f* 1.0 state JunoState.lfo-out@ f+ f*  f-
  fsel-lt | width |
  ( each source term is bound before summing - a naked running sum
    would interleave with the bind values pushed by later | x | frames )
  phs dt saw-falling-polyblep params JunoParams.saw-on@ f* | osc-saw |
  phs dt width pulse-polyblep params JunoParams.pulse-on@ f* | osc-pls |
  ( sub: blep square at half rate )
  state JunoState.sub-phase@ dt 0.5 f* phase-advance01 | sph |
  sph state JunoState.sub-phase-p f!64
  sph  dt 0.5 f*  0.5 pulse-polyblep params JunoParams.sub-level@ f* | osc-sub |
  ( noise: float LCG )
  state JunoState.noise-rng@ 1103515245.0 f* 0.31337 f+ ffrac | rng |
  rng state JunoState.noise-rng-p f!64
  rng 2.0 f* 1.0 f-  params JunoParams.noise-level@ f* | osc-nz |
  osc-saw osc-pls f+ osc-sub f+ osc-nz f+ 0.32 f*
  state JunoState.osc-mix-p f!64
  drop2 drop2 drop2 drop2 drop2 drop
;

( state params -- : envelope/LFO/tracking-modulated 4-pole, then HPF. )
dsp2: v-jn-vcf
  | state params |
  params JunoParams.cutoff-hz@
  state JunoState.env-out@ params JunoParams.env-amt-hz@ f* f+
  state JunoState.lfo-out@ params JunoParams.lfo-vcf-hz@ f* f+
  state JunoState.note-hz@ 261.6 f-  params JunoParams.kybd@ f*  6.0 f* f+
  4.0 params JunoParams.inv-sr@ f/ svf-g | g |
  ( lpf4 damping convention - 1.2/[1+res*8], NOT the svf's mapping:
    that one rings at zero resonance and whistles at the cutoff )
  1.2  1.0 params JunoParams.resonance@ 8.0 f* f+  f/ 0.015 2.0 fclamp | damp |
  state JunoState.ic1-p state JunoState.ic2-p
  state JunoState.osc-mix@
  g damp 1.0
  fms20-lpf4 | lp |
  ( one-pole highpass: hp = x - lp-state )
  state JunoState.hpf-lp@ | hz0 |
  hz0  lp hz0 f-  params JunoParams.hpf-a@ f*  f+ | hz1 |
  hz1 state JunoState.hpf-lp-p f!64
  lp hz1 f-
  state JunoState.vcf-out-p f!64
  drop2 drop2 drop2 drop
;

( out state params -- : VCA - env or gate mode - ACCUMULATE into out. )
dsp2: v-jn-vca
  | out state params |
  params JunoParams.vca-mode@ 0.5
    state JunoState.env-out@
    state JunoState.age@ state JunoState.gate-time@ 1.0 0.0 fsel-lt
  fsel-lt | amp |
  out f@64
  state JunoState.vcf-out@ amp f*
  state JunoState.vel@ f* params JunoParams.level@ f* f+
  out f!64
  drop2 drop2
;

( out state params -- : one polyphonic voice tick, staged. )
dsp2: k-juno-voice
  | out state params |
  state params call: v-jn-mod
  state params call: v-jn-dco
  state params call: v-jn-vcf
  out state params call: v-jn-vca
;
