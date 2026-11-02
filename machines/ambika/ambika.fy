( ambika.fy - Ambika: Mutable Instruments' six-voice hybrid polysynth, one voicecard
  and the whole synth in six voices.

  The voice is kernels/06-voices/ambika.fy and the study behind it
  docs/48-ambika.md.  Values are the Ambika's: parameters 0..127 [the mixer's 0..63],
  the matrix's amounts -63..63, so a patch reads as it does on the unit.  Firmware and
  table data: Emilie Gillet, GPL-3.0-or-later; the tables are packed in assets/tables.wav
  by tools/ambika/gen_tables.py. )

include "../../kernels/06-voices/ambika.fy"
include "../lib/manifest.fy"

: amb-onoff  "OFF" 0.0 opt  "ON" 1.0 opt  as-button ;

: amb-shapes  "NONE" 0.0 opt  "SAW" 1.0 opt  "SQUARE" 2.0 opt  "TRIANG" 3.0 opt  "SINE" 4.0 opt
    "ZSAW" 5.0 opt  "LPZSAW" 6.0 opt  "PKZSAW" 7.0 opt  "BPZSAW" 8.0 opt  "HPZSAW" 9.0 opt
    "LPZPLS" 10.0 opt  "PKZPLS" 11.0 opt  "BPZPLS" 12.0 opt  "HPZPLS" 13.0 opt  "ZTRI" 14.0 opt
    "PAD" 15.0 opt  "FM" 16.0 opt  "8BITS" 17.0 opt  "PWM" 18.0 opt  "NOISE" 19.0 opt
    "VOWEL" 20.0 opt  "MALE" 21.0 opt  "FEMALE" 22.0 opt  "CHOIR" 23.0 opt  "TAMPURA" 24.0 opt
    "BOWED" 25.0 opt  "CELLO" 26.0 opt  "VIBES" 27.0 opt  "SLAP" 28.0 opt  "EPIANO" 29.0 opt
    "ORGAN" 30.0 opt  "WAVES" 31.0 opt  "DIGITAL" 32.0 opt  "DRONE1" 33.0 opt  "DRONE2" 34.0 opt
    "METALLIC" 35.0 opt  "BELL" 36.0 opt  "WAVQNCE" 37.0 opt   as-display ;

: amb-subs  "SQ1" 0.0 opt  "TR1" 1.0 opt  "PL1" 2.0 opt  "SQ2" 3.0 opt  "TR2" 4.0 opt
    "PL2" 5.0 opt  "CLICK" 6.0 opt  "GLITCH" 7.0 opt  "BLOW" 8.0 opt  "METAL" 9.0 opt
    "POP" 10.0 opt   as-display ;

: amb-ops  "SUM" 0.0 opt  "SYNC" 1.0 opt  "RING" 2.0 opt  "XOR" 3.0 opt  "FOLD" 4.0 opt
    "BITS" 5.0 opt  as-list ;

: amb-lfow  "TRI" 0.0 opt  "SQR" 1.0 opt  "S&H" 2.0 opt  "RAMP" 3.0 opt  "WAV1" 4.0 opt
    "WAV2" 5.0 opt  "WAV3" 6.0 opt  "WAV4" 7.0 opt  "WAV5" 8.0 opt  "WAV6" 9.0 opt
    "WAV7" 10.0 opt  "WAV8" 11.0 opt  "WAV9" 12.0 opt  "WAV10" 13.0 opt  "WAV11" 14.0 opt
    "WAV12" 15.0 opt  "WAV13" 16.0 opt  "WAV14" 17.0 opt  "WAV15" 18.0 opt  "WAV16" 19.0 opt   as-display ;

