( shared_clock.fy - fixture: a shared word that branches on ctx.clock, and
  voices heard only through it that report their level with voice-level!
  [docs/04 §Shared state].

  Each held voice adds its gate to the shared drive.  The shared word
  outputs the drive on odd samples of the host clock and nothing on even
  ones, so its output shows where each step falls.  A voice makes no sound
  itself: its level is 1 while held and decays by 0.9 a sample after the
  release, and that field alone keeps it awake. )

include "../../kernels/00-primitives/ctx.fy"

ustruct: SkVState  f64 gate  f64 lvl ;
ustruct: SkVParams f64 dummy ;
ustruct: SkBody    f64 drive ;

dsp: sk-voice-render | io ctx:Ctx state:SkVState params -- |
  ctx.shared& p@64 | sk:SkBody |
  state.gate 0.5 f>  1.0  state.lvl 0.9 f*  select -> state.lvl
  sk.drive state.gate f+ -> sk.drive
;

dsp: sk-voice-on
  | ctx state:SkVState params -- |  1.0 -> state.gate  1.0 -> state.lvl ;
dsp: sk-voice-off
  | ctx state:SkVState params -- |  0.0 -> state.gate ;

dsp: sk-body-render | io:Io ctx:Ctx body:SkBody params -- |
  ctx.clock 0.5 f* dup floor f- 0.25 f> [ body.drive ] [ 0.0 ] ifte | y |
  io.out-l y f+ -> io.out-l
  0.0 -> body.drive
;

include "../lib/manifest.fy"

: manifest
  "raw-shared-clock" voice-sample machine*
  "sk-voice-render" render!
  "sk-voice-on" note-on!
  "sk-voice-off" note-off!
  4 voices!
  SkVState.size  state-size!
  SkVParams.size params-size!
  SkBody.size shared-size!
  "sk-body-render" 1 shared!
  SkVState.lvl voice-level!
  machine-desc
;
