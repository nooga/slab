( silence.fy - raw DSP2 fixture machine that always writes silence. )

ustruct: RawSilenceState
  f64 dummy
;

ustruct: RawSilenceParams
  f64 dummy
;

( out state params -- : write one silent mono sample. )
dsp: raw-silence-render
  | out state params |
  0.0
  out
  f!64
  drop2 drop
;

include "../lib/manifest.fy"

: manifest
  "raw-silence" voice-sample machine*
  "raw-silence-render" render!
  RawSilenceState.size  state-size!
  RawSilenceParams.size params-size!
  machine-desc
;
