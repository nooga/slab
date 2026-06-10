( drum2.fy — synthesized drum machine, docs/16. Kick slot only for now;
  snare / clap / hats / tom land as further kernels/05-drums voices.

  DSP lives in the kernels rig [kernels/05-drums]; this file declares the
  machine: slot trigger map, controls, and the panel strip. note-pitch
  mode: the host passes raw MIDI pitch to note-on and the trigger words
  address slots by note number. )

include "../../kernels/05-drums/kick.fy"
include "../lib/manifest.fy"

( state params pitch velocity -- : route a note to a drum slot. Only the
  kick for now — any pitch fires it, so it is playable from any key. )
dsp2: drum2-note-on
  | state params pitch velocity |
  state params velocity kick-trigger
  drop2 drop2
;

: manifest
  "drum2" voice-sample machine*
  "k-kick-render" render!
  "kick-prepare"  prepare!
  "drum2-note-on" note-on!
  KickState.size  state-size!
  KickParams.size params-size!
  104.0 panel-w!
  note-pitch
  36 "KICK" note-label

  ( module label id offset min max default curve )
  "KICK" "TUNE"  "kick-tune"   KickParams.tune-hz      30.0 120.0 50.0 curve-exp knob
  "KICK" "SWEEP" "kick-sweep"  KickParams.sweep-amount 0.0 12.0 7.0 curve-lin knob
  "KICK" "BEND"  "kick-bend"   KickParams.sweep-time   0.01 0.3 0.055 curve-exp knob
  "KICK" "DEC"   "kick-decay"  KickParams.decay-s      0.05 2.0 0.42 curve-exp knob
  "KICK" "CLICK" "kick-click"  KickParams.click-level  0.0 1.0 0.35 curve-lin knob
  "KICK" "DRIVE" "kick-drive"  KickParams.drive        0.5 6.0 1.8 curve-lin knob
  "KICK" "LVL"   "kick-level"  KickParams.level        0.0 1.0 0.9 curve-lin knob

  "KICK" 1 strip
  machine-desc
;
