( env_dig.fy - the digital envelope: AHDSR that lands exactly.

  A softsynth envelope, the counterpart of env_rc.fy's capacitor:

    attack   a straight line from the current level up to 1
    hold     1, for `hold` seconds
    decay    exponential toward sustain
    release  exponential toward 0

  Decay and release chase a target a little past where they stop
  [ENV-D-UNDER under it] and clamp there, so they arrive in finite time
  instead of approaching forever: a released voice reaches true zero and
  the host can put it to sleep, and a decay to 0 sustain goes silent.
  They cover 99% of their distance in the knob time and land at about
  1.5x it.

  A retrigger attacks from the current level, so a voice that is still
  sounding doesn't click back to 0.  The step can run per sample or at a
  control rate: the coefficients take the step length in seconds. )

include "../../00-primitives/math.fy"

:: ENV-D-UNDER 0.001 ;

ustruct: EnvD
  f64 level
  f64 stage    ( 0 release, 1 attack, 2 hold, 3 decay/sustain )
  f64 hold     ( steps left in the hold stage )
;

ustruct: EnvDCoefs
  f64 ainc     ( attack: level per step )
  f64 hold     ( hold: steps )
  f64 cd       ( decay: fraction of the distance per step )
  f64 sus
  f64 cr       ( release: fraction of the distance per step )
;

( t dt -- c : per-step coefficient covering 99% of the distance in t. )
dsp: env-d-coef | t dt -- c |
  1.0  -4.605170185988091 dt f*  t 0.0002 fmax f/  exp  f-
;

( co atk hold dec sus rel dt -- : coefficients for steps of dt seconds. )
dsp: env-d-coefs | co:EnvDCoefs atk hold dec sus rel dt -- |
  dt  atk 0.00005 fmax  f/  1.0 fmin -> co.ainc
  hold dt f/ -> co.hold
  dec dt env-d-coef -> co.cd
  sus -> co.sus
  rel dt env-d-coef -> co.cr
;

( e co legato -- : key down, unless the note is legato [ctx.legato 1]. )
dsp: env-d-trigger | e:EnvD co:EnvDCoefs legato -- |
  legato 0.5 f< | fresh |
  fresh 1.0 e.stage select -> e.stage
  fresh co.hold e.hold select -> e.hold
;

( e -- : key up. )
dsp: env-d-release | e:EnvD -- |
  0.0 -> e.stage
;

( e co -- level : one step. )
dsp: env-d-step | e:EnvD co:EnvDCoefs -- y |
  e.level | l |
  e.stage | st |
  e.hold 1.0 f- | h |
  ( attack: up a line, into hold at the top )
  l co.ainc f+ | na |
  na 1.0 f>= | top |
  ( decay and release: past the target, clamped at it )
  co.sus ENV-D-UNDER f- l f-  co.cd f*  l f+  co.sus fmax | nd |
  ENV-D-UNDER fneg l f-  co.cr f*  l f+  0.0 fmax | nr |
  st 0.5 f< | rel |
  st 1.5 f< | atk |
  st 2.5 f< | hld |
  rel  nr  atk  na 1.0 fmin  hld  1.0  nd  select  select  select | y |
  rel  0.0  atk  top 2.0 1.0 select  hld  h 0.0 f<= 3.0 2.0 select  3.0  select  select  select -> e.stage
  atk not hld and  h  e.hold  select -> e.hold
  y -> e.level
  y
;
