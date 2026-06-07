( ms20_voice_probe.fy - fused fy MS-20-style mono voice fixture.

  The rig calls `k-ms20-voice-sample` with auto-advancing output pointer for
  contiguous note-event segments. Zig updates note params at event boundaries;
  fy owns the per-sample oscillator/filter/VCA/DC composition. )

include "../01-oscillators/primitives/phase.fy"
include "../01-oscillators/primitives/blep.fy"
include "../01-oscillators/primitives/shapes.fy"
include "../02-shapers/tanh_table.fy"
include "../03-envelopes/primitives/segments.fy"
include "../04-filters/ms20_lpf.fy"
include "../04-filters/ms20_svf.fy"

ustruct: Ms20VoiceState
  f64 phase1
  f64 phase2
  f64 ic1
  f64 ic2
  f64 dc-prev-x
  f64 dc-prev-y
  f64 amp-smooth
  f64 age
;

ustruct: Ms20VoiceParams
  f64 note-hz
  f64 target-amp
  f64 inv-sample-rate
  f64 detune
  f64 cutoff           ( base filter cutoff Hz - control @32 )
  f64 resonance        ( filter resonance - control @40 )
  f64 drive            ( unused on svf path; profile.drive drives the filter )
  f64 level
  f64 amp-coeff
  f64 gate-time
  f64 amp-attack
  f64 amp-decay
  f64 amp-sustain
  f64 amp-release
  f64 env-peak         ( filter env peak cutoff Hz - control @112 )
  f64 filter-attack
  f64 filter-decay
  f64 filter-sustain
  f64 filter-release
  f64 saw-level
  f64 pulse-level
  f64 pulse-width
  ( appended SvfParams profile region @176; host fills it per block via
    k-svf-coeffs-dc / k-svf-coeffs-profile (profile-ptr = params 176 ptr+).
    Layout MUST match SvfParams so fms20-svf reads drive@+16 .. out-dc@+72. )
  f64 svf-g
  f64 svf-damping
  f64 svf-drive
  f64 svf-resonance
  f64 svf-fb-gain
  f64 svf-fb-clip
  f64 svf-out-clip
  f64 svf-leak
  f64 svf-fb-dc-coeff
  f64 svf-out-dc-coeff
  f64 vco-octave       ( @256, VCO1 octave/SCALE frequency multiplier - switch )
  f64 vco2-octave      ( @264, VCO2 octave/SCALE frequency multiplier - switch )
;

( state params sample-rate -- : update sample-rate derived params. )
dsp2: ms20-voice-prepare
  | state params sample-rate |
  1.0
  sample-rate
  f/
  params Ms20VoiceParams.inv-sample-rate-p
  f!64
  drop2 drop
;

( state params hz velocity -- : start a mono note and reset oscillator age. )
dsp2: ms20-voice-note-on
  | state params hz velocity |
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
  drop2 drop2
;

( state params -- : release the amp/filter envelopes from current age. )
dsp2: ms20-voice-note-off
  | state params |
  state Ms20VoiceState.age@
  params Ms20VoiceParams.gate-time-p
  f!64
  drop2
;

( state params -- value : advance note age and return the new age in seconds. )
dsp2: v-age-next
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
dsp2: v-amp-env
  | state params |
  Ms20VoiceState@: age ;
  Ms20VoiceParams@: amp-attack amp-decay amp-sustain gate-time amp-release ;
  adsr-cap
  params Ms20VoiceParams.target-amp@
  f*
  nip
  nip
;

( state params -- value : render oscillator 1 falling saw and advance phase. )
dsp2: v-saw1
  | state params |
  Ms20VoiceState@: phase1 ;
  Ms20VoiceParams@: note-hz vco-octave inv-sample-rate ;
  f*
  f*
  | phase dt |
  phase dt phase-advance01
  state Ms20VoiceState.phase1-p
  f!64
  phase dt saw-falling-polyblep
  nip
  nip
  nip
  nip
;

