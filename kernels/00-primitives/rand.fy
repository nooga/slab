( rand.fy - a uniform random generator for dsp: words that is actually
  random: the full-period LCG mod 2^32 of Numerical Recipes,
  x' = [1664525 x + 1013904223] mod 2^32, period 2^32, kept as the
  fraction f = x / 2^32:

    f' = frac[1664525 f + 1013904223 / 2^32]

  f is a multiple of 2^-32, so 1664525 f fits 53 bits, the sum is
  exact and frac is exact: the same sequence as the integer LCG, in
  three native ops and no floor.  That matters: inlined into the
  MS-20's large voice word, a version with floor and two correcting
  selects [Park-Miller] tipped it over fy's frame-corruption limit and
  the voice turned to crackle; this one doesn't.

  It replaced the float hash frac[x * 1103515245 + c] everywhere: that
  falls into a cycle a few thousand samples long [3143 values for
  c = 0.27183 from 0, never within 4.8e-4 of 0], so noise repeated as a
  buzz every ~65 ms, every voice of a poly played the same noise, and a
  rare-event trigger never fired.

  The low bits of a power-of-two LCG are weak; the values here use all
  32, as a fraction, which is fine for audio noise and event draws.  A
  zeroed cell is a valid start; streams that must differ [voices,
  channels] seed their cells with rand-seed-once, or a constant that is
  a multiple of 2^-32 [k / 4294967296]. )

:: RAND-A 1664525.0 ;
:: RAND-CF 0.23606797284446657 ;   ( 1013904223 / 2^32, exact )

( f -- f' : the next state, pure - for callers that keep it in a field
  and store it themselves [the MS-20]. )
dsp: rand-next  RAND-A f* RAND-CF f+ ffrac ;

( p -- u : the next value in 0..1 [never 1] from the cell at p. )
dsp: rand-u | p -- u |  p f@64 rand-next  dup p f!64 ;

( p -- v : the next value in -1..1 [never 1]. )
dsp: rand-b | p -- v |  p rand-u 2.0 f* 1.0 f- ;

( p salt -- : seed a cell that has never run [still 0] from a salt
  [a voice index plus a part number]: golden-ratio spaced, so nearby
  salts land far apart, and rounded to a multiple of 2^-32. )
dsp: rand-seed-once | p salt -- |
  p f@64 | s0 |
  salt 0.6180339887498949 f* 0.1234567 f+ ffrac  4294967296.0 f* floor  2.3283064365386963e-10 f* | seed |
  s0 0.0 f=  seed s0  select  p f!64
;
