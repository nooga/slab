( clap.fy - the classic analog clap: band-passed noise through a
  retrigger envelope - three fast restarts about a SPREAD apart, the
  burst decaying quickly between restarts, then a longer tail. All
  branchless: the repeat machinery is fsel-selected state updates.

  The envelope machinery advances ClapState.env and returns it; the body
  filters noise under it and drives the clipper. Probe case:
  drum-clap-render. )

include "decay.fy"
include "noise.fy"
include "svf2.fy"
include "../02-shapers/rational.fy"   ( tanh-rational )

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
  | state params:ClapParams sr |
  1.0 sr f/
  -> params.inv-sample-rate
  0.025 sr decay-exp-coeff
  -> params.burst-coeff
  params.decay-s sr decay-exp-coeff
  -> params.tail-coeff
  params.tone-hz sr svf2-coeff
  -> params.svf-f
  1.0  params.spread-s 0.003 0.05 fclamp sr f*  f/
  -> params.spread-inc
;

( state params gate velocity -- : fire the clap when gate is 1. )
dsp: clap-trigger
  | state:ClapState params gate velocity |
  0.5 gate  velocity 0.0 1.0 fclamp  state.vel  fsel-lt
  -> state.vel
  0.5 gate 1.0 state.env fsel-lt -> state.env
  0.5 gate 0.0 state.repeat-phase fsel-lt -> state.repeat-phase
  0.5 gate 3.0 state.repeats-left fsel-lt -> state.repeats-left
  0.5 gate 0.5551212 state.noise-rng fsel-lt -> state.noise-rng
;

( Advance the retrigger envelope machinery; returns the new env. )
dsp: clap-env | state:ClapState params:ClapParams -- env |
  state.repeat-phase params.spread-inc f+
  | rp |
  state.repeats-left
  | reps |
  ( retrig fires when the spread interval elapses and repeats remain )
  rp 1.0
  0.0
  0.5 reps 1.0 0.0 fsel-lt
  fsel-lt
  | trig |
  ( burst decay while repeats remain, tail decay after )
  0.5 reps params.burst-coeff params.tail-coeff fsel-lt
  | coeff |
  rp trig f- -> state.repeat-phase
  reps trig f- -> state.repeats-left
  trig 0.5  state.env coeff f*  1.0  fsel-lt
  dup -> state.env
;

( Band-passed noise * env, driven through the clipper. )
dsp: clap-body | state:ClapState params:ClapParams env -- y |
  state.svf-lp&
  state.noise-rng& noise-step
  params.svf-f
  0.7
  svf2-bp-step
  env f*
  2.2 f*
  state.vel f*
  tanh-rational
  params.level f*
;

( One mono clap sample. )
dsp: clap-voice | state params -- y |
  state params  state params clap-env  clap-body
;

( out state params -- : one mono clap sample, accumulated into out. )
dsp: k-clap-render | out state params -- |
  out f@64
  state params clap-voice
  f+
  out f!64
;
