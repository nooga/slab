( profit5.fy - Consequential Circuits Profit-5: a Prophet-5 style 2-VCO
  poly, 8 voices, with an Oberheim SEM filter behind the FILTER switch.

  The voice is kernels/06-voices/profit5.fy.  POLY-MOD [filter env and
  OSC B to FREQ A, PW A, FILTER] is the instrument: env -> FREQ A with
  SYNC is the sync sweep, OSC B -> FREQ A the bells.  WHEEL-MOD is the
  LFO/noise with its AMOUNT knob standing in for the mod wheel.  HEAT and
  FEEDBACK go past the original, toward filth. )

include "../../kernels/06-voices/profit5.fy"
include "../lib/manifest.fy"

: manifest
  "Profit-5" voice-sample machine*
  "k-p5-voice"       render!
  "p5-note-on"       note-on!
  "p5-note-expr"     note-expr!
  "p5-note-off"      note-off!
  "p5-block-prepare" block-prepare!
  8 voices!
  P5State.size  state-size!
  P5Params.size params-size!
  780.0 panel-w!

  "POLY-MOD" "F ENV" "p5-pm-fenv" P5Params.pm-fenv 0.0 1.0 0.0 curve-pow knob
  "POLY-MOD" "OSC B" "p5-pm-oscb" P5Params.pm-oscb 0.0 1.0 0.0 curve-pow knob
  "POLY-MOD" "FREQ A" "p5-pm-dfa" P5Params.pm-dfa 0 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "POLY-MOD" "PW A"   "p5-pm-dpw" P5Params.pm-dpw 0 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "POLY-MOD" "FILT"   "p5-pm-dfl" P5Params.pm-dfl 0 switch  "OFF" 0.0 opt  "ON" 1.0 opt

  "OSC A" "FREQ"  "p5-freq-a" P5Params.freq-a -24.0 24.0 0.0 int-step
  "OSC A" "SAW"   "p5-saw-a"  P5Params.saw-a 1 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "OSC A" "PULSE" "p5-pul-a"  P5Params.pul-a 0 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "OSC A" "PW"    "p5-pw-a"   P5Params.pw-a 0.05 0.95 0.5 curve-lin knob
  "OSC A" "SYNC"  "p5-sync"   P5Params.sync 0 switch  "OFF" 0.0 opt  "ON" 1.0 opt

  "OSC B" "FREQ"  "p5-freq-b" P5Params.freq-b -24.0 24.0 0.0 int-step
  "OSC B" "FINE"  "p5-fine-b" P5Params.fine-b -1.0 1.0 0.08 curve-lin knob
  "OSC B" "PW"    "p5-pw-b"   P5Params.pw-b 0.05 0.95 0.5 curve-lin knob
  "OSC B" "SAW"   "p5-saw-b"  P5Params.saw-b 1 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "OSC B" "TRI"   "p5-tri-b"  P5Params.tri-b 0 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "OSC B" "PULSE" "p5-pul-b"  P5Params.pul-b 0 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "OSC B" "LO"    "p5-lo-b"   P5Params.lo-b 0 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "OSC B" "KBD"   "p5-kbd-b"  P5Params.kbd-b 1 switch  "OFF" 0.0 opt  "ON" 1.0 opt

  "WHEEL-MOD" "RATE"  "p5-lfo-rate" P5Params.lfo-rate 0.04 20.0 5.0 curve-exp knob
  "WHEEL-MOD" "WAVE"  "p5-lfo-wave" P5Params.lfo-wave 1 switch
    "SAW" 0.0 opt  "TRI" 1.0 opt  "SQR" 2.0 opt  as-list
  "WHEEL-MOD" "MIX"   "p5-wm-mix" P5Params.wm-mix 0.0 1.0 0.0 curve-lin knob
  "WHEEL-MOD" "AMOUNT" "p5-wm-amt" P5Params.wm-amt 0.0 1.0 0.0 curve-pow knob
  "WHEEL-MOD" "FREQ A" "p5-wm-dfa" P5Params.wm-dfa 1 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "WHEEL-MOD" "FREQ B" "p5-wm-dfb" P5Params.wm-dfb 1 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "WHEEL-MOD" "PW A"   "p5-wm-dpa" P5Params.wm-dpa 0 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "WHEEL-MOD" "PW B"   "p5-wm-dpb" P5Params.wm-dpb 0 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "WHEEL-MOD" "FILT"   "p5-wm-dfl" P5Params.wm-dfl 0 switch  "OFF" 0.0 opt  "ON" 1.0 opt

  "MIXER" "OSC A" "p5-lvl-a" P5Params.lvl-a 0.0 1.0 1.0 curve-pow knob
  "MIXER" "OSC B" "p5-lvl-b" P5Params.lvl-b 0.0 1.0 0.8 curve-pow knob
  "MIXER" "NOISE" "p5-lvl-n" P5Params.lvl-n 0.0 1.0 0.0 curve-pow knob

  "FILTER" "TYPE"   "p5-ftype"  P5Params.ftype 0 switch
    "P5" 0.0 opt  "OB" 1.0 opt  "OB BP" 2.0 opt  as-list span-rows
  "FILTER" "CUTOFF" "p5-cutoff" P5Params.cutoff 20.0 18000.0 1600.0 curve-exp knob
  "FILTER" "RES"    "p5-res"    P5Params.res 0.0 1.1 0.15 curve-lin knob
  "FILTER" "ENV"    "p5-env"    P5Params.env-amt 0.0 1.0 0.35 curve-lin knob
  "FILTER" "KBD"    "p5-kbd"    P5Params.kbd 0.0 1.0 0.5 curve-lin knob
  "FILTER" "DRIVE"  "p5-drive"  P5Params.drive 0.0 1.0 0.35 curve-lin knob
  "FILTER" "MODE"   "p5-mode"   P5Params.mode 0.0 1.0 0.0 curve-lin knob

  "F ENV" "ATK" "p5-f-atk" P5Params.f-atk 0.001 10.0 0.002 curve-exp knob
  "F ENV" "DEC" "p5-f-dec" P5Params.f-dec 0.005 12.0 0.4 curve-exp knob
  "F ENV" "SUS" "p5-f-sus" P5Params.f-sus 0.0 1.0 0.3 curve-lin knob
  "F ENV" "REL" "p5-f-rel" P5Params.f-rel 0.005 12.0 0.35 curve-exp knob

  "A ENV" "ATK" "p5-a-atk" P5Params.a-atk 0.001 10.0 0.002 curve-exp knob
  "A ENV" "DEC" "p5-a-dec" P5Params.a-dec 0.005 12.0 0.6 curve-exp knob
  "A ENV" "SUS" "p5-a-sus" P5Params.a-sus 0.0 1.0 0.8 curve-lin knob
  "A ENV" "REL" "p5-a-rel" P5Params.a-rel 0.005 12.0 0.35 curve-exp knob

  "OUT" "GLIDE"    "p5-glide"   P5Params.glide 0.0 5.0 0.0 curve-pow knob
  "OUT" "VEL"      "p5-vel"     P5Params.vel-amt 0.0 1.0 0.3 curve-lin knob
  "OUT" "HEAT"     "p5-heat"    P5Params.heat-amt 0.0 1.0 0.0 curve-lin knob
  "OUT" "FEEDBACK" "p5-fbk"     P5Params.fbk 0.0 1.0 0.0 curve-lin knob
  "OUT" "AGE"      "p5-age"     P5Params.age-amt 0.0 1.0 0.4 curve-lin knob
  "OUT" "LEVEL"    "p5-level"   P5Params.level 0.0 1.0 0.3 curve-pow knob

  "POLY-MOD" 2 strip
  "OSC A" 3 strip
  "OSC B" 4 strip
  "WHEEL-MOD" 4 strip
  "MIXER" 1 strip
  "FILTER" 3 strip
  "F ENV" 4 strip
  "A ENV" 4 strip
  "OUT" 3 strip

  "ENVELOPES" "F ENV,A ENV" adsr-display

  ( The Prophet's face in two rows: modulation and oscillators over the
    mixer, filter, envelopes and output. )
  1.0 row
    1.0 cell  "POLY-MOD" 1.0 item
    1.0 cell  "OSC A" 1.0 item
    1.0 cell  "OSC B" 1.0 item
    1.0 cell  "WHEEL-MOD" 1.0 item
  1.0 row
    1.0 cell  "MIXER" 1.0 item
    1.0 cell  "FILTER" 1.0 item
    1.0 cell  "F ENV" 0.0 item  "A ENV" 0.0 item  "ENVELOPES" 1.0 item
    1.0 cell  "OUT" 1.0 item

  machine-desc
;
