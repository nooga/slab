( juno2.fy — Juno-style 8-voice polysynth machine.

  The voice lives in the kernels rig [kernels/06-voices/juno.fy]; this
  file declares the machine.  The host voice pool calls the render
  composition once per voice per segment against per-voice state; all
  note data is per-voice, params are shared.  ctx.chan carries the
  voice index, which DETUNE uses for the analog-spread cents offsets.

  Panel follows the 106: LFO | DCO | HPF | VCF | ENV | VCA.
  Chain it into chorus2 mode I — that is THE sound. )

include "../../kernels/06-voices/juno.fy"
include "../lib/manifest.fy"

: manifest
  "Ju-Know" voice-sample machine*
  "k-juno-voice"       render!
  "juno-note-on"       note-on!
  "juno-note-expr"     note-expr!
  "juno-note-off"      note-off!
  "juno-block-prepare" block-prepare!
  8 voices!
  JunoState.size  state-size!
  JunoParams.size params-size!
  560.0 panel-w!


  "LFO" "RATE" "jn-lfo-rate" JunoParams.lfo-rate 0.3 20.0 1.5 curve-exp knob as-fader
  "LFO" "DELAY" "jn-lfo-delay" JunoParams.lfo-delay 0.0 2.0 0.0 curve-pow knob as-fader
  "LFO" "VIB"  "jn-vib"      JunoParams.vibrato  0.0 1.0  0.0 curve-pow knob as-fader
  "LFO" 3 strip

  "DCO" "RANGE" "jn-range" JunoParams.range 1.0 switch
    "16'" 0.5 opt  "8'" 1.0 opt  "4'" 2.0 opt  as-vradio
  "DCO" "SAW" "jn-saw" JunoParams.saw-on 1.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt
  "DCO" "PULSE" "jn-pulse" JunoParams.pulse-on 0.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt
  "DCO" "PWM"   "jn-pwm"    JunoParams.pwm        0.0 1.0 0.0  curve-lin knob as-fader
  "DCO" "PWMOD" "jn-pwmod" JunoParams.pwm-mode 0.0 switch
    "MAN" 0.0 opt  "LFO" 1.0 opt  "ENV" 2.0 opt  as-list
  "DCO" "SUB"    "jn-sub"    JunoParams.sub-level   0.0 1.0 0.0 curve-pow knob as-fader
  "DCO" "NOISE"  "jn-noise"  JunoParams.noise-level 0.0 1.0 0.0 curve-pow knob as-fader
  "DCO" "DETUNE" "jn-detune" JunoParams.detune      0.0 1.0 0.0 curve-lin knob as-fader
  "DCO" 8 strip

  "HPF" "FREQ" "jn-hpf" JunoParams.hpf-pos 1 switch
    "0" 0.0 opt  "1" 1.0 opt  "2" 2.0 opt  "3" 3.0 opt  as-list
  "HPF" 1 strip

  "VCF" "FREQ" "jn-cutoff" JunoParams.cutoff-hz 30.0 16000.0 1800.0 curve-exp knob as-fader
  "VCF" "RES"  "jn-res"    JunoParams.resonance 0.0  1.0     0.10   curve-lin knob as-fader
  "VCF" "ENV"  "jn-env"    JunoParams.env-amount -1.0 1.0    0.17   curve-lin knob as-fader
  "VCF" "LFO"  "jn-lfovcf" JunoParams.lfo-vcf   0.0  1.0     0.0    curve-pow knob as-fader
  "VCF" "KYBD" "jn-kybd"   JunoParams.kybd      0.0  1.0     0.5    curve-lin knob as-fader
  "VCF" 5 strip

  "ENV" "ATK" "jn-atk" JunoParams.atk-s 0.001 3.0 0.01 curve-exp knob as-fader
  "ENV" "DEC" "jn-dec" JunoParams.dec-s 0.002 12.0 0.30 curve-exp knob as-fader
  "ENV" "SUS" "jn-sus" JunoParams.sus   0.0   1.0 0.60 curve-lin knob as-fader
  "ENV" "REL" "jn-rel" JunoParams.rel-s 0.002 12.0 0.40 curve-exp knob as-fader
  "ENV" 4 strip

  "VCA" "MODE" "jn-vca-mode" JunoParams.vca-mode 0.0 switch
    "ENV" 0.0 opt  "GATE" 1.0 opt
  "VCA" "LEVEL" "jn-level" JunoParams.level 0.0 1.0 0.6 curve-pow knob as-fader
  "VCA" "AGE"   "jn-age"   JunoParams.age-amt 0.0 1.0 0.3 curve-lin knob
  "VCA" 3 strip

  "ENV ADSR" "ENV" adsr-display

  ( The 106 face in two rows: the sources over the shaping, the ADSR
    beside its faders.  Range is a column of LED buttons, the PWM source
    and the 4-step HPF LED lists. )
  1.0 row
    1.0 cell  "LFO" 1.0 item
    1.0 cell  "DCO" 1.0 item
    1.0 cell  "HPF" 1.0 item
  1.0 row
    1.0 cell  "VCF" 1.0 item
    1.0 cell  "VCA" 1.0 item
    1.0 cell  "ENV" 1.0 item
    1.0 cell  "ENV ADSR" 1.0 item

  machine-desc
;
