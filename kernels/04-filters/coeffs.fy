( coeffs.fy - shared filter coefficient helpers, in fy.

  svf-g        cutoff -> g = tan[pi fc / fs], the TPT prewarp
  svf-damping  resonance -> damping for simple SVFs [the MS-20 HPF]
  svf-dc-coeff corner -> one-pole coefficient 1 - e^[-2 pi f / fs] )

include "../00-primitives/math.fy"

( cutoff os-rate -- g : tan[pi clamp[cutoff, 20, 20160] / osr].
  osr >= 44.1 kHz keeps the angle inside tan-warp's range. )
dsp: svf-g | cutoff osr -- g |
  cutoff 20.0 20160.0 fclamp 3.141592653589793 f* osr f/ tan-warp
;

( resonance -- damping : clamp(0.58/(1+resonance*6.2), 0.035, 100). )
dsp: svf-damping
  | resonance |
  0.58  1.0 resonance 6.2 f* f+  f/  0.035 100.0 fclamp
;

( os-rate f -- coeff : 1 - e^[-2 pi f / osr]. )
dsp: svf-dc-coeff | osr f -- coeff |
  1.0  -6.283185307179586 f f* osr f/ exp  f-
;
