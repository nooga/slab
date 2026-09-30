( ms20.fy — MS-20-style mono voice machine.

  The DSP lives in the kernels rig [kernels/06-voices/ms20_voice_probe.fy];
  this file declares the machine: entry words, sizes and param offsets from
  ustruct introspection, controls, and the panel layout.  The host walks the
  descriptor returned by `manifest` [src/machine_desc.zig]. )

include "../../kernels/00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../../kernels/06-voices/ms20_voice_probe.fy"
include "../lib/manifest.fy"

( ctx state params -- : a block's coefficients: both envelopes, the LPF
  profile [MODE, DRV, RES] and the HPF. )
dsp: ms20-block-prepare | ctx:Ctx state params:Ms20VoiceParams -- |
  ctx.inv-sr -> params.inv-sample-rate
  ctx.sr 4.0 f* | osr |
  osr -> params.osr
  params.amp-co&  params.amp-attack params.amp-decay params.amp-sustain params.amp-release
    0.0 params.amp-hold  ctx.inv-sr env-rc-coefs
  params.flt-co&  params.filter-attack params.filter-decay params.filter-sustain params.filter-release
    params.filter-delay 0.0  ctx.inv-sr env-rc-coefs
  ( portamento: a one-pole in the pitch domain, ~3 time constants over
    the knob's time; 0 is off )
  params.portamento 0.001  1.0
    1.0  -3.0  params.portamento ctx.sr f* f/  exp  f-
  fsel-lt -> params.porta-c
  params.lpf-pr&  params.drive  params.resonance 0.8 f*  params.lpf-mode osr ms20-lpf-set
  params.detune 0.08333333333333333 f* exp2 -> params.detune-ratio
  params.hpf-cutoff ctx.sr svf-g 2.0 f* -> params.hpf-f
  ( HPF damping [q = 1/Q] 1.4 [1 - RES/2]^2: flat at 0, Q 3 at 1, Q 18 at
    1.6, zero at full PEAK, where it sings,
    bounded by its bandpass clip )
  1.0  params.hpf-resonance 0.5 f*  f- 0.0 fmax | u |
  u u f* 1.4 f* -> params.hpf-q
  ( AGE: the analog layer [ms20_voice_probe.fy] )
  params.age-amt | ag |
  ag 0.3 f* -> params.curve1
  ag 0.22 f* -> params.curve2
  0.35 ctx.inv-sr drift-coef -> params.drift-c
  0.15 ctx.inv-sr drift-coef -> params.cut-drift-c
  0.0 -> params.bleed
  1.0  1.0  6.283185307179586 15.0 f* ctx.inv-sr f*  f+  f/ -> params.dro-a
  params.lpf-pr&  0.1 ag 0.2 f* f+  ms20-lpf-set-offs
;

: manifest
  "SM-24 Mono" voice-sample machine*
  "k-ms20-voice-sample" render!
  "ms20-voice-note-on"  note-on!
  "ms20-voice-note-expr" note-expr!
  "ms20-voice-note-off" note-off!
  "ms20-block-prepare"  block-prepare!
  Ms20VoiceState.size  state-size!
  Ms20VoiceParams.size params-size!
  940.0 panel-w!

  ( module label id offset min max default curve )
  "VCO1" "WAVE"  "vco1-wave"   Ms20VoiceParams.vco1-wave   1 switch
    "TRI" 0.0 opt  "SAW" 1.0 opt  "PUL" 2.0 opt
  "VCO1" "SCALE" "vco-octave"  Ms20VoiceParams.vco-octave  2 switch
    "32" 0.25 opt  "16" 0.5 opt  "8" 1.0 opt  "4" 2.0 opt
  "VCO2" "WAVE"  "vco2-wave"   Ms20VoiceParams.vco2-wave   2 switch
    "SAW" 0.0 opt  "SQR" 1.0 opt  "PUL" 2.0 opt  "RING" 3.0 opt
  "VCO2" "SCALE" "vco2-octave" Ms20VoiceParams.vco2-octave 1 switch
    "16" 0.5 opt  "8" 1.0 opt  "4" 2.0 opt  "2" 4.0 opt
  "VCO2" "PITCH" "detune"      Ms20VoiceParams.detune      -12.0 12.0 0.1 curve-lin knob
  "VCO2" "PW"    "pulse-width" Ms20VoiceParams.pulse-width 0.5 0.95 0.56 curve-lin knob

  "MIX" "V1"    "saw-level"   Ms20VoiceParams.saw-level   0.0 1.0 0.62 curve-pow knob
  "MIX" "V2"    "pulse-level" Ms20VoiceParams.pulse-level 0.0 1.0 0.38 curve-pow knob
  "MIX" "NOISE" "noise-level" Ms20VoiceParams.noise-level 0.0 1.0 0.0  curve-pow knob

  "HPF" "CUT"  "hpf-cutoff"    Ms20VoiceParams.hpf-cutoff    20.0 15000.0 20.0 curve-exp knob
  "HPF" "PEAK" "hpf-resonance" Ms20VoiceParams.hpf-resonance 0.0 2.0 0.0 curve-lin knob

  "LPF" "CUT"  "cutoff"    Ms20VoiceParams.cutoff    20.0 18000.0 700.0 curve-exp knob
  "LPF" "PEAK" "resonance" Ms20VoiceParams.resonance 0.0 2.0 0.7 curve-lin knob
  "LPF" "DRV"  "drive"     Ms20VoiceParams.drive     0.25 4.0 1.0 curve-exp knob
  "LPF" "MODE" "lpf-mode"  Ms20VoiceParams.lpf-mode  0 switch
    "HOT" 0.0 opt  "WET" 1.0 opt
  "LPF" "ENV"  "env-amount" Ms20VoiceParams.env-amount 0.0 8.0 4.8 curve-lin knob

  "VCA" "LVL" "level" Ms20VoiceParams.level 0.0 1.0 0.44 curve-pow knob
  "VCA" "AGE" "age"   Ms20VoiceParams.age-amt 0.0 1.0 0.4 curve-lin knob

  "AMP ENV" "HOLD" "amp-hold"   Ms20VoiceParams.amp-hold    0.0 20.0 0.0 curve-pow knob
  "AMP ENV" "ATK" "amp-attack"  Ms20VoiceParams.amp-attack  0.001 10.0 0.0055 curve-exp knob
  "AMP ENV" "DEC" "amp-decay"   Ms20VoiceParams.amp-decay   0.01 10.0 0.12 curve-exp knob
  "AMP ENV" "SUS" "amp-sustain" Ms20VoiceParams.amp-sustain 0.0 1.0 0.46 curve-lin knob
  "AMP ENV" "REL" "amp-release" Ms20VoiceParams.amp-release 0.01 10.0 0.13 curve-exp knob

  "FLT ENV" "DLY" "filter-delay"   Ms20VoiceParams.filter-delay   0.0 10.0 0.0 curve-pow knob
  "FLT ENV" "ATK" "filter-attack"  Ms20VoiceParams.filter-attack  0.001 10.0 0.014 curve-exp knob
  "FLT ENV" "DEC" "filter-decay"   Ms20VoiceParams.filter-decay   0.01 10.0 0.14 curve-exp knob
  "FLT ENV" "SUS" "filter-sustain" Ms20VoiceParams.filter-sustain 0.0 1.0 0.18 curve-lin knob
  "FLT ENV" "REL" "filter-release" Ms20VoiceParams.filter-release 0.01 10.0 0.11 curve-exp knob

  "MG" "FREQ" "mg-freq" Ms20VoiceParams.mg-freq 0.1 20.0 3.0 curve-exp knob
  "MG" "WAVE" "mg-wave" Ms20VoiceParams.mg-wave 0.0 1.0 0.5 curve-lin knob

  "MOD" "MG>PIT" "mg-pitch"  Ms20VoiceParams.mg-pitch  0.0 0.12 0.0 curve-pow knob
  "MOD" "MG>PW"  "mg-pw"     Ms20VoiceParams.mg-pw     0.0 0.45 0.0 curve-pow knob
  "MOD" "MG>CUT" "mg-cutoff" Ms20VoiceParams.mg-cutoff 0.0 4.0 0.0 curve-pow knob
  "MOD" "EG>PIT" "eg-pitch"  Ms20VoiceParams.eg-pitch  0.0 1.0 0.0 curve-pow knob
  "MOD" "PORTA"  "portamento" Ms20VoiceParams.portamento 0.0 10.0 0.0 curve-pow knob

  ( The MS-20 face in two rows: the signal path left to right over the
    modulation section.  Waves and scales are LED lists. )
  "VCO1" 2 strip
  "VCO2" 4 strip
  "MIX" 3 strip
  "HPF" 2 strip
  "LPF" 5 strip
  "VCA" 2 strip
  "MG" 2 strip
  "MOD" 5 strip
  "FLT ENV" 5 strip
  "AMP ENV" 5 strip

  ( built-in visualizer cell [docs/15]; comma-separated sources overlay )
  "EG" "FLT ENV,AMP ENV" adsr-display

  1.0 row
    1.0 cell  "VCO1" 1.0 item
    1.0 cell  "VCO2" 1.0 item
    1.0 cell  "MIX" 1.0 item
    1.0 cell  "HPF" 1.0 item
    1.0 cell  "LPF" 1.0 item
    1.0 cell  "VCA" 1.0 item
  1.0 row
    1.0 cell  "MG" 1.0 item
    1.0 cell  "MOD" 1.0 item
    1.0 cell  "FLT ENV" 1.0 item
    1.0 cell  "AMP ENV" 1.0 item
    4.0 cell  "EG" 1.0 item

  machine-desc
;
