( stereo_voice.fy - fixture: a stereo voice writing different L and R
  [manifest `stereo`].  Held notes write +0.25 left, -0.25 right. )

include "../../kernels/00-primitives/ctx.fy"

ustruct: StVState  f64 gate ;
ustruct: StVParams f64 dummy ;

dsp: st-voice-render | io:Io ctx state:StVState params -- |
  io.out-l  state.gate 0.25 f*  f+  -> io.out-l
  io.out-r  state.gate -0.25 f* f+  -> io.out-r
;

dsp: st-voice-on
  | ctx state:StVState params -- |  1.0 -> state.gate ;
dsp: st-voice-off
  | ctx state:StVState params -- |  0.0 -> state.gate ;

include "../lib/manifest.fy"

: manifest
  "raw-stereo-voice" voice-sample machine*
  "st-voice-render" render!
  "st-voice-on" note-on!
  "st-voice-off" note-off!
  stereo
  StVState.size  state-size!
  StVParams.size params-size!
  machine-desc
;
