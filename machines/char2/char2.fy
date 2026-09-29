( char2.fy - character compressor machine [docs/24 §Character modes].

  MODE picks a bundle: FET [2 dB knee, peak, REL as set, odd-leaning
  colour], OPTO [12 dB knee, RMS, half back in 60 ms and the rest over
  REL, slower after long squash, light even colour], VARI [24 dB knee -
  the ratio rises with level - peak, a slow branch that holds a floor,
  heavy even colour].  DRIVE scales the colour, which grows with the
  gain reduction; 0 is clean.  The DSP is kernels/07-effects/char.fy. )

include "../../kernels/07-effects/char.fy"
include "../lib/manifest.fy"

: manifest
  "Char" effect-block machine*
  "k-char-tick"        render!
  "char-derive"        derive!
  "char-block-prepare" block-prepare!
  "k-char-tick-clean" CompParams.size CharParams.k2 + render-lite!
  CompState.size CharState.size +   state-size!
  CompParams.size CharParams.size + params-size!
  300.0 panel-w!
  stereo
  sidechain

  "COMP" "MODE"   "char-mode"   CompParams.size CharParams.mode + 0.0 switch
    "FET" 0.0 opt  "OPTO" 1.0 opt  "VARI" 2.0 opt
  "COMP" "THRESH" "char-thresh" CompParams.thresh-db -40.0 0.0 -18.0 curve-lin knob
  "COMP" "RATIO"  "char-ratio"  CompParams.ratio 1.0 20.0 4.0 curve-pow knob
  "TIME" "ATK"    "char-atk"    CompParams.atk-s 0.00002 0.05 0.001 curve-exp knob
  "TIME" "REL"    "char-rel"    CompParams.rel-s 0.05 5.0 0.3 curve-exp knob
  "SC"   "HPF"    "char-hpf"    CompParams.hpf-hz 20.0 500.0 20.0 curve-exp knob
  "OUT"  "DRIVE"  "char-drive"  CompParams.size CharParams.drive + 0.0 1.0 0.3 curve-lin knob
  "OUT"  "MAKEUP" "char-makeup" CompParams.makeup-db 0.0 24.0 0.0 curve-lin knob
  "OUT"  "MIX"    "char-mix"    CompParams.mix 0.0 1.0 1.0 curve-pow knob
  "COMP" 1 strip
  "TIME" 2 strip
  "SC" 1 strip
  "OUT" 3 strip
  "CURVE" "char" CompState.size CharState.gr-db + CompState.lvl CompState.size CharState.knee + dyn-display-knee

  1.0 row
    1.3 cell  "CURVE" 1.0 item
    1.0 cell  "COMP" 1.0 item
  1.0 row
    1.0 cell  "TIME" 1.0 item
    0.5 cell  "SC" 1.0 item
    1.5 cell  "OUT" 1.0 item

  machine-desc
;
