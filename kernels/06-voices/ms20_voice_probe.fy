( ms20_voice_probe.fy - MS-20-style mono voice.

  The host calls `k-ms20-voice-sample` once per sample [io advances];
  note-on/off update the per-note params.  Signal path:
    MG + filter EG -> VCO1 + VCO2 + noise -> mixer saturation -> series HPF
    -> OTA LPF [4x] -> VCA -> DC block -> out )

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
  f64 dc-prev-x
  f64 dc-prev-y
  f64 age
  f64 noise-rng        ( float-LCG noise state )
  f64 hpf-lp           ( HPF Chamberlin state {lp, bp}: must stay contiguous )
  f64 hpf-bp
  f64 mg-phase         ( free-running MG/LFO phase )
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
  | ctx:Ctx state params:Ms20VoiceParams |
  ctx.sr | sample-rate |
  1.0
  sample-rate
  f/
  -> params.inv-sample-rate
;

( ctx state params -- : start a mono note and reset oscillator age. )
dsp: ms20-voice-note-on
  | ctx:Ctx state:Ms20VoiceState params:Ms20VoiceParams |
  ctx.hz ctx.vel | hz velocity |
  hz
  -> params.note-hz
  velocity
  -> params.target-amp
  1000000000.0
  -> params.gate-time
  0.0
  -> state.phase1
  0.37
  -> state.phase2
  0.0
  -> state.age
;

( ctx state params -- : release the amp/filter envelopes from current age. )
dsp: ms20-voice-note-off
  | ctx state:Ms20VoiceState params:Ms20VoiceParams |
  state.age
  -> params.gate-time
;

( Advance note age; returns the new age in seconds. )
dsp: v-age-next | state:Ms20VoiceState params:Ms20VoiceParams -- age |
  state.age params.inv-sample-rate f+
  dup -> state.age
;

( Capacitor ADSR amplitude multiplied by note velocity. )
dsp: v-amp-env | state:Ms20VoiceState params:Ms20VoiceParams -- amp |
  state.age
  params.amp-attack  params.amp-decay  params.amp-sustain  params.gate-time  params.amp-release
  adsr-cap
  params.target-amp f*
;

( VCO1 with waveform select (tri/saw/pulse), octave scaled, phase advanced.
  The three candidates are computed and fsel-picked - no branches. pmod is
  the frequency multiplier from MG/EG routing, pw the effective pulse width. )
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

( VCO2 with waveform select (saw/square/pulse), detuned and octave-scaled. )
dsp: v-vco2 | state:Ms20VoiceState params:Ms20VoiceParams pmod pw -- y |
  state.phase2
  params.note-hz  params.detune  params.vco2-octave  params.inv-sample-rate
  f* f* f*
  pmod f*
  | phase dt |
  phase dt phase-advance01
  -> state.phase2
  params.vco2-wave
  phase dt saw-falling-polyblep
  phase dt 0.5 pulse-polyblep
  phase dt pw pulse-polyblep
  wave-sel3
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

( VCO1*lvl + VCO2*lvl + noise*lvl, gently saturated: a hot sum rounds over
  in the rational-tanh shaper instead of clipping hard. )
dsp: v-osc-mix | state params:Ms20VoiceParams pmod pw -- y |
  state params pmod pw v-vco1  params.saw-level f*
  state params pmod pw v-vco2  params.pulse-level f*  f+
  state v-noise-raw  params.noise-level f*  f+
  1.3 f*
  k-tanh-rational-shape-dsp2
;

( Modulated cutoff -> filter g.  Modulation sums in OCTAVES, like control
  voltage on the real filter:
    cutoff * 2^[env * env-amount + mg * mg-cutoff]
  so an envelope sweep spends equal time in every octave instead of racing
  through the top and snapping at the end.  ms20-ota-g clamps to [20, 20000]. )
dsp: v-filter-g | state params:Ms20VoiceParams mg fenv -- g |
  fenv params.env-amount f*
  mg  params.mg-cutoff  f*  f+
  exp2-approx
  params.cutoff f*
  params.os-inv ms20-ota-g
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

( Modulation hub: advances note age and the MG/LFO and evaluates the
  filter envelope.  mg is bipolar, fenv 0..1. )
dsp: v-mod | state:Ms20VoiceState params:Ms20VoiceParams -- mg fenv |
  state params v-age-next | age |
  state.mg-phase
  params.mg-freq params.inv-sample-rate f*
  phase-advance01
  dup -> state.mg-phase
  params.mg-wave 0.02 0.98 fclamp mg-shape
  age
  params.filter-attack
  params.filter-decay
  params.filter-sustain
  params.gate-time
  params.filter-release
  adsr-cap
;

( Self-oscillating series HPF.  Coeffs computed in fy:
  f = 2*svf-g[hpf-cutoff, fs], q = svf-damping[res]. )
dsp: v-hpf | state:Ms20VoiceState params:Ms20VoiceParams x -- y |
  state.hpf-lp&
  params.hpf-cutoff
  1.0 params.inv-sample-rate f/
  svf-g 2.0 f*
  params.hpf-resonance svf-damping
  x
  k-hpf
;

( One of the four LPF substeps per sample.  Input is held across the four
  [zero-order upsampling]; the caller sums the quarter-weighted outputs. )
dsp: v-ota-sub | state:Ms20VoiceState params:Ms20VoiceParams x g -- y |
  state.ota-y1&  x g  params.ota-k  params.ota-drive  ms20-ota-step
  0.25 f*
;

( Amp env * filter out * level -> DC block -> out.  The OTA LPF passes DC
  [pulse-width asymmetry, drive]; a ~20 Hz one-pole highpass
  [y = x - x1 + 0.9974*y1] removes it. )
dsp: v-vca | out state:Ms20VoiceState params:Ms20VoiceParams y -- |
  state params v-amp-env
  y f*
  params.level f* 2.0 f* | x |  ( +6 dB makeup: LEVEL keeps headroom )
  x state.dc-prev-x f-  state.dc-prev-y 0.9974 f*  f+ | o |
  x -> state.dc-prev-x
  o -> state.dc-prev-y
  o out f!64
;

( io ctx state params -- : render one mono voice sample. )
dsp: k-ms20-voice-sample | io ctx state params:Ms20VoiceParams -- |
  state params v-mod | mg fenv |
  ( pitch-mod = 1 + mg*mg-pitch + fenv*eg-pitch )
  1.0  mg params.mg-pitch f* f+  fenv params.eg-pitch f* f+ | pmod |
  ( pw = clamp[pulse-width + mg*mg-pw, 0.02, 0.98] )
  params.pulse-width  mg params.mg-pw f* f+  0.02 0.98 fclamp | pw |
  state params  state params pmod pw v-osc-mix  v-hpf | x |
  state params mg fenv v-filter-g | g |
  0.0
  state params x g v-ota-sub f+
  state params x g v-ota-sub f+
  state params x g v-ota-sub f+
  state params x g v-ota-sub f+ | y |
  io state params y v-vca
;
