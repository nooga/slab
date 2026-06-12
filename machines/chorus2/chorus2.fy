( chorus2.fy — Juno-style BBD chorus machine.

  The DSP lives in the kernels rig [kernels/07-effects/chorus.fy].
  MODE picks the measured Juno-106 voicings; RATE/DEPTH scale around
  them, TONE is the BBD darkness, SPREAD scales the inverted-LFO
  stereo, MIX runs from dry through the canned 50/50 to full vibrato.
  Everything at noon with MIX at half = the Juno. )

include "../../kernels/07-effects/chorus.fy"
include "../lib/manifest.fy"

: manifest
  "chorus2" effect-block machine*
  "k-chorus-tick"        render!
  "chorus-block-prepare" block-prepare!
  ChorusState.size  state-size!
  ChorusParams.size params-size!
  170.0 panel-w!

  ( 12 ms BBD line per channel )
  "bbd" ChorusState.buf ChorusState.buf-len 0.012 buffer
  ChorusState.chan channel-cell

  "CHORUS" "MODE" "chorus-mode" ChorusParams.mode 0.0 switch
    "I" 0.0 opt  "II" 1.0 opt  "I+II" 2.0 opt
  "CHORUS" "RATE"   "chorus-rate"   ChorusParams.rate-mul  0.25  4.0   1.0  curve-exp knob
  "CHORUS" "DEPTH"  "chorus-depth"  ChorusParams.depth-mul 0.0   3.0   1.0  curve-lin knob
  "CHORUS" "TONE"   "chorus-tone"   ChorusParams.tone-hz   2000.0 16000.0 8000.0 curve-exp knob
  "CHORUS" "SPREAD" "chorus-spread" ChorusParams.spread    0.0   1.0   1.0  curve-lin knob
  "CHORUS" "MIX"    "chorus-mix"    ChorusParams.mix       0.0   1.0   0.5  curve-pow knob
  "CHORUS" 2 strip

  machine-desc
;
