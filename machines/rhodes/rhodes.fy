( rhodes.fy — Rhodes-type electric piano machine.

  The voice lives in the kernels rig [kernels/06-voices/rhodes.fy];
  this file declares the machine.  The host voice pool calls the render
  composition once per voice per segment against per-voice state; all
  note data is per-voice, params are shared.  ctx.chan carries the
  voice index (unused in DSP but reserved for future per-voice detune).

  Panel: TINE | BAR | PICKUP | AMP.  The tine Q is the sustain knob -
  high Q rings for seconds, low Q dies fast.  Damper controls how fast
  the note decays after key release (sustain pedal up = high damper). )

include "../../kernels/06-voices/rhodes.fy"
include "../lib/manifest.fy"

: manifest
  "Rhodes E-Piano" voice-sample machine*
  "k-rhodes-voice"       render!
  "rhodes-note-on"       note-on!
  "rhodes-note-off"      note-off!
  "rhodes-block-prepare" block-prepare!
  8 voices!
  RhodesState.size  state-size!
  RhodesParams.size params-size!
  520.0 panel-w!


  "TINE" "BELL"  "rd-tine-q"     RhodesParams.tine-q     0.0 1.0 0.7 curve-lin knob
  "TINE" "BARK"  "rd-bark"       RhodesParams.bark        0.0 1.0 0.3 curve-lin knob
  "TINE" "SNAP"  "rd-bark-decay" RhodesParams.bark-decay  0.0 1.0 0.2 curve-lin knob
  "TINE" 3 strip

  "BODY" "DECAY"  "rd-bar-q"      RhodesParams.bar-q       0.0 1.0 0.4 curve-lin knob
  "BODY" "CHORUS" "rd-bar-detune" RhodesParams.bar-detune  0.0 1.0 0.3 curve-lin knob
  "BODY" 2 strip

  "PICKUP" "DRIVE" "rd-pickup-drive" RhodesParams.pickup-drive 0.0 1.0 0.3 curve-lin knob
  "PICKUP" "VOICE" "rd-voicing"      RhodesParams.voicing      0.0 1.0 0.4 curve-lin knob
  "PICKUP" 2 strip

  "AMP" "TONE"    "rd-warmth" RhodesParams.warmth 0.0 1.0 0.5 curve-lin knob
  "AMP" "RELEASE" "rd-damper" RhodesParams.damper 0.0 1.0 0.7 curve-lin knob
  "AMP" "LEVEL"   "rd-level"  RhodesParams.level  0.0 1.0 0.8 curve-pow knob
  "AMP" 3 strip
  1.0 row
    1.0 cell  "TINE" 1.0 item
    1.0 cell  "BODY" 1.0 item
    1.0 cell  "PICKUP" 1.0 item
    1.0 cell  "AMP" 1.0 item

  machine-desc
;
