( clap.fy - the classic analog clap: band-passed noise through a
  retrigger envelope - three fast restarts about a SPREAD apart, the
  burst decaying quickly between restarts, then a longer tail. All
  branchless: the repeat machinery is fsel-selected state updates.

  Staged like the snare: the envelope machinery writes ClapState.env,
  the accum stage filters noise and drives into out. Probe case:
  drum-clap-render. )

include "decay.fy"
include "noise.fy"
include "svf2.fy"
include "../02-shapers/tanh_table.fy"

ustruct: ClapState
  f64 env
  f64 repeat-phase  ( 0..1 within one spread interval )
  f64 repeats-left
  f64 noise-rng
  f64 svf-lp        ( Svf2State region )
  f64 svf-bp
  f64 vel
;

ustruct: ClapParams
  ( user-facing )
  f64 tone-hz       ( band-pass center )
  f64 spread-s      ( repeat spacing, s )
  f64 decay-s       ( tail decay -60 dB time, s )
  f64 level
  ( derived - filled by clap-prepare )
  f64 inv-sample-rate
  f64 burst-coeff   ( fast decay between repeats, fixed 25 ms )
  f64 tail-coeff
  f64 svf-f
  f64 spread-inc    ( repeat-phase increment per sample )
;

( state params sample-rate -- : block-rate coefficient fill. )
dsp: clap-prepare
  | state params sr |
  1.0 sr f/
  params ClapParams.inv-sample-rate-p f!64
  0.025 sr decay-exp-coeff
  params ClapParams.burst-coeff-p f!64
  params ClapParams.decay-s@ sr decay-exp-coeff
  params ClapParams.tail-coeff-p f!64
  params ClapParams.tone-hz@ sr svf2-coeff
  params ClapParams.svf-f-p f!64
  1.0  params ClapParams.spread-s@ 0.003 0.05 fclamp sr f*  f/
  params ClapParams.spread-inc-p f!64
  drop2 drop
;

( state params gate velocity -- : fire the clap when gate is 1. )
dsp: clap-trigger
  | state params gate velocity |
  0.5 gate  velocity 0.0 1.0 fclamp  state ClapState.vel@  fsel-lt
  state ClapState.vel-p f!64
  0.5 gate 1.0 state ClapState.env@ fsel-lt state ClapState.env-p f!64
  0.5 gate 0.0 state ClapState.repeat-phase@ fsel-lt state ClapState.repeat-phase-p f!64
  0.5 gate 3.0 state ClapState.repeats-left@ fsel-lt state ClapState.repeats-left-p f!64
  0.5 gate 0.5551212 state ClapState.noise-rng@ fsel-lt state ClapState.noise-rng-p f!64
  drop2 drop2
;

( state params -- : advance the retrigger envelope machinery in place. )
dsp: clap-env-write
  | state params |
  state ClapState.repeat-phase@ params ClapParams.spread-inc@ f+
  | rp |
  state ClapState.repeats-left@
  | reps |
  ( retrig fires when the spread interval elapses and repeats remain )
  rp 1.0
  0.0
  0.5 reps 1.0 0.0 fsel-lt
  fsel-lt
  | trig |
  ( burst decay while repeats remain, tail decay after )
  0.5 reps params ClapParams.burst-coeff@ params ClapParams.tail-coeff@ fsel-lt
  | coeff |
  trig 0.5  state ClapState.env@ coeff f*  1.0  fsel-lt
  state ClapState.env-p f!64
  rp trig f- state ClapState.repeat-phase-p f!64
  reps trig f- state ClapState.repeats-left-p f!64
  drop2 drop2 drop2
;

( out state params -- : band-passed noise * env, driven into out. )
dsp: clap-accum
  | out state params |
  out f@64
  state ClapState.svf-lp-p
  state ClapState.noise-rng-p noise-step
  params ClapParams.svf-f@
  0.7
  svf2-bp-step
  state ClapState.env@ f*
  2.2 f*
  state ClapState.vel@ f*
  k-tanh-rational-shape-dsp2
  params ClapParams.level@ f*
  f+
  out f!64
  drop2 drop
;

( out state params -- : one mono clap sample, staged composition. )
dsp: k-clap-render
  | out state params |
  state params call: clap-env-write
  out state params call: clap-accum
;
