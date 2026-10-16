( shared_body.fy - fixture: voices acting on one shared region
  [manifest `shared-size!` / `shared!`, docs/04 §Shared state].

  Every held voice adds its velocity to the shared drive each sample.  The
  shared word is a leaky body: it adds the drive to its level, outputs the
  level and decays it by half each step, then clears the drive.  A voice
  also reads the body's level into its own state, so the test can see
  that voices observe what the shared word left after the previous step. )

include "../../kernels/00-primitives/ctx.fy"

ustruct: ShVState  f64 gate  f64 vel  f64 seen ;
ustruct: ShVParams f64 dummy ;
ustruct: ShBody    f64 drive  f64 level ;

dsp: sh-voice-render | io ctx:Ctx state:ShVState params -- |
  ctx.shared& p@64 | sh:ShBody |
  sh.level -> state.seen
  sh.drive  state.gate state.vel f* f+  -> sh.drive
;

dsp: sh-voice-on
  | ctx:Ctx state:ShVState params -- |  1.0 -> state.gate  ctx.vel -> state.vel ;
dsp: sh-voice-off
  | ctx state:ShVState params -- |  0.0 -> state.gate ;

dsp: sh-body-render | io:Io ctx body:ShBody params -- |
  body.level body.drive f+ | y |
  io.out-l y f+ -> io.out-l
  y 0.5 f* -> body.level
  0.0 -> body.drive
;

include "../lib/manifest.fy"

: manifest
  "raw-shared-body" voice-sample machine*
  "sh-voice-render" render!
  "sh-voice-on" note-on!
  "sh-voice-off" note-off!
  4 voices!
  ShVState.size  state-size!
  ShVParams.size params-size!
  ShBody.size shared-size!
  "sh-body-render" 1 shared!
  machine-desc
;
