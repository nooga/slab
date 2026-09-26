( oscillator.fy - raw DSP2 fixture machine with one note-controlled saw. )

include "../../kernels/00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../../kernels/01-oscillators/primitives/phase.fy"
ustruct: RawOscState
  f64 phase
;

ustruct: RawOscParams
  f64 note-hz
  f64 amp
  f64 inv-sample-rate
;

( ctx state params -- : update block-rate derived params. )
dsp: raw-osc-prepare
  | ctx:Ctx state params:RawOscParams |
  ctx.sr | sample-rate |
  1.0
  sample-rate
  f/
  -> params.inv-sample-rate
;

( ctx state params -- : start a note and reset phase. )
dsp: raw-osc-note-on
  | ctx:Ctx state:RawOscState params:RawOscParams |
  ctx.hz ctx.vel | hz velocity |
  hz
  -> params.note-hz
  velocity
  -> params.amp
  0.0
  -> state.phase
;

( ctx state params -- : stop the note immediately. )
dsp: raw-osc-note-off
  | ctx state params:RawOscParams |
  0.0
  -> params.amp
;

( io ctx state params -- : render one mono saw sample. )
dsp: raw-osc-render
  | out ctx state:RawOscState params:RawOscParams |
  state.phase
  params.note-hz
  params.inv-sample-rate
  f*
  f+
  wrap01
  | phase |
  phase
  -> state.phase
  phase
  2.0
  f*
  1.0
  f-
  params.amp
  f*
  out
  f!64
;

include "../lib/manifest.fy"

: manifest
  "raw-osc" voice-sample machine*
  "raw-osc-render"   render!
  "raw-osc-prepare"  prepare!
  "raw-osc-note-on"  note-on!
  "raw-osc-note-off" note-off!
  RawOscState.size  state-size!
  RawOscParams.size params-size!
  machine-desc
;
