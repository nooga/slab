( kit.fy - Skinwork Kit: a modal physical-model drum kit [docs/41].

  The voice is kernels/06-voices/kit.fy: each hit is a drumhead [Bessel
  modes, tension glide, snare wires] or a cymbal [coupled plate modes]
  struck by a stick or beater through an implicit contact.  Notes follow
  the GM drum map; notes outside it fold into it by octave. )

include "../../kernels/06-voices/kit.fy"
include "../lib/manifest.fy"

: manifest
  "Skinwork Kit" voice-sample machine*
  "k-kit-voice"       render!
  "kit-note-on"       note-on!
  "kit-block-prepare" block-prepare!
  "kit-control" 32    control!
  12 voices!
  stereo
  note-pitch
  KitState.size  state-size!
  KitParams.size params-size!
  36 "KICK" note-label  38 "SNARE" note-label  37 "SIDE" note-label
  41 "LT" note-label  45 "MT" note-label  48 "HT" note-label
  42 "CH" note-label  44 "PH" note-label  46 "OH" note-label
  49 "CRASH" note-label  51 "RIDE" note-label  53 "BELL" note-label
  760.0 panel-w!

  "KICK" "TUNE"  "sk-kick-tune"  KitParams.kick-tune  -12.0 12.0 0.0 curve-lin knob
  "KICK" "DECAY" "sk-kick-decay" KitParams.kick-decay 0.25 4.0 1.0 curve-exp knob
  "KICK" "LEVEL" "sk-kick-level" KitParams.kick-level 0.0 1.0 0.8 curve-pow knob
  "KICK" 3 strip
  "SNARE" "TUNE"  "sk-snare-tune"  KitParams.snare-tune  -12.0 12.0 0.0 curve-lin knob
  "SNARE" "DECAY" "sk-snare-decay" KitParams.snare-decay 0.25 4.0 1.0 curve-exp knob
  "SNARE" "LEVEL" "sk-snare-level" KitParams.snare-level 0.0 1.0 0.8 curve-pow knob
  "SNARE" 3 strip
  "TOMS" "TUNE"  "sk-tom-tune"  KitParams.tom-tune  -12.0 12.0 0.0 curve-lin knob
  "TOMS" "DECAY" "sk-tom-decay" KitParams.tom-decay 0.25 4.0 1.0 curve-exp knob
  "TOMS" "LEVEL" "sk-tom-level" KitParams.tom-level 0.0 1.0 0.8 curve-pow knob
  "TOMS" 3 strip
  "HATS" "TUNE"  "sk-hat-tune"  KitParams.hat-tune  -12.0 12.0 0.0 curve-lin knob
  "HATS" "DECAY" "sk-hat-decay" KitParams.hat-decay 0.25 4.0 1.0 curve-exp knob
  "HATS" "LEVEL" "sk-hat-level" KitParams.hat-level 0.0 1.0 0.7 curve-pow knob
  "HATS" 3 strip
  "CRASH" "TUNE"  "sk-crash-tune"  KitParams.crash-tune  -12.0 12.0 0.0 curve-lin knob
  "CRASH" "DECAY" "sk-crash-decay" KitParams.crash-decay 0.25 4.0 1.0 curve-exp knob
  "CRASH" "LEVEL" "sk-crash-level" KitParams.crash-level 0.0 1.0 0.7 curve-pow knob
  "CRASH" 3 strip
  "RIDE" "TUNE"  "sk-ride-tune"  KitParams.ride-tune  -12.0 12.0 0.0 curve-lin knob
  "RIDE" "DECAY" "sk-ride-decay" KitParams.ride-decay 0.25 4.0 1.0 curve-exp knob
  "RIDE" "LEVEL" "sk-ride-level" KitParams.ride-level 0.0 1.0 0.7 curve-pow knob
  "RIDE" 3 strip
  "PLAY" "STICK" "sk-stick" KitParams.stick -1.0 1.0 0.0 curve-lin knob
  "PLAY" "WIRES" "sk-wires" KitParams.wires 0.0 1.0 0.7 curve-lin knob
  "PLAY" "GLIDE" "sk-glide" KitParams.glide 0.0 2.0 1.0 curve-lin knob
  "PLAY" "BLOOM" "sk-bloom" KitParams.bloom 0.0 2.0 1.0 curve-lin knob
  "PLAY" "WIDTH" "sk-width" KitParams.width 0.0 1.0 0.6 curve-lin knob
  "PLAY" "LEVEL" "sk-level" KitParams.level 0.0 1.0 0.7 curve-pow knob
  "PLAY" 3 strip
  1.0 row
    1.0 cell  "KICK" 1.0 item
    1.0 cell  "SNARE" 1.0 item
    1.0 cell  "TOMS" 1.0 item
    1.0 cell  "HATS" 1.0 item
    1.0 cell  "CRASH" 1.0 item
    1.0 cell  "RIDE" 1.0 item
    2.0 cell  "PLAY" 1.0 item

  machine-desc
;
