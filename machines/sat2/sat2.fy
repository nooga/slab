( sat2.fy - multi-mode coloring saturator machine.

  DSP in the kernels rig [kernels/07-effects/saturator.fy]; this file
  declares the machine.  The host runs the render word once per channel
  against per-channel state (independent DC-block + tone state per L/R),
  shares one params block, and runs sat-block-prepare each block to derive
  the gains, tone coefficient, and mode-dependent shaper constants.

  From bus glue [tape, transformer] to sulfur [diode, fuzz], the triode
  [valve] and shred [rail, fold], 4x oversampled.  Each mode has its own
  filtering around the curve, scaled by COLOR; SAG lets the level move
  the operating point; parallel MIX for glue. )

include "../../kernels/07-effects/saturator.fy"
include "../lib/manifest.fy"

: manifest
  "Saturator" effect-block machine*
  "k-sat-tick"        render!
  "sat-block-prepare" block-prepare!
  SatState.size  state-size!
  SatParams.size params-size!
  SatParams.lat latency!
  300.0 panel-w!

  "STAGE" "DRIVE" "sat-drive" SatParams.drive-db 0.0   48.0   6.0    curve-lin knob
  "STAGE" "MODE"  "sat-mode"  SatParams.mode 0.0 switch
    "TUBE" 0.0 opt  "TAPE" 1.0 opt  "XFMR" 2.0 opt  "DIODE" 3.0 opt
    "FUZZ" 4.0 opt  "VALVE" 5.0 opt  "RAIL" 6.0 opt  "FOLD" 7.0 opt  as-list span-rows
  "STAGE" "SAG"   "sat-sag"   SatParams.sag      0.0   1.0    0.0    curve-lin knob
  "VOICE" "COLOR" "sat-color" SatParams.color    0.0   1.0    1.0    curve-lin knob
  "VOICE" "TONE"  "sat-tone"  SatParams.tone-hz 800.0 18000.0 18000.0 curve-exp knob
  "OUT"   "MIX"   "sat-mix"   SatParams.mix      0.0   1.0    1.0    curve-pow knob
  "OUT"   "OUT"   "sat-out"   SatParams.out-db   -24.0 24.0   0.0    curve-lin knob
  "STAGE" 2 strip
  "VOICE" 1 strip
  "OUT" 1 strip

  ( the stage [its character beside DRIVE and SAG], its voicing, the output )
  1.0 row
    2.0 cell  "STAGE" 1.0 item
    1.0 cell  "VOICE" 1.0 item
    1.0 cell  "OUT" 1.0 item

  machine-desc
;
