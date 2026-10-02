( noise.fy - white noise on a caller-owned rng cell [rand.fy], so
  every drum voice gets an independent stream from its own state field.
  The drums reseed their cell on each hit, so a hit's noise is the same
  every time, like a sample. )

include "../00-primitives/rand.fy"

( rng-ptr -- value : -1..1 noise, advancing the rng state in place. )
dsp: noise-step | rngp |  rngp rand-b ;
