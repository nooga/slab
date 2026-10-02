( rand.fy - a uniform random generator for dsp: words that is actually
  random: Park-Miller's minimal standard with a = 48271, m = 2^31 - 1,
  period 2^31 - 2.  Every product a x stays under 2^47, so the f64s
  hold it exactly and x mod m is exact: floor by the reciprocal can be
  off by one at a boundary, and the two selects put it back.

  The float hash frac[x * 1103515245 + c] that noise.fy uses is not
  this: it falls into a cycle a few thousand samples long [3143 for
  c = 0.27183 from 0, which never comes within 4.8e-4 of 0], so hiss
  repeats as a buzz and a rare-event trigger never fires.

  The state cell starts at 0 [machine state is zeroed]; 0 is the one
  fixed point, so rand-u seeds it with the caller's seed on first use.
  Give each stream its own seed. )

:: RAND-A 48271.0 ;
:: RAND-M 2147483647.0 ;
:: RAND-IM 4.656612875245797e-10 ;   ( 1 / m )

( p seed -- u : the next value in 0..1 [never 1] from the cell at p. )
dsp: rand-u | p seed -- u |
  p f@64 | s0 |
  s0 1.0 f<  seed s0  select RAND-A f* | x |
  x  x RAND-IM f* floor RAND-M f*  f- | r0 |
  r0 0.0 f<  r0 RAND-M f+  r0  select | r1 |
  r1 RAND-M f>=  r1 RAND-M f-  r1  select | r |
  r p f!64
  r RAND-IM f*
;

( p seed -- v : the next value in -1..1 [never 1]. )
dsp: rand-b | p seed -- v |  p seed rand-u 2.0 f* 1.0 f- ;
