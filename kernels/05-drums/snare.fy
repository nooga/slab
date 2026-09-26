( snare.fy - analog-model snare after the 909/808 recipe: two sine
  partials at ~1x / 1.83x for the shell modes, the upper partial with
  its OWN faster decay - one shared envelope on a static inharmonic
  pair rings like a gong - plus a short pitch pulse at the hit, plus
  high-passed noise with a separate snappy decay. TONE-vs-SNAP balance
  and the snap HP cutoff are the character axes.

  shell, snap and drive are value-returning words inlined into one
  snare-voice word. Probe: drum-snare-render. )

include "../00-primitives/math.fy"
include "decay.fy"
include "noise.fy"
include "svf2.fy"
include "../02-shapers/rational.fy"   ( tanh-rational )

ustruct: SnareState
  f64 phase1
  f64 phase2
  f64 body-env
  f64 snap-env
  f64 noise-rng
  f64 svf-lp        ( Svf2State region - lp/bp adjacent, passed as base )
  f64 svf-bp
  f64 vel
  f64 pitch-env     ( short 909-style pitch pulse at the hit )
;

ustruct: SnareParams
  ( user-facing )
  f64 tune-hz       ( fundamental, ~120..400; second mode at 1.83x )
  f64 body-decay    ( shell decay -60 dB time, s )
  f64 snap-level    ( wires amount, 0..1 )
  f64 snap-decay    ( wires decay -60 dB time, s )
  f64 snap-hz       ( noise high-pass cutoff )
  f64 level
  ( derived - filled by snare-prepare )
  f64 inv-sample-rate
  f64 body-coeff
  f64 snap-coeff
  f64 svf-f
  f64 pitch-coeff   ( fixed ~20 ms pitch-pulse decay )
;

( state params sample-rate -- : block-rate coefficient fill. )
dsp: snare-prepare
  | state params:SnareParams sr |
  1.0 sr f/
  -> params.inv-sample-rate
  params.body-decay sr decay-exp-coeff
  -> params.body-coeff
  params.snap-decay sr decay-exp-coeff
  -> params.snap-coeff
  params.snap-hz sr svf2-coeff
  -> params.svf-f
  0.02 sr decay-exp-coeff
  -> params.pitch-coeff
;

( state params gate velocity -- : fire the snare when gate is 1. )
dsp: snare-trigger
  | state:SnareState params gate velocity |
  0.5 gate  velocity 0.0 1.0 fclamp  state.vel  fsel-lt
  -> state.vel
  0.5 gate 1.0 state.body-env fsel-lt -> state.body-env
  0.5 gate 1.0 state.snap-env fsel-lt -> state.snap-env
  0.5 gate 0.0  state.phase1 fsel-lt -> state.phase1
  0.5 gate 0.31 state.phase2 fsel-lt -> state.phase2
  0.5 gate 0.7654321 state.noise-rng fsel-lt -> state.noise-rng
  0.5 gate 1.0 state.pitch-env fsel-lt -> state.pitch-env
;

( Shell - two pitch-pulsed sine modes. The upper mode rides the body
  env SQUARED - half the decay time - so the pair thumps instead of
  ringing like a bell. )
dsp: snare-shell | state:SnareState params:SnareParams -- shell |
  state.pitch-env& params.pitch-coeff decay-exp-step
  | penv |
  params.tune-hz  1.0 1.4 penv f* f+  f*
  params.inv-sample-rate f*
  | dt |
  state.phase1 dt f+ ffrac
  dup -> state.phase1
  sin2pi
  | p1 |
  state.phase2 dt 1.83 f* f+ ffrac
  dup -> state.phase2
  sin2pi
  | p2 |
  state.body-env& params.body-coeff decay-exp-step
  | benv |
  p1 benv f*
  p2 benv benv f* f* 0.5 f*
  f+ 0.85 f*
;

( Wires - high-passed noise * snap env, added to the shell. )
dsp: snare-snap | state:SnareState params:SnareParams shell -- mix |
  shell
  state.svf-lp&
  state.noise-rng& noise-step
  params.svf-f
  1.3
  svf2-hp-step
  state.snap-env& params.snap-coeff decay-exp-step
  f*
  params.snap-level f*
  f+
;

( Velocity + fixed drive into the clipper, then level. )
dsp: snare-drive | state:SnareState params:SnareParams mix -- y |
  mix
  state.vel f*
  1.4 f*
  tanh-rational
  params.level f*
;

( One mono snare sample. )
dsp: snare-voice | state params -- y |
  state params  state params  state params snare-shell  snare-snap  snare-drive
;

( out state params -- : one mono snare sample, accumulated into out. )
dsp: k-snare-render | out state params -- |
  out f@64
  state params snare-voice
  f+
  out f!64
;
