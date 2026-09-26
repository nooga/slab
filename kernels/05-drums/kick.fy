( kick.fy - analog-model kick voice: sine body with a fast exponential
  pitch sweep, exponential amp decay, a noise click transient, and drive
  into the rational-tanh clipper.

  The SWEEP / DECAY / CLICK / DRIVE axes are the 808-to-909 character
  space: shallow slow sweep + low drive ~ 808 boom; deep fast sweep +
  click + drive ~ 909 punch. Probe case: drum-kick-render - three hits,
  WAV + lane CSV + ratcheted stats. )

include "../00-primitives/math.fy"
include "decay.fy"
include "noise.fy"
include "../02-shapers/rational.fy"   ( tanh-rational )

ustruct: KickState
  f64 phase
  f64 amp-env
  f64 pitch-env
  f64 click-env
  f64 noise-rng
  f64 vel
;

ustruct: KickParams
  ( user-facing - written by controls / the probe )
  f64 tune-hz       ( body frequency at sweep end, ~30..120 Hz )
  f64 sweep-amount  ( peak hz = tune * 1+sweep-amount, 0..12 )
  f64 sweep-time    ( pitch envelope -60 dB time, s )
  f64 decay-s       ( amp envelope -60 dB time, s )
  f64 click-level   ( noise transient amount, 0..1 )
  f64 drive         ( pre-clipper gain, 0.5..6 )
  f64 level         ( post-clipper gain, 0..1 )
  ( derived - filled by kick-prepare )
  f64 inv-sample-rate
  f64 amp-coeff
  f64 pitch-coeff
  f64 click-coeff
;

( state params sample-rate -- : block-rate coefficient fill. )
dsp: kick-prepare
  | state params:KickParams sr |
  1.0 sr f/
  -> params.inv-sample-rate
  params.decay-s sr decay-exp-coeff
  -> params.amp-coeff
  params.sweep-time sr decay-exp-coeff
  -> params.pitch-coeff
  0.0015 sr decay-exp-coeff
  -> params.click-coeff
;

( state params gate velocity -- : fire the kick when gate is 1; gate 0
  leaves the voice untouched. Branchless so a multi-slot note-on can call
  every slot's trigger with per-slot gates. )
dsp: kick-trigger
  | state:KickState params gate velocity |
  0.5 gate  velocity 0.0 1.0 fclamp  state.vel  fsel-lt
  -> state.vel
  0.5 gate 1.0 state.amp-env   fsel-lt -> state.amp-env
  0.5 gate 1.0 state.pitch-env fsel-lt -> state.pitch-env
  0.5 gate 1.0 state.click-env fsel-lt -> state.click-env
  0.5 gate 0.0 state.phase     fsel-lt -> state.phase
  0.5 gate 0.1234567 state.noise-rng fsel-lt -> state.noise-rng
;

( Swept sine body: pitch envelope -> instantaneous frequency -> phase
  advance -> polynomial sine. )
dsp: kick-osc | state:KickState params:KickParams -- body |
  state.pitch-env& params.pitch-coeff decay-exp-step
  | penv |
  params.tune-hz
  1.0  params.sweep-amount penv f*  f+
  f*
  params.inv-sample-rate f*
  state.phase f+ ffrac
  dup -> state.phase
  sin2pi
;

( Body * amp env + click, velocity, driven through the clipper. )
dsp: kick-amp | state:KickState params:KickParams body -- y |
  body
  state.amp-env& params.amp-coeff decay-exp-step
  f*
  state.click-env& params.click-coeff decay-exp-step
  state.noise-rng& noise-step f*
  params.click-level f* f+
  state.vel f*
  params.drive f*
  tanh-rational
  params.level f*
;

( One mono kick sample. )
dsp: kick-voice | state params -- y |
  state params  state params kick-osc  kick-amp
;

( out state params -- : one mono kick sample, accumulated into out. )
dsp: k-kick-render | out state params -- |
  out f@64
  state params kick-voice
  f+
  out f!64
;
