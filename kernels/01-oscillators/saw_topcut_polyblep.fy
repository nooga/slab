( saw_topcut_polyblep.fy - stateful asymmetric top-cut polyBLEP saw kernel. )

include "primitives/phase.fy"
include "primitives/blep.fy"

( out phase freq inv-sample-rate -- : write one top-cut polyBLEP saw sample and advance phase. )
dsp: k-saw-topcut-polyblep
  2 pick f@64
  2 pick 2 pick f*
  1 pick 1 pick saw-polyblep
  top-cut
  6 pick f!64
  phase-advance01
  3 pick f!64
  drop drop drop drop
;
