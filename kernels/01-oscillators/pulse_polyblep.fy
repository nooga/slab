( pulse_polyblep.fy - stateful variable-width polyBLEP pulse kernel. )

include "primitives/phase.fy"
include "primitives/blep.fy"

( out phase freq inv-sample-rate width -- : write one variable-width polyBLEP pulse sample and advance phase. )
dsp2: k-pulse-polyblep
  3 pick f@64
  3 pick 3 pick f*
  1 pick 1 pick 4 pick pulse-polyblep
  7 pick f!64
  phase-advance01
  4 pick f!64
  drop drop drop drop drop
;
