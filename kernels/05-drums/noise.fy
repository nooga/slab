( noise.fy - float-LCG white-ish noise on a caller-owned rng cell, so
  every drum voice gets an independent stream from its own state field. )

( rng-ptr -- value : -1..1 noise, advancing the rng state in place. )
dsp: noise-step
  | rngp |
  rngp f@64
  1103515245.0 f*
  0.31337 f+
  ffrac
  dup rngp f!64
  2.0 f* 1.0 f-
;
