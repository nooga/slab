( blep.fy - polyBLEP anti-alias helpers for oscillator kernels. )

include "shapes.fy"

( phase dt -- correction : return the scalar phase-zero polyBLEP correction. )
dsp2: polyblep
  fpolyblep
;

( phase dt -- sample : render a rising saw with phase-zero polyBLEP correction. )
dsp2: saw-polyblep
  1 pick saw-rising-raw
  2 pick 2 pick polyblep
  f-
  swap drop swap drop
;

( phase dt -- sample : render a falling saw with phase-zero polyBLEP correction. )
dsp2: saw-falling-polyblep
  1 pick saw-falling-raw
  2 pick 2 pick polyblep
  f+
  swap drop swap drop
;

( phase dt -- sample : render a capacitor-like saw with phase-zero polyBLEP correction. )
dsp2: cap-saw-polyblep
  1 pick cap-ramp-raw
  2 pick 2 pick polyblep
  f-
  swap drop swap drop
;

( phase dt width -- sample : render a bipolar pulse with polyBLEP-corrected edges. )
dsp2: pulse-polyblep
  fpulseblep
;