: amb-srcs  "ENV1" 0.0 opt  "ENV2" 1.0 opt  "ENV3" 2.0 opt  "LFO1" 3.0 opt  "LFO2" 4.0 opt
    "LFO3" 5.0 opt  "LFO4" 6.0 opt  "MOD1" 7.0 opt  "MOD2" 8.0 opt  "MOD3" 9.0 opt
    "MOD4" 10.0 opt  "VELO" 11.0 opt  "AFTR" 12.0 opt  "BEND" 13.0 opt  "MWHL" 14.0 opt
    "WHL2" 15.0 opt  "PDAL" 16.0 opt  "NOTE" 17.0 opt  "GATE" 18.0 opt  "NOIS" 19.0 opt
    "RAND" 20.0 opt  "[256]" 21.0 opt  "[128]" 22.0 opt  "[64]" 23.0 opt  "[32]" 24.0 opt
    "[16]" 25.0 opt  "[8]" 26.0 opt  "[4]" 27.0 opt   as-display ;

: amb-dsts  "PRM1" 0.0 opt  "PRM2" 1.0 opt  "OSC1" 2.0 opt  "OSC2" 3.0 opt  "~1+2" 4.0 opt
    "VIBR" 5.0 opt  "MIX" 6.0 opt  "XMOD" 7.0 opt  "NOIS" 8.0 opt  "SUB" 9.0 opt
    "FUZZ" 10.0 opt  "CRSH" 11.0 opt  "FREQ" 12.0 opt  "RESO" 13.0 opt  "ATTK" 14.0 opt
    "DECA" 15.0 opt  "RELE" 16.0 opt  "LFO4" 17.0 opt  "VCA" 18.0 opt   as-display ;

: amb-mops  "OFF" 0.0 opt  "ADD" 1.0 opt  "PRD" 2.0 opt  "ATTN" 3.0 opt  "MAX" 4.0 opt
    "MIN" 5.0 opt  "XOR" 6.0 opt  ">=" 7.0 opt  "<=" 8.0 opt  "QTZ" 9.0 opt  "LAG" 10.0 opt   as-display ;

: amb-boards  "SMR4" 0.0 opt  "SVF" 1.0 opt  as-button ;
: amb-modes  "LP" 0.0 opt  "BP" 1.0 opt  "HP" 2.0 opt  "NOTCH" 3.0 opt  as-list ;
: amb-trigs  "FREE" 0.0 opt  "RETRIG" 1.0 opt  as-list ;

( an integer knob: module label id field min max default )
: amb-int  int-step ;

