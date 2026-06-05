( control.fy - scalar control/audio utility kernels for voice construction.

  These are deliberately small `dsp2:` words. They form the glue between
  oscillators, envelopes, filters, and final gain without depending on a
  Slab machine or `MachineCtx` host service. )

( out hz inv-sample-rate -- : write normalized phase increment for one sample. )
dsp2: k-hz-step
  1 pick 1 pick f*
  3 pick f!64
  drop drop drop
;

( out current target coeff -- : slew current toward target by coeff and update current state. )
dsp2: k-slew-onepole
  2 pick f@64
  2 pick f-
  1 pick f*
  3 pick f@64
  swap f-
  dup 5 pick f!64
  3 pick f!64
  drop drop drop drop
;

( out input amp level -- : write input multiplied by envelope amp and output level. )
dsp2: k-vca
  2 pick f@64
  2 pick f*
  1 pick f*
  4 pick f!64
  drop drop drop drop
;

( out osc-a osc-b gain-a gain-b -- : mix two oscillator samples with independent gains. )
dsp2: k-osc-mix2
  3 pick f@64
  2 pick f*
  3 pick f@64
  2 pick f*
  f+
  5 pick f!64
  drop drop drop drop drop
;
