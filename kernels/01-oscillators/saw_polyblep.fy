( saw_polyblep.fy - stateful scalar polyBLEP saw oscillator.

  k-saw-polyblep ( out phase freq inv-sample-rate -- )

  phase is a raw f64 cell in the 0..1 range.  The kernel writes one output
  sample and stores the advanced wrapped phase back into the phase cell.

  The words above the adapter are intentionally reusable oscillator
  construction blocks.  They should fuse away under dsp2 inlining. )

dsp2: phase-advance01
  f+ fwrap01
;

dsp2: saw-rising-raw
  dup f+ 1.0 f-
;

dsp2: saw-falling-raw
  1.0 swap dup f+ f-
;

dsp2: cap-ramp-raw
  fcapramp
;

dsp2: top-cut
  -1.0 0.65 fclamp
;

( phase dt -- correction )
dsp2: polyblep
  fpolyblep
;

( phase dt -- sample )
dsp2: saw-polyblep
  1 pick saw-rising-raw
  2 pick 2 pick polyblep
  f-
  swap drop swap drop
;

dsp2: saw-falling-polyblep
  1 pick saw-falling-raw
  2 pick 2 pick polyblep
  f+
  swap drop swap drop
;

dsp2: cap-saw-polyblep
  1 pick cap-ramp-raw
  2 pick 2 pick polyblep
  f-
  swap drop swap drop
;

dsp2: pulse-polyblep
  fpulseblep
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

dsp2: k-saw-falling-polyblep
  2 pick f@64
  2 pick 2 pick f*
  1 pick 1 pick saw-falling-polyblep
  6 pick f!64
  phase-advance01
  3 pick f!64
  drop drop drop drop
;

dsp2: k-saw-cap-polyblep
  2 pick f@64
  2 pick 2 pick f*
  1 pick 1 pick cap-saw-polyblep
  6 pick f!64
  phase-advance01
  3 pick f!64
  drop drop drop drop
;

dsp2: k-saw-topcut-polyblep
  2 pick f@64
  2 pick 2 pick f*
  1 pick 1 pick saw-polyblep
  top-cut
  6 pick f!64
  phase-advance01
  3 pick f!64
  drop drop drop drop
;

dsp2: k-square-polyblep
  2 pick f@64
  2 pick 2 pick f*
  1 pick 1 pick 0.5 pulse-polyblep
  6 pick f!64
  phase-advance01
  3 pick f!64
  drop drop drop drop
;

dsp2: k-pulse-polyblep
  3 pick f@64
  3 pick 3 pick f*
  1 pick 1 pick 4 pick pulse-polyblep
  7 pick f!64
  phase-advance01
  4 pick f!64
  drop drop drop drop drop
;