: manifest
  "Ambika" voice-sample machine*
  "k-amb-voice"        render!
  "k-amb-note-on"      note-on!
  "k-amb-note-expr"    note-expr!
  "k-amb-note-off"     note-off!
  "k-amb-block-prepare" block-prepare!
  "k-amb-control" 49   control!
  6 voices!
  AmbState.size  state-size!
  AmbParams.size params-size!
  1200.0 panel-w!

  "tables" AmbParams.tbl AmbParams.tbl-len AmbParams.tbl-sr "assets/tables.wav" asset

  "OSC 1" "WAVE" "am-o1-shape" AmbParams.o1-shape 1 switch amb-shapes
  "OSC 1" "PARA" "am-o1-prm" AmbParams.o1-prm 0.0 127.0 0.0 int-step
  "OSC 1" "RANG" "am-o1-range" AmbParams.o1-range -36.0 36.0 0.0 int-step
  "OSC 1" "TUNE" "am-o1-tune" AmbParams.o1-tune -64.0 63.0 0.0 int-step
  "OSC 2" "WAVE" "am-o2-shape" AmbParams.o2-shape 1 switch amb-shapes
  "OSC 2" "PARA" "am-o2-prm" AmbParams.o2-prm 0.0 127.0 0.0 int-step
  "OSC 2" "RANG" "am-o2-range" AmbParams.o2-range -36.0 36.0 0.0 int-step
  "OSC 2" "TUNE" "am-o2-tune" AmbParams.o2-tune -64.0 63.0 6.0 int-step
  "MIXER" "MIX" "am-balance" AmbParams.balance 0.0 63.0 32.0 int-step
  "MIXER" "XMOD" "am-op" AmbParams.op 0 switch amb-ops
  "MIXER" "AMNT" "am-mixprm" AmbParams.mixprm 0.0 63.0 0.0 int-step
  "MIXER" "TYPE" "am-sub-shape" AmbParams.sub-shape 0 switch amb-subs
  "MIXER" "SUB" "am-sub-lvl" AmbParams.sub-lvl 0.0 63.0 0.0 int-step
  "MIXER" "NOIS" "am-noise" AmbParams.noise 0.0 63.0 0.0 int-step
  "MIXER" "FUZZ" "am-fuzz" AmbParams.fuzz 0.0 63.0 0.0 int-step
  "MIXER" "CRSH" "am-crush" AmbParams.crush-p 0.0 63.0 0.0 int-step
  "FILTER" "FREQ" "am-cutoff" AmbParams.cutoff 0.0 127.0 90.0 int-step
  "FILTER" "RESO" "am-reso" AmbParams.reso 0.0 63.0 10.0 int-step
  "FILTER" "MODE" "am-fmode" AmbParams.fmode 0 switch amb-modes
  "FILTER" "BOARD" "am-board" AmbParams.board 0 switch amb-boards
  "FILTER" "ENV2" "am-env2" AmbParams.env2 -63.0 63.0 30.0 int-step
  "FILTER" "LFO2" "am-lfo2" AmbParams.lfo2 -63.0 63.0 0.0 int-step
  "ENV 1" "ATTK" "am-e1-a" AmbParams.ea 0 + 0.0 127.0 0.0 int-step
  "ENV 1" "DECA" "am-e1-d" AmbParams.ed 0 + 0.0 127.0 40.0 int-step
  "ENV 1" "SUST" "am-e1-s" AmbParams.es 0 + 0.0 127.0 20.0 int-step
  "ENV 1" "RELE" "am-e1-r" AmbParams.er 0 + 0.0 127.0 60.0 int-step
  "ENV 2" "ATTK" "am-e2-a" AmbParams.ea 8 + 0.0 127.0 0.0 int-step
  "ENV 2" "DECA" "am-e2-d" AmbParams.ed 8 + 0.0 127.0 40.0 int-step
  "ENV 2" "SUST" "am-e2-s" AmbParams.es 8 + 0.0 127.0 20.0 int-step
  "ENV 2" "RELE" "am-e2-r" AmbParams.er 8 + 0.0 127.0 60.0 int-step
  "ENV 3" "ATTK" "am-e3-a" AmbParams.ea 16 + 0.0 127.0 0.0 int-step
  "ENV 3" "DECA" "am-e3-d" AmbParams.ed 16 + 0.0 127.0 50.0 int-step
  "ENV 3" "SUST" "am-e3-s" AmbParams.es 16 + 0.0 127.0 100.0 int-step
  "ENV 3" "RELE" "am-e3-r" AmbParams.er 16 + 0.0 127.0 60.0 int-step
  "LFO 1" "WAVE" "am-l1-shape" AmbParams.lshape 0 + 0 switch amb-lfow
  "LFO 1" "RATE" "am-l1-rate" AmbParams.lrate 0 + 0.0 127.0 40.0 int-step
  "LFO 1" "TRIG" "am-l1-trig" AmbParams.ltrig 0 + 0 switch amb-trigs
  "LFO 2" "WAVE" "am-l2-shape" AmbParams.lshape 8 + 0 switch amb-lfow
  "LFO 2" "RATE" "am-l2-rate" AmbParams.lrate 8 + 0.0 127.0 40.0 int-step
  "LFO 2" "TRIG" "am-l2-trig" AmbParams.ltrig 8 + 0 switch amb-trigs
  "LFO 3" "WAVE" "am-l3-shape" AmbParams.lshape 16 + 0 switch amb-lfow
  "LFO 3" "RATE" "am-l3-rate" AmbParams.lrate 16 + 0.0 127.0 40.0 int-step
  "LFO 3" "TRIG" "am-l3-trig" AmbParams.ltrig 16 + 0 switch amb-trigs
  "LFO 4" "WAVE" "am-vl-shape" AmbParams.vl-shape 0 switch amb-lfow
  "LFO 4" "RATE" "am-vl-rate" AmbParams.vl-rate 0.0 127.0 40.0 int-step
  "PART" "VOLU" "am-volume" AmbParams.volume 0.0 127.0 100.0 int-step
  "PART" "LEGA" "am-legato" AmbParams.legato 0 switch amb-onoff
  "PART" "PORT" "am-porta" AmbParams.porta 0.0 127.0 0.0 int-step
  "PART" "OCTV" "am-octave" AmbParams.octave -2.0 2.0 0.0 int-step
  "PART" "TUNE" "am-tune" AmbParams.tune -100.0 100.0 0.0 int-step
  "PERFORM" "BEND" "am-bend" AmbParams.bend -1.0 1.0 0.0 curve-lin knob
  "PERFORM" "MWHL" "am-mwhl" AmbParams.mwhl 0.0 1.0 0.0 curve-lin knob
  "PERFORM" "WHL2" "am-whl2" AmbParams.whl2 0.0 1.0 0.0 curve-lin knob
  "PERFORM" "PDAL" "am-pdal" AmbParams.pdal 0.0 1.0 0.0 curve-lin knob
  "OUT" "LEVEL" "am-gain" AmbParams.gain 0.0 1.0 0.5 curve-pow knob
  "SLOT 1" "SRC" "am-m1-src" AmbParams.m-src 0 + 0 switch amb-srcs
  "SLOT 1" "DEST" "am-m1-dst" AmbParams.m-dst 0 + 0 switch amb-dsts
  "SLOT 1" "AMT" "am-m1-amt" AmbParams.m-amt 0 + -63.0 63.0 0.0 curve-lin knob
  "SLOT 2" "SRC" "am-m2-src" AmbParams.m-src 8 + 0 switch amb-srcs
  "SLOT 2" "DEST" "am-m2-dst" AmbParams.m-dst 8 + 1 switch amb-dsts
  "SLOT 2" "AMT" "am-m2-amt" AmbParams.m-amt 8 + -63.0 63.0 0.0 curve-lin knob
  "SLOT 3" "SRC" "am-m3-src" AmbParams.m-src 16 + 3 switch amb-srcs
  "SLOT 3" "DEST" "am-m3-dst" AmbParams.m-dst 16 + 4 switch amb-dsts
  "SLOT 3" "AMT" "am-m3-amt" AmbParams.m-amt 16 + -63.0 63.0 0.0 curve-lin knob
  "SLOT 4" "SRC" "am-m4-src" AmbParams.m-src 24 + 4 switch amb-srcs
  "SLOT 4" "DEST" "am-m4-dst" AmbParams.m-dst 24 + 0 switch amb-dsts
  "SLOT 4" "AMT" "am-m4-amt" AmbParams.m-amt 24 + -63.0 63.0 0.0 curve-lin knob
  "SLOT 5" "SRC" "am-m5-src" AmbParams.m-src 32 + 4 switch amb-srcs
  "SLOT 5" "DEST" "am-m5-dst" AmbParams.m-dst 32 + 1 switch amb-dsts
  "SLOT 5" "AMT" "am-m5-amt" AmbParams.m-amt 32 + -63.0 63.0 0.0 curve-lin knob
  "SLOT 6" "SRC" "am-m6-src" AmbParams.m-src 40 + 5 switch amb-srcs
  "SLOT 6" "DEST" "am-m6-dst" AmbParams.m-dst 40 + 6 switch amb-dsts
  "SLOT 6" "AMT" "am-m6-amt" AmbParams.m-amt 40 + -63.0 63.0 0.0 curve-lin knob
  "SLOT 7" "SRC" "am-m7-src" AmbParams.m-src 48 + 6 switch amb-srcs
  "SLOT 7" "DEST" "am-m7-dst" AmbParams.m-dst 48 + 12 switch amb-dsts
  "SLOT 7" "AMT" "am-m7-amt" AmbParams.m-amt 48 + -63.0 63.0 0.0 curve-lin knob
  "SLOT 8" "SRC" "am-m8-src" AmbParams.m-src 56 + 11 switch amb-srcs
  "SLOT 8" "DEST" "am-m8-dst" AmbParams.m-dst 56 + 12 switch amb-dsts
  "SLOT 8" "AMT" "am-m8-amt" AmbParams.m-amt 56 + -63.0 63.0 0.0 curve-lin knob
  "SLOT 9" "SRC" "am-m9-src" AmbParams.m-src 64 + 17 switch amb-srcs
  "SLOT 9" "DEST" "am-m9-dst" AmbParams.m-dst 64 + 12 switch amb-dsts
  "SLOT 9" "AMT" "am-m9-amt" AmbParams.m-amt 64 + -63.0 63.0 0.0 curve-lin knob
  "SLOT 10" "SRC" "am-m10-src" AmbParams.m-src 72 + 0 switch amb-srcs
  "SLOT 10" "DEST" "am-m10-dst" AmbParams.m-dst 72 + 12 switch amb-dsts
  "SLOT 10" "AMT" "am-m10-amt" AmbParams.m-amt 72 + -63.0 63.0 0.0 curve-lin knob
  "SLOT 11" "SRC" "am-m11-src" AmbParams.m-src 80 + 2 switch amb-srcs
  "SLOT 11" "DEST" "am-m11-dst" AmbParams.m-dst 80 + 18 switch amb-dsts
  "SLOT 11" "AMT" "am-m11-amt" AmbParams.m-amt 80 + -63.0 63.0 63.0 curve-lin knob
  "SLOT 12" "SRC" "am-m12-src" AmbParams.m-src 88 + 11 switch amb-srcs
  "SLOT 12" "DEST" "am-m12-dst" AmbParams.m-dst 88 + 18 switch amb-dsts
  "SLOT 12" "AMT" "am-m12-amt" AmbParams.m-amt 88 + -63.0 63.0 16.0 curve-lin knob
  "SLOT 13" "SRC" "am-m13-src" AmbParams.m-src 96 + 13 switch amb-srcs
  "SLOT 13" "DEST" "am-m13-dst" AmbParams.m-dst 96 + 4 switch amb-dsts
  "SLOT 13" "AMT" "am-m13-amt" AmbParams.m-amt 96 + -63.0 63.0 32.0 curve-lin knob
  "SLOT 14" "SRC" "am-m14-src" AmbParams.m-src 104 + 6 switch amb-srcs
  "SLOT 14" "DEST" "am-m14-dst" AmbParams.m-dst 104 + 5 switch amb-dsts
  "SLOT 14" "AMT" "am-m14-amt" AmbParams.m-amt 104 + -63.0 63.0 0.0 curve-lin knob
  "MOD 1" "IN1" "am-d1-in1" AmbParams.md-in1 0 + 0 switch amb-srcs
  "MOD 1" "IN2" "am-d1-in2" AmbParams.md-in2 0 + 0 switch amb-srcs
  "MOD 1" "OPER" "am-d1-op" AmbParams.md-op 0 + 0 switch amb-mops
  "MOD 2" "IN1" "am-d2-in1" AmbParams.md-in1 8 + 0 switch amb-srcs
  "MOD 2" "IN2" "am-d2-in2" AmbParams.md-in2 8 + 0 switch amb-srcs
  "MOD 2" "OPER" "am-d2-op" AmbParams.md-op 8 + 0 switch amb-mops
  "MOD 3" "IN1" "am-d3-in1" AmbParams.md-in1 16 + 0 switch amb-srcs
  "MOD 3" "IN2" "am-d3-in2" AmbParams.md-in2 16 + 0 switch amb-srcs
  "MOD 3" "OPER" "am-d3-op" AmbParams.md-op 16 + 0 switch amb-mops
  "MOD 4" "IN1" "am-d4-in1" AmbParams.md-in1 24 + 0 switch amb-srcs
  "MOD 4" "IN2" "am-d4-in2" AmbParams.md-in2 24 + 0 switch amb-srcs
  "MOD 4" "OPER" "am-d4-op" AmbParams.md-op 24 + 0 switch amb-mops
  ( strips )
  "OSC 1" 4 strip  "OSC 2" 4 strip  "MIXER" 8 strip  "FILTER" 6 strip
  "ENV 1" 4 strip  "ENV 2" 4 strip  "ENV 3" 4 strip
  "LFO 1" 3 strip  "LFO 2" 3 strip  "LFO 3" 3 strip  "LFO 4" 2 strip
  "PART" 5 strip  "PERFORM" 4 strip  "OUT" 1 strip
  "MOD 1" 3 strip  "MOD 2" 3 strip  "MOD 3" 3 strip  "MOD 4" 3 strip

  ( the dock's sources, the knobs they reach [docs/15 §Modulation] )
  "ENV1" 0 AmbState.mv 0 + 0 mod-source
  "ENV2" 1 AmbState.mv 8 + 0 mod-source
  "ENV3" 2 AmbState.mv 16 + 0 mod-source
  "LFO1" 3 AmbState.mv 24 + 1 mod-source
  "LFO2" 4 AmbState.mv 32 + 1 mod-source
  "LFO3" 5 AmbState.mv 40 + 1 mod-source
  "LFO4" 6 AmbState.mv 48 + 1 mod-source
  "MOD1" 7 AmbState.mv 56 + 0 mod-source
  "MOD2" 8 AmbState.mv 64 + 0 mod-source
  "MOD3" 9 AmbState.mv 72 + 0 mod-source
  "MOD4" 10 AmbState.mv 80 + 0 mod-source
  "VELO" 11 AmbState.mv 88 + 0 mod-source
  "AFTR" 12 AmbState.mv 96 + 0 mod-source
  "BEND" 13 AmbState.mv 104 + 1 mod-source
  "MWHL" 14 AmbState.mv 112 + 0 mod-source
  "WHL2" 15 AmbState.mv 120 + 0 mod-source
  "PDAL" 16 AmbState.mv 128 + 0 mod-source
  "NOTE" 17 AmbState.mv 136 + 1 mod-source
  "GATE" 18 AmbState.mv 144 + 0 mod-source
  "NOIS" 19 AmbState.mv 152 + 0 mod-source
  "RAND" 20 AmbState.mv 160 + 0 mod-source
  "am-o1-prm" 0 AmbState.prm1 mod-dest
  "am-o2-prm" 1 AmbState.prm2 mod-dest
  "am-env2" 1 12 mod-fixed
  "MOD DOCK" mod-dock

  "MATRIX" matrix-display
  "am-m" 14 mod-matrix

  "SOUND" page
    1.0 row  1.0 cell  "OSC 1" 1.0 item  1.0 cell  "OSC 2" 1.0 item  1.6 cell  "MIXER" 1.0 item
    1.0 row  1.0 cell  "FILTER" 1.0 item  0.8 cell  "ENV 1" 1.0 item  0.8 cell  "ENV 2" 1.0 item
             0.8 cell  "ENV 3" 1.0 item  0.4 cell  "OUT" 1.0 item
  "MOD" page
    0.25 row  1.0 cell  "MOD DOCK" 1.0 item
    1.0 row  1.0 cell  "LFO 1" 1.0 item  1.0 cell  "LFO 2" 1.0 item  1.0 cell  "LFO 3" 1.0 item
             0.7 cell  "LFO 4" 1.0 item
    2.4 row  1.0 cell  "MATRIX" 1.0 item
    1.0 row  1.0 cell  "MOD 1" 1.0 item  1.0 cell  "MOD 2" 1.0 item  1.0 cell  "MOD 3" 1.0 item
             1.0 cell  "MOD 4" 1.0 item
  "PART" page
    1.0 row  1.0 cell  "PART" 1.0 item  1.0 cell  "PERFORM" 1.0 item

  machine-desc
;
