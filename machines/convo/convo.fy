( convo.fy - CONVO: a convolution reverb: the input played through a
  recorded or made impulse response, which the host's `convolver`
  convolves [src/convolver.zig].  The DSP after the convolution is in
  the kernels rig [kernels/07-effects/convo.fy].

  Two IRs ship: hall.wav, a synthetic stereo hall [made with a
  noise-and-early-reflections model, no recording], and
  bowed-cymbal.wav, a bowed cymbal from VSCO 2 CE [CC0] as a texture.
  Any WAV can take the "room" slot. )

include "../../kernels/07-effects/convo.fy"
include "../lib/manifest.fy"

: manifest
  "CONVO" effect-block machine*
  "k-convo-tick"         render!
  "convo-block-prepare"  block-prepare!
  ConvoState.size  state-size!
  ConvoParams.size params-size!
  ConvoParams.lat latency!
  10.0 tail!
  560.0 panel-w!
  stereo

  "ring" ConvoState.buf ConvoState.buf-len 0.411 buffer
  "room" ConvoParams.ir ConvoParams.ir-len ConvoParams.ir-sr "assets/hall.wav" convolver
  "IR" "room" waveform-display

  "SPACE" "PREDELAY" "convo-predelay" ConvoParams.predelay-ms 0.0 200.0 10.0 curve-pow knob
  "SPACE" "LO CUT"   "convo-lowcut"   ConvoParams.lowcut-hz 20.0 1000.0 80.0 curve-exp knob
  "SPACE" "HI CUT"   "convo-highcut"  ConvoParams.highcut-hz 1000.0 20000.0 16000.0 curve-exp knob
  "SPACE" 3 strip

  "OUT" "WIDTH" "convo-width" ConvoParams.width 0.0 1.5 1.0 curve-lin knob
  "OUT" "LEVEL" "convo-level" ConvoParams.level-db -24.0 12.0 0.0 curve-lin knob
  "OUT" "MIX"   "convo-mix"   ConvoParams.mix 0.0 1.0 0.35 curve-pow knob
  "OUT" 3 strip

  1.0 row
    1.0 cell  "IR" 1.0 item
  1.0 row
    1.0 cell  "SPACE" 1.0 item
    1.0 cell  "OUT" 1.0 item

  machine-desc
;
