( table.fy - reading `table:` data from dsp: words.

  `table: name len body ;` [fy, docs/18] builds len + 1 f64 at load: the
  body runs for i = 0..len and leaves one number.  `name` is the table's
  address, `name-len` its length as a float.  The extra cell at i = len is
  what lets tbl-lerp read index len - 1 + frac safely.

    table: curve 256  256.0 f/ dup f* ;       [ x^2 over 0..1 ]
    dsp: shape | x -- y |  curve  x curve-len f*  tbl-lerp ;

  The body is ordinary fy, so it may use the heap, loops, or libm through
  bind:.

  Indices are not clamped: keep x in [0, len] yourself. )

( t x -- y : linear interpolation at fractional index x. )
dsp: tbl-lerp | t x -- y |
  x floor | i |
  t i f@i | a |
  t 8 ptr+ i f@i  a f-  x i f- f*  a f+
;
