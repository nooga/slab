( silence.fy - raw DSP2 fixture machine that always writes silence. )

ustruct: RawSilenceState
  f64 dummy
;

ustruct: RawSilenceParams
  f64 dummy
;

( out state params -- : write one silent mono sample. )
dsp2: raw-silence-render
  | out state params |
  0.0
  out
  f!64
  drop2 drop
;
