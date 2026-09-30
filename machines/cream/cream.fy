( cream.fy - Mog Passenger: a Prodigy / Messenger style mono synth.

  The voice is kernels/06-voices/cream.fy: OSC 1, OSC 2 with hard sync,
  OSC 3 as a locked SUB or a free oscillator, into a driven ladder.  Mono with a note stack:
  legato notes glide without retriggering the contours.  Push DRIVE for
  the overdriven-mixer growl, EMPH toward 1 for the whistle; AGE is the
  analog layer [drift and part spread]. )

include "../../kernels/06-voices/cream.fy"
include "../lib/manifest.fy"

: manifest
  "Mog Passenger" voice-sample machine*
  "k-cream-voice"       render!
  "cream-note-on"       note-on!
  "cream-note-expr"     note-expr!
  "cream-note-off"      note-off!
  "cream-block-prepare" block-prepare!
  CreamState.size  state-size!
  CreamParams.size params-size!
  780.0 panel-w!

  ( module label id offset default switch / min max default curve knob )
  "OSC 1" "RANGE" "cr-range1" CreamParams.range1 2 switch
    "32" 0.25 opt  "16" 0.5 opt  "8" 1.0 opt  "4" 2.0 opt  "2" 4.0 opt  as-knob
  "OSC 1" "WAVE" "cr-wave1" CreamParams.wave1 1 switch
    "TRI" 0.0 opt  "SAW" 1.0 opt  "SQR" 2.0 opt  "WIDE" 3.0 opt  "NARR" 4.0 opt  as-knob

  "OSC 2" "RANGE" "cr-range2" CreamParams.range2 2 switch
    "32" 0.25 opt  "16" 0.5 opt  "8" 1.0 opt  "4" 2.0 opt  "2" 4.0 opt  as-knob
  "OSC 2" "WAVE" "cr-wave2" CreamParams.wave2 1 switch
    "TRI" 0.0 opt  "SAW" 1.0 opt  "SQR" 2.0 opt  "WIDE" 3.0 opt  "NARR" 4.0 opt  as-knob
  "OSC 2" "FREQ" "cr-detune2" CreamParams.detune2 -7.0 7.0 0.07 curve-lin knob
  "OSC 2" "SYNC" "cr-sync2" CreamParams.sync2 0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt  as-lever
  "OSC 2" "SWEEP" "cr-env-osc2" CreamParams.env-osc2 0.0 24.0 0.0 curve-pow knob

  "OSC 3" "MODE" "cr-osc3-mode" CreamParams.osc3-mode 0 switch
    "SUB" 0.0 opt  "OSC" 1.0 opt
  "OSC 3" "SUB" "cr-sub-oct" CreamParams.sub-oct 0 switch
    "-1" 0.5 opt  "-2" 0.25 opt
  "OSC 3" "RANGE" "cr-range3" CreamParams.range3 1 switch
    "32" 0.25 opt  "16" 0.5 opt  "8" 1.0 opt  "4" 2.0 opt  "2" 4.0 opt  as-knob
  "OSC 3" "WAVE" "cr-wave3" CreamParams.wave3 2 switch
    "TRI" 0.0 opt  "SAW" 1.0 opt  "SQR" 2.0 opt  "WIDE" 3.0 opt  "NARR" 4.0 opt  as-knob
  "OSC 3" "FREQ" "cr-detune3" CreamParams.detune3 -7.0 7.0 -0.05 curve-lin knob

  "MIXER" "OSC1"  "cr-lvl1"  CreamParams.lvl1  0.0 1.0 1.0  curve-pow knob
  "MIXER" "OSC2"  "cr-lvl2"  CreamParams.lvl2  0.0 1.0 0.8  curve-pow knob
  "MIXER" "OSC3"  "cr-lvl3"  CreamParams.lvl3  0.0 1.0 0.5  curve-pow knob
  "MIXER" "NOISE" "cr-noise" CreamParams.noise 0.0 1.0 0.0  curve-pow knob
  "MIXER" "DRIVE" "cr-drive" CreamParams.drive 0.0 1.0 0.45 curve-lin knob

  "FILTER" "CUTOFF" "cr-cutoff"   CreamParams.cutoff   20.0 18000.0 700.0 curve-exp knob
  "FILTER" "EMPH"   "cr-emphasis" CreamParams.emphasis 0.0 1.1 0.35 curve-lin knob
  "FILTER" "AMOUNT" "cr-contour"  CreamParams.contour  0.0 6.0 3.0 curve-lin knob
  "FILTER" "KBD"    "cr-kbd"      CreamParams.kbd      0.0 1.0 0.33 curve-lin knob
  "FILTER" "MODE"   "cr-flt-mode" CreamParams.flt-mode 0 switch
    "LP24" 0.0 opt  "LP12" 1.0 opt  "BP12" 2.0 opt  "HP24" 3.0 opt  as-knob
  "FILTER" "BASS"   "cr-bass-comp" CreamParams.bass-comp 1 switch
    "OFF" 0.0 opt  "ON" 1.0 opt

  "F CONTOUR" "ATK" "cr-f-atk" CreamParams.f-atk 0.001 10.0 0.003 curve-exp knob
  "F CONTOUR" "DEC" "cr-f-dec" CreamParams.f-dec 0.005 10.0 0.35 curve-exp knob
  "F CONTOUR" "SUS" "cr-f-sus" CreamParams.f-sus 0.0 1.0 0.25 curve-lin knob
  "F CONTOUR" "REL" "cr-f-rel" CreamParams.f-rel 0.005 10.0 0.25 curve-exp knob

  "L CONTOUR" "ATK" "cr-a-atk" CreamParams.a-atk 0.001 10.0 0.002 curve-exp knob
  "L CONTOUR" "DEC" "cr-a-dec" CreamParams.a-dec 0.005 10.0 0.6 curve-exp knob
  "L CONTOUR" "SUS" "cr-a-sus" CreamParams.a-sus 0.0 1.0 0.8 curve-lin knob
  "L CONTOUR" "REL" "cr-a-rel" CreamParams.a-rel 0.005 10.0 0.15 curve-exp knob

  "LFO" "RATE"  "cr-lfo-rate"  CreamParams.lfo-rate  0.1 20.0 5.0 curve-exp knob
  "LFO" "WAVE"  "cr-lfo-wave"  CreamParams.lfo-wave  0 switch
    "TRI" 0.0 opt  "SQR" 1.0 opt  "SAW" 2.0 opt  "S&H" 3.0 opt  as-knob
  "LFO" "PITCH" "cr-lfo-pitch" CreamParams.lfo-pitch 0.0 12.0 0.0 curve-pow knob
  "LFO" "CUT"   "cr-lfo-cut"   CreamParams.lfo-cut   0.0 4.0 0.0 curve-pow knob

  "OUT" "GLIDE" "cr-glide" CreamParams.glide   0.0 5.0 0.0 curve-pow knob
  "OUT" "AGE"   "cr-age"   CreamParams.age-amt 0.0 1.0 0.4 curve-lin knob
  "OUT" "LEVEL" "cr-level" CreamParams.level   0.0 1.0 0.6 curve-pow knob
  "OUT" "FEEDBACK" "cr-fbk" CreamParams.fbk    0.0 1.0 0.0 curve-lin knob

  ( The Moog face: the oscillator bank as three rows, the mixer, the
    modifiers [filter over its contour over the loudness contour], then
    the LFO and output over the contours.  Range, waveform and filter
    mode are rotary selectors. )
  "OSC 1" 2 strip
  "OSC 2" 5 strip
  "OSC 3" 5 strip
  "MIXER" 2 strip
  "FILTER" 6 strip
  "F CONTOUR" 4 strip
  "L CONTOUR" 4 strip
  "LFO" 2 strip
  "OUT" 4 strip

  "CONTOURS" "F CONTOUR,L CONTOUR" adsr-display

  1.0 row
    1.0 cell  "OSC 1" 0.0 item  "OSC 2" 0.0 item  "OSC 3" 1.0 item
    1.0 cell  "MIXER" 1.0 item
    1.0 cell  "FILTER" 0.0 item  "F CONTOUR" 0.0 item  "L CONTOUR" 1.0 item
    1.0 cell  "LFO" 0.0 item  "OUT" 0.0 item  "CONTOURS" 1.0 item

  machine-desc
;
