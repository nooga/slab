( bus2.fy - SSL-style glue compressor machine [docs/24 §bus2].

  Stepped like the hardware: three ratios, six attacks, four releases
  and AUTO, four sidechain high-passes - fewer choices, all of them
  useful.  The knee is fixed at 4 dB and the detector is PEAK.  AUTO is
  a program-dependent release: fast after single hits, slow after
  sustained squash.  COLOR adds the distortion that grows with the gain
  reduction; 0 is clean.  The DSP is kernels/07-effects/bus.fy. )

include "../../kernels/07-effects/bus.fy"
include "../lib/manifest.fy"

: manifest
  "Bus" effect-block machine*
  "k-bus-tick"        render!
  "bus-block-prepare" block-prepare!
  CompState.size BusState.size +   state-size!
  CompParams.size BusParams.size + params-size!
  300.0 panel-w!
  stereo
  sidechain

  "COMP" "THRESH" "bus-thresh" CompParams.thresh-db -36.0 0.0 -18.0 curve-lin knob
  "COMP" "RATIO"  "bus-ratio"  CompParams.ratio 1.0 switch
    "2" 2.0 opt  "4" 4.0 opt  "10" 10.0 opt
  "TIME" "ATK" "bus-atk" CompParams.atk-s 4.0 switch
    ".1" 0.0001 opt  ".3" 0.0003 opt  "1" 0.001 opt  "3" 0.003 opt  "10" 0.01 opt  "30" 0.03 opt
  "TIME" "REL" "bus-rel" CompParams.rel-s 4.0 switch
    ".1" 0.1 opt  ".3" 0.3 opt  ".6" 0.6 opt  "1.2" 1.2 opt  "AUTO" 0.0 opt
  "SC" "HPF" "bus-hpf" CompParams.hpf-hz 0.0 switch
    "OFF" 20.0 opt  "60" 60.0 opt  "90" 90.0 opt  "150" 150.0 opt  "250" 250.0 opt
  "OUT" "COLOR"  "bus-color"  CompParams.size BusParams.color + 0.0 1.0 0.0 curve-lin knob
  "OUT" "MAKEUP" "bus-makeup" CompParams.makeup-db 0.0 15.0 0.0 curve-lin knob
  "OUT" "MIX"    "bus-mix"    CompParams.mix 0.0 1.0 1.0 curve-pow knob
  CompParams.knee-db 4.0 const-f64
  CompParams.det 0.0 const-f64
  "COMP" 2 strip
  "TIME" 2 strip
  "SC" 1 strip
  "OUT" 3 strip
  "CURVE" "bus" CompState.size BusState.gr-db + CompState.lvl dyn-display

  1.0 row
    1.3 cell  "CURVE" 1.0 item
    1.0 cell  "COMP" 1.0 item
  1.0 row
    1.0 cell  "TIME" 1.0 item
    0.5 cell  "SC" 1.0 item
    1.5 cell  "OUT" 1.0 item

  machine-desc
;
