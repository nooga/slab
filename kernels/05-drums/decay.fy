( decay.fy - one-shot retriggerable exponential decay: the drum workhorse.

  State is a single f64 cell: trigger writes 1.0, every sample multiplies
  by a coefficient below 1. decay-seconds is the time to fall to -60 dB,
  coeff = exp of -ln1000 / t*sr. The exp is a 5-term series - the argument
  is tiny, t clamped to 0.5 ms or more keeps x at 0.29 or less, series
  error under 1e-6 - ratcheted against libm exp by the decay-exp-render
  probe case. )

( decay-seconds sample-rate -- coeff : per-sample decay multiplier. )
dsp2: decay-exp-coeff
  | t sr |
  6.907755278982137  t 0.0005 10.0 fclamp sr f*  f/
  | x |
  1.0  x 0.2 f*  f-
  | h5 |
  1.0  x 0.25 f* h5 f*  f-
  | h4 |
  1.0  x 0.3333333333333333 f* h4 f*  f-
  | h3 |
  1.0  x 0.5 f* h3 f*  f-
  | h2 |
  1.0  x h2 f*  f-
  nip nip nip nip nip nip nip
;

( env-ptr coeff -- value : advance the decay state one sample, return it. )
dsp2: decay-exp-step
  | envp coeff |
  envp f@64 coeff f*
  dup envp f!64
  nip nip
;

( out env-ptr coeff -- : raw probe entry, one decay step per call. )
dsp2: k-decay-exp
  | out envp coeff |
  envp coeff decay-exp-step
  out f!64
  drop2 drop
;

( out t sr -- : raw probe entry for the coefficient itself. )
dsp2: k-decay-exp-coeff
  | out t sr |
  t sr decay-exp-coeff
  out f!64
  drop2 drop
;
