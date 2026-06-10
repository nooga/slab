( saturator.fy - raw DSP2 fixture effect with a rational tanh shaper. )

ustruct: RawSatState
  f64 dummy
;

ustruct: RawSatParams
  f64 drive
;

( state params sample-rate -- : initialize a visible drive amount. )
dsp2: raw-sat-prepare
  | state params sample-rate |
  1.35
  params RawSatParams.drive-p
  f!64
  drop2 drop
;

( out state params input-ptr -- : shape one mono sample from an input stream. )
dsp2: raw-sat-render
  | out state params input |
  input
  f@64
  params RawSatParams.drive@
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
  drop
  drop
  drop2 drop2
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
