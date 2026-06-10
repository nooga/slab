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
dsp2: snare-prepare
  | state params sr |
  1.0 sr f/
  params SnareParams.inv-sample-rate-p f!64
  params SnareParams.body-decay@ sr decay-exp-coeff
  params SnareParams.body-coeff-p f!64
  params SnareParams.snap-decay@ sr decay-exp-coeff
  params SnareParams.snap-coeff-p f!64
  params SnareParams.snap-hz@ sr svf2-coeff
  params SnareParams.svf-f-p f!64
  0.02 sr decay-exp-coeff
  params SnareParams.pitch-coeff-p f!64
  drop2 drop
;

( state params gate velocity -- : fire the snare when gate is 1. )
dsp2: snare-trigger
  | state params gate velocity |
  0.5 gate  velocity 0.0 1.0 fclamp  state SnareState.vel@  fsel-lt
  state SnareState.vel-p f!64
  0.5 gate 1.0 state SnareState.body-env@ fsel-lt state SnareState.body-env-p f!64
  0.5 gate 1.0 state SnareState.snap-env@ fsel-lt state SnareState.snap-env-p f!64
  0.5 gate 0.0  state SnareState.phase1@ fsel-lt state SnareState.phase1-p f!64
  0.5 gate 0.31 state SnareState.phase2@ fsel-lt state SnareState.phase2-p f!64
  0.5 gate 0.7654321 state SnareState.noise-rng@ fsel-lt state SnareState.noise-rng-p f!64
  0.5 gate 1.0 state SnareState.pitch-env@ fsel-lt state SnareState.pitch-env-p f!64
  drop2 drop2
;

( state params -- : shell - two pitch-pulsed sine modes -> mix. The
  upper mode rides the body env SQUARED - half the decay time - so the
  pair thumps instead of ringing like a bell. )
dsp2: snare-shell-write
  | state params |
  state SnareState.pitch-env-p params SnareParams.pitch-coeff@ decay-exp-step
  | penv |
  params SnareParams.tune-hz@  1.0 1.4 penv f* f+  f*
  params SnareParams.inv-sample-rate@ f*
  | dt |
  state SnareState.phase1@ dt f+ ffrac
  dup state SnareState.phase1-p f!64
  sine-shape
  | p1 |
  state SnareState.phase2@ dt 1.83 f* f+ ffrac
  dup state SnareState.phase2-p f!64
  sine-shape
  | p2 |
  state SnareState.body-env-p params SnareParams.body-coeff@ decay-exp-step
  | benv |
  p1 benv f*
  p2 benv benv f* f* 0.5 f*
  f+ 0.85 f*
  state SnareState.mix-p f!64
  drop2 drop2 drop2 drop
;

( state params -- : wires - high-passed noise * snap env, added to mix. )
dsp2: snare-snap-write
  | state params |
  state SnareState.mix@
  state SnareState.svf-lp-p
  state SnareState.noise-rng-p noise-step
  params SnareParams.svf-f@
  1.3
  svf2-hp-step
  state SnareState.snap-env-p params SnareParams.snap-coeff@ decay-exp-step
  f*
  params SnareParams.snap-level@ f*
  f+
  state SnareState.mix-p f!64
  drop2
;

( out state params -- : drive the mix and accumulate into out. )
dsp2: snare-accum
  | out state params |
  out f@64
  state SnareState.mix@
  state SnareState.vel@ f*
  1.4 f*
  k-tanh-rational-shape-dsp2
  params SnareParams.level@ f*
  f+
  out f!64
  drop2 drop
;

( out state params -- : one mono snare sample, staged composition. )
dsp2: k-snare-render
  | out state params |
  state params call: snare-shell-write
  state params call: snare-snap-write
  out state params call: snare-accum
;
