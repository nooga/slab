( adsr_cap.fy - stateless capacitor-like ADSR control-rate kernel. )

include "primitives/segments.fy"

( out time attack decay sustain gate release -- : write capacitor-like ADSR value for the current time cell. )
dsp: k-adsr-cap
  5 pick f@64
  5 pick 5 pick 5 pick 5 pick 5 pick adsr-cap
  7 pick f!64
  drop drop drop drop drop drop drop
;
