( zitherfx.fy - Magnet Zither FX: ten steel strings in a tuning, driven by
  the input through a coil and by two spinning discs of magnets.

  As an insert the strings that agree with the input answer it: a tuned
  sympathetic bank.  With a disc ON it sounds by itself, a drone whose
  partials come and go as SPIN sweeps the pass rate across the strings'
  modes.  machines/zither is the same strings as an instrument, plucked
  from the keys.  The DSP is kernels/07-effects/zither.fy. )

include "../../kernels/07-effects/zither.fy"
include "../lib/manifest.fy"

: manifest
  "Magnet Zither FX" effect-block machine*
  "k-zither-tick" render!  "zither-block-prepare" block-prepare!
  ZState.size state-size!  ZParams.size params-size!
  760.0 panel-w!  stereo
  ( a spinning disc sounds from silence )
  -1.0 tail!

  "STRINGS" "TUNING" "zi-tuning" ZParams.tuning 0.0 switch
    "OPEN D" 0.0 opt "MINOR" 1.0 opt "PENTA" 2.0 opt "5THS" 3.0 opt
    "LYDIAN" 4.0 opt "CLUSTER" 5.0 opt "HARM" 6.0 opt as-list span-rows
  "STRINGS" "ROOT" "zi-root" ZParams.root -12.0 12.0 0.0 curve-lin knob
  "STRINGS" "RING" "zi-ring" ZParams.ring 0.5 30.0 8.0 curve-exp knob
  "STRINGS" "TONE" "zi-tone" ZParams.tone 0.0 1.0 0.5 curve-lin knob
  "STRINGS" "COIL" "zi-coil" ZParams.coil 0.0 1.0 0.5 curve-lin knob
  "STRINGS" 3 strip

  "DISC A" "ON" "zi-a-on" ZParams.a-on 0.0 switch
    "OFF" 0.0 opt "ON" 1.0 opt as-button
  "DISC A" "SPIN" "zi-a-spin" ZParams.a-spin 4.0 400.0 55.0 curve-exp knob
  "DISC A" "HEIGHT" "zi-a-height" ZParams.a-height 0.0 1.0 0.3 curve-lin knob
  "DISC A" "ACROSS" "zi-a-across" ZParams.a-across 0.0 1.0 0.3 curve-lin knob
  "DISC A" "ALONG" "zi-a-along" ZParams.a-along 0.03 0.5 0.3 curve-lin knob
  "DISC A" 3 strip

  "DISC B" "ON" "zi-b-on" ZParams.b-on 0.0 switch
    "OFF" 0.0 opt "ON" 1.0 opt as-button
  "DISC B" "SPIN" "zi-b-spin" ZParams.b-spin 4.0 400.0 147.0 curve-exp knob
  "DISC B" "HEIGHT" "zi-b-height" ZParams.b-height 0.0 1.0 0.4 curve-lin knob
  "DISC B" "ACROSS" "zi-b-across" ZParams.b-across 0.0 1.0 0.75 curve-lin knob
  "DISC B" "ALONG" "zi-b-along" ZParams.b-along 0.03 0.5 0.15 curve-lin knob
  "DISC B" 3 strip

  "OUT" "MIX" "zi-mix" ZParams.mix 0.0 1.0 0.5 curve-lin knob
  "OUT" "LEVEL" "zi-out" ZParams.out -24.0 12.0 0.0 curve-lin knob
  "OUT" 1 strip

  1.0 row
    1.6 cell "STRINGS" 1.0 item
    1.2 cell "DISC A" 1.0 item
    1.2 cell "DISC B" 1.0 item
    0.5 cell "OUT" 1.0 item
  machine-desc
;
