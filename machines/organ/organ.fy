( organ.fy - Tonewheel Organ: 91 wheels that never stop, nine drawbars,
  percussion, scanner vibrato and key click, in the manner of the
  electromechanical organs of the 1930s to 70s.

  Pull drawbars to build the tone: 16' and 5 1/3' under the key, 8' the
  key, then its harmonics.  Velocity is how fast the key goes down,
  which is how tight the click is, not how loud the note.  Play it into
  machines/rotary.  The DSP is kernels/06-voices/organ.fy: the wheels
  live in the shared region, a voice is a key's nine contacts. )

include "../../kernels/06-voices/organ.fy"
include "../lib/manifest.fy"

: manifest
  "Tonewheel Organ" voice-sample machine*
  "k-organ-voice" render!
  "organ-note-on" note-on!  "organ-note-off" note-off!
  "organ-block-prepare" block-prepare!
  16 voices!
  OrVoice.size state-size!  OrParams.size params-size!
  OrState.size shared-size!
  "k-organ-shared" 1 shared!
  OrVoice.lvl voice-level!
  760.0 panel-w!

  "DRAWBARS" "16"    "or-d16"  OrParams.d16  0.0 8.0 8.0 curve-lin knob as-fader
  "DRAWBARS" "5 1/3" "or-d513" OrParams.d513 0.0 8.0 8.0 curve-lin knob as-fader
  "DRAWBARS" "8"     "or-d8"   OrParams.d8   0.0 8.0 8.0 curve-lin knob as-fader
  "DRAWBARS" "4"     "or-d4"   OrParams.d4   0.0 8.0 0.0 curve-lin knob as-fader
  "DRAWBARS" "2 2/3" "or-d223" OrParams.d223 0.0 8.0 0.0 curve-lin knob as-fader
  "DRAWBARS" "2"     "or-d2"   OrParams.d2   0.0 8.0 0.0 curve-lin knob as-fader
  "DRAWBARS" "1 3/5" "or-d135" OrParams.d135 0.0 8.0 0.0 curve-lin knob as-fader
  "DRAWBARS" "1 1/3" "or-d113" OrParams.d113 0.0 8.0 0.0 curve-lin knob as-fader
  "DRAWBARS" "1"     "or-d1"   OrParams.d1   0.0 8.0 0.0 curve-lin knob as-fader
  "DRAWBARS" 9 strip

  "PERC" "ON" "or-perc" OrParams.perc 0.0 switch
    "OFF" 0.0 opt "ON" 1.0 opt as-button
  "PERC" "HARM" "or-pharm" OrParams.pharm 1.0 switch
    "2ND" 0.0 opt "3RD" 1.0 opt
  "PERC" "DECAY" "or-pfast" OrParams.pfast 1.0 switch
    "SLOW" 0.0 opt "FAST" 1.0 opt
  "PERC" "LEVEL" "or-psoft" OrParams.psoft 0.0 switch
    "NORM" 0.0 opt "SOFT" 1.0 opt
  "PERC" 2 strip

  "VIBRATO" "MODE" "or-vib" OrParams.vib 0.0 switch
    "OFF" 0.0 opt "V1" 1.0 opt "C1" 2.0 opt "V2" 3.0 opt
    "C2" 4.0 opt "V3" 5.0 opt "C3" 6.0 opt as-list span-rows
  "VIBRATO" 1 strip

  "TONE" "CLICK" "or-click" OrParams.click 0.0 1.0 0.5 curve-lin knob
  "TONE" "LEAK"  "or-leak"  OrParams.leak 0.0 1.0 0.3 curve-lin knob
  "TONE" "DRIVE" "or-drive" OrParams.drive 0.0 1.0 0.0 curve-lin knob
  "TONE" "VOLUME" "or-volume" OrParams.volume -24.0 12.0 0.0 curve-lin knob
  "TONE" 2 strip

  1.0 row
    3.0 cell "DRAWBARS" 1.0 item
    0.9 cell "PERC" 1.0 item
    0.6 cell "VIBRATO" 1.0 item
    0.9 cell "TONE" 1.0 item
  machine-desc
;
