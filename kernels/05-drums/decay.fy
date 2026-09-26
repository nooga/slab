( decay.fy - one-shot retriggerable exponential decay: the drum workhorse.

  State is a single f64 cell: trigger writes 1.0, every sample multiplies
  by a coefficient below 1. decay-seconds is the time to fall to -60 dB,
  coeff = exp of -ln1000 / t*sr, t clamped to 0.5 ms .. 10 s. )

include "../00-primitives/math.fy"

( decay-seconds sample-rate -- coeff : per-sample decay multiplier. )
dsp: decay-exp-coeff | t sr -- coeff |
  -6.907755278982137  t 0.0005 10.0 fclamp sr f*  f/ exp
;

( env-ptr coeff -- value : advance the decay state one sample, return it. )
dsp: decay-exp-step
  | envp coeff |
  envp f@64 coeff f*
  dup envp f!64
;

( out env-ptr coeff -- : raw probe entry, one decay step per call. )
dsp: k-decay-exp
  | out envp coeff |
  envp coeff decay-exp-step
  out f!64
;

( out t sr -- : raw probe entry for the coefficient itself. )
dsp: k-decay-exp-coeff
  | out t sr |
  t sr decay-exp-coeff
  out f!64
;
