( stereo_voice.fy - fixture: a stereo voice writing different L and R
  [manifest `stereo`].  Held notes write +0.25 left, -0.25 right. )

include "../../kernels/00-primitives/ctx.fy"

ustruct: StVState  f64 gate ;
ustruct: StVParams f64 dummy ;

dsp: st-voice-render ( io ctx state params -- )
  | io ctx state params |
  io Io.out-l@  state StVState.gate@ 0.25 f*  f+  io Io.out-l-p f!64
  io Io.out-r@  state StVState.gate@ -0.25 f* f+  io Io.out-r-p f!64
  drop2 drop2
;

dsp: st-voice-on ( ctx state params -- )
  | ctx state params |  1.0 state StVState.gate-p f!64  drop2 drop ;
dsp: st-voice-off ( ctx state params -- )
  | ctx state params |  0.0 state StVState.gate-p f!64  drop2 drop ;

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
