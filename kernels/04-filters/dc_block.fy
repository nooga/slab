( dc_block.fy - stateful one-pole DC blocker.

  Keep previous input and previous output in separate f64 cells. This avoids
  pointer arithmetic in the current `dsp:` raw ABI and maps directly onto a
  future voice-state struct where each field is passed by address. )

( out prev-x prev-y input coeff -- : write y = input - prev-x + coeff * prev-y and update state. )
dsp: k-dc-block
  3 pick f@64
  2 pick swap f-
  3 pick f@64
  2 pick f*
  f+
  dup 6 pick f!64
  dup 4 pick f!64
  2 pick 5 pick f!64
  drop drop drop drop drop drop
;
