( rational.fy - the rational soft clipper.

  x [27 + x^2] / [27 + 9 x^2] is the [3/2] Pade form of tanh: it follows
  tanh closely for small x, reaches exactly 1 at |x| = 3 and is held
  there.  It is a shaper with its own character - harder shoulder than
  tanh - not an approximation to be swapped for dsp-std tanh. )

( x -- y )
dsp: tanh-rational | x -- y |
  x -4.0 4.0 fclamp | c |
  c c f* | c2 |
  c2 27.0 f+ c f*  c2 9.0 f* 27.0 f+  f/
  -1.0 1.0 fclamp
;
