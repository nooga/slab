( char2.fy - character compressor machine [docs/24 §Character modes].

  MODE picks a bundle: FET [2 dB knee, peak, REL as set, odd-leaning
  color], OPTO [12 dB knee, RMS, half back in 60 ms and the rest over
  REL, slower after long squash, light even color], VARI [24 dB knee -
  the ratio rises with level - peak, a slow branch that holds a floor,
  heavy even color], SMUSH [3 dB knee, peak, the attack faster the
  further over, auto makeup that brings the room up between hits - the
  SP-303 Vinyl Sim pump].  DRIVE scales the color, which grows with the
  gain reduction; 0 is clean.  LO-FI [ANALOG / 90s / 80s, with NOISE
  that pumps] and WOW work in every mode.  The DSP is
  kernels/07-effects/char.fy. )

include "../../kernels/07-effects/char.fy"
include "../lib/manifest.fy"

: manifest
  "Char" effect-block machine*
  "k-char-tick"        render!
  "char-seed"          prepare!
  "char-derive"        derive!
  "char-block-prepare" block-prepare!
  CompState.size CharState.size +   state-size!
  CompParams.size CharParams.size + params-size!
  460.0 panel-w!
  stereo
  sidechain

  ( WOW swings at most ~3 ms around its centre )
  "wow-l" CompState.size CharState.wow + WowState.bl +  CompState.size CharState.wow + WowState.bl-len +  0.02 buffer
  "wow-r" CompState.size CharState.wow + WowState.br +  CompState.size CharState.wow + WowState.br-len +  0.02 buffer

  "COMP" "MODE"   "char-mode"   CompParams.size CharParams.mode + 0.0 switch
    "FET" 0.0 opt  "OPTO" 1.0 opt  "VARI" 2.0 opt
    ( the plugin's defaults: a deep squash that breathes, LO-FI 50 %, WOW 15 % )
    "SMUSH" 3.0 opt  "char-thresh" -30.0 sets  "char-ratio" 20.0 sets  "char-atk" 0.0015 sets  "char-rel" 0.07 sets
      "char-lofi" 0.5 sets  "char-wow" 0.15 sets
  "COMP" "THRESH" "char-thresh" CompParams.thresh-db -40.0 0.0 -18.0 curve-lin knob
  "COMP" "RATIO"  "char-ratio"  CompParams.ratio 1.0 20.0 4.0 curve-pow knob
  "TIME" "ATK"    "char-atk"    CompParams.atk-s 0.00002 0.05 0.001 curve-exp knob
  "TIME" "REL"    "char-rel"    CompParams.rel-s 0.05 5.0 0.3 curve-exp knob
  "SC"   "HPF"    "char-hpf"    CompParams.hpf-hz 20.0 500.0 20.0 curve-exp knob
  "OUT"  "DRIVE"  "char-drive"  CompParams.size CharParams.drive + 0.0 1.0 0.3 curve-lin knob
  "OUT"  "MAKEUP" "char-makeup" CompParams.makeup-db 0.0 24.0 0.0 curve-lin knob
  "OUT"  "MIX"    "char-mix"    CompParams.mix 0.0 1.0 1.0 curve-pow knob
  "LO-FI" "TYPE"  "char-ltype"  CompParams.size CharParams.lofi + LofiParams.type + 0.0 switch
    "ANALOG" 0.0 opt  "90s" 1.0 opt  "80s" 2.0 opt
  "LO-FI" "LOFI"  "char-lofi"   CompParams.size CharParams.lofi + LofiParams.amount + 0.0 1.0 0.0 curve-lin knob
  "LO-FI" "NOISE" "char-noise"  CompParams.size CharParams.lofi + LofiParams.noise + 0.0 1.0 0.3 curve-lin knob
  "WOW"  "RPM"    "char-rpm"    CompParams.size CharParams.wow + WowParams.rate + 0.0 switch
    ( the record's turn, Hz )
    "33" 0.5555555555555556 opt  "45" 0.75 opt  "78" 1.3 opt
  "WOW"  "WOW"    "char-wow"    CompParams.size CharParams.wow + WowParams.depth + 0.0 1.0 0.0 curve-pow knob
  "COMP" 1 strip
  "TIME" 2 strip
  "SC" 1 strip
  "OUT" 3 strip
  "LO-FI" 1 strip
  "WOW" 1 strip
  "CURVE" "char" CompState.size CharState.gr-db + CompState.lvl CompState.size CharState.knee + dyn-display-knee

  1.0 row
    1.3 cell  "CURVE" 1.0 item
    0.75 cell  "COMP" 1.0 item
    0.75 cell  "LO-FI" 1.0 item
    0.6 cell  "WOW" 1.0 item
  1.0 row
    1.0 cell  "TIME" 1.0 item
    0.5 cell  "SC" 1.0 item
    1.5 cell  "OUT" 1.0 item

  machine-desc
;
