( shapers.fy - one parametric waveshaper for the whole saturation family.

    u = x + bias + even x^2               bias and x^2 tilt the curve:
                                          even harmonics, the tube warmth
    u = u < 0 ? u neg : u                 a weaker negative side: diode
                                          and fuzz asymmetry
    y = knee * tanh[hard u] / hard        the tanh shoulder ...
      + [1 - knee] * u / sqrt[1 + u^2]    ... or the softer algebraic one
    y = [y - y0] gain                     y0 = the same at x = 0, so the
                                          curve passes through zero; gain
                                          = 1 / its slope there

  So every setting has unity slope at small signals and DRIVE alone
  decides how hard it works.  The machine derives the five constants
  per block from its MODE switch; the per-sample cost is one tanh-fast and
  one sqrt.  Run it oversampled [oversample.fy]: every curve here makes
  harmonics without limit. )

include "../00-primitives/math.fy"

ustruct: Shape
  f64 bias
  f64 even
  f64 hard
  f64 knee
  f64 neg
  f64 y0
  f64 gain
;

( x sh -- y : the curve without the rest-point correction. )
dsp: shape-raw | x sh:Shape -- y |
  x sh.bias f+  x x f* sh.even f*  f+ | u0 |
  u0 0.0  u0 sh.neg f*  u0  fsel-lt | u |
  u sh.hard f* tanh-fast  sh.hard f/  sh.knee f*
  u  1.0 u u f* f+ fsqrt  f/  1.0 sh.knee f- f*  f+
;

( x sh -- y )
dsp: shape | x sh:Shape -- y |
  x sh shape-raw  sh.y0 f-  sh.gain f*
;

( sh bias even hard knee neg -- : set a shape and its rest point. )
dsp: shape-set | sh:Shape bias even hard knee neg -- |
  bias -> sh.bias
  even -> sh.even
  hard -> sh.hard
  knee -> sh.knee
  neg  -> sh.neg
  0.0 sh shape-raw -> sh.y0
  ( slope at rest, central difference; the negative side's slope for
    x < 0 is neg times this and stays that way on purpose )
  1.0
    0.00005 sh shape-raw  -0.00005 sh shape-raw  f-  10000.0 f*  0.001 fmax
  f/ -> sh.gain
;
