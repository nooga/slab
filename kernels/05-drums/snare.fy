( snare.fy - analog-model snare after the 909/808 recipe: two sine
  partials at ~1x / 1.83x for the shell modes, the upper partial with
  its OWN faster decay - one shared envelope on a static inharmonic
  pair rings like a gong - plus a short pitch pulse at the hit, plus
  high-passed noise with a separate snappy decay. TONE-vs-SNAP balance
  and the snap HP cutoff are the character axes.

  The voice will not fit one straight-line dsp2 word, so it is staged:
  shell and snap write into the SnareState.mix scratch, the accum stage
  drives the sum into out. k-snare-render composes them with call:
  boundaries - fresh registers per stage. Probe: drum-snare-render. )

include "sine.fy"
include "decay.fy"
include "noise.fy"
include "svf2.fy"
include "../02-shapers/tanh_table.fy"

ustruct: SnareState
  f64 phase1
  f64 phase2
  f64 body-env
  f64 snap-env
  f64 noise-rng
  f64 svf-lp        ( Svf2State region - lp/bp adjacent, passed as base )
  f64 svf-bp
  f64 vel
  f64 mix           ( stage scratch: shell + snap sum )
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

( state params -- : shell - two pitch-pulsed sine modes -> mix. The
  upper mode rides the body env SQUARED - half the decay time - so the
  pair thumps instead of ringing like a bell. )
dsp: snare-shell-write
  | state:SnareState params:SnareParams |
  state.pitch-env& params.pitch-coeff decay-exp-step
  | penv |
  params.tune-hz  1.0 1.4 penv f* f+  f*
  params.inv-sample-rate f*
  | dt |
  state.phase1 dt f+ ffrac
  dup -> state.phase1
  sine-shape
  | p1 |
  state.phase2 dt 1.83 f* f+ ffrac
  dup -> state.phase2
  sine-shape
  | p2 |
  state.body-env& params.body-coeff decay-exp-step
  | benv |
  p1 benv f*
  p2 benv benv f* f* 0.5 f*
  f+ 0.85 f*
  -> state.mix
;

( state params -- : wires - high-passed noise * snap env, added to mix. )
dsp: snare-snap-write
  | state:SnareState params:SnareParams |
  state.mix
  state.svf-lp&
  state.noise-rng& noise-step
  params.svf-f
  1.3
  svf2-hp-step
  state.snap-env& params.snap-coeff decay-exp-step
  f*
  params.snap-level f*
  f+
  -> state.mix
;

( out state params -- : drive the mix and accumulate into out. )
dsp: snare-accum
  | out state:SnareState params:SnareParams |
  out f@64
  state.mix
  state.vel f*
  1.4 f*
  k-tanh-rational-shape-dsp2
  params.level f*
  f+
  out f!64
;

( out state params -- : one mono snare sample, staged composition. )
dsp: k-snare-render
  | out state params |
  state params call: snare-shell-write
  state params call: snare-snap-write
  out state params call: snare-accum
;
