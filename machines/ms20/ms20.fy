( ms20.fy — MS-20-style mono voice machine.

  The DSP lives in the kernels rig [kernels/06-voices/ms20_voice_probe.fy];
  this file declares the machine: entry words, sizes and param offsets from
  ustruct introspection, controls, and the panel layout.  The host walks the
  descriptor returned by `manifest` [src/machine_desc.zig]. )

include "../../kernels/06-voices/ms20_voice_probe.fy"
include "../lib/manifest.fy"

( params sample-rate -- : per-block coefficient fill.  The SvfParams-shaped
  profile region starts at Ms20VoiceParams.svf-g; the two coeff words drop
  their own args, so only ours remain. )
dsp: ms20-block-prepare
  | params sr |
  params Ms20VoiceParams.svf-g-p  sr 4.0 f*  k-svf-coeffs-dc
  params Ms20VoiceParams.svf-g-p  params Ms20VoiceParams.resonance@  k-svf-coeffs-profile
  drop2
;

: manifest
  "SM-24 Mono" voice-sample machine*
  "k-ms20-voice-sample" render!
  "ms20-voice-prepare"  prepare!
  "ms20-voice-note-on"  note-on!
  "ms20-voice-note-off" note-off!
  "ms20-block-prepare"  block-prepare!
  Ms20VoiceState.size  state-size!
  Ms20VoiceParams.size params-size!
  420.0 panel-w!

  ( module label id offset min max default curve )
  "VCO1" "WAVE"  "vco1-wave"   Ms20VoiceParams.vco1-wave   1 switch
    "TRI" 0.0 opt  "SAW" 1.0 opt  "PUL" 2.0 opt
  "VCO1" "SCALE" "vco-octave"  Ms20VoiceParams.vco-octave  2 switch
    "32" 0.25 opt  "16" 0.5 opt  "8" 1.0 opt  "4" 2.0 opt
  "VCO2" "WAVE"  "vco2-wave"   Ms20VoiceParams.vco2-wave   2 switch
    "SAW" 0.0 opt  "SQR" 1.0 opt  "PUL" 2.0 opt
  "VCO2" "SCALE" "vco2-octave" Ms20VoiceParams.vco2-octave 2 switch
    "32" 0.25 opt  "16" 0.5 opt  "8" 1.0 opt  "4" 2.0 opt
  "VCO2" "DET"   "detune"      Ms20VoiceParams.detune      0.995 1.018 1.0058 curve-lin knob
  "VCO2" "PW"    "pulse-width" Ms20VoiceParams.pulse-width 0.05 0.95 0.44 curve-lin knob

  "MIX" "V1"    "saw-level"   Ms20VoiceParams.saw-level   0.0 1.0 0.62 curve-pow knob
  "MIX" "V2"    "pulse-level" Ms20VoiceParams.pulse-level 0.0 1.0 0.38 curve-pow knob
  "MIX" "NOISE" "noise-level" Ms20VoiceParams.noise-level 0.0 1.0 0.0  curve-pow knob

  "HPF" "CUT"  "hpf-cutoff"    Ms20VoiceParams.hpf-cutoff    20.0 2000.0 20.0 curve-exp knob
  "HPF" "PEAK" "hpf-resonance" Ms20VoiceParams.hpf-resonance 0.0 2.0 0.0 curve-lin knob

  "LPF" "CUT"  "cutoff"    Ms20VoiceParams.cutoff    60.0 5000.0 180.0 curve-exp knob
  "LPF" "PEAK" "resonance" Ms20VoiceParams.resonance 0.0 2.0 1.25 curve-lin knob
  "LPF" "DRV"  "drive"     Ms20VoiceParams.drive     0.4 2.2 1.25 curve-lin knob
  "LPF" "ENV"  "env-peak"  Ms20VoiceParams.env-peak  250.0 8000.0 5000.0 curve-exp knob

  "VCA" "LVL" "level" Ms20VoiceParams.level 0.0 1.0 0.72 curve-pow knob

  "AMP ENV" "ATK" "amp-attack"  Ms20VoiceParams.amp-attack  0.001 0.4 0.0055 curve-exp knob
  "AMP ENV" "DEC" "amp-decay"   Ms20VoiceParams.amp-decay   0.01 1.2 0.12 curve-exp knob
  "AMP ENV" "SUS" "amp-sustain" Ms20VoiceParams.amp-sustain 0.0 1.0 0.46 curve-lin knob
  "AMP ENV" "REL" "amp-release" Ms20VoiceParams.amp-release 0.01 1.2 0.13 curve-exp knob

  "FLT ENV" "ATK" "filter-attack"  Ms20VoiceParams.filter-attack  0.001 0.5 0.014 curve-exp knob
  "FLT ENV" "DEC" "filter-decay"   Ms20VoiceParams.filter-decay   0.01 1.4 0.14 curve-exp knob
  "FLT ENV" "SUS" "filter-sustain" Ms20VoiceParams.filter-sustain 0.0 1.0 0.18 curve-lin knob
  "FLT ENV" "REL" "filter-release" Ms20VoiceParams.filter-release 0.01 1.2 0.11 curve-exp knob

  "MG" "FREQ" "mg-freq" Ms20VoiceParams.mg-freq 0.05 30.0 3.0 curve-exp knob
  "MG" "WAVE" "mg-wave" Ms20VoiceParams.mg-wave 0.0 1.0 0.5 curve-lin knob

  "MOD" "MG>PIT" "mg-pitch"  Ms20VoiceParams.mg-pitch  0.0 0.12 0.0 curve-pow knob
  "MOD" "MG>PW"  "mg-pw"     Ms20VoiceParams.mg-pw     0.0 0.45 0.0 curve-pow knob
  "MOD" "MG>CUT" "mg-cutoff" Ms20VoiceParams.mg-cutoff 0.0 3000.0 0.0 curve-pow knob
  "MOD" "EG>PIT" "eg-pitch"  Ms20VoiceParams.eg-pitch  0.0 1.0 0.0 curve-pow knob

  ( module knob-cols — module strip + its internal knob-grid columns )
  "VCO1" 1 strip
  "VCO2" 1 strip
  "MIX" 1 strip
  "HPF" 1 strip
  "LPF" 1 strip
  "VCA" 1 strip
  "AMP ENV" 1 strip
  "FLT ENV" 1 strip
  "MG" 1 strip
  "MOD" 4 strip

  ( built-in visualizer cell [docs/15]; comma-separated sources overlay )
  "EG" "FLT ENV,AMP ENV" adsr-display

  ( weighted box layout [docs/15]: row then cells; items stack in a cell )
  4.0 row
    1.0 cell  "VCO1" 1.0 item  "MG" 1.0 item
    1.0 cell  "VCO2" 1.0 item
    1.0 cell  "MIX" 3.0 item  "VCA" 1.0 item
    1.6 cell  "HPF" 4.0 item  "EG" 1.0 item
    1.0 cell  "LPF" 1.0 item
    1.0 cell  "AMP ENV" 1.0 item
    1.0 cell  "FLT ENV" 1.0 item
  1.0 row
    1.0 cell  "MOD" 1.0 item

  Ms20VoiceParams.amp-coeff 0.0035 const-f64
  machine-desc
;
