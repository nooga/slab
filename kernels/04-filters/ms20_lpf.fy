( ms20_lpf.fy - stateful MS-20-style lowpass kernel.

  This is the first real fy wrapper for the nonlinear lowpass. The heavy
  filter step is a low-level `dsp2:` primitive in fy (`fms20-lpf4`) because
  spelling four clipped integrator substeps with raw stack words is both slow
  and unreadable.

  Coefficients are passed in for now:
  - `g` is tan(pi * cutoff / oversampled_sample_rate)
  - `damping` is the resonance-derived damping term

  The host/probe computes those until `dsp2:` grows coefficient math such as
  tan/exp or a dedicated cutoff-to-coefficient primitive. )

( out ic1 ic2 input g damping drive -- : render one four-times-oversampled nonlinear lowpass sample. )
dsp2: k-ms20-lpf4
  5 pick 5 pick 5 pick 5 pick 5 pick 5 pick fms20-lpf4
  7 pick f!64
  drop drop drop drop drop drop drop
;

( out ic1 ic2 input g damping drive -- : render one lowpass sample with a division-free cubic clipper. )
dsp2: k-ms20-lpf4-cubic
  5 pick 5 pick 5 pick 5 pick 5 pick 5 pick fms20-lpf4-cubic
  7 pick f!64
  drop drop drop drop drop drop drop
;
