( follow.fy - an envelope follower: rectify, then a one-pole that rises
  at the attack coefficient and falls at the release one.  The state is
  flushed below ~1e-18 so a decaying tail reaches 0 and the machine can
  go idle. )

include "math.fy"

ustruct: Follow f64 env ;

( t sr -- c : the one-pole coefficient for time constant t seconds
  [63 % of a step in t]. )
dsp: follow-coef | t sr -- c |
  -1.0  t 0.00001 fmax sr f*  f/ exp
;

( s x atk-c rel-c -- env : one step on |x|. )
dsp: follow-step | s:Follow x atk-c rel-c -- env |
  x fabs | a |
  s.env | e0 |
  e0 a atk-c rel-c fsel-lt | c |
  a  e0 a f-  c f*  f+ | e |
  e 1.0e-18 f+ 1.0e-18 f- | e |
  e -> s.env
  e
;
