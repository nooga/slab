( wob2.fy - Wobble: a filter that moves [docs/43 §Wobble].

  An SVF [LP/BP/HP, 12 or 24 dB, self-oscillating] or a wah, swept by an
  LFO, a 16-step sequence, the input's envelope or a pedal.  The LFO
  wobble, the step filter, the auto-wah and the pedal wah are all this
  box.  The DSP is kernels/07-effects/wobble.fy. )

include "../../kernels/07-effects/wobble.fy"
include "../lib/manifest.fy"

: manifest
  "Wobble" effect-block machine*
  "k-wobble-tick" render!  "wobble-block-prepare" block-prepare!
  WobbleState.size state-size!  WobbleParams.size params-size!
  880.0 panel-w!  stereo
  1.0 tail!

  "FILTER" "TYPE" "wob-type" WobbleParams.type 0.0 switch
    "SVF" 0.0 opt "WAH" 1.0 opt as-radio
  "FILTER" "CUTOFF" "wob-cutoff" WobbleParams.cutoff 20.0 18000.0 400.0 curve-exp knob
  "FILTER" "RES" "wob-res" WobbleParams.res 0.0 1.0 0.5 curve-lin knob
  "FILTER" "MORPH" "wob-morph" WobbleParams.morph 0.0 1.0 0.0 curve-lin knob
  "FILTER" "SLOPE" "wob-slope" WobbleParams.slope 0.0 switch
    "12" 0.0 opt "24" 1.0 opt as-radio
  "FILTER" "DRIVE" "wob-drive" WobbleParams.drive-db 0.0 24.0 0.0 curve-lin knob
  "MOD" "SOURCE" "wob-source" WobbleParams.source 0.0 switch
    "LFO" 0.0 opt "STEP" 1.0 opt "ENV" 2.0 opt "PEDAL" 3.0 opt as-list span-rows
  "MOD" "DEPTH" "wob-depth" WobbleParams.depth -6.0 6.0 3.0 curve-lin knob
  "MOD" "AMP" "wob-amp" WobbleParams.amp 0.0 1.0 0.0 curve-lin knob
  "MOD" "GLIDE" "wob-glide" WobbleParams.glide 0.0 1.0 0.0 curve-lin knob
  "MOD" "POS" "wob-pos" WobbleParams.pos 0.0 1.0 0.5 curve-lin knob
  "LFO" "SHAPE" "wob-shape" WobbleParams.shape 0.0 switch
    "SINE" 0.0 opt "TRI" 1.0 opt "SAW UP" 2.0 opt "SAW DN" 3.0 opt
    "SQUARE" 4.0 opt "S&H" 5.0 opt "RANDOM" 6.0 opt as-display
  "LFO" "RATE" "wob-rate" WobbleParams.rate 0.05 40.0 2.0 curve-exp knob
  "LFO" "SYNC" "wob-sync" WobbleParams.sync 1.0 switch
    "FREE" 0.0 opt "SYNC" 1.0 opt as-button
  "LFO" "DIV" "wob-div" WobbleParams.div 5.0 switch
    "4 BAR" 16.0 opt "2 BAR" 8.0 opt "1 BAR" 4.0 opt "1/2" 2.0 opt
    "1/4" 1.0 opt "1/8" 0.5 opt "1/16" 0.25 opt "1/32" 0.125 opt
    "1/4D" 1.5 opt "1/8D" 0.75 opt "1/16D" 0.375 opt
    "1/4T" 0.6666666666666666 opt "1/8T" 0.3333333333333333 opt "1/16T" 0.16666666666666666 opt as-display
  "LFO" "PHASE" "wob-phase" WobbleParams.phase0 0.0 1.0 0.0 curve-lin knob
  "LFO" "SPREAD" "wob-spread" WobbleParams.spread 0.0 180.0 0.0 curve-lin knob
  "LFO" "RETRIG" "wob-retrig" WobbleParams.retrig 0.0 switch
    "OFF" 0.0 opt "ON" 1.0 opt as-button
  "STEP" "1" "wob-s1" WobbleParams.steps 0 + 0.0 1.0 1 curve-lin knob as-fader
  "STEP" "2" "wob-s2" WobbleParams.steps 8 + 0.0 1.0 0 curve-lin knob as-fader
  "STEP" "3" "wob-s3" WobbleParams.steps 16 + 0.0 1.0 0.5 curve-lin knob as-fader
  "STEP" "4" "wob-s4" WobbleParams.steps 24 + 0.0 1.0 0 curve-lin knob as-fader
  "STEP" "5" "wob-s5" WobbleParams.steps 32 + 0.0 1.0 1 curve-lin knob as-fader
  "STEP" "6" "wob-s6" WobbleParams.steps 40 + 0.0 1.0 0 curve-lin knob as-fader
  "STEP" "7" "wob-s7" WobbleParams.steps 48 + 0.0 1.0 0.75 curve-lin knob as-fader
  "STEP" "8" "wob-s8" WobbleParams.steps 56 + 0.0 1.0 0.25 curve-lin knob as-fader
  "STEP" "9" "wob-s9" WobbleParams.steps 64 + 0.0 1.0 1 curve-lin knob as-fader
  "STEP" "10" "wob-s10" WobbleParams.steps 72 + 0.0 1.0 0 curve-lin knob as-fader
  "STEP" "11" "wob-s11" WobbleParams.steps 80 + 0.0 1.0 0.5 curve-lin knob as-fader
  "STEP" "12" "wob-s12" WobbleParams.steps 88 + 0.0 1.0 0.25 curve-lin knob as-fader
  "STEP" "13" "wob-s13" WobbleParams.steps 96 + 0.0 1.0 1 curve-lin knob as-fader
  "STEP" "14" "wob-s14" WobbleParams.steps 104 + 0.0 1.0 0.5 curve-lin knob as-fader
  "STEP" "15" "wob-s15" WobbleParams.steps 112 + 0.0 1.0 0.75 curve-lin knob as-fader
  "STEP" "16" "wob-s16" WobbleParams.steps 120 + 0.0 1.0 0 curve-lin knob as-fader
  "STEP" "LEN" "wob-length" WobbleParams.length 1.0 16.0 16.0 curve-lin knob
  "ENV" "SENS" "wob-sens" WobbleParams.sens-db -12.0 36.0 12.0 curve-lin knob
  "ENV" "ATK" "wob-atk" WobbleParams.atk 0.001 0.1 0.005 curve-exp knob
  "ENV" "REL" "wob-rel" WobbleParams.rel 0.02 1.0 0.15 curve-exp knob
  "OUT" "MIX" "wob-mix" WobbleParams.mix 0.0 1.0 1.0 curve-lin knob
  "OUT" "LEVEL" "wob-out" WobbleParams.out-db -24.0 12.0 0.0 curve-lin knob
  "FILTER" 3 strip
  "MOD" 3 strip
  "LFO" 4 strip
  "STEP" 17 strip
  "ENV" 3 strip
  "OUT" 2 strip
  1.0 row
    1.0 cell "FILTER" 1.0 item
    1.0 cell "MOD" 1.0 item
    1.3 cell "LFO" 1.0 item
  1.0 row
    2.6 cell "STEP" 1.0 item
    0.7 cell "ENV" 1.0 item
    0.5 cell "OUT" 1.0 item
  machine-desc
;
