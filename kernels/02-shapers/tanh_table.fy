( tanh_table.fy - table-driven tanh saturator kernel.

  k-tanh-table ( out in table span drive -- )

  table is a raw f64 array covering [-4, 4].
  span is table_len - 2; one guard cell is left at the high edge.
  drive scales input before lookup; driven input is clamped to [-4, 4].

  This is intentionally single-sample and quotation-free. The probe
  sweeps it from Zig until Fy has compile-time loop/quote fusion for
  `dsp:` kernels.

  The fixture samples off-grid points and checks linear interpolation
  between adjacent table cells. )

dsp1: k-tanh-table
  3 pick f@64
  1 pick f*
  -4.0 4.0 fclamp
  4.0 f+
  0.125 f*
  2 pick i>f f*
  dup f>i
  dup i>f
  rot swap f-
  1 pick
  5 pick swap 8 * + f@64
  2 pick 1 +
  6 pick swap 8 * + f@64
  over f-
  2 pick f*
  f+
  swap drop swap drop
  5 pick f!64
  drop drop drop drop drop
;

( k-tanh-rational ( out in table span drive -- )

  Cheap tanh-like approximation:

    y = x * (27 + x*x) / (27 + 9*x*x)

  This ignores the table/span slots but keeps the same ABI as
  k-tanh-table, so the probe can compare both kernels directly.  The
  dsp: shaper kernels use is tanh-rational in rational.fy. )

dsp1: k-tanh-rational
  3 pick f@64
  1 pick f*
  -4.0 4.0 fclamp
  dup dup f*
  dup 27.0 f+
  2 pick f*
  1 pick 9.0 f* 27.0 f+
  f/
  -1.0 1.0 fclamp
  swap drop swap drop
  5 pick f!64
  drop drop drop drop drop
;
