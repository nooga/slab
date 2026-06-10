( kick.fy - analog-model kick voice: sine body with a fast exponential
  pitch sweep, exponential amp decay, a noise click transient, and drive
  into the rational-tanh clipper.

  The SWEEP / DECAY / CLICK / DRIVE axes are the 808-to-909 character
  space: shallow slow sweep + low drive ~ 808 boom; deep fast sweep +
  click + drive ~ 909 punch. Probe case: drum-kick-render - three hits,
  WAV + lane CSV + ratcheted stats. )

include "sine.fy"
include "decay.fy"
include "../02-shapers/tanh_table.fy"

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
dsp2: kick-prepare
  | state params sr |
  1.0 sr f/
  params KickParams.inv-sample-rate-p f!64
  params KickParams.decay-s@ sr decay-exp-coeff
  params KickParams.amp-coeff-p f!64
  params KickParams.sweep-time@ sr decay-exp-coeff
  params KickParams.pitch-coeff-p f!64
  0.0015 sr decay-exp-coeff
  params KickParams.click-coeff-p f!64
  drop2 drop
;

( state params velocity -- : fire the kick. )
dsp2: kick-trigger
  | state params velocity |
  velocity 0.0 1.0 fclamp
  state KickState.vel-p f!64
  1.0 state KickState.amp-env-p f!64
  1.0 state KickState.pitch-env-p f!64
  1.0 state KickState.click-env-p f!64
  0.0 state KickState.phase-p f!64
  0.1234567 state KickState.noise-rng-p f!64
  drop2 drop
;

( state -- value : float-LCG white-ish noise in -1..1, advancing rng state. )
dsp2: kick-noise-raw
  | state |
  state KickState.noise-rng@
  1103515245.0 f*
  0.31337 f+
  ffrac
  dup
  state KickState.noise-rng-p
  f!64
  2.0 f* 1.0 f-
  nip
;

( state params -- value : one kick sample. )
dsp2: kick-body
  | state params |
  ( pitch envelope -> instantaneous frequency -> phase advance )
  state KickState.pitch-env-p params KickParams.pitch-coeff@ decay-exp-step
  | penv |
  params KickParams.tune-hz@
  1.0  params KickParams.sweep-amount@ penv f*  f+
  f*
  params KickParams.inv-sample-rate@ f*
  state KickState.phase@ f+ ffrac
  dup state KickState.phase-p f!64
  sine-shape
  | body |
  state KickState.amp-env-p params KickParams.amp-coeff@ decay-exp-step
  | aenv |
  state KickState.click-env-p params KickParams.click-coeff@ decay-exp-step
  | cenv |
  body aenv f*
  state kick-noise-raw cenv f* params KickParams.click-level@ f* f+
  state KickState.vel@ f*
  params KickParams.drive@ f*
  k-tanh-rational-shape-dsp2
  params KickParams.level@ f*
  nip nip nip nip nip nip
;

( out state params -- : raw render entry, one mono sample per call. )
dsp2: k-kick-render
  | out state params |
  state params kick-body
  out f!64
  drop2 drop
;
