( concoction.fy - Concoction, a clean digital wavetable synth after Serum.

  The voice lives in kernels/06-voices/concoction.fy.  Two wavetable
  oscillators read the built-in bank [assets/bank.wav, the TABLE switch]
  or their own USER file: any Serum wavetable [2048-sample frames, the
  `clm ` chunk], loaded with LOAD on the WAVES page.  Nothing drifts and
  every note starts each oscillator at its PHASE, which is what makes a
  digital bass hit the same way every time.

  Pages: OSC [the sound: the oscillators over their wavetables, the
  filter's response, the scope], MOD [what moves it: the LFOs, the
  FILTER and MOD envelopes, the 8-slot matrix], WAVES [the USER tables].
  Both first pages carry the modulation dock: drag a source onto a knob
  with a ring, or onto a slot's SRC, to route it.  Every display follows
  the newest voice. )

include "../../kernels/06-voices/concoction.fy"
include "../lib/manifest.fy"

: cn-tables
  "BASIC" 0.0 opt  "PWM" 1.0 opt  "SYNC" 2.0 opt  "FM" 3.0 opt  "PD" 4.0 opt
  "DRIVE" 5.0 opt  "FOLD" 6.0 opt  "HARM" 7.0 opt  "RESO" 8.0 opt  "VOWEL" 9.0 opt
  "USER" 10.0 opt  as-display ;
: cn-warps
  "OFF" 0.0 opt  "SYNC" 1.0 opt  "PWM" 2.0 opt  "BEND" 3.0 opt  "FM" 4.0 opt  as-display ;
: cn-onoff  "OFF" 0.0 opt  "ON" 1.0 opt ;
: cn-shapes
  "SINE" 0.0 opt  "TRI" 1.0 opt  "SAW UP" 2.0 opt  "SAW DN" 3.0 opt  "SQUARE" 4.0 opt
  "S&H" 5.0 opt  as-display ;
: cn-syncs
  "HZ" 0.0 opt  "4 BAR" 16.0 opt  "2 BAR" 8.0 opt  "1 BAR" 4.0 opt  "1/2" 2.0 opt
  "1/4" 1.0 opt  "1/8" 0.5 opt  "1/16" 0.25 opt  "1/32" 0.125 opt
  "1/4D" 1.5 opt  "1/8D" 0.75 opt  "1/16D" 0.375 opt
  "1/4T" 0.6666666666666666 opt  "1/8T" 0.3333333333333333 opt  "1/16T" 0.16666666666666666 opt
  as-display ;
: cn-modes  "FREE" 0.0 opt  "RETRIG" 1.0 opt  "ENV" 2.0 opt  as-list ;
: cn-srcs
  "OFF" 0.0 opt  "ENV2" 1.0 opt  "ENV3" 2.0 opt  "LFO1" 3.0 opt  "LFO2" 4.0 opt
  "VEL" 5.0 opt  "NOTE" 6.0 opt  "PRESS" 7.0 opt  "SLIDE" 8.0 opt  "RAND" 9.0 opt
  as-display ;
: cn-dsts
  "OFF" 0.0 opt  "A POS" 1.0 opt  "B POS" 2.0 opt  "A WARP" 3.0 opt  "B WARP" 4.0 opt
  "A PITCH" 5.0 opt  "B PITCH" 6.0 opt  "PITCH" 7.0 opt  "A LVL" 8.0 opt  "B LVL" 9.0 opt
  "SUB LVL" 10.0 opt  "NOISE" 11.0 opt  "CUTOFF" 12.0 opt  "RES" 13.0 opt  "DRIVE" 14.0 opt
  "AMP" 15.0 opt  as-display ;

