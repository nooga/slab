( comp2.fy — stereo-linked compressor machine.

  The DSP lives in the kernels rig [kernels/07-effects/comp.fy]; this
  file declares the machine.  One true-stereo pass: the detector hears
  both channels [or the KEY], so the gain is identical on L and R and
  the image stays put — what makes it usable on buses, not just inserts.
  ATK and REL are the gain's time constants [63 %].  SC HPF keeps the
  low end from pumping the rest; RMS reads average level, PEAK the hits.
  MIX under 100% is parallel [New York] compression. )

include "../../kernels/07-effects/comp.fy"
include "../lib/manifest.fy"

: manifest
  "Comp" effect-block machine*
  "k-comp-tick"        render!
  "comp-block-prepare" block-prepare!
  CompState.size  state-size!
  CompParams.size params-size!
  440.0 panel-w!
  stereo
  sidechain


  "COMP" "THRESH" "comp-thresh" CompParams.thresh-db -48.0 0.0  -18.0 curve-lin knob
  "COMP" "RATIO"  "comp-ratio"  CompParams.ratio     1.0   20.0 4.0   curve-pow knob
  "COMP" "KNEE"   "comp-knee"   CompParams.knee-db   0.0   18.0 6.0   curve-lin knob
  "TIME" "ATK"    "comp-atk"    CompParams.atk-s     0.0001 0.1 0.003 curve-exp knob
  "TIME" "REL"    "comp-rel"    CompParams.rel-s     0.01  2.0  0.1   curve-exp knob
  "SC"   "HPF"    "comp-hpf"    CompParams.hpf-hz    20.0  500.0 20.0 curve-exp knob
  "SC"   "DET"    "comp-det"    CompParams.det       0.0 switch
    "PEAK" 0.0 opt  "RMS" 1.0 opt
  "OUT" "GAIN"   "comp-makeup" CompParams.makeup-db 0.0   24.0 0.0   curve-lin knob
  "OUT" "MIX"    "comp-mix"    CompParams.mix       0.0   1.0  1.0   curve-pow knob
  "COMP" 3 strip
  "TIME" 2 strip
  "SC" 2 strip
  "OUT" 2 strip
  1.0 row
    1.0 cell  "COMP" 1.0 item
    1.0 cell  "TIME" 1.0 item
    1.0 cell  "SC" 1.0 item
    1.0 cell  "OUT" 1.0 item

  machine-desc
;
