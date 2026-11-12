( echo2.fy - Tape Echo: a loop of tape past four playback heads, in the
  manner of the drum and tape echoes of the 1960s and 70s.  Short loops
  are a multi-head echo, SWELL smears the heads into a wash, long loops
  with REPEAT near 1 are sound on sound, FREEZE holds what is on the
  tape.  SPEED and LENGTH bend the pitch while the motor catches up; the
  tape hisses, wobbles and pops as much as its knobs say.  The DSP is
  kernels/07-effects/tapeecho.fy. )

include "../../kernels/07-effects/tapeecho.fy"
include "../lib/manifest.fy"

: manifest
  "Tape Echo" effect-block machine*
  "k-tapeecho-tick"        render!
  "tapeecho-prepare"       prepare!
  "tapeecho-block-prepare" block-prepare!
  TeState.size state-size!  TeParams.size params-size!
  760.0 panel-w!
  stereo

  ( LENGTH 4 s at SPEED 0.5 is an 8 s loop )
  "loop-l" TeState.bl TeState.bl-len 8.2 buffer
  "loop-r" TeState.br TeState.br-len 8.2 buffer

  "LOOP" "LENGTH" "echo-length" TeParams.length 0.06 4.0 0.42 curve-exp knob
  "LOOP" "SPEED"  "echo-speed"  TeParams.speed 0.5 2.0 1.0 curve-exp knob
  "LOOP" "SYNC"   "echo-sync"   TeParams.sync 0.0 switch
    "FREE" 0.0 opt  "SYNC" 1.0 opt
  ( the whole loop, in beats; head 1 is a quarter of it )
  "LOOP" "DIV"    "echo-div"    TeParams.div 3.0 switch
    "1/8" 0.5 opt  "1/8." 0.75 opt  "1/4" 1.0 opt  "1/2" 2.0 opt
    "3/4" 3.0 opt  "1 BAR" 4.0 opt  "2 BAR" 8.0 opt  as-display
  "LOOP" 2 strip

  "HEADS" "1" "echo-h1" TeParams.h1 0.0 switch  "OFF" 0.0 opt "ON" 1.0 opt as-button
  "HEADS" "2" "echo-h2" TeParams.h2 0.0 switch  "OFF" 0.0 opt "ON" 1.0 opt as-button
  "HEADS" "3" "echo-h3" TeParams.h3 0.0 switch  "OFF" 0.0 opt "ON" 1.0 opt as-button
  "HEADS" "4" "echo-h4" TeParams.h4 1.0 switch  "OFF" 0.0 opt "ON" 1.0 opt as-button
  "HEADS" "MODE" "echo-mode" TeParams.mode 0.0 switch
    "ECHO" 0.0 opt  "SWELL" 1.0 opt
  "HEADS" "SPREAD" "echo-spread" TeParams.spread 0.0 1.0 0.5 curve-lin knob
  "HEADS" 2 strip

  "RECORD" "REPEAT" "echo-repeat" TeParams.repeat 0.0 1.1 0.45 curve-lin knob
  "RECORD" "TONE"   "echo-tone"   TeParams.tone 500.0 16000.0 4500.0 curve-exp knob
  "RECORD" "DRIVE"  "echo-drive"  TeParams.drive 0.0 1.0 0.25 curve-lin knob
  "RECORD" "FREEZE" "echo-freeze" TeParams.freeze 0.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt  as-button
  "RECORD" 2 strip

  "TAPE" "WOW"     "echo-wow"     TeParams.wow 0.0 1.0 0.3 curve-lin knob
  "TAPE" "FLUTTER" "echo-flutter" TeParams.flutter 0.0 1.0 0.3 curve-lin knob
  "TAPE" "HISS"    "echo-hiss"    TeParams.hiss 0.0 1.0 0.35 curve-lin knob
  "TAPE" "POPS"    "echo-pops"    TeParams.pops 0.0 1.0 0.25 curve-lin knob
  "TAPE" "WEAR"    "echo-wear"    TeParams.wear 0.0 1.0 0.15 curve-lin knob
  "TAPE" 3 strip

  "OUT" "MIX" "echo-mix" TeParams.mix 0.0 1.0 0.35 curve-pow knob
  "OUT" 1 strip

  1.0 row
    1.0 cell "LOOP" 1.0 item
    1.0 cell "HEADS" 1.0 item
    1.0 cell "RECORD" 1.0 item
    1.3 cell "TAPE" 1.0 item
    0.5 cell "OUT" 1.0 item
  machine-desc
;
