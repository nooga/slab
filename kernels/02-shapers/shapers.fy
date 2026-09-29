( shapers.fy - one parametric waveshaper for the whole saturation family.

    u = x + bias + even x^2               bias and x^2 tilt the curve:
                                          even harmonics, the tube warmth
    u = u < 0 ? u neg : u                 a weaker negative side: diode
                                          and fuzz asymmetry
    y = knee * tanh[hard u] / hard        the tanh shoulder ...
      + [1 - knee] * u / sqrt[1 + u^2]    ... or the softer algebraic one
    y = valve v + [1 - valve] y           v = 2 tanh[exp[3 hard u - 0.6]] - 1, the
                                          triode: grid conduction clips the
                                          top hard, the bottom runs into
                                          cutoff along a long soft tail
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
  f64 valve
  f64 y0
  f64 gain
;

( u -- v : the triode curve, through 0 near u = 0 [b = 0.6 ~ -ln atanh
  1/2], slope ~2.5 there; +1 by u ~ 0.6, -1 only far below. )
dsp: valve-curve | u -- v |
  u -8.0 3.0 fclamp 3.0 f* 0.6 f- exp tanh-fast 2.0 f* 1.0 f-
;

( x sh -- y : the curve without the rest-point correction. )
dsp: shape-raw | x sh:Shape -- y |
  x sh.bias f+  x x f* sh.even f*  f+ | u0 |
  u0 0.0  u0 sh.neg f*  u0  fsel-lt | u |
  u sh.hard f* tanh-fast  sh.hard f/  sh.knee f*
  u  1.0 u u f* f+ fsqrt  f/  1.0 sh.knee f- f*  f+ | y |
  u sh.hard f* valve-curve sh.valve f*  y 1.0 sh.valve f- f*  f+
;

( x sh -- y )
dsp: shape | x sh:Shape -- y |
  x sh shape-raw  sh.y0 f-  sh.gain f*
;

( x off y0 sh -- y : the curve with its operating point moved by off
  [a bias shift]; y0 is its value at x = 0 there, so rest stays at 0.
  The slope isn't renormalized: moving off the rest point is the sag. )
dsp: shape-at | x off y0 sh:Shape -- y |
  x off f+ sh shape-raw  y0 f-  sh.gain f*
;

( sh bias even hard knee neg valve -- : set a shape and its rest point. )
dsp: shape-set | sh:Shape bias even hard knee neg valve -- |
  bias -> sh.bias
  even -> sh.even
  hard -> sh.hard
  knee -> sh.knee
  neg  -> sh.neg
  valve -> sh.valve
  0.0 sh shape-raw -> sh.y0
  ( slope at rest, central difference; the negative side's slope for
    x < 0 is neg times this and stays that way on purpose )
  1.0
    0.00005 sh shape-raw  -0.00005 sh shape-raw  f-  10000.0 f*  0.001 fmax
  f/ -> sh.gain
;
