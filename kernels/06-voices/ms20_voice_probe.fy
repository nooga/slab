( ms20_voice_probe.fy - MS-20-style mono voice.

  The host calls `k-ms20-voice-sample` once per sample [io advances];
  note-on/off gate the envelopes.  Signal path:

    MG + filter EG -> VCO1 + VCO2 + noise -> mixer -> series HPF
      -> LPF [ms20_lpf.fy, 4x, dec4] -> VCA -> DC block -> out

  The mixer is clean: a quiet sum [0.62 per unit level, the level the
  LPF was voiced at].  The grit belongs to the LPF's input stage, which
  subtracts its clipped feedback from the hot input; clipping two detuned
  saws in the mixer first only made intermodulation mud on low notes.

  The oscillators free-run - a note never resets their phase - and the
  envelopes are RC [env_rc.fy]: a retrigger attacks from the current
  level, so nothing in the voice jumps.  A legato note [ctx.legato] only
  moves the pitch.

  PORTAMENTO glides every note, in octaves, the way the MS-20's does [up
  to 10 s].  VCO2's RING is the MS-20's: an XOR of VCO1's pulse [at PW]
  and VCO2's square, which with +-1 pulses is minus their product.  It
  keeps both pitches and follows PW, closer to sync than to a ring
  modulator.  The filter EG has EG1's DELAY, the amp EG has EG2's HOLD. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/math.fy"
include "../00-primitives/oversample.fy"
include "../01-oscillators/primitives/phase.fy"
include "../01-oscillators/primitives/blep.fy"
include "../01-oscillators/primitives/shapes.fy"
include "../02-shapers/rational.fy"   ( tanh-rational )
include "../03-envelopes/primitives/env_rc.fy"
include "../04-filters/coeffs.fy"   ( svf-g, svf-damping )
include "../04-filters/ms20_hpf.fy"
include "../04-filters/ms20_lpf.fy"

ustruct: Ms20VoiceState
  f64 phase1
  f64 phase2
  f64 dc-prev-x
  f64 dc-prev-y
  f64 noise-rng        ( float-LCG noise state )
  f64 hpf-lp           ( HPF Chamberlin state {lp, bp}: must stay contiguous )
  f64 hpf-bp
  f64 mg-phase         ( free-running MG/LFO phase )
  f64 vel
  f64 oct              ( current pitch, log2 Hz - glides toward target-oct )
  f64 target-oct
  EnvRc amp-env
  EnvRc flt-env
  Ms20Lpf lpf
  Dec4 dec
;

