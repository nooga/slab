( oct2.fy - Octaver: an analog-style octave divider and an Octavia
  [docs/43 §Octaver].

  One and two octaves down from a comparator and two flip-flops, each sub
  through its own resonant lowpass; GLITCH pushes it into chatter; UP is
  the rectified octave up into a fuzz.  Mono sources, single notes: chords
  glitch, as the pedals do.  The DSP is kernels/07-effects/octaver.fy. )

include "../../kernels/07-effects/octaver.fy"
include "../lib/manifest.fy"

: manifest
  "Octaver" effect-block machine*
  "k-octaver-tick" render!  "octaver-block-prepare" block-prepare!
  OctState.size state-size!  OctParams.size params-size!
  560.0 panel-w!

  "TRACK" "TRACK" "oct-track" OctParams.track-hz 150.0 2000.0 600.0 curve-exp knob
  "TRACK" "GLITCH" "oct-glitch" OctParams.glitch 0.0 1.0 0.0 curve-lin knob
  "TRACK" "THRESH" "oct-thresh" OctParams.thresh-db -70.0 -20.0 -50.0 curve-lin knob
  "TRACK" "MODE" "oct-mode" OctParams.mode 1.0 switch
    "SQUARE" 0.0 opt "FLIP" 1.0 opt as-radio
  "SUB" "OCT 1" "oct-oct1" OctParams.oct1 0.0 1.0 0.8 curve-pow knob
  "SUB" "CUT 1" "oct-cut1" OctParams.cut1 60.0 3000.0 700.0 curve-exp knob
  "SUB" "RES 1" "oct-res1" OctParams.res1 0.0 1.0 0.2 curve-lin knob
  "SUB" "OCT 2" "oct-oct2" OctParams.oct2 0.0 1.0 0.0 curve-pow knob
  "SUB" "CUT 2" "oct-cut2" OctParams.cut2 40.0 2000.0 350.0 curve-exp knob
  "SUB" "RES 2" "oct-res2" OctParams.res2 0.0 1.0 0.2 curve-lin knob
  "UP" "UP" "oct-up" OctParams.up 0.0 1.0 0.0 curve-pow knob
  "UP" "FUZZ" "oct-fuzz" OctParams.fuzz 0.0 1.0 0.5 curve-lin knob
  "OUT" "DIRECT" "oct-direct" OctParams.direct 0.0 1.0 1.0 curve-pow knob
  "OUT" "LEVEL" "oct-out" OctParams.out-db -24.0 12.0 0.0 curve-lin knob
  "TRACK" 2 strip
  "SUB" 3 strip
  "UP" 1 strip
  "OUT" 1 strip
  1.0 row
    1.0 cell "TRACK" 1.0 item
    1.5 cell "SUB" 1.0 item
    0.5 cell "UP" 1.0 item
    0.5 cell "OUT" 1.0 item
  machine-desc
;
