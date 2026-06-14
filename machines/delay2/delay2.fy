( delay2.fy — stereo digital delay machine.

  The DSP lives in the kernels rig [kernels/07-effects/delay.fy]; this
  file declares the machine: entry words, sizes, the host-allocated ring
  buffer request, controls, and the panel layout.  The host runs the
  render word once per channel against per-channel state, so L and R get
  independent rings and write heads. )

include "../../kernels/07-effects/delay.fy"
include "../lib/manifest.fy"

: manifest
  "Delay" effect-block machine*
  "k-delay-tick"        render!
  "delay-prepare"       prepare!
  "delay-block-prepare" block-prepare!
  DelayState.size  state-size!
  DelayParams.size params-size!
  150.0 panel-w!

  ( 1.6 s ring per channel; TIME tops out at 1.5 s with headroom )
  "dline" DelayState.buf DelayState.buf-len 1.6 buffer

  "DELAY" "TIME" "delay-time" DelayParams.time-s   0.02  1.5    0.36   curve-exp knob
  "DELAY" "FB"   "delay-fb"   DelayParams.feedback 0.0   0.92   0.45   curve-pow knob
  "DELAY" "DAMP" "delay-damp" DelayParams.damp-hz  500.0 16000.0 5500.0 curve-exp knob
  "DELAY" "MIX"  "delay-mix"  DelayParams.mix      0.0   1.0    0.35   curve-pow knob
  "DELAY" 2 strip

  machine-desc
;