ustruct: Ms20VoiceParams
  f64 note-hz          ( this sample's pitch, from the glide )
  f64 inv-sample-rate
  f64 detune           ( VCO2 PITCH, semitones -12 .. 12: the real MS-20's +-1 octave )
  f64 osr              ( 4x rate: the LPF's )
  f64 cutoff           ( base filter cutoff Hz )
  f64 resonance        ( LPF resonance 0..2 )
  f64 drive            ( LPF input drive, x the mode's own )
  f64 level
  f64 lpf-mode         ( 0 HOT 1 WET - switch )
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
  f64 portamento       ( glide time, seconds - 0 is off )
  f64 filter-delay     ( filter EG: key-down -> attack, seconds [EG1 DELAY] )
  f64 amp-hold         ( amp EG: key-up -> release, seconds [EG2 HOLD] )
  ( derived per block by ms20-block-prepare )
  EnvRcCoefs amp-co
  EnvRcCoefs flt-co
  Ms20LpfProfile lpf-pr
  f64 detune-ratio     ( 2^[detune/12] )
  f64 hpf-f            ( HPF Chamberlin f )
  f64 hpf-q            ( HPF damping )
  f64 porta-c          ( glide one-pole coefficient, per sample )
;

( ctx state params -- : a note.  A fresh note gates both envelopes from
  wherever they are; a legato note only moves the pitch. )
dsp: ms20-voice-note-on
  | ctx:Ctx state:Ms20VoiceState params:Ms20VoiceParams |
  ctx.hz 1.0 fmax log2 | o |
  o -> state.target-oct
  ( the very first note starts on pitch instead of gliding up from 0 Hz )
  state.oct 1.0  o  state.oct  fsel-lt -> state.oct
  ctx.legato 0.5  ctx.vel state.vel  fsel-lt -> state.vel
  state.amp-env& params.amp-co& ctx.legato env-rc-trigger
  state.flt-env& params.flt-co& ctx.legato env-rc-trigger
;

( ctx state params -- : release both envelopes from where they are. )
dsp: ms20-voice-note-off
  | ctx state:Ms20VoiceState params:Ms20VoiceParams |
  state.amp-env& params.amp-co& env-rc-release
  state.flt-env& params.flt-co& env-rc-release
;

( VCO1 with waveform select (tri/saw/pulse), octave scaled, phase advanced.
  The three candidates are computed and picked - no branches. pmod is the
  frequency multiplier from MG/EG routing, pw the effective pulse width. )
dsp: v-vco1 | state:Ms20VoiceState params:Ms20VoiceParams pmod pw -- y |
  state.phase1
  params.note-hz  params.vco-octave  params.inv-sample-rate
  f* f*
  pmod f*
  | phase dt |
  phase dt phase-advance01
  -> state.phase1
  params.vco1-wave
  phase tri-raw
  phase dt saw-falling-polyblep
  phase dt pw pulse-polyblep
  wave-sel3
;

( VCO2 with waveform select (saw/square/pulse/ring), detuned and
  octave-scaled.  Runs after v-vco1: RING reads VCO1's new phase. )
dsp: v-vco2 | state:Ms20VoiceState params:Ms20VoiceParams pmod pw -- y |
  state.phase2
  params.note-hz  params.detune-ratio  params.vco2-octave  params.inv-sample-rate
  f* f* f*
  pmod f*
  | phase dt |
  phase dt phase-advance01
  -> state.phase2
  phase dt 0.5 pulse-polyblep | sq |
  params.vco2-wave 2.5
    params.vco2-wave
    phase dt saw-falling-polyblep
    sq
    phase dt pw pulse-polyblep
    wave-sel3
  ( RING: VCO1's pulse at PW times VCO2's square, sign flipped - the XOR )
    state.phase1
      params.note-hz params.vco-octave f* params.inv-sample-rate f* pmod f*
      pw pulse-polyblep
    sq f* -1.0 f*
  fsel-lt
;

( Float-LCG white-ish noise in -1..1, advancing the rng state. )
dsp: v-noise-raw | state:Ms20VoiceState -- y |
  state.noise-rng
  1103515245.0 f*
  0.31337 f+
  ffrac
  dup -> state.noise-rng
  2.0 f* 1.0 f-
;

( VCO1*lvl + VCO2*lvl + noise*lvl at 0.62 per unit: clean. )
dsp: v-osc-mix | state params:Ms20VoiceParams pmod pw -- y |
  state params pmod pw v-vco1  params.saw-level f*
  state params pmod pw v-vco2  params.pulse-level f*  f+
  state v-noise-raw  params.noise-level f*  f+
  0.62 f*
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
;

( Self-oscillating series HPF, coefficients from the block. )
dsp: v-hpf | state:Ms20VoiceState params:Ms20VoiceParams x -- y |
  state.hpf-lp&  params.hpf-f  params.hpf-q  x  k-hpf
;

( One LPF substep; the input is held across the four. )
dsp: v-lpf-sub | state:Ms20VoiceState params:Ms20VoiceParams x g -- y |
  state.lpf&  params.lpf-pr&  x g  ms20-lpf-step
;

( io ctx state params -- : render one mono voice sample. )
dsp: k-ms20-voice-sample | io ctx state:Ms20VoiceState params:Ms20VoiceParams -- |
  ( portamento, in octaves )
  state.oct  state.target-oct state.oct f-  params.porta-c f*  f+ | oct |
  oct -> state.oct
  oct exp2 -> params.note-hz
  ( MG and the envelopes )
  state.mg-phase  params.mg-freq params.inv-sample-rate f*  phase-advance01
  dup -> state.mg-phase
  params.mg-wave 0.02 0.98 fclamp mg-shape | mg |
  state.flt-env&  params.flt-co&  env-rc-step | fenv |
  state.amp-env&  params.amp-co&  env-rc-step | aenv |
  ( pitch-mod = 1 + mg*mg-pitch + fenv*eg-pitch )
  1.0  mg params.mg-pitch f* f+  fenv params.eg-pitch f* f+ | pmod |
  ( pw = clamp[pulse-width + mg*mg-pw, 0.02, 0.98] )
  params.pulse-width  mg params.mg-pw f* f+  0.02 0.98 fclamp | pw |
  state params  state params pmod pw v-osc-mix  v-hpf | x |
  ( cutoff in octaves, like control voltage: base * 2^[env + MG] )
  fenv params.env-amount f*  mg params.mg-cutoff f*  f+  exp2  params.cutoff f*
    params.osr svf-g | g |
  state.dec&
    state params x g v-lpf-sub
    state params x g v-lpf-sub
    state params x g v-lpf-sub
    state params x g v-lpf-sub
  dec4 | y |
  ( VCA: envelope, velocity, level; then a ~20 Hz DC block )
  y aenv f*  state.vel f*  params.level f*  1.6 f* | v |
  v state.dc-prev-x f-  state.dc-prev-y 0.9974 f*  f+ | o |
  v -> state.dc-prev-x
  o -> state.dc-prev-y
  o io f!64
;
