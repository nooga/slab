( delay2.fy — stereo delay machine.

  The DSP lives in the kernels rig [kernels/07-effects/delay.fy]; this
  file declares the machine: entry words, sizes, the two host-allocated
  rings, controls, and the panel.  One true-stereo pass: MODE picks
  STEREO [two independent delays], PING [repeats bounce L/R] or WIDE
  [one ring, two taps]; CHAR picks DIGITAL, TAPE or BBD. )

include "../../kernels/07-effects/delay.fy"
include "../lib/manifest.fy"

: manifest
  "Delay" effect-block machine*
  "k-delay-tick"        render!
  "delay-prepare"       prepare!
  "delay-block-prepare" block-prepare!
  DelayState.size  state-size!
  DelayParams.size params-size!
  560.0 panel-w!
  stereo
  sidechain

  ( 3.1 s per ring: TIME tops out at 1.5 s, RATIO at 2:1, plus OFFSET
    and modulation headroom )
  "dline-l" DelayState.l DlChan.buf +  DelayState.l DlChan.buf-len +  3.1 buffer
  "dline-r" DelayState.r DlChan.buf +  DelayState.r DlChan.buf-len +  3.1 buffer

  "TIME" "TIME"  "delay-time" DelayParams.time-s   0.02  1.5    0.36   curve-exp knob
  ( SYNC off → TIME knob in seconds; on → 60/bpm * DIV.  DIV option values
    are beat multipliers, quarter-note = 1.0. )
  "TIME" "SYNC" "delay-sync" DelayParams.sync 0.0 switch
    "FREE" 0.0 opt  "SYNC" 1.0 opt
  "TIME" "DIV"  "delay-div"  DelayParams.div  2.0 switch
    "1/16" 0.25 opt  "1/8T" 0.33333 opt  "1/8" 0.5 opt  "1/8." 0.75 opt
    "1/4" 1.0 opt  "1/4." 1.5 opt  "1/2" 2.0 opt  as-display
  "TIME" "R:L" "delay-ratio" DelayParams.ratio 0.0 switch
    "1:1" 1.0 opt  "3:4" 0.75 opt  "2:3" 0.66667 opt  "1:2" 0.5 opt
    "4:3" 1.33333 opt  "3:2" 1.5 opt  "2:1" 2.0 opt  as-display
  "TIME" "OFFSET" "delay-offset" DelayParams.offset-s -0.02 0.02 0.0 curve-lin knob
  "TIME" 3 strip

  "FEEDBACK" "FB"     "delay-fb"     DelayParams.feedback  0.0   1.1    0.45   curve-pow knob
  "FEEDBACK" "LO CUT" "delay-lowcut" DelayParams.lowcut-hz 20.0  2000.0 20.0   curve-exp knob
  "FEEDBACK" "HI CUT" "delay-damp"   DelayParams.damp-hz   500.0 16000.0 5500.0 curve-exp knob
  "FEEDBACK" "DRIVE"  "delay-drive"  DelayParams.drive     0.0   1.0    0.0    curve-lin knob
  "FEEDBACK" 4 strip

  "CHAR" "MODE" "delay-mode" DelayParams.mode 0.0 switch
    "STEREO" 0.0 opt  "PING" 1.0 opt  "WIDE" 2.0 opt  as-vradio
  "CHAR" "CHAR" "delay-char" DelayParams.char 0.0 switch
    "DIGITAL" 0.0 opt  "TAPE" 1.0 opt  "BBD" 2.0 opt  as-vradio
  "CHAR" "MOD"  "delay-mod"  DelayParams.mod   0.0 1.0 0.0 curve-pow knob
  "CHAR" "RATE" "delay-rate" DelayParams.rate  0.1 6.0 0.8 curve-exp knob
  "CHAR" 4 strip

  "OUT" "DUCK"   "delay-duck"   DelayParams.duck   0.0 1.0 0.0 curve-lin knob
  "OUT" "WIDTH"  "delay-width"  DelayParams.width  0.0 1.5 1.0 curve-lin knob
  "OUT" "MIX"    "delay-mix"    DelayParams.mix    0.0 1.0 0.35 curve-pow knob
  "OUT" "FREEZE" "delay-freeze" DelayParams.freeze 0.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt  as-button
  "OUT" 4 strip

  "TAPS" "delay" taps-display

  ( the tap display over the time controls; feedback, character and
    output in a row under them )
  1.0 row
    1.6 cell  "TAPS" 1.0 item
    1.0 cell  "TIME" 1.0 item
  1.0 row
    1.0 cell  "FEEDBACK" 1.0 item
    1.0 cell  "CHAR" 1.0 item
    1.0 cell  "OUT" 1.0 item

  machine-desc
;
