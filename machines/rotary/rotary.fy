( rotary.fy - Rotary Speaker: a valve amp into a treble horn and a bass
  drum that turn, heard by two microphones, in the manner of the
  rotating organ cabinets of the 1940s onward.

  SPEED is the performance control: automate it between SLOW and FAST
  and the horn follows in a second while the drum takes four or five.
  It is made for machines/organ and is as good on guitars, electric
  pianos and voices.  The DSP is kernels/07-effects/rotary.fy. )

include "../../kernels/07-effects/rotary.fy"
include "../lib/manifest.fy"

: manifest
  "Rotary Speaker" effect-block machine*
  "k-rotary-tick"         render!
  "rotary-block-prepare"  block-prepare!
  RoState.size state-size!  RoParams.size params-size!
  620.0 panel-w!
  stereo

  "horn" RoState.hb RoState.hb-len 0.05 buffer
  "drum" RoState.db RoState.db-len 0.05 buffer

  "MOTOR" "SPEED" "ro-speed" RoParams.speed 1.0 switch
    "STOP" 0.0 opt "SLOW" 1.0 opt "FAST" 2.0 opt as-list span-rows
  "MOTOR" "SLOW" "ro-slow" RoParams.slow 0.3 2.0 0.8 curve-exp knob
  "MOTOR" "FAST" "ro-fast" RoParams.fast 3.0 10.0 6.8 curve-exp knob
  "MOTOR" "INERTIA" "ro-inertia" RoParams.inertia 0.25 4.0 1.0 curve-exp knob
  "MOTOR" 2 strip

  "CABINET" "DRIVE" "ro-drive" RoParams.drive 0.0 1.0 0.15 curve-lin knob
  "CABINET" "BALANCE" "ro-balance" RoParams.balance 0.0 1.0 0.5 curve-lin knob
  "CABINET" "DEPTH" "ro-depth" RoParams.depth 0.0 1.0 0.7 curve-lin knob
  "CABINET" 2 strip

  "MICS" "MIC" "ro-mic" RoParams.mic 0.0 1.0 0.4 curve-lin knob
  "MICS" "SPREAD" "ro-spread" RoParams.spread 0.0 0.5 0.3 curve-lin knob
  "MICS" 1 strip

  "OUT" "MIX" "ro-mix" RoParams.mix 0.0 1.0 1.0 curve-pow knob
  "OUT" "LEVEL" "ro-out" RoParams.out -24.0 12.0 0.0 curve-lin knob
  "OUT" 1 strip

  1.0 row
    1.3 cell "MOTOR" 1.0 item
    1.0 cell "CABINET" 1.0 item
    0.6 cell "MICS" 1.0 item
    0.6 cell "OUT" 1.0 item
  machine-desc
;
