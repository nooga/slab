( trig.fy - sin/cos approximations for dsp2.

  pow2.fy gives the dB <-> linear bridge; this gives the angle bridge.
  RBJ-cookbook biquad coefficients (kernels/07-effects/eq.fy) need
  sin/cos of omega = 2*pi*fc/sr, which reaches ~2.56 rad at 18 kHz -
  far outside the tiny-angle range svf-g relies on (kernels/04-filters/
  coeffs.fy), so the EQ needs real range-reduced trig.

  dsp2 has no libm.  Both words assume the argument is already in
  [0, pi] (omega < pi whenever fc < sr/2; the caller clamps).  A single
  branchless fsel fold maps the angle to r in [0, pi/2] - where
  sin(pi-r)=sin(r) and cos(pi-r)=-cos(r) - then a Taylor polynomial in
  r^2 evaluates the half-range value.  Through r^9 (sin) / r^10 (cos)
  the residual over [0, pi/2] is ~2e-6, well past what a filter coeff
  needs.  Register discipline mirrors pow2.fy: only the fold result r
  and r^2 are bound; the polynomial is a Horner chain of unbound terms.

  Probe cases: sin-sweep / cos-sweep against libm over [0, pi]. )

( fsel-lt convention: a b t f -- [a < b ? t : f]. )

( w -- sin w : valid for w in [0, pi]. )
dsp: sin-approx
  | w |
  w 0.0 3.141592653589793 fclamp | x |
  ( fold to r in [0, pi/2]: r = x > pi/2 ? pi - x : x )
  1.5707963267948966 x  3.141592653589793 x f-  x  fsel-lt | r |
  r r f* | s2 |
  0.0000027557319223985893   ( 1/9! )
  s2 f* -0.0001984126984126984 f+  ( -1/7! )
  s2 f* 0.008333333333333333 f+    ( 1/5! )
  s2 f* -0.16666666666666666 f+    ( -1/3! )
  s2 f* 1.0 f+
  r f*
  ( bindings: w x r s2 = 4 )
;

( w -- cos w : valid for w in [0, pi]. )
dsp: cos-approx
  | w |
  w 0.0 3.141592653589793 fclamp | x |
  1.5707963267948966 x  3.141592653589793 x f-  x  fsel-lt | r |
  ( sign flips on the far half: cos(pi-r) = -cos(r) )
  1.5707963267948966 x  -1.0  1.0  fsel-lt | sgn |
  r r f* | s2 |
  -0.0000002505210838544172  ( -1/10! )
  s2 f* 0.000024801587301587 f+    ( 1/8! )
  s2 f* -0.001388888888888889 f+   ( -1/6! )
  s2 f* 0.041666666666666664 f+    ( 1/4! )
  s2 f* -0.5 f+                    ( -1/2! )
  s2 f* 1.0 f+
  sgn f*
  ( bindings: w x r sgn s2 = 5 )
;

( out w -- : raw probe entries for the sweep grids. )
dsp: k-sin | out w | w sin-approx out f!64 ;
dsp: k-cos | out w | w cos-approx out f!64 ;
