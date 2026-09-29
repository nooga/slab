( sat2.fy - multi-mode coloring saturator machine.

  DSP in the kernels rig [kernels/07-effects/saturator.fy]; this file
  declares the machine.  The host runs the render word once per channel
  against per-channel state (independent DC-block + tone state per L/R),
  shares one params block, and runs sat-block-prepare each block to derive
  the gains, tone coefficient, and mode-dependent shaper constants.

  From bus glue [tape, transformer] to sulfur [diode, fuzz], 4x
  oversampled; parallel MIX for glue. )

include "../../kernels/07-effects/saturator.fy"
include "../lib/manifest.fy"

: manifest
  "Saturator" effect-block machine*
  "k-sat-tick"        render!
  "sat-block-prepare" block-prepare!
  SatState.size  state-size!
  SatParams.size params-size!
  SatParams.lat latency!
  270.0 panel-w!

  "SAT" "DRIVE" "sat-drive" SatParams.drive-db 0.0   36.0   6.0    curve-lin knob
  "SAT" "MODE"  "sat-mode"  SatParams.mode 0.0 switch
    "TUBE" 0.0 opt  "TAPE" 1.0 opt  "XFMR" 2.0 opt  "DIODE" 3.0 opt  "FUZZ" 4.0 opt
  "SAT" "TONE"  "sat-tone"  SatParams.tone-hz 800.0 18000.0 18000.0 curve-exp knob
  "SAT" "MIX"   "sat-mix"   SatParams.mix      0.0   1.0    1.0    curve-pow knob
  "SAT" "OUT"   "sat-out"   SatParams.out-db   -24.0 24.0   0.0    curve-lin knob
  "SAT" 5 strip

  machine-desc
;
