( adsr_linear.fy - stateless linear ADSR control-rate kernel. )

include "primitives/segments.fy"

( out time attack decay sustain gate release -- : write linear ADSR value for the current time cell. )
dsp2: k-adsr-linear
  5 pick f@64
  5 pick 5 pick 5 pick 5 pick 5 pick adsr-linear
  7 pick f!64
  drop drop drop drop drop drop drop
;
