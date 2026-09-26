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
  | state params:HatParams sr |
  1.0 sr f/
  | isr |
  205.3 params.tune f* isr f* -> params.dt1
  304.4 params.tune f* isr f* -> params.dt2
  369.6 params.tune f* isr f* -> params.dt3
  522.7 params.tune f* isr f* -> params.dt4
  540.0 params.tune f* isr f* -> params.dt5
  800.0 params.tune f* isr f* -> params.dt6
  params.ch-decay sr decay-exp-coeff
  -> params.ch-coeff
  params.oh-decay sr decay-exp-coeff
  -> params.oh-coeff
  3400.0 params.tone f* sr svf2-coeff
  -> params.bp-f
  5200.0 params.tone f* sr svf2-coeff
  -> params.hp-f
;

( state params gate velocity -- : closed hat; chokes the open hat. )
dsp: hat-ch-trigger
  | state:HatState params gate velocity |
  0.5 gate  velocity 0.0 1.0 fclamp  state.ch-vel  fsel-lt
  -> state.ch-vel
  0.5 gate 1.0 state.ch-env fsel-lt -> state.ch-env
  0.5 gate 0.0 state.oh-env fsel-lt -> state.oh-env
;

( state params gate velocity -- : open hat. )
dsp: hat-oh-trigger
  | state:HatState params gate velocity |
  0.5 gate  velocity 0.0 1.0 fclamp  state.oh-vel  fsel-lt
  -> state.oh-vel
  0.5 gate 1.0 state.oh-env fsel-lt -> state.oh-env
;

( phase-ptr dt -- value : advance a naive square oscillator one sample. )
dsp: square-step
  | php dt |
  php f@64 dt f+ ffrac
  dup php f!64
  0.5 1.0 -1.0 fsel-lt
;

( Six-square inharmonic sum, normalized. )
dsp: hat-metal | state:HatState params:HatParams -- core |
  state.ph1& params.dt1 square-step
  state.ph2& params.dt2 square-step f+
  state.ph3& params.dt3 square-step f+
  state.ph4& params.dt4 square-step f+
  state.ph5& params.dt5 square-step f+
  state.ph6& params.dt6 square-step f+
  0.1666666666666667 f*
;

( Band-pass then high-pass the core. )
dsp: hat-filter | state:HatState params:HatParams core -- y |
  state.bp-lp&  core  params.bp-f  0.8  svf2-bp-step
  | bp |
  state.hp-lp&  bp  params.hp-f  1.0  svf2-hp-step
;

( Filtered core * [ch env + oh env], then level. )
dsp: hat-amp | state:HatState params:HatParams x -- y |
  x
  state.ch-env& params.ch-coeff decay-exp-step
  state.ch-vel f*
  state.oh-env& params.oh-coeff decay-exp-step
  state.oh-vel f*
  f+
  f*
  params.level f*
;

( One mono hat sample - closed and open share the core. )
dsp: hat-voice | state params -- y |
  state params  state params  state params hat-metal  hat-filter  hat-amp
;

( out state params -- : one mono hat sample, accumulated into out. )
dsp: k-hat-render | out state params -- |
  out f@64
  state params hat-voice
  f+
  out f!64
;
