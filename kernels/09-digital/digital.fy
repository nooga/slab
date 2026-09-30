( digital.fy - converter primitives for the sample-era machines.

  The parts of an 80s sampler's signal path, as reusable words:

    quantize-round   midtread rounding to a 2^[1-bits] grid
    quantize-trunc   two's-complement truncation [floor]: the cheap
                     converters' way, with its -1/2 LSB offset
    mulaw-quantize   mu = 255 companding: quantize the log-encoded
                     magnitude, so quiet signals keep their resolution
                     and loud ones get coarse [the DMX / Emulator trick]
    quantize-mode    one of the three by a 0/1/2 switch value
    zoh-tick         a sample-and-hold at any rate below the host's,
                     sampling between host samples and polyBLEP-stepping
                     the held value, so the steps land at their true
                     times instead of on the host grid

  BITS may be fractional: the grid step is exp2[1 - bits], so a sweep
  moves smoothly between resolutions.  Hardware presets use whole bits.

  The era effect [07-effects/era.fy] strings these into a converter; the
  sampler's sample-clock playback will reuse zoh-tick and the quantizers. )

include "../00-primitives/math.fy"

( x step -- q : round to the nearest multiple of step, clipped to the
  converter's range [-1, 1 - step]. )
dsp: quantize-round | x step -- q |
  x step f/ 0.5 f+ floor step f*  -1.0  1.0 step f-  fclamp
;

( x step -- q : truncate toward -inf. )
dsp: quantize-trunc | x step -- q |
  x step f/ floor step f*  -1.0  1.0 step f-  fclamp
;

( x step -- q : mu-law 255: encode |x| as log2[1 + 255|x|] / 8 [0..1],
  round that to step, decode, restore the sign.  step covers the
  magnitude, so the sign bit is the one bit the grid leaves out. )
dsp: mulaw-quantize | x step -- q |
  x fabs 1.0 fmin | a |
  255.0 a f* 1.0 f+ log2 0.125 f* | e |
  e step f/ 0.5 f+ floor step f*  0.0 1.0 fclamp | eq |
  8.0 eq f* exp2 1.0 f-  0.00392156862745098 f* | d |
  x 0.0  d fneg  d  fsel-lt
;

( x step mode -- q : 0 ROUND, 1 TRUNC, 2 MU-LAW. )
dsp: quantize-mode | x step mode -- q |
  ( a switch: only the chosen quantizer runs )
  mode 0.5 f<  [ x step quantize-round ]
  [ mode 1.5 f<  [ x step quantize-trunc ]  [ x step mulaw-quantize ]  ifte ]  ifte
;

( x3 x2 x1 x0 t -- y : 4-point, 3rd-order Hermite between x2 and x1,
  t samples before x1 [x3 oldest, x0 newest].  Midway between samples,
  where it is worst, it loses 0.5 dB at 10 kHz and 1 dB at 12 kHz
  [48 kHz host]; linear interpolation loses 2 dB at 10 kHz. )
dsp: hermite4-back | x3 x2 x1 x0 t -- y |
  1.0 t f- | u |
  x1 x3 f- 0.5 f* | c1 |
  x3  x2 2.5 f* f-  x1 2.0 f* f+  x0 0.5 f* f- | c2 |
  x0 x3 f- 0.5 f*  x2 x1 f- 1.5 f*  f+ | c3 |
  c3 u f* c2 f+ u f* c1 f+ u f* x2 f+
;

( The sample-and-hold's state: the clock phase, the held value, the
  last three host inputs [for sampling between host samples] and the
  output waiting one sample for the step's polyBLEP correction. )
ustruct: Zoh
  f64 ph      ( converter clock phase, 0..1 )
  f64 held    ( value on the hold capacitor )
  f64 x1      ( host input one sample back )
  f64 x2
  f64 x3
  f64 pend    ( next output, naive + its after-step correction )
;

( z x dt step mode -- y : one host sample through the hold.  dt is the
  converter rate over the host rate, at most 1, so a sample period holds
  at most one conversion.  A conversion at t samples before now samples
  the input there [Hermite, one host sample further back so the
  interpolator has a point on each side], quantizes it, and steps the
  hold by delta; the two-sample polyBLEP of that step adds delta*t^2/2
  to the previous output and -delta*[1-t]^2/2 to this one.  Two samples
  of latency pay for the look-back. )
dsp: zoh-tick | z:Zoh x dt step mode -- y |
  z.ph dt f+ | ph |
  ph 1.0 f>= | ev |
  ph 1.0 f- dt f/ 0.0 1.0 fclamp | t |
  ev  ph 1.0 f-  ph  select -> z.ph
  z.x3 z.x2 z.x1 x t hermite4-back | xs |
  z.x2 -> z.x3
  z.x1 -> z.x2
  x -> z.x1
  xs step mode quantize-mode | q |
  z.held | h |
  ev  q h f-  0.0  select | delta |
  ev  q  h  select -> z.held
  z.pend  delta t t f* f* 0.5 f*  f+ | y |
  1.0 t f- | u |
  ev  q  h  select  delta u u f* f* 0.5 f*  f-  -> z.pend
  y
;
