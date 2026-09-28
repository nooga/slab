( gate2.fy - stereo-linked noise gate machine.

  DSP in the kernels rig [kernels/07-effects/gate.fy]; this file declares
  the machine.  Like the compressor, the host feeds both channels one
  shared max-abs-stereo detector trace [io.det], so L and R gate
  identically and the stereo image stays put - usable on a drum bus.

  THRESH sets the open level, RANGE the attenuation when closed [0 = off],
  HOLD bridges short dips, ATK/REL the open/close speed.  Tightening drums,
  cleaning bleed, or - chained before a reverb send once routing lands -
  classic gated reverb. )

include "../../kernels/07-effects/gate.fy"
include "../lib/manifest.fy"

: manifest
  "Gate" effect-block machine*
  "k-gate-tick"        render!
  "gate-block-prepare" block-prepare!
  GateState.size  state-size!
  GateParams.size params-size!
  260.0 panel-w!
  sidechain


  "GATE" "THRESH" "gate-thresh" GateParams.thresh-db -60.0  0.0  -40.0 curve-lin knob
  "GATE" "RANGE"  "gate-range"  GateParams.range-db  -80.0  0.0  -60.0 curve-lin knob
  "GATE" "ATK"    "gate-atk"    GateParams.atk-s     0.0002 0.05 0.001 curve-exp knob
  "GATE" "HOLD"   "gate-hold"   GateParams.hold-s    0.0    0.5  0.05  curve-lin knob
  "GATE" "REL"    "gate-rel"    GateParams.rel-s     0.005  1.0  0.12  curve-exp knob
  "GATE" 5 strip

  machine-desc
;
