( fm_operator.fy - one DX-style FM operator: a phase accumulator driving a
  sine, phase-modulated by an external input and its own two-sample-averaged
  feedback. Pure dsp2; reuses the validated sine-shape polynomial so the
  operator inherits its ~-104 dB sine accuracy. The 32-algorithm matrix
  composes six of these; this file is the single trustworthy building block. )

include "../05-drums/sine.fy"

ustruct: FmOpState
  f64 phase       ( normalized 0..1 phase accumulator )
  f64 fb1         ( last output sample )
  f64 fb2         ( output before last )
;

( state inc mod level fb -- out : one operator sample.
  out = level * sine( phase + mod + fb*0.5*(fb1+fb2) ), phase advances by inc
  and wraps, and the feedback history shifts. inc is cycles/sample, mod is in
  0..1 phase units, fb is the self-feedback amount. )
dsp: fm-op-step
  | state:FmOpState inc mod level fb |
  ( feedback modulation = fb * 0.5 * (fb1 + fb2) — the DX two-sample average )
  state.fb1 state.fb2 f+ 0.5 f* fb f*
  | fbmod |
  ( out = level * sine-shape(phase + mod + fbmod) )
  state.phase mod f+ fbmod f+ sine-shape level f*
  ( shift feedback: fb2 <- old fb1, then fb1 <- out (dup keeps out on top) )
  state.fb1 -> state.fb2
  dup -> state.fb1
  ( advance phase = frac(phase + inc) )
  state.phase inc f+ ffrac -> state.phase
  ( out remains on top; drop the six named slots below it )
;

( out state inc mod level fb -- : raw probe entry, one operator sample to out.
  fm-op-step is called inline (by name); `call:` composition is pointer-args
  only, but inline calls take f64 args like decay-exp-coeff in kick-prepare. )
dsp: k-fm-op
  | out state inc mod level fb |
  state inc mod level fb fm-op-step
  out f!64
;
