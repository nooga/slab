( phase.fy - phase-domain helpers for oscillator kernels. )

( x -- x' : wrap once into 0..1 - one period either way. )
dsp: wrap01 | x -- y |
  1.0 x  x 1.0 f-  x  fsel-lt | r |
  r 0.0  r 1.0 f+  r  fsel-lt
;

( phase dt -- phase' : advance normalized 0..1 phase by dt and wrap once. )
dsp: phase-advance01
  f+ wrap01
;
