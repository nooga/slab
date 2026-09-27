( env_rc.fy - the analog envelope: a capacitor chasing a target.

  State is the level and the stage, never the time since the note, so
  nothing ever jumps.  A retrigger attacks from wherever the level is, and
  a release falls from wherever it is, even mid-attack.  [An age-based
  ADSR restarts at zero on retrigger and snaps to the sustain level on an
  early release: both are clicks.]

    attack   level -> 1.2, until it crosses 1    [the overshoot target of
                                                  a real EG: a sharper knee]
    decay    level -> sustain
    release  level -> 0

  In front of the stages sits a gate with a timer, the MS-20's two extra
  controls: DELAY [EG1] holds a key-down back before the attack starts,
  HOLD [EG2] keeps the gate open for a while after the key is up.  A
  key-down arms the gate after `delay`, a key-up closes it after `hold`;
  the stages only ever see the gate.

  Times are the knob values: the attack reaches 1 in `atk` seconds; decay
  and release cover 99% of their distance in theirs.  Coefficients are
  per-block work [env-rc-coefs]; the step is one multiply-add and a few
  selects. )

include "../../00-primitives/math.fy"

ustruct: EnvRc
  f64 level
  f64 stage    ( 0 release, 1 attack, 2 decay/sustain )
  f64 gate     ( the key: 1 down, 0 up )
  f64 timer    ( seconds until the key reaches the stages )
;

ustruct: EnvRcCoefs
  f64 ca   f64 cd   f64 sus   f64 cr
  f64 delay    ( key-down -> attack, seconds )
  f64 hold     ( key-up -> release, seconds )
  f64 dt       ( one sample, seconds )
;

( t inv-sr k -- c : per-sample coefficient covering k time constants in t. )
dsp: env-rc-coef | t inv-sr k -- c |
  1.0  k -1.0 f* inv-sr f*  t 0.0002 fmax f/  exp  f-
;

( co atk dec sus rel delay hold inv-sr -- : a block's coefficients.
  ln 6 = 1.7918: from 0 toward 1.2, the level crosses 1 after ln[1.2/0.2]
  time constants. )
dsp: env-rc-coefs | co:EnvRcCoefs atk dec sus rel delay hold inv-sr -- |
  atk inv-sr 1.791759469228055 env-rc-coef -> co.ca
  dec inv-sr 4.605170185988091 env-rc-coef -> co.cd
  sus -> co.sus
  rel inv-sr 4.605170185988091 env-rc-coef -> co.cr
  delay -> co.delay
  hold -> co.hold
  inv-sr -> co.dt
;

( e co legato -- : key down, unless the note is legato [ctx.legato 1].
  The stages drop to release until the delay runs out, so a retrigger
  restarts the attack from the current level. )
dsp: env-rc-trigger | e:EnvRc co:EnvRcCoefs legato -- |
  legato 0.5 f< | fresh |
  fresh 1.0 e.gate select -> e.gate
  fresh co.delay e.timer select -> e.timer
  fresh 0.0 e.stage select -> e.stage
;

( e -- gate : the key as the stages see it, 1 or 0 [a GATE-mode VCA]. )
dsp: env-rc-gate | e:EnvRc -- g |
  e.stage 0.5 f>  1.0 0.0 select
;

( e co -- : key up: the gate closes after the hold time. )
dsp: env-rc-release | e:EnvRc co:EnvRcCoefs -- |
  0.0 -> e.gate
  co.hold -> e.timer
;

( e co -- level : one sample. )
dsp: env-rc-step | e:EnvRc co:EnvRcCoefs -- y |
  ( the gate reaches the stages once its timer runs out )
  e.timer co.dt f- | tm |
  tm -> e.timer
  tm 0.0 f<= | due |
  e.gate 0.5 f> | down |
  e.stage | st0 |
  due down and  st0 0.5 f< and  1.0
    due down not and  0.0  st0  select  select | st |
  e.level | l |
  st 0.5 f<  0.0  st 1.5 f<  1.2  co.sus  select  select | tgt |
  st 0.5 f<  co.cr  st 1.5 f<  co.ca  co.cd  select  select | c |
  l  tgt l f- c f*  f+ | n |
  ( an attack that crosses 1 hands over to the decay )
  st 0.5 f>  st 1.5 f< and  n 1.0 f>= and | top |
  top 2.0 st select -> e.stage
  top 1.0 n select | y |
  y -> e.level
  y
;
