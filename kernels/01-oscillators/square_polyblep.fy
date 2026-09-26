( square_polyblep.fy - stateful 50 percent duty polyBLEP square kernel. )

include "primitives/phase.fy"
include "primitives/blep.fy"

( out phase freq inv-sample-rate -- : write one 50 percent duty polyBLEP pulse sample and advance phase. )
dsp: k-square-polyblep
  2 pick f@64
  2 pick 2 pick f*
  1 pick 1 pick 0.5 pulse-polyblep
  6 pick f!64
  phase-advance01
  3 pick f!64
  drop drop drop drop
;
