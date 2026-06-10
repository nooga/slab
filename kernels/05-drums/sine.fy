( sine.fy - polynomial sine shape on a 0..1 phase accumulator.

  dsp2 has no libm, so the drum oscillators need an in-fy sine. Mapping:
  u = 1 - 2*frac of phase, in -1..1, and sin of 2*pi*phase = sin of pi*u.
  The odd degree-9 polynomial below is a near-minimax fit of sin pi*u on
  -1..1; max abs error ~5.9e-6, about -104 dB, ratcheted by the
  sine-shape-render kernel-probe case against libm sin. )

( phase -- value : sine of 2*pi*phase, phase wraps via frac. )
dsp2: sine-shape
  | phase |
  1.0  phase ffrac 2.0 f*  f-
  | u |
  u u f*
  | u2 |
  0.064026102748925784
  u2 f* -0.58185926636534557 f+
  u2 f* 2.5427128809580819 f+
  u2 f* -5.1664017645052089 f+
  u2 f* 3.1415278977538725 f+
  u f*
  nip nip nip
;

( out phase -- : raw probe entry for the shape grid. )
dsp2: k-sine-shape
  | out phase |
  phase sine-shape
  out f!64
  drop2
;
