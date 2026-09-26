( tpt_svf.fy - linear zero-delay-feedback [TPT] state-variable filter step,
  in fy.  Zavalishin, "The Art of VA Filter Design", ch. 4:

    hp = [x - [2d + g]*s1 - s2] / [1 + 2dg + g^2]
    bp = g*hp + s1        s1' = g*hp + bp
    lp = g*bp + s2        s2' = g*bp + lp

  g = tan[pi fc / fs] [svf-g in coeffs.fy gives it at small angles], d =
  damping [0.707 Butterworth, -> 0 resonant].  Callers wanting oversampling
  run the step several times per sample [call: stages]. )

include "../02-shapers/tanh_table.fy"   ( k-tanh-rational-shape-dsp2 )

( s1p s2p x g d -- lp : one lowpass step; s1p / s2p point at the two
  integrator states. )
dsp: tpt-svf-lp-step ( s1p s2p x g d -- lp )
  | s1p s2p x g d |
  s1p f@64 | s1 |
  s2p f@64 | s2 |
  2.0 d f* | d2 |
  1.0  d2 g f*  f+  g g f*  f+ | den |
  x  d2 g f+ s1 f*  f-  s2 f-  den f/ | hp |
  g hp f*  s1 f+ | bp |
  g bp f*  s2 f+ | lp |
  g hp f* bp f+  s1p f!64
  g bp f* lp f+  s2p f!64
  lp
  nip nip nip nip nip nip nip nip nip nip nip nip
;

( s1p s2p x g d -- lp : the same step with both integrator states written
  back through a soft clip, tanh[1.05*s] - the saturating "lpf4" voicing
  Funk Overload uses. )
dsp: tpt-svf-lp-sat-step ( s1p s2p x g d -- lp )
  | s1p s2p x g d |
  s1p f@64 | s1 |
  s2p f@64 | s2 |
  2.0 d f* g f+ | a |
  1.0  1.0  2.0 d f* g f*  f+  g g f*  f+  f/ | h |
  x  a s1 f*  f-  s2 f-  h f* | hp |
  g hp f* | ghp |
  ghp s1 f+ | bp |
  ghp bp f+ 1.05 f* k-tanh-rational-shape-dsp2  s1p f!64
  g bp f*  s2 f+ | lp |
  g bp f* lp f+ 1.05 f* k-tanh-rational-shape-dsp2  s2p f!64
  lp
  nip nip nip nip nip nip nip nip nip nip nip nip nip
;
