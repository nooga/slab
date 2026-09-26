( hat.fy - 808-family hi-hats: the six-square metallic core. Six naive
  square oscillators at the inharmonic schematic frequencies - 205.3,
  304.4, 369.6, 522.7, 540, 800 Hz - summed, band-passed, then
  high-passed. Closed and open hat share the one core through two
  envelopes; a closed-hat trigger CHOKES the open hat. The squares
  alias like the original clocked logic - that is part of the dirt.
  TUNE shifts the bank, TONE shifts both filters. Probe cases:
  drum-hat-render [CH] and drum-openhat-render [OH]. )

include "decay.fy"
include "svf2.fy"

ustruct: HatState
  f64 ph1
  f64 ph2
  f64 ph3
  f64 ph4
  f64 ph5
  f64 ph6
  f64 ch-env
  f64 oh-env
  f64 bp-lp         ( Svf2State region - band-pass )
  f64 bp-bp
  f64 hp-lp         ( Svf2State region - high-pass )
  f64 hp-bp
  f64 ch-vel
  f64 oh-vel
  f64 metal         ( stage scratch: filtered core )
;

ustruct: HatParams
  ( user-facing )
  f64 tune          ( oscillator bank multiplier, 0.6..1.8 )
  f64 tone          ( filter tuning multiplier, 0.6..1.6 )
  f64 ch-decay      ( closed hat -60 dB time, s )
  f64 oh-decay      ( open hat -60 dB time, s )
  f64 level
  ( derived - filled by hat-prepare )
  f64 dt1
  f64 dt2
  f64 dt3
  f64 dt4
  f64 dt5
  f64 dt6
  f64 ch-coeff
  f64 oh-coeff
  f64 bp-f
  f64 hp-f
;

( state params sample-rate -- : block-rate coefficient fill. )
dsp: hat-prepare
  | state params sr |
  1.0 sr f/
  | isr |
  205.3 params HatParams.tune@ f* isr f* params HatParams.dt1-p f!64
  304.4 params HatParams.tune@ f* isr f* params HatParams.dt2-p f!64
  369.6 params HatParams.tune@ f* isr f* params HatParams.dt3-p f!64
  522.7 params HatParams.tune@ f* isr f* params HatParams.dt4-p f!64
  540.0 params HatParams.tune@ f* isr f* params HatParams.dt5-p f!64
  800.0 params HatParams.tune@ f* isr f* params HatParams.dt6-p f!64
  params HatParams.ch-decay@ sr decay-exp-coeff
  params HatParams.ch-coeff-p f!64
  params HatParams.oh-decay@ sr decay-exp-coeff
  params HatParams.oh-coeff-p f!64
  3400.0 params HatParams.tone@ f* sr svf2-coeff
  params HatParams.bp-f-p f!64
  5200.0 params HatParams.tone@ f* sr svf2-coeff
  params HatParams.hp-f-p f!64
  drop2 drop2
;

( state params gate velocity -- : closed hat; chokes the open hat. )
dsp: hat-ch-trigger
  | state params gate velocity |
  0.5 gate  velocity 0.0 1.0 fclamp  state HatState.ch-vel@  fsel-lt
  state HatState.ch-vel-p f!64
  0.5 gate 1.0 state HatState.ch-env@ fsel-lt state HatState.ch-env-p f!64
  0.5 gate 0.0 state HatState.oh-env@ fsel-lt state HatState.oh-env-p f!64
  drop2 drop2
;

( state params gate velocity -- : open hat. )
dsp: hat-oh-trigger
  | state params gate velocity |
  0.5 gate  velocity 0.0 1.0 fclamp  state HatState.oh-vel@  fsel-lt
  state HatState.oh-vel-p f!64
  0.5 gate 1.0 state HatState.oh-env@ fsel-lt state HatState.oh-env-p f!64
  drop2 drop2
;

( phase-ptr dt -- value : advance a naive square oscillator one sample. )
dsp: square-step
  | php dt |
  php f@64 dt f+ ffrac
  dup php f!64
  0.5 1.0 -1.0 fsel-lt
  nip nip
;

( state params -- : six-square inharmonic sum -> metal scratch. )
dsp: hat-metal-write
  | state params |
  state HatState.ph1-p params HatParams.dt1@ square-step
  state HatState.ph2-p params HatParams.dt2@ square-step f+
  state HatState.ph3-p params HatParams.dt3@ square-step f+
  state HatState.ph4-p params HatParams.dt4@ square-step f+
  state HatState.ph5-p params HatParams.dt5@ square-step f+
  state HatState.ph6-p params HatParams.dt6@ square-step f+
  0.1666666666666667 f*
  state HatState.metal-p f!64
  drop2
;

( state params -- : band-pass then high-pass the core, in place. )
dsp: hat-filter-write
  | state params |
  state HatState.bp-lp-p  state HatState.metal@  params HatParams.bp-f@  0.8  svf2-bp-step
  | bp |
  state HatState.hp-lp-p  bp  params HatParams.hp-f@  1.0  svf2-hp-step
  state HatState.metal-p f!64
  drop2 drop
;

( out state params -- : core * [ch env + oh env], into out. )
dsp: hat-accum
  | out state params |
  out f@64
  state HatState.metal@
  state HatState.ch-env-p params HatParams.ch-coeff@ decay-exp-step
  state HatState.ch-vel@ f*
  state HatState.oh-env-p params HatParams.oh-coeff@ decay-exp-step
  state HatState.oh-vel@ f*
  f+
  f*
  params HatParams.level@ f*
  f+
  out f!64
  drop2 drop
;

( out state params -- : one mono hat sample, staged composition. )
dsp: k-hat-render
  | out state params |
  state params call: hat-metal-write
  state params call: hat-filter-write
  out state params call: hat-accum
;