( state params -- value : render oscillator 2 pulse and advance phase. )
dsp2: v-pulse2
  | state params |
  Ms20VoiceState@: phase2 ;
  Ms20VoiceParams@: note-hz detune vco2-octave inv-sample-rate ;
  f*
  f*
  f*
  | phase dt |
  phase dt phase-advance01
  state Ms20VoiceState.phase2-p
  f!64
  phase dt
  params Ms20VoiceParams.pulse-width@
  pulse-polyblep
  nip
  nip
  nip
  nip
;

( state params -- value : mix the two oscillator primitives. )
dsp2: v-osc-mix
  | state params |
  state params v-saw1
  state params v-pulse2
  params Ms20VoiceParams.pulse-level@
  f*
  swap
  params Ms20VoiceParams.saw-level@
  f*
  f+
  ( gentle analog mixer saturation: drive into the rational-tanh shaper
    so a hot VCO1+VCO2 sum rounds over instead of clipping hard. )
  1.3 f*
  k-tanh-rational-shape-dsp2
  nip
  nip
;

( state params -- g : envelope-modulated cutoff -> filter g, computed in fy.
  cutoff = base + (env-peak - base) * filter-adsr ; g = svf-g(cutoff, osr). )
dsp2: v-filter-g
  | state params |
  Ms20VoiceState@: age ;
  Ms20VoiceParams@: filter-attack filter-decay filter-sustain gate-time filter-release ;
  adsr-cap
  params Ms20VoiceParams.env-peak@
  params Ms20VoiceParams.cutoff@
  f-
  f*
  params Ms20VoiceParams.cutoff@
  f+
  4.0
  params Ms20VoiceParams.inv-sample-rate@
  f/
  svf-g
  nip
  nip
;

( state params input -- value : run the g-wet svf filter. Filter state
  {ic1,ic2,fb_dc,out_dc} is the contiguous block at state+16; static profile
  at params+176; g per-sample (envelope-modulated); damping from resonance. )
dsp2: v-filter
  | state params input |
  state 16 ptr+
  params 176 ptr+
  input
  state params v-filter-g
  params Ms20VoiceParams.resonance@ svf-damping
  fms20-svf
  nip
  nip
  nip
;

( out state input -- : DC block input and write it to out. )
dsp2: v-dc-out
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
dsp2: k-ms20-voice-osc-probe
  | out state params |
  state params v-osc-mix
  out
  f!64
  drop2 drop
;

( out state params -- : probe oscillator mix through the voice filter. )
dsp2: k-ms20-voice-filter-probe
  | out state params |
  state params v-age-next
  drop
  state params v-osc-mix
  | osc |
  state params osc v-filter
  nip
  out
  f!64
  drop2 drop
;

( out state params -- : probe only the smoothed amp envelope. )
dsp2: k-ms20-voice-amp-probe
  | out state params |
  state params v-age-next
  drop
  state params v-amp-env
  out
  f!64
  drop2 drop
;

( out state params -- : probe the fused voice before DC blocking. )
dsp2: k-ms20-voice-vca-probe
  | out state params |
  state params v-age-next
  drop
  state params v-amp-env
  | amp |
  state params v-osc-mix
  | osc |
  state params osc v-filter
  nip
  params Ms20VoiceParams.level@
  f*
  amp
  f*
  nip
  out
  f!64
  drop2 drop
;

( out state params -- : probe DC/output with a constant input. )
dsp2: k-ms20-voice-dc-probe
  | out state params |
  out state 0.5 v-dc-out
  drop2 drop
;

( out state params -- : render one mono voice sample, update state, and write output. )
dsp2: k-ms20-voice-sample
  | out state params |
  state params v-age-next
  drop
  state params v-osc-mix
  | osc |
  state params osc v-filter
  nip
  ( amp env after the filter: keep register pressure low while fms20-svf inlines )
  state params v-amp-env
  f*
  params Ms20VoiceParams.level@
  f*
  out
  f!64
  drop2 drop
;
