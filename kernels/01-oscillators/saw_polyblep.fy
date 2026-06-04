( saw_polyblep.fy - stateful scalar polyBLEP saw oscillator.

  k-saw-polyblep ( out phase freq inv-sample-rate -- )

  phase is a raw f64 cell in the 0..1 range.  The kernel writes one output
  sample and stores the advanced wrapped phase back into the phase cell.

  The words above the adapter are intentionally reusable oscillator
  construction blocks.  They should fuse away under dsp2 inlining. )

dsp2: phase-advance01
  f+ fwrap01
;

dsp2: saw-raw
  dup f+ 1.0 f-
;

( phase dt -- correction )
dsp2: polyblep
  fpolyblep
;

( phase dt -- sample )
dsp2: saw-polyblep
  1 pick saw-raw
  2 pick 2 pick polyblep
  f-
  swap drop swap drop
;

dsp2: k-saw-polyblep
  2 pick f@64
  2 pick 2 pick f*
  1 pick 1 pick saw-polyblep
  6 pick f!64
  phase-advance01
  3 pick f!64
  drop drop drop drop
;
