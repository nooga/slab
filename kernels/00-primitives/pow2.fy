( pow2.fy - log2 and exp2 approximations for dsp2.

  dsp2 has no libm and no float bit tricks, so range reduction is a
  branchless fsel ladder of conditional power-of-two scalings - a greedy
  single-pass ladder over 16,8,4,2,1 is exactly a binary decomposition
  of the exponent - and the residual is a short polynomial.  These are
  the dB <-> linear bridge for dynamics processors, meters, and future
  pitch <-> Hz work.

  Register discipline: only the remainder chain is bound; the per-step
  scale factors and the exponent terms are each used once, so they stay
  unbound on the stack and their registers retire immediately.

  fsel-lt convention: a b t f -- [a < b ? t : f].

  log2-approx: x in [2^-24 .. 2^25], max abs error ~2e-6.  x <= 0 is the
  caller's problem - clamp to a small positive floor first.
  exp2-approx: y clamped to [-32, 32], max rel error ~3e-6.
  Probe cases: log2-sweep / exp2-sweep against libm. )

( x -- log2-x : one conditional up-scale by 2^24 for x < 1, then a
  divide-down ladder into m in [1 .. 2], the atanh series
  log2 m = 2/ln2 * [u + u^3/3 + u^5/5 + u^7/7 + u^9/9] with
  u = [m-1]/[m+1], then the exponent terms summed on. )
dsp2: log2-approx
  | x |
  x 1.0  x 16777216.0 f*  x  fsel-lt | m0 |
  m0 65536.0  m0  m0 0.0000152587890625 f*  fsel-lt | m1 |
  m1 256.0  m1  m1 0.00390625 f*  fsel-lt | m2 |
  m2 16.0  m2  m2 0.0625 f*  fsel-lt | m3 |
  m3 4.0  m3  m3 0.25 f*  fsel-lt | m4 |
  m4 2.0  m4  m4 0.5 f*  fsel-lt | m5 |
  m5 1.0 f-  m5 1.0 f+  f/ | u |
  u u f* | u2 |
  0.320598897975325
  u2 f* 0.412198583111132 f+
  u2 f* 0.577078016355585 f+
  u2 f* 0.961796693925976 f+
  u2 f* 2.885390081777927 f+
  u f*
  x 1.0  -24.0  0.0  fsel-lt f+
  m0 65536.0  0.0  16.0  fsel-lt f+
  m1 256.0  0.0  8.0  fsel-lt f+
  m2 16.0  0.0  4.0  fsel-lt f+
  m3 4.0  0.0  2.0  fsel-lt f+
  m4 2.0  0.0  1.0  fsel-lt f+
  nip nip nip nip nip nip nip nip nip
;

( y -- 2^y : split integer/fraction with ffrac, Taylor of e^[f ln2] for
  the fractional part, conditional power factors off the |n| remainder
  chain for the integer part, reciprocal for negative exponents. )
dsp2: exp2-approx
  | y |
  y -32.0 32.0 fclamp | yc |
  yc ffrac | f |
  yc f f- | n |
  n 0.0  0.0 n f-  n  fsel-lt | m |
  m 32.0  m  m 32.0 f-  fsel-lt | m0 |
  m0 16.0  m0  m0 16.0 f-  fsel-lt | m1 |
  m1 8.0  m1  m1 8.0 f-  fsel-lt | m2 |
  m2 4.0  m2  m2 4.0 f-  fsel-lt | m3 |
  m3 2.0  m3  m3 2.0 f-  fsel-lt | m4 |
  0.000021871427813
  f f* 0.000154035303934 f+
  f f* 0.001333355814643 f+
  f f* 0.009618129107628 f+
  f f* 0.055504108664822 f+
  f f* 0.240226506959101 f+
  f f* 0.693147180559945 f+
  f f* 1.0 f+ | p |
  ( integer power 2^|n|; the reciprocal applies to this part only )
  m 32.0  1.0  4294967296.0  fsel-lt
  m0 16.0  1.0  65536.0  fsel-lt f*
  m1 8.0  1.0  256.0  fsel-lt f*
  m2 4.0  1.0  16.0  fsel-lt f*
  m3 2.0  1.0  4.0  fsel-lt f*
  m4 1.0  1.0  2.0  fsel-lt f* | gi |
  n 0.0  1.0 gi f/  gi  fsel-lt
  p f*
  nip nip nip nip nip nip nip nip nip nip nip nip
;

( out x -- : raw probe entries for the sweep grids. )
dsp2: k-log2 | out x | x log2-approx out f!64 drop2 ;
dsp2: k-exp2 | out x | x exp2-approx out f!64 drop2 ;
