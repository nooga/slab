( math.fy - dsp-std: elementary functions for dsp: words, in fy.

  Built on the native ops [docs/18]: floor, fmin/fmax, compares and
  select, and the exponent-bit primitives fexp2i [2^floor n], flog2i
  [floor log2 |x|] and fmant [mantissa in 1..2].  The polynomials are
  near-minimax fits from tools/fit/minimax.py; each one pins its value at
  zero, so exp2 of an integer is exact [0 dB is exactly unity gain],
  cos 0 = 1 and tanh 0 = 0.

  word        domain                 max error
  exp2        any [clamped to +-1022]  4.7e-11 relative
  log2        x > 0 [floored at the    1.1e-12 absolute
              smallest normal]
  exp ln pow  via exp2 / log2
  sinpi cospi any                      1.9e-11 relative / 8.2e-13
  sin2pi      any, turns               same
  sin cos     any, radians             same, plus argument rounding
  tan         any, radians             ratio of the two
  tan-warp    |x| < 1.45               7e-9 relative [filter prewarp]
  tanh        any                      ~5e-11 absolute
  db>lin lin>db                        via exp2 / log2

  Arguments far from zero lose accuracy the usual way: the range
  reduction rounds x/pi to a double first. )

( x -- 2^x : n = round x, f = x - n in +-1/2, 2^f = 1 + f Q[f]. )
dsp: exp2 | x -- y |
  x -1022.0 1023.0 fclamp | xc |
  xc 0.5 f+ floor | n |
  xc n f- | f |
  1.5196156676232585e-05
  f f* 0.00015466756328423606 f+
  f f* 0.0013333935055137428 f+
  f f* 0.009618038132012684 f+
  f f* 0.055504103659917314 f+
  f f* 0.24022651066561568 f+
  f f* 0.6931471807045324 f+
  f f* 1.0 f+
  n fexp2i f*
;

( x -- log2 x : x = m 2^e with m folded into [1/sqrt2, sqrt2], then
  log2 m = u Q[u^2], u = [m-1]/[m+1] - the atanh series, refitted. )
dsp: log2 | x -- y |
  x 2.2250738585072014e-308 fmax | xc |
  xc fmant | m0 |
  xc flog2i | e0 |
  1.4142135623730951 m0  m0 0.5 f*  m0  fsel-lt | m |
  1.4142135623730951 m0  e0 1.0 f+  e0  fsel-lt | e |
  m 1.0 f-  m 1.0 f+  f/ | u |
  u u f* | s |
  0.34282028984749296
  s f* 0.4115342256549241 f+
  s f* 0.5770866439150979 f+
  s f* 0.9617966483162439 f+
  s f* 2.885390081845373 f+
  u f*  e f+
;

( x -- e^x )
dsp: exp  1.4426950408889634 f* exp2 ;

( x -- ln x )
dsp: ln  log2 0.6931471805599453 f* ;

( x y -- x^y : x > 0. )
dsp: pow | x y -- z |  x log2 y f* exp2 ;

( dB -- gain : 10^[dB/20]. )
dsp: db>lin  0.16609640474436813 f* exp2 ;

( gain -- dB : 20 log10 gain. )
dsp: lin>db  log2 6.020599913279624 f* ;

( The shared half-turn reduction: y = x/pi, n = round y, r = [y-n] pi in
  +-pi/2, and the odd/even polynomials on r. )
dsp: sin-r | r -- s |
  r r f* | s |
  -2.3909597256746232e-08
  s f* 2.7526639292592648e-06 f+
  s f* -0.00019840894515007722 f+
  s f* 0.008333331326760368 f+
  s f* -0.16666666631809604 f+
  s f*  r f*  r f+
;

dsp: cos-r | r -- c |
  r r f* | s |
  1.9919951838658433e-09
  s f* -2.752566090480927e-07 f+
  s f* 2.480107017198174e-05 f+
  s f* -0.001388888461232762 f+
  s f* 0.041666666503967276 f+
  s f* -0.49999999997938444 f+
  s f*  1.0 f+
;

( n -- +-1 : [-1]^n for an integral n. )
dsp: turn-sign | n -- s |
  1.0  n  n 0.5 f* floor 2.0 f* f-  2.0 f*  f-
;

( y -- sin[pi y] : r = pi [y - n] in +-pi/2; odd half-turns flip the sign. )
dsp: sinpi | y -- s |
  y 0.5 f+ floor | n |
  y n f- 3.141592653589793 f* sin-r  n turn-sign f*
;

( y -- cos[pi y] )
dsp: cospi | y -- c |
  y 0.5 f+ floor | n |
  y n f- 3.141592653589793 f* cos-r  n turn-sign f*
;

( p -- sin[2 pi p] : a 0..1 phase accumulator's sine; any p wraps. )
dsp: sin2pi  ffrac 2.0 f* sinpi ;

( x -- sin x, radians )
dsp: sin  0.3183098861837907 f* sinpi ;

( x -- cos x, radians )
dsp: cos  0.3183098861837907 f* cospi ;

( x -- tan x, radians : the half-turn sign cancels in the ratio. )
dsp: tan | x -- t |
  x 0.3183098861837907 f* | y |
  y  y 0.5 f+ floor  f- 3.141592653589793 f* | r |
  r sin-r  r cos-r  f/
;

( x -- tan x for |x| < 1.45 : the [7/6] Pade form, 7.5e-12 relative
  below 1 rad and 7e-9 at 1.45 - the bilinear prewarp tan[pi fc / fs]
  for fc up to ~20 kHz at 44.1 kHz, at half the cost of tan. )
dsp: tan-warp | x -- t |
  x x f* | s |
  -1.0 s f* 378.0 f+ s f* -17325.0 f+ s f* 135135.0 f+ x f*
  -28.0 s f* 3150.0 f+ s f* -62370.0 f+ s f* 135135.0 f+
  f/
;

( x -- tanh x : [e^2x - 1] / [e^2x + 1], exact 0 at 0. )
dsp: tanh | x -- y |
  x -20.0 20.0 fclamp 2.8853900817779268 f* exp2 | e |
  e 1.0 f-  e 1.0 f+  f/
;
