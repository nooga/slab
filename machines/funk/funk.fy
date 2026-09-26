( funk.fy — FUNK OVERLOAD machine.

  The DSP lives in the kernels rig [kernels/07-effects/funk.fy].  One
  big macro knob sweeps the whole effect from clean lowpass, through
  touch-wah and drive, into envelope-gated stutter.  The strip title
  "FUNK" sits above the hero knob labelled "OVERLOAD".  Per-channel
  effect; chain it after juno2 clav patches or across a drum bus. )

include "../../kernels/07-effects/funk.fy"
include "../lib/manifest.fy"

: manifest
  "Funk Overload" effect-block machine*
  "k-funk-tick"        render!
  "funk-block-prepare" block-prepare!
  FunkState.size  state-size!
  FunkParams.size params-size!
  250.0 panel-w!

  "FUNK" "OVERLOAD" "funk-macro" FunkParams.funk 0.0 1.0 0.35 curve-lin knob
  "TONE" "FREQ"  "funk-freq"  FunkParams.freq  150.0 2000.0 420.0 curve-exp knob
  "TONE" "SPEED" "funk-speed" FunkParams.speed 0.02  0.4    0.08  curve-exp knob
  "TONE" "MIX"   "funk-mix"   FunkParams.mix   0.0   1.0    1.0   curve-pow knob

  "FUNK" 1 strip
  "TONE" 3 strip
  1.0 row
    1.3 cell  "FUNK" 1.0 item
    1.0 cell  "TONE" 1.0 item

  machine-desc
;