: manifest
  "Concoction" voice-sample machine*
  "k-concoction-voice"         render!
  "concoction-note-on"         note-on!
  "concoction-note-off"        note-off!
  "concoction-note-expr"       note-expr!
  "concoction-block-prepare"   block-prepare!
  "k-concoction-control" 32    control!
  8 voices!
  ConcoctionState.size  state-size!
  ConcoctionParams.size params-size!
  780.0 panel-w!

  "bank" ConcoctionParams.bank ConcoctionParams.bank-frames "assets/bank.wav" wavetable
  "wt-a" ConcoctionParams.wt-a ConcoctionParams.wt-a-frames "assets/kick.wav" wavetable
  "wt-b" ConcoctionParams.wt-b ConcoctionParams.wt-b-frames "assets/kick.wav" wavetable

  ( ── OSC A ── )
  "OSC A" "TABLE" "cn-a-table" ConcoctionParams.a-table 0 switch cn-tables
  "OSC A" "POS"   "cn-a-pos"   ConcoctionParams.a-pos   0.0 1.0 0.0 curve-lin knob
  "OSC A" "OCT"   "cn-a-oct"   ConcoctionParams.a-oct   -4.0 4.0 0.0 int-step
  "OSC A" "SEMI"  "cn-a-semi"  ConcoctionParams.a-semi  -12.0 12.0 0.0 int-step
  "OSC A" "FINE"  "cn-a-fine"  ConcoctionParams.a-fine  -100.0 100.0 0.0 curve-lin knob
  "OSC A" "LEVEL" "cn-a-level" ConcoctionParams.a-level 0.0 1.0 0.75 curve-pow knob
  "OSC A" "WARP"  "cn-a-warp"  ConcoctionParams.a-warp  0 switch cn-warps
  "OSC A" "AMT"   "cn-a-wamt"  ConcoctionParams.a-wamt  0.0 1.0 0.0 curve-lin knob
  "OSC A" "PHASE" "cn-a-phase" ConcoctionParams.a-phase 0.0 1.0 0.5 curve-lin knob
  "OSC A" "RAND"  "cn-a-rand"  ConcoctionParams.a-rand  0.0 1.0 0.0 curve-lin knob
  "OSC A" "FILT"  "cn-a-filt"  ConcoctionParams.a-filt  1 switch cn-onoff as-button

  ( ── OSC B ── )
  "OSC B" "ON"    "cn-b-on"    ConcoctionParams.b-on    0 switch cn-onoff as-button
  "OSC B" "TABLE" "cn-b-table" ConcoctionParams.b-table 0 switch cn-tables
  "OSC B" "POS"   "cn-b-pos"   ConcoctionParams.b-pos   0.0 1.0 0.0 curve-lin knob
  "OSC B" "OCT"   "cn-b-oct"   ConcoctionParams.b-oct   -4.0 4.0 0.0 int-step
  "OSC B" "SEMI"  "cn-b-semi"  ConcoctionParams.b-semi  -12.0 12.0 0.0 int-step
  "OSC B" "FINE"  "cn-b-fine"  ConcoctionParams.b-fine  -100.0 100.0 0.0 curve-lin knob
  "OSC B" "LEVEL" "cn-b-level" ConcoctionParams.b-level 0.0 1.0 0.75 curve-pow knob
  "OSC B" "WARP"  "cn-b-warp"  ConcoctionParams.b-warp  0 switch cn-warps
  "OSC B" "AMT"   "cn-b-wamt"  ConcoctionParams.b-wamt  0.0 1.0 0.0 curve-lin knob
  "OSC B" "PHASE" "cn-b-phase" ConcoctionParams.b-phase 0.0 1.0 0.5 curve-lin knob
  "OSC B" "RAND"  "cn-b-rand"  ConcoctionParams.b-rand  0.0 1.0 0.0 curve-lin knob
  "OSC B" "FILT"  "cn-b-filt"  ConcoctionParams.b-filt  1 switch cn-onoff as-button

  ( ── SUB, NOISE ── )
  "SUB" "ON"    "cn-sub-on"    ConcoctionParams.sub-on    0 switch cn-onoff as-button
  "SUB" "SHAPE" "cn-sub-shape" ConcoctionParams.sub-shape 0 switch
    "SINE" 0.0 opt  "TRI" 1.0 opt  "SAW" 2.0 opt  "SQUARE" 3.0 opt  as-list
  "SUB" "OCT"   "cn-sub-oct"   ConcoctionParams.sub-oct   -3.0 1.0 -1.0 int-step
  "SUB" "LEVEL" "cn-sub-level" ConcoctionParams.sub-level 0.0 1.0 0.75 curve-pow knob
  "SUB" "FILT"  "cn-sub-filt"  ConcoctionParams.sub-filt  0 switch cn-onoff as-button
  "NOISE" "LEVEL" "cn-n-level" ConcoctionParams.n-level 0.0 1.0 0.0 curve-pow knob
  "NOISE" "COLOR" "cn-n-color" ConcoctionParams.n-color -1.0 1.0 0.0 curve-lin knob
  "NOISE" "FILT"  "cn-n-filt"  ConcoctionParams.n-filt  1 switch cn-onoff as-button

  ( ── FILTER ── )
  "FILTER" "MODE"  "cn-f-mode"  ConcoctionParams.f-mode 1 switch
    "OFF" 0.0 opt  "LP24" 1.0 opt  "LP18" 2.0 opt  "LP12" 3.0 opt  "BP" 4.0 opt
    "HP12" 5.0 opt  "HP24" 6.0 opt  "NOTCH" 7.0 opt  as-display
  "FILTER" "CUTOFF" "cn-f-cut"  ConcoctionParams.f-cut   20.0 20000.0 20000.0 curve-exp knob
  "FILTER" "RES"    "cn-f-res"  ConcoctionParams.f-res   0.0 1.0 0.0 curve-lin knob
  "FILTER" "DRIVE"  "cn-f-drive" ConcoctionParams.f-drive 0.0 1.0 0.0 curve-lin knob
  "FILTER" "KEY"    "cn-f-key"  ConcoctionParams.f-key   0.0 1.0 0.0 curve-lin knob
  "FILTER" "ENV"    "cn-f-env"  ConcoctionParams.f-env   -1.0 1.0 0.0 curve-lin knob

  ( ── envelopes ── )
  "AMP" "ATK"  "cn-e1-a" ConcoctionParams.e1-a 0.0005 10.0 0.0005 curve-exp knob as-fader
  "AMP" "HOLD" "cn-e1-h" ConcoctionParams.e1-h 0.0 2.0 0.0 curve-pow knob as-fader
  "AMP" "DEC"  "cn-e1-d" ConcoctionParams.e1-d 0.001 20.0 1.0 curve-exp knob as-fader
  "AMP" "SUS"  "cn-e1-s" ConcoctionParams.e1-s 0.0 1.0 1.0 curve-lin knob as-fader
  "AMP" "REL"  "cn-e1-r" ConcoctionParams.e1-r 0.001 20.0 0.015 curve-exp knob as-fader
  "FILTER ENV" "ATK" "cn-e2-a" ConcoctionParams.e2-a 0.0005 10.0 0.0005 curve-exp knob as-fader
  "FILTER ENV" "DEC" "cn-e2-d" ConcoctionParams.e2-d 0.001 20.0 0.3 curve-exp knob as-fader
  "FILTER ENV" "SUS" "cn-e2-s" ConcoctionParams.e2-s 0.0 1.0 0.0 curve-lin knob as-fader
  "FILTER ENV" "REL" "cn-e2-r" ConcoctionParams.e2-r 0.001 20.0 0.1 curve-exp knob as-fader
  "MOD ENV" "ATK" "cn-e3-a" ConcoctionParams.e3-a 0.0005 10.0 0.0005 curve-exp knob as-fader
  "MOD ENV" "DEC" "cn-e3-d" ConcoctionParams.e3-d 0.001 20.0 0.5 curve-exp knob as-fader
  "MOD ENV" "SUS" "cn-e3-s" ConcoctionParams.e3-s 0.0 1.0 0.0 curve-lin knob as-fader
  "MOD ENV" "REL" "cn-e3-r" ConcoctionParams.e3-r 0.001 20.0 0.1 curve-exp knob as-fader

  ( ── pitch ── )
  "PITCH" "P.ENV" "cn-p-amt"  ConcoctionParams.p-amt  -48.0 48.0 0.0 curve-lin knob
  "PITCH" "TIME"  "cn-p-time" ConcoctionParams.p-time 0.001 2.0 0.05 curve-exp knob
  "PITCH" "TO"    "cn-p-dest" ConcoctionParams.p-dest 0 switch  "ALL" 0.0 opt  "A+B" 1.0 opt  as-list
  "PITCH" "GLIDE" "cn-glide"  ConcoctionParams.glide  0.0 2.0 0.0 curve-pow knob
  "PITCH" "MODE"  "cn-g-mode" ConcoctionParams.g-mode 1 switch  "ALWAYS" 0.0 opt  "LEGATO" 1.0 opt  as-list

  ( ── out ── )
  "OUT" "VEL"   "cn-vel"   ConcoctionParams.vel   0.0 1.0 0.3 curve-lin knob
  "OUT" "LEVEL" "cn-level" ConcoctionParams.level 0.0 1.0 0.7 curve-pow knob

  ( ── LFOs ── )
  "LFO 1" "SHAPE" "cn-l1-shape" ConcoctionParams.l1-shape 0 switch cn-shapes
  "LFO 1" "RATE"  "cn-l1-rate"  ConcoctionParams.l1-rate 0.01 40.0 2.0 curve-exp knob
  "LFO 1" "SYNC"  "cn-l1-sync"  ConcoctionParams.l1-sync 0 switch cn-syncs
  "LFO 1" "MODE"  "cn-l1-mode"  ConcoctionParams.l1-mode 1 switch cn-modes
  "LFO 1" "UNI"   "cn-l1-uni"   ConcoctionParams.l1-uni 0 switch cn-onoff as-button
  "LFO 2" "SHAPE" "cn-l2-shape" ConcoctionParams.l2-shape 0 switch cn-shapes
  "LFO 2" "RATE"  "cn-l2-rate"  ConcoctionParams.l2-rate 0.01 40.0 2.0 curve-exp knob
  "LFO 2" "SYNC"  "cn-l2-sync"  ConcoctionParams.l2-sync 0 switch cn-syncs
  "LFO 2" "MODE"  "cn-l2-mode"  ConcoctionParams.l2-mode 1 switch cn-modes
  "LFO 2" "UNI"   "cn-l2-uni"   ConcoctionParams.l2-uni 0 switch cn-onoff as-button

  ( ── matrix: SRC, DEST, AMT per slot ── )
  "SLOT 1" "SRC" "cn-m1-src" ConcoctionParams.m-src  0 + 0 switch cn-srcs
  "SLOT 1" "DEST" "cn-m1-dst" ConcoctionParams.m-dst 0 + 0 switch cn-dsts
  "SLOT 1" "AMT" "cn-m1-amt" ConcoctionParams.m-amt  0 + -1.0 1.0 0.0 curve-lin knob
  "SLOT 2" "SRC" "cn-m2-src" ConcoctionParams.m-src  8 + 0 switch cn-srcs
  "SLOT 2" "DEST" "cn-m2-dst" ConcoctionParams.m-dst 8 + 0 switch cn-dsts
  "SLOT 2" "AMT" "cn-m2-amt" ConcoctionParams.m-amt  8 + -1.0 1.0 0.0 curve-lin knob
  "SLOT 3" "SRC" "cn-m3-src" ConcoctionParams.m-src  16 + 0 switch cn-srcs
  "SLOT 3" "DEST" "cn-m3-dst" ConcoctionParams.m-dst 16 + 0 switch cn-dsts
  "SLOT 3" "AMT" "cn-m3-amt" ConcoctionParams.m-amt  16 + -1.0 1.0 0.0 curve-lin knob
  "SLOT 4" "SRC" "cn-m4-src" ConcoctionParams.m-src  24 + 0 switch cn-srcs
  "SLOT 4" "DEST" "cn-m4-dst" ConcoctionParams.m-dst 24 + 0 switch cn-dsts
  "SLOT 4" "AMT" "cn-m4-amt" ConcoctionParams.m-amt  24 + -1.0 1.0 0.0 curve-lin knob
  "SLOT 5" "SRC" "cn-m5-src" ConcoctionParams.m-src  32 + 0 switch cn-srcs
  "SLOT 5" "DEST" "cn-m5-dst" ConcoctionParams.m-dst 32 + 0 switch cn-dsts
  "SLOT 5" "AMT" "cn-m5-amt" ConcoctionParams.m-amt  32 + -1.0 1.0 0.0 curve-lin knob
  "SLOT 6" "SRC" "cn-m6-src" ConcoctionParams.m-src  40 + 0 switch cn-srcs
  "SLOT 6" "DEST" "cn-m6-dst" ConcoctionParams.m-dst 40 + 0 switch cn-dsts
  "SLOT 6" "AMT" "cn-m6-amt" ConcoctionParams.m-amt  40 + -1.0 1.0 0.0 curve-lin knob
  "SLOT 7" "SRC" "cn-m7-src" ConcoctionParams.m-src  48 + 0 switch cn-srcs
  "SLOT 7" "DEST" "cn-m7-dst" ConcoctionParams.m-dst 48 + 0 switch cn-dsts
  "SLOT 7" "AMT" "cn-m7-amt" ConcoctionParams.m-amt  48 + -1.0 1.0 0.0 curve-lin knob
  "SLOT 8" "SRC" "cn-m8-src" ConcoctionParams.m-src  56 + 0 switch cn-srcs
  "SLOT 8" "DEST" "cn-m8-dst" ConcoctionParams.m-dst 56 + 0 switch cn-dsts
  "SLOT 8" "AMT" "cn-m8-amt" ConcoctionParams.m-amt  56 + -1.0 1.0 0.0 curve-lin knob

  ( ── strips ── )
  "OSC A" 6 strip  "OSC B" 6 strip
  "SUB" 5 strip  "NOISE" 3 strip  "FILTER" 6 strip
  "AMP" 5 strip  "FILTER ENV" 4 strip  "PITCH" 5 strip  "OUT" 2 strip
  "LFO 1" 5 strip  "LFO 2" 5 strip  "MOD ENV" 4 strip
  "SLOT 1" 3 strip  "SLOT 2" 3 strip  "SLOT 3" 3 strip  "SLOT 4" 3 strip
  "SLOT 5" 3 strip  "SLOT 6" 3 strip  "SLOT 7" 3 strip  "SLOT 8" 3 strip

  ( ── modulation: the dock's sources, the knobs they reach [docs/15 §Modulation] ── )
  "LFO1" 3 ConcoctionState.l1-v 1 mod-source
  "LFO2" 4 ConcoctionState.l2-v 1 mod-source
  "ENV2" 1 ConcoctionState.e2 EnvD.level + 0 mod-source
  "ENV3" 2 ConcoctionState.e3 EnvD.level + 0 mod-source
  "VEL"  5 ConcoctionState.velo 0 mod-source
  "NOTE" 6 ConcoctionState.note 1 mod-source
  "RAND" 9 ConcoctionState.rnd 1 mod-source
  "cn-a-pos"     1 ConcoctionState.a-pos  mod-dest
  "cn-b-pos"     2 ConcoctionState.b-pos  mod-dest
  "cn-a-wamt"    3 ConcoctionState.a-w    mod-dest
  "cn-b-wamt"    4 ConcoctionState.b-w    mod-dest
  "cn-a-level"   8 ConcoctionState.a-lv   mod-dest
  "cn-b-level"   9 ConcoctionState.b-lv   mod-dest
  "cn-sub-level" 10 ConcoctionState.s-lv  mod-dest
  "cn-n-level"   11 ConcoctionState.n-lv  mod-dest
  "cn-f-cut"     12 ConcoctionState.cut-hz mod-dest
  "cn-f-res"     13 ConcoctionState.res-v mod-dest
  "cn-f-drive"   14 ConcoctionState.drv-v mod-dest
  "cn-level"     15 ConcoctionState.amp-v mod-dest
  "cn-m" 8 mod-matrix

  ( ── displays: the newest voice drives them ── )
  "MOD DOCK" mod-dock
  "OSC A VIEW" "cn-a,bank,wt-a" ConcoctionState.a-pos ConcoctionState.a-w 16 wavetable-display
  "OSC B VIEW" "cn-b,bank,wt-b" ConcoctionState.b-pos ConcoctionState.b-w 16 wavetable-display
  "FILTER VIEW" "cn-f" ConcoctionState.cut-hz ConcoctionState.res-v filter-display
  "LFO 1 VIEW" "cn-l1" ConcoctionState.l1-ph ConcoctionState.l1-v lfo-display
  "LFO 2 VIEW" "cn-l2" ConcoctionState.l2-ph ConcoctionState.l2-v lfo-display
  "AMP ADSR" "AMP" ConcoctionState.e1 EnvD.level + ConcoctionState.e1 EnvD.stage + env-display
  "FILTER ADSR" "FILTER ENV" ConcoctionState.e2 EnvD.level + ConcoctionState.e2 EnvD.stage + env-display
  "MOD ADSR" "MOD ENV" ConcoctionState.e3 EnvD.level + ConcoctionState.e3 EnvD.stage + env-display
  "SCOPE" scope-display
  "USER A" "wt-a" waveform-display
  "USER B" "wt-b" waveform-display

  ( ── pages: OSC the sound, MOD what moves it ── )
  "OSC" page
    0.2 row  1.0 cell  "MOD DOCK" 1.0 item
    1.6 row  1.0 cell  "OSC A" 1.0 item  "OSC A VIEW" 1.6 item
             1.0 cell  "OSC B" 1.0 item  "OSC B VIEW" 1.6 item
             0.5 cell  "SUB" 1.0 item  "NOISE" 1.0 item
    1.0 row  0.8 cell  "FILTER" 1.0 item  "FILTER VIEW" 1.4 item
             0.8 cell  "AMP" 1.0 item  "AMP ADSR" 0.5 item
             0.6 cell  "PITCH" 1.0 item
             0.8 cell  "OUT" 1.0 item  "SCOPE" 1.4 item
  "MOD" page
    0.2 row  1.0 cell  "MOD DOCK" 1.0 item
    1.0 row  1.0 cell  "LFO 1" 1.0 item  "LFO 1 VIEW" 1.0 item
             1.0 cell  "LFO 2" 1.0 item  "LFO 2 VIEW" 1.0 item
             1.0 cell  "FILTER ENV" 1.0 item  "FILTER ADSR" 0.6 item
             1.0 cell  "MOD ENV" 1.0 item  "MOD ADSR" 0.6 item
    0.6 row  1.0 cell  "SLOT 1" 1.0 item  1.0 cell  "SLOT 2" 1.0 item  1.0 cell  "SLOT 3" 1.0 item  1.0 cell  "SLOT 4" 1.0 item
    0.6 row  1.0 cell  "SLOT 5" 1.0 item  1.0 cell  "SLOT 6" 1.0 item  1.0 cell  "SLOT 7" 1.0 item  1.0 cell  "SLOT 8" 1.0 item
  "WAVES" page
    1.0 row  1.0 cell  "USER A" 1.0 item
    1.0 row  1.0 cell  "USER B" 1.0 item

  machine-desc
;
