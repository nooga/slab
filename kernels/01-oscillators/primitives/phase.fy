( phase.fy - phase-domain helpers for oscillator kernels. )

( phase dt -- phase' : advance normalized 0..1 phase by dt and wrap once. )
dsp: phase-advance01
  f+ fwrap01
;
