( grand.fy - Hammerwork Grand: a modal physical-model piano [docs/41].

  The voice is kernels/06-voices/piano.fy: per key, up to three unison
  strings as banks of stiff-string modes, a felt hammer solved as an
  implicit contact, and a 12-mode soundboard the strings drive through a
  moving bridge.  Stereo comes from two microphone points over the
  board.  PEDAL lifts the dampers on held and released notes alike. )

include "../../kernels/06-voices/piano.fy"
include "../lib/manifest.fy"

: manifest
  "Hammerwork Grand" voice-sample machine*
  "k-piano-voice"       render!
  "piano-note-on"       note-on!
  "piano-note-off"      note-off!
  "piano-block-prepare" block-prepare!
  "piano-control" 32    control!
  16 voices!
  stereo
  PianoState.size  state-size!
  PianoParams.size params-size!
  560.0 panel-w!

  "HAMMER" "HARD"   "gp-hard"   PianoParams.hard   -1.0 1.0 -0.6 curve-lin knob
  "HAMMER" "FELT"   "gp-felt"   PianoParams.felt   0.0 1.0 0.35 curve-lin knob
  "HAMMER" "STRIKE" "gp-strike" PianoParams.strike -1.0 1.0 0.0 curve-lin knob
  "HAMMER" 3 strip

  "STRING" "DECAY"  "gp-decay"  PianoParams.decay    0.25 4.0 1.5 curve-exp knob
  "STRING" "HF DEC" "gp-hfdec"  PianoParams.hf-decay 0.2 8.0 3.0 curve-exp knob
  "STRING" "STIFF"  "gp-stiff"  PianoParams.stiff    0.0 3.0 1.0 curve-lin knob
  "STRING" "UNISON" "gp-unison" PianoParams.unison   0.0 6.0 1.2 curve-lin knob
  "STRING" 2 strip

  "BOARD" "COUPLE" "gp-board" PianoParams.board 0.1 2.0 1.0 curve-exp knob
  "BOARD" "WIDTH"  "gp-width" PianoParams.width 0.0 1.0 0.7 curve-lin knob
  "BOARD" 2 strip

  "DAMPER" "RELEASE" "gp-release" PianoParams.release 0.05 2.0 0.25 curve-exp knob
  "DAMPER" "PEDAL"   "gp-pedal"   PianoParams.pedal   0.0 1.0 0.0 curve-lin knob
  "DAMPER" "LEVEL"   "gp-level"   PianoParams.level   0.0 1.0 0.7 curve-pow knob
  "DAMPER" 3 strip
  1.0 row
    1.0 cell  "HAMMER" 1.0 item
    1.0 cell  "STRING" 1.0 item
    1.0 cell  "BOARD" 1.0 item
    1.0 cell  "DAMPER" 1.0 item

  machine-desc
;
