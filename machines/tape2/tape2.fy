( tape2.fy - tape machine: a cassette deck [types I, II, IV] or a VCR's
  audio [linear track, Hi-Fi], new or worn out [docs/26].  WEAR moves
  everything a tired transport does at once; the knobs set the format's
  own amounts [WOW, FLUTTER at 0.25 and HISS at 0.5 are the format as
  specified].  The DSP is kernels/07-effects/tape.fy. )

include "../../kernels/07-effects/tape.fy"
include "../lib/manifest.fy"

: manifest
  "Tape" effect-block machine*
  "k-tape-tick"        render!
  "tape-seed"          prepare!
  "tape-derive"        derive!
  "tape-block-prepare" block-prepare!
  TapeState.size  state-size!
  TapeParams.size params-size!
  560.0 panel-w!
  stereo

  ( the transport's swing plus azimuth skew, with headroom for WEAR 1 )
  "wow-l" TapeState.wow WowState.bl +  TapeState.wow WowState.bl-len +  0.05 buffer
  "wow-r" TapeState.wow WowState.br +  TapeState.wow WowState.br-len +  0.05 buffer

  "TAPE" "MODE"  "tape-mode"  TapeParams.mode 0.0 switch
    "CASS I" 0.0 opt  "CASS II" 1.0 opt  "CASS IV" 2.0 opt
    "VHS LIN" 3.0 opt  "VHS HIFI" 4.0 opt  as-list span-rows
  "TAPE" "WEAR"  "tape-wear"  TapeParams.wear 0.0 1.0 0.2 curve-lin knob
  "TAPE" "NR"    "tape-nr"    TapeParams.nr 0.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt
  "REC"  "DRIVE" "tape-drive" TapeParams.drive-db -12.0 18.0 0.0 curve-lin knob
  "REC"  "BIAS"  "tape-bias"  TapeParams.bias 0.0 1.0 0.6 curve-lin knob
  "TRANSPORT" "WOW"     "tape-wow"     TapeParams.wow 0.0 1.0 0.25 curve-pow knob
  "TRANSPORT" "FLUTTER" "tape-flutter" TapeParams.flutter 0.0 1.0 0.25 curve-pow knob
  "TRANSPORT" "DROPS"   "tape-drops"   TapeParams.drops 0.0 1.0 0.0 curve-pow knob
  "NOISE" "HISS"  "tape-hiss"  TapeParams.hiss 0.0 1.0 0.5 curve-lin knob
  "NOISE" "HUM"   "tape-hum"   TapeParams.hum 0.0 1.0 0.0 curve-lin knob
  "NOISE" "MAINS" "tape-mains" TapeParams.mains 0.0 switch
    "50" 50.0 opt  "60" 60.0 opt
  "OUT"  "OUT"   "tape-out"   TapeParams.out-db -12.0 12.0 0.0 curve-lin knob
  "OUT"  "MIX"   "tape-mix"   TapeParams.mix 0.0 1.0 1.0 curve-pow knob
  "TAPE" 2 strip
  "REC" 1 strip
  "TRANSPORT" 1 strip
  "NOISE" 1 strip
  "OUT" 1 strip

  1.0 row
    1.6 cell  "TAPE" 1.0 item
    0.8 cell  "REC" 1.0 item
    0.8 cell  "TRANSPORT" 1.0 item
    0.8 cell  "NOISE" 1.0 item
    0.8 cell  "OUT" 1.0 item

  machine-desc
;
