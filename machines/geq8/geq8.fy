( geq8.fy — 8-band EQ machine, after Ableton's EQ Eight.

  DSP in kernels/07-effects/geq.fy: eight bands in series, each with an
  on switch, a type [LC48 LC12 LSHLF BELL NOTCH HSHLF HC12 HC48], a
  frequency, a Q and a +-15 dB gain; ADAPT [adaptive Q] narrows a bell
  as it boosts or cuts; an output trim follows.

  The panel puts a spectrum analyser over the band columns: the live
  output spectrum, 20 Hz to 20 kHz, with the EQ's response curve and a
  handle per band on top. )

include "../../kernels/07-effects/geq.fy"
include "../lib/manifest.fy"

: manifest
  "GEQ" effect-block machine*
  "k-geq-tick"        render!
  "geq-block-prepare" block-prepare!
  GeqState.size  state-size!
  GeqParams.size params-size!
  540.0 panel-w!

  "spec" GeqState.ring GeqState.ring-len 0.05 buffer

  ( one column per band: the strip's table fills eight columns a row, so
    the rows are type, frequency, gain, Q and the on switch )
  "BANDS" "BAND 1" "geq-t1" GeqParams.t1 2.0 switch
    "LC48" 0.0 opt  "LC12" 1.0 opt  "LSHLF" 2.0 opt  "BELL" 3.0 opt  "NOTCH" 4.0 opt  "HSHLF" 5.0 opt  "HC12" 6.0 opt  "HC48" 7.0 opt  as-display
  "BANDS" "BAND 2" "geq-t2" GeqParams.t2 3.0 switch
    "LC48" 0.0 opt  "LC12" 1.0 opt  "LSHLF" 2.0 opt  "BELL" 3.0 opt  "NOTCH" 4.0 opt  "HSHLF" 5.0 opt  "HC12" 6.0 opt  "HC48" 7.0 opt  as-display
  "BANDS" "BAND 3" "geq-t3" GeqParams.t3 3.0 switch
    "LC48" 0.0 opt  "LC12" 1.0 opt  "LSHLF" 2.0 opt  "BELL" 3.0 opt  "NOTCH" 4.0 opt  "HSHLF" 5.0 opt  "HC12" 6.0 opt  "HC48" 7.0 opt  as-display
  "BANDS" "BAND 4" "geq-t4" GeqParams.t4 3.0 switch
    "LC48" 0.0 opt  "LC12" 1.0 opt  "LSHLF" 2.0 opt  "BELL" 3.0 opt  "NOTCH" 4.0 opt  "HSHLF" 5.0 opt  "HC12" 6.0 opt  "HC48" 7.0 opt  as-display
  "BANDS" "BAND 5" "geq-t5" GeqParams.t5 3.0 switch
    "LC48" 0.0 opt  "LC12" 1.0 opt  "LSHLF" 2.0 opt  "BELL" 3.0 opt  "NOTCH" 4.0 opt  "HSHLF" 5.0 opt  "HC12" 6.0 opt  "HC48" 7.0 opt  as-display
  "BANDS" "BAND 6" "geq-t6" GeqParams.t6 3.0 switch
    "LC48" 0.0 opt  "LC12" 1.0 opt  "LSHLF" 2.0 opt  "BELL" 3.0 opt  "NOTCH" 4.0 opt  "HSHLF" 5.0 opt  "HC12" 6.0 opt  "HC48" 7.0 opt  as-display
  "BANDS" "BAND 7" "geq-t7" GeqParams.t7 3.0 switch
    "LC48" 0.0 opt  "LC12" 1.0 opt  "LSHLF" 2.0 opt  "BELL" 3.0 opt  "NOTCH" 4.0 opt  "HSHLF" 5.0 opt  "HC12" 6.0 opt  "HC48" 7.0 opt  as-display
  "BANDS" "BAND 8" "geq-t8" GeqParams.t8 5.0 switch
    "LC48" 0.0 opt  "LC12" 1.0 opt  "LSHLF" 2.0 opt  "BELL" 3.0 opt  "NOTCH" 4.0 opt  "HSHLF" 5.0 opt  "HC12" 6.0 opt  "HC48" 7.0 opt  as-display
  "BANDS" "FREQ" "geq-f1" GeqParams.f1 20.0 20000.0 60.0 curve-exp knob
  "BANDS" "FREQ" "geq-f2" GeqParams.f2 20.0 20000.0 150.0 curve-exp knob
  "BANDS" "FREQ" "geq-f3" GeqParams.f3 20.0 20000.0 350.0 curve-exp knob
  "BANDS" "FREQ" "geq-f4" GeqParams.f4 20.0 20000.0 800.0 curve-exp knob
  "BANDS" "FREQ" "geq-f5" GeqParams.f5 20.0 20000.0 1800.0 curve-exp knob
  "BANDS" "FREQ" "geq-f6" GeqParams.f6 20.0 20000.0 4000.0 curve-exp knob
  "BANDS" "FREQ" "geq-f7" GeqParams.f7 20.0 20000.0 8000.0 curve-exp knob
  "BANDS" "FREQ" "geq-f8" GeqParams.f8 20.0 20000.0 12000.0 curve-exp knob
  "BANDS" "GAIN" "geq-b1" GeqParams.g1 -15.0 15.0 0.0 curve-lin knob
  "BANDS" "GAIN" "geq-b2" GeqParams.g2 -15.0 15.0 0.0 curve-lin knob
  "BANDS" "GAIN" "geq-b3" GeqParams.g3 -15.0 15.0 0.0 curve-lin knob
  "BANDS" "GAIN" "geq-b4" GeqParams.g4 -15.0 15.0 0.0 curve-lin knob
  "BANDS" "GAIN" "geq-b5" GeqParams.g5 -15.0 15.0 0.0 curve-lin knob
  "BANDS" "GAIN" "geq-b6" GeqParams.g6 -15.0 15.0 0.0 curve-lin knob
  "BANDS" "GAIN" "geq-b7" GeqParams.g7 -15.0 15.0 0.0 curve-lin knob
  "BANDS" "GAIN" "geq-b8" GeqParams.g8 -15.0 15.0 0.0 curve-lin knob
  "BANDS" "Q" "geq-q1" GeqParams.q1 0.1 18.0 0.71 curve-exp knob
  "BANDS" "Q" "geq-q2" GeqParams.q2 0.1 18.0 0.71 curve-exp knob
  "BANDS" "Q" "geq-q3" GeqParams.q3 0.1 18.0 0.71 curve-exp knob
  "BANDS" "Q" "geq-q4" GeqParams.q4 0.1 18.0 0.71 curve-exp knob
  "BANDS" "Q" "geq-q5" GeqParams.q5 0.1 18.0 0.71 curve-exp knob
  "BANDS" "Q" "geq-q6" GeqParams.q6 0.1 18.0 0.71 curve-exp knob
  "BANDS" "Q" "geq-q7" GeqParams.q7 0.1 18.0 0.71 curve-exp knob
  "BANDS" "Q" "geq-q8" GeqParams.q8 0.1 18.0 0.71 curve-exp knob
  "BANDS" "1" "geq-on1" GeqParams.on1 1.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt  as-button
  "BANDS" "2" "geq-on2" GeqParams.on2 1.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt  as-button
  "BANDS" "3" "geq-on3" GeqParams.on3 1.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt  as-button
  "BANDS" "4" "geq-on4" GeqParams.on4 1.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt  as-button
  "BANDS" "5" "geq-on5" GeqParams.on5 1.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt  as-button
  "BANDS" "6" "geq-on6" GeqParams.on6 1.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt  as-button
  "BANDS" "7" "geq-on7" GeqParams.on7 1.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt  as-button
  "BANDS" "8" "geq-on8" GeqParams.on8 1.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt  as-button
  "BANDS" 8 strip

  "OUT" "ADAPT" "geq-adapt" GeqParams.adapt 1.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt  as-button
  "OUT" "LEVEL" "geq-out" GeqParams.out-db -12.0 12.0 0.0 curve-lin knob
  "OUT" 1 strip

  "SPECTRUM" "geq,spec" GeqState.wpos graphic-display

  1.0 row
    6.0 cell  "SPECTRUM" 1.0 item  "BANDS" 0.0 item
    1.0 cell  "OUT" 1.0 item

  machine-desc
;
