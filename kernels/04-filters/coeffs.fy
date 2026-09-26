( coeffs.fy - shared filter coefficient helpers, in fy.

  svf-g        cutoff -> g = tan[pi fc / fs] by a tiny-angle series
  svf-damping  resonance -> damping for simple SVFs [the MS-20 HPF]
  svf-dc-coeff corner -> one-pole coefficient 1 - e^[-2 pi f / fs]

  dsp: has no libm yet [docs/17 A4]; these series are valid for the small
  angles an oversampled filter sees. )

( cutoff os-rate -- g : g = th*(1 + p*(1/3 + p*(2/15 + p*17/315))),
  p = th^2, th = pi*clamp(cutoff,20,20160)/osr. Tiny-angle tan series. )
dsp: svf-g
  | cutoff osr |
  cutoff 20.0 20160.0 fclamp 3.141592653589793 f* osr f/
  | th |
  th th f* | p |
  0.1333333333333333  p 0.05396825396825397 f*  f+
  p f* 0.3333333333333333 f+
  p f* 1.0 f+
  th f*
;

( resonance -- damping : clamp(0.58/(1+resonance*6.2), 0.035, 100). )
dsp: svf-damping
  | resonance |
  0.58  1.0 resonance 6.2 f* f+  f/  0.035 100.0 fclamp
;

( os-rate f -- coeff : 1 - exp(-2pi*f/osr) ~ a*(1 + a*(-1/2 + a/6)). )
dsp: svf-dc-coeff
  | osr f |
  6.283185307179586 f f* osr f/
  | a |
  -0.5  a 0.1666666666666667 f*  f+
  a f* 1.0 f+
  a f*
;
