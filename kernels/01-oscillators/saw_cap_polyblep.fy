( saw_cap_polyblep.fy - stateful capacitor-like polyBLEP saw kernel. )

include "primitives/phase.fy"
include "primitives/blep.fy"

( out phase freq inv-sample-rate -- : write one capacitor-like polyBLEP saw sample and advance phase. )
dsp: k-saw-cap-polyblep
  2 pick f@64
  2 pick 2 pick f*
  1 pick 1 pick cap-saw-polyblep
  6 pick f!64
  phase-advance01
  3 pick f!64
  drop drop drop drop
;
