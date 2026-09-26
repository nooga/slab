( stereo_swap.fy - fixture: a true-stereo effect [manifest `stereo`] that
  swaps channels, which a dual-mono pass could not do. )

include "../../kernels/00-primitives/ctx.fy"

ustruct: StSState  f64 dummy ;
ustruct: StSParams f64 dummy ;

dsp: st-swap-render ( io ctx state params -- )
  | io ctx state params |
  io Io.in-r@ io Io.out-l-p f!64
  io Io.in-l@ io Io.out-r-p f!64
  drop2 drop2
;

include "../lib/manifest.fy"

: manifest
  "raw-stereo-swap" effect-block machine*
  "st-swap-render" render!
  stereo
  StSState.size  state-size!
  StSParams.size params-size!
  machine-desc
;
