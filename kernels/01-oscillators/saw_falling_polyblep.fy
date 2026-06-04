( saw_falling_polyblep.fy - stateful falling polyBLEP saw kernel. )

include "primitives/phase.fy"
include "primitives/blep.fy"

( out phase freq inv-sample-rate -- : write one falling polyBLEP saw sample and advance phase. )
dsp2: k-saw-falling-polyblep
  2 pick f@64
  2 pick 2 pick f*
  1 pick 1 pick saw-falling-polyblep
  6 pick f!64
  phase-advance01
  3 pick f!64
  drop drop drop drop
;
