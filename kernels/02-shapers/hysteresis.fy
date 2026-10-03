( hysteresis.fy - a cheap magnetic-tape transfer curve: the algebraic
  soft shoulder of sat2's TAPE mode, with the loop opened by the
  direction the signal is moving, a crossover dead zone that grows as
  the bias drops, and an offset for the even harmonics of a magnetized
  head.  Not Jiles-Atherton [Chow Tape solves that with RK4]; what it
  keeps is what the ear gets from it: phase lag and odd harmonics that
  grow with level, grit at low bias.  k is steep, so s is nearly the
  sign of the motion and the loop doesn't depend on frequency [a
  gentle k turns the loop into a treble boost: the slope grows with
  frequency].  The bias's HF loss is the owner's band limit.

    u  = g x
    s  = tanh[k [u - u_prev]]               which way the flux moves
    a  = |sat[u]|
    m  = 2.6 a [1 - a^2]                    0 at rest, 1 mid-curve,
                                            closed at saturation
    v  = sat[u + off + w s m] - sat[off]    sat[v] = v / sqrt[1 + v^2]
    y  = v |v| / [|v| + dz] / g             the dead zone, unity slope

  BIAS 1 [over-biased] gives w = dz = 0: the plain curve.  As it falls
  the loop widens [w up to 0.06] and the dead zone opens [dz up to 0.04],
  the crossover distortion of an under-biased deck.  OFF is the head's
  magnetization [a few hundredths]: even harmonics, which the owner's
  coupling cap clears of DC.  Run it oversampled [every term here makes
  harmonics without limit]; k assumes 2x at 48 kHz. )

include "../00-primitives/math.fy"

ustruct: HystState
  f64 up       ( last driven input )
;

ustruct: HystParams
  f64 g        ( drive, linear )
  f64 ig       ( 1 / g )
  f64 w        ( loop width )
  f64 k        ( direction sharpness )
  f64 dz       ( dead zone )
  f64 off      ( magnetization offset, and the curve there )
  f64 f0
;

:: HYST-W 0.06 ;
:: HYST-DZ 0.04 ;
:: HYST-K 400.0 ;

( v -- y : the soft shoulder. )
dsp: hyst-sat | v -- y |  v  1.0 v v f* f+ fsqrt  f/ ;

( hp g bias off -- : the curve's constants; g linear, bias and off 0..1. )
dsp: hyst-set | hp:HystParams g bias off -- |
  g -> hp.g
  1.0 g f/ -> hp.ig
  1.0 bias 0.0 1.0 fclamp f- | ub |
  ub ub f* HYST-W f* -> hp.w
  ub ub f* ub f* HYST-DZ f* -> hp.dz
  HYST-K -> hp.k
  off -> hp.off
  off hyst-sat -> hp.f0
;

( st hp x -- y : one sample. )
dsp: hyst-tick | st:HystState hp:HystParams x -- y |
  x hp.g f* | u |
  u st.up f-  hp.k f* tanh-fast | s |
  u -> st.up
  u hyst-sat fabs | a |
  1.0 a a f* f-  a f*  2.598076211353316 f* | m |
  u hp.off f+  hp.w s f* m f*  f+  hyst-sat  hp.f0 f- | v |
  v fabs | va |
  v va f*  va hp.dz f+ 1.0e-30 f+  f/  hp.ig f*
;
