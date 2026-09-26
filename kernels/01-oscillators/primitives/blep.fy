( blep.fy - polyBLEP anti-alias helpers for oscillator kernels. )

include "shapes.fy"

( phase dt -- correction : the two-sample polyBLEP residual around the
  phase-zero edge: t = phase/dt just after it, u = [phase-1]/dt just before. )
dsp: polyblep | phase dt -- c |
  phase dt f/ | t |
  phase dt  t t f+ t t f* f- 1.0 f-  0.0  fsel-lt | c |
  phase 1.0 f- dt f/ | u |
  1.0 dt f-  phase  u u f+ u u f* f+ 1.0 f+  c  fsel-lt
;

( phase dt -- sample : render a rising saw with phase-zero polyBLEP correction. )
dsp: saw-polyblep
  1 pick saw-rising-raw
  2 pick 2 pick polyblep
  f-
  swap drop swap drop
;

( phase dt -- sample : render a falling saw with phase-zero polyBLEP correction. )
dsp: saw-falling-polyblep
  1 pick saw-falling-raw
  2 pick 2 pick polyblep
  f+
  swap drop swap drop
;

( phase dt -- sample : render a capacitor-like saw with phase-zero polyBLEP correction. )
dsp: cap-saw-polyblep
  1 pick cap-ramp-raw
  2 pick 2 pick polyblep
  f-
  swap drop swap drop
;

( phase dt width -- sample : render a bipolar pulse with polyBLEP-corrected edges. )
dsp: pulse-polyblep | phase dt width -- y |
  phase width 1.0 -1.0 fsel-lt
  phase dt polyblep f+
  ( the falling edge sits at phase = width )
  phase width f- | p |
  p 0.0  p 1.0 f+  p  fsel-lt  dt polyblep f-
;
