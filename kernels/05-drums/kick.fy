( kick.fy - analog-model kick voice: sine body with a fast exponential
  pitch sweep, exponential amp decay, a noise click transient, and drive
  into the rational-tanh clipper.

  The SWEEP / DECAY / CLICK / DRIVE axes are the 808-to-909 character
  space: shallow slow sweep + low drive ~ 808 boom; deep fast sweep +
  click + drive ~ 909 punch. Probe case: drum-kick-render - three hits,
  WAV + lane CSV + ratcheted stats. )

include "sine.fy"
include "decay.fy"
include "noise.fy"
include "../02-shapers/tanh_table.fy"

ustruct: KickState
  f64 phase
  f64 amp-env
  f64 pitch-env
  f64 click-env
  f64 noise-rng
  f64 vel
  f64 mix           ( stage scratch: swept sine body )
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
  | state params sr |
  1.0 sr f/
  params KickParams.inv-sample-rate-p f!64
  params KickParams.decay-s@ sr decay-exp-coeff
  params KickParams.amp-coeff-p f!64
  params KickParams.sweep-time@ sr decay-exp-coeff
  params KickParams.pitch-coeff-p f!64
  0.0015 sr decay-exp-coeff
  params KickParams.click-coeff-p f!64
;

( state params gate velocity -- : fire the kick when gate is 1; gate 0
  leaves the voice untouched. Branchless so a multi-slot note-on can call
  every slot's trigger with per-slot gates. )
dsp: kick-trigger
  | state params gate velocity |
  0.5 gate  velocity 0.0 1.0 fclamp  state KickState.vel@  fsel-lt
  state KickState.vel-p f!64
  0.5 gate 1.0 state KickState.amp-env@   fsel-lt state KickState.amp-env-p f!64
  0.5 gate 1.0 state KickState.pitch-env@ fsel-lt state KickState.pitch-env-p f!64
  0.5 gate 1.0 state KickState.click-env@ fsel-lt state KickState.click-env-p f!64
  0.5 gate 0.0 state KickState.phase@     fsel-lt state KickState.phase-p f!64
  0.5 gate 0.1234567 state KickState.noise-rng@ fsel-lt state KickState.noise-rng-p f!64
;

( state params -- : swept sine body -> mix scratch. )
dsp: kick-osc-write
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
  state KickState.mix-p f!64
;

( out state params -- : body * amp env + click, driven, into out. )
dsp: kick-accum
  | out state params |
  out f@64
  state KickState.mix@
  state KickState.amp-env-p params KickParams.amp-coeff@ decay-exp-step
  f*
  state KickState.click-env-p params KickParams.click-coeff@ decay-exp-step
  state KickState.noise-rng-p noise-step f*
  params KickParams.click-level@ f* f+
  state KickState.vel@ f*
  params KickParams.drive@ f*
  k-tanh-rational-shape-dsp2
  params KickParams.level@ f*
  f+
  out f!64
;

( out state params -- : one mono kick sample, staged composition. )
dsp: k-kick-render
  | out state params |
  state params call: kick-osc-write
  out state params call: kick-accum
;
