( stereo_swap.fy - fixture: a true-stereo effect [manifest `stereo`] that
  swaps channels, which a dual-mono pass could not do. )

include "../../kernels/00-primitives/ctx.fy"

ustruct: StSState  f64 dummy ;
ustruct: StSParams f64 dummy ;

dsp: st-swap-render | io:Io ctx state params -- |
  io.in-r -> io.out-l
  io.in-l -> io.out-r
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
