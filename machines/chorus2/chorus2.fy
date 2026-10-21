( chorus2.fy — Juno-style BBD chorus machine.

  The DSP lives in the kernels rig [kernels/07-effects/chorus.fy].
  MODE picks the measured Juno-106 voicings; RATE/DEPTH scale around
  them, TONE is the BBD darkness, SPREAD scales the inverted-LFO
  stereo, MIX runs from dry through the canned 50/50 to full vibrato.
  Everything at noon with MIX at half = the Juno. )

include "../../kernels/07-effects/chorus.fy"
include "../lib/manifest.fy"

: manifest
  "Chorus" effect-block machine*
  "k-chorus-tick"        render!
  "chorus-block-prepare" block-prepare!
  ChorusState.size  state-size!
  ChorusParams.size params-size!
  520.0 panel-w!

  ( 12 ms BBD line per channel )
  "bbd" ChorusState.buf ChorusState.buf-len 0.012 buffer

  "CHORUS" "MODE" "chorus-mode" ChorusParams.mode 0.0 switch
    "I" 0.0 opt  "II" 1.0 opt  "I+II" 2.0 opt  as-radio
  "CHORUS" "RATE"   "chorus-rate"   ChorusParams.rate-mul  0.25  4.0   1.0  curve-exp knob
  "CHORUS" "DEPTH"  "chorus-depth"  ChorusParams.depth-mul 0.0   3.0   1.0  curve-lin knob
  "CHORUS" "TONE"   "chorus-tone"   ChorusParams.tone-hz   2000.0 16000.0 8000.0 curve-exp knob
  "CHORUS" "SPREAD" "chorus-spread" ChorusParams.spread    0.0   1.0   1.0  curve-lin knob
  "CHORUS" "MIX"    "chorus-mix"    ChorusParams.mix       0.0   1.0   0.5  curve-pow knob
  "CHOKE" "FDBK"   "chorus-fb"     ChorusParams.feedback  0.0   0.9   0.0  curve-lin knob
  "CHOKE" "WET HP" "chorus-hp"     ChorusParams.hp-hz     0.0   800.0 0.0  curve-pow knob
  "CHOKE" "INVERT" "chorus-invert" ChorusParams.invert 0.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt  as-radio
  "CHORUS" 6 strip
  "CHOKE" 3 strip
  1.0 row
    2.0 cell  "CHORUS" 1.0 item
    1.0 cell  "CHOKE" 1.0 item

  machine-desc
;
