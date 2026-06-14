( comp2.fy — stereo-linked compressor machine.

  The DSP lives in the kernels rig [kernels/07-effects/comp.fy]; this
  file declares the machine.  The host detector-cell feeds both channels
  one max-abs-stereo trace, so the gain is identical on L and R and the
  image stays put — what makes it usable on buses, not just inserts.
  MIX under 100% is parallel [New York] compression. )

include "../../kernels/07-effects/comp.fy"
include "../lib/manifest.fy"

: manifest
  "Comp" effect-block machine*
  "k-comp-tick"        render!
  "comp-prepare"       prepare!
  "comp-block-prepare" block-prepare!
  CompState.size  state-size!
  CompParams.size params-size!
  190.0 panel-w!

  CompState.det detector-cell

  "COMP" "THRESH" "comp-thresh" CompParams.thresh-db -48.0 0.0  -18.0 curve-lin knob
  "COMP" "RATIO"  "comp-ratio"  CompParams.ratio     1.0   20.0 4.0   curve-pow knob
  "COMP" "KNEE"   "comp-knee"   CompParams.knee-db   0.0   18.0 6.0   curve-lin knob
  "COMP" "ATK"    "comp-atk"    CompParams.atk-s     0.0002 0.1 0.005 curve-exp knob
  "COMP" "REL"    "comp-rel"    CompParams.rel-s     0.02  1.5  0.12  curve-exp knob
  "COMP" "GAIN"   "comp-makeup" CompParams.makeup-db 0.0   24.0 0.0   curve-lin knob
  "COMP" "MIX"    "comp-mix"    CompParams.mix       0.0   1.0  1.0   curve-pow knob
  "COMP" 4 strip

  machine-desc
;
