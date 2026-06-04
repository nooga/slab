( segments.fy - reusable envelope segment models. )

( time attack decay sustain gate release -- amp : evaluate a linear ADSR envelope at time. )
dsp2: adsr-linear
  fadsr-linear
;

( time attack decay sustain gate release -- amp : evaluate a capacitor-like ADSR envelope at time. )
dsp2: adsr-cap
  fadsr-cap
;
