( verb2.fy — Dattorro plate reverb machine.

  The DSP lives in the kernels rig [kernels/07-effects/reverb.fy]; this
  file declares the machine.  One packed ring per channel; the host
  channel-cell drives L/R decorrelation [tap sets, LFO phase + rate], so
  the tail goes properly wide while staying dual-mono in structure. )

include "../../kernels/07-effects/reverb.fy"
include "../lib/manifest.fy"

: manifest
  "Verb" effect-block machine*
  "k-verb-tick"        render!
  "verb-prepare"       prepare!
  "verb-block-prepare" block-prepare!
  VerbState.size  state-size!
  VerbParams.size params-size!
  170.0 panel-w!

  ( one packed tank ring per channel; region table in reverb.fy )
  "tank" VerbState.buf VerbState.buf-len 0.9 buffer
  VerbState.chan channel-cell

  "PLATE" "PREDLY" "verb-predelay" VerbParams.predelay-s 0.001 0.12  0.02 curve-exp knob
  "PLATE" "DECAY"  "verb-decay"    VerbParams.decay      0.30  0.97  0.75 curve-lin knob
  "PLATE" "DAMP"   "verb-damp"     VerbParams.damp-hz    1000.0 16000.0 5000.0 curve-exp knob
  "PLATE" "TONE"   "verb-tone"     VerbParams.bw-hz      1000.0 18000.0 9000.0 curve-exp knob
  "PLATE" "MIX"    "verb-mix"      VerbParams.mix        0.0   1.0   0.30 curve-pow knob
  "PLATE" "MOD"    "verb-mod"      VerbParams.mod-depth  0.0   24.0  10.0 curve-lin knob
  "PLATE" 2 strip

  ( fixed modulation rate; depth is the MOD knob )
  VerbParams.mod-rate 1.2 const-f64

  machine-desc
;
