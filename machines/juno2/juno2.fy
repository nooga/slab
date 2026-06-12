( juno2.fy — Juno-style 8-voice polysynth machine.

  The voice lives in the kernels rig [kernels/06-voices/juno.fy]; this
  file declares the machine.  The host voice pool calls the render
  composition once per voice per segment against per-voice state; all
  note data is per-voice, params are shared.  channel-cell injects the
  voice index, which DETUNE uses for the analog-spread cents offsets.

  Panel follows the 106: LFO | DCO | HPF | VCF | ENV | VCA.
  Chain it into chorus2 mode I — that is THE sound. )

include "../../kernels/06-voices/juno.fy"
include "../lib/manifest.fy"

: manifest
  "juno2" voice-sample machine*
  "k-juno-voice"       render!
  "juno-note-on"       note-on!
  "juno-note-off"      note-off!
  "juno-block-prepare" block-prepare!
  8 voices!
  JunoState.size  state-size!
  JunoParams.size params-size!
  560.0 panel-w!

  JunoState.voice-idx channel-cell

  "LFO" "RATE" "jn-lfo-rate" JunoParams.lfo-rate 0.1 20.0 1.5 curve-exp knob
  "LFO" "VIB"  "jn-vib"      JunoParams.vibrato  0.0 1.0  0.0 curve-pow knob
  "LFO" 1 strip

  "DCO" "RANGE" "jn-range" JunoParams.range 1.0 switch
    "16'" 0.5 opt  "8'" 1.0 opt  "4'" 2.0 opt
  "DCO" "SAW" "jn-saw" JunoParams.saw-on 1.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt
  "DCO" "PULSE" "jn-pulse" JunoParams.pulse-on 0.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt
  "DCO" "PWM"   "jn-pwm"    JunoParams.pwm        0.0 1.0 0.0  curve-lin knob
  "DCO" "PWMOD" "jn-pwmod" JunoParams.pwm-mode 0.0 switch
    "MAN" 0.0 opt  "LFO" 1.0 opt
  "DCO" "SUB"    "jn-sub"    JunoParams.sub-level   0.0 1.0 0.0 curve-pow knob
  "DCO" "NOISE"  "jn-noise"  JunoParams.noise-level 0.0 1.0 0.0 curve-pow knob
  "DCO" "DETUNE" "jn-detune" JunoParams.detune      0.0 1.0 0.0 curve-lin knob
  "DCO" 2 strip

  "HPF" "FREQ" "jn-hpf" JunoParams.hpf-hz 10.0 800.0 20.0 curve-exp knob
  "HPF" 1 strip

  "VCF" "FREQ" "jn-cutoff" JunoParams.cutoff-hz 30.0 16000.0 1800.0 curve-exp knob
  "VCF" "RES"  "jn-res"    JunoParams.resonance 0.0  1.0     0.10   curve-lin knob
  "VCF" "ENV"  "jn-env"    JunoParams.env-amount -1.0 1.0    0.35   curve-lin knob
  "VCF" "LFO"  "jn-lfovcf" JunoParams.lfo-vcf   0.0  1.0     0.0    curve-pow knob
  "VCF" "KYBD" "jn-kybd"   JunoParams.kybd      0.0  1.0     0.5    curve-lin knob
  "VCF" 1 strip

  "ENV" "ATK" "jn-atk" JunoParams.atk-s 0.001 3.0 0.01 curve-exp knob
  "ENV" "DEC" "jn-dec" JunoParams.dec-s 0.01  3.0 0.30 curve-exp knob
  "ENV" "SUS" "jn-sus" JunoParams.sus   0.0   1.0 0.60 curve-lin knob
  "ENV" "REL" "jn-rel" JunoParams.rel-s 0.01  6.0 0.40 curve-exp knob
  "ENV" 1 strip

  "VCA" "MODE" "jn-vca-mode" JunoParams.vca-mode 0.0 switch
    "ENV" 0.0 opt  "GATE" 1.0 opt
  "VCA" "LEVEL" "jn-level" JunoParams.level 0.0 1.0 0.65 curve-pow knob
  "VCA" 1 strip

  "ENV ADSR" "ENV" adsr-display

  machine-desc
;
