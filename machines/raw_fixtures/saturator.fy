( saturator.fy - raw DSP2 fixture effect with a rational tanh shaper. )

include "../../kernels/00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
ustruct: RawSatState
  f64 dummy
;

ustruct: RawSatParams
  f64 drive
;

( ctx state params -- : initialize a visible drive amount. )
dsp: raw-sat-prepare
  | ctx:Ctx state params:RawSatParams |
  ctx.sr | sample-rate |
  1.35
  -> params.drive
;

( io ctx state params -- : shape one mono sample from an input stream. )
dsp: raw-sat-render
  | out:Io ctx state params:RawSatParams |
  out.in-l
  params.drive
  f*
  -4.0
  4.0
  fclamp
  | x |
  x
  x
  f*
  | x2 |
  x
  27.0
  x2
  f+
  f*
  27.0
  9.0
  x2
  f*
  f+
  f/
  -1.0
  1.0
  fclamp
  out
  f!64
;

include "../lib/manifest.fy"

: manifest
  "raw-sat" effect-block machine*
  "raw-sat-render"  render!
  "raw-sat-prepare" prepare!
  RawSatState.size  state-size!
  RawSatParams.size params-size!
  machine-desc
;
