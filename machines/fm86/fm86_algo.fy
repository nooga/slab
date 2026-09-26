( fm86_algo.fy — the 32 DX7 algorithms as fy data, plus the routing `derive`
  word. This keeps all DX7-specific knowledge in the machine (fy); the host
  only calls a generic derive hook with (params, derive-data).

  derive-data is a heap table the manifest builds: 32 rows of 48 f64. Per row
  the first 36 are a 6x6 modulation matrix m[car][mod] (1.0 where operator
  mod+1 modulates carrier car+1), then 6 carrier flags, then 6 feedback flags.
  The 6x6 layout makes the table trivial to fill (no triangular packing); the
  derive word reads only the 15 upper-triangular cells it needs.

  fm86-derive ( params derive-data -- ) runs each block (cheap): it selects the
  ALGO row and copies the routing into params, folding MASTER into the carrier
  weights and FEEDBACK into the per-op feedback. dx7_algorithms.zig is the Zig
  oracle the fy table is cross-checked against. )

( --- table builder (non-dsp: heap + loops) --------------------------- )

:: _fm86-t 8 alloc ;   ( table base, during build )
:: _fm86-r 8 alloc ;   ( current row )

( table elem -- : write 1.0 at table[elem] (f64 elements). )
: fm86-tset  ( table elem -- ) 8 * + 1.0 swap f!64 ;

( mod car -- : operator `mod` modulates carrier `car` in the current row.
  6x6 cell = car-1 row of 6, plus mod-1. )
: fm-e   ( mod car -- ) 1 - 6 * swap 1 - + _fm86-r @64 48 * + _fm86-t @64 swap fm86-tset ;
( car -- : carrier flag, at row offset 36 + car-1. )
: fm-c   ( car -- ) 1 - 36 + _fm86-r @64 48 * + _fm86-t @64 swap fm86-tset ;
( op -- : feedback flag, at row offset 42 + op-1. )
: fm-f   ( op -- ) 1 - 42 + _fm86-r @64 48 * + _fm86-t @64 swap fm86-tset ;
( n -- : select the current row. )
: fm-row ( n -- ) _fm86-r !64 ;

( -- table : allocate the zeroed 32x48 table and fill the 32 algorithms.
  Edges are `mod car fm-e`, carriers `car fm-c`, feedback `op fm-f`. Data
  transcribed from the DX7 chart; validated against dx7_algorithms.zig. )
: fm86-algo-table  ( -- table )
  32 48 * 8 * alloc _fm86-t !64
  0  fm-row  6 5 fm-e 5 4 fm-e 4 3 fm-e 2 1 fm-e   1 fm-c 3 fm-c            6 fm-f
  1  fm-row  6 5 fm-e 5 4 fm-e 4 3 fm-e 2 1 fm-e   1 fm-c 3 fm-c            2 fm-f
  2  fm-row  6 5 fm-e 5 4 fm-e 3 2 fm-e 2 1 fm-e   1 fm-c 4 fm-c            6 fm-f
  3  fm-row  6 5 fm-e 5 4 fm-e 3 2 fm-e 2 1 fm-e   1 fm-c 4 fm-c            6 fm-f
  4  fm-row  6 5 fm-e 4 3 fm-e 2 1 fm-e            1 fm-c 3 fm-c 5 fm-c     6 fm-f
  5  fm-row  6 5 fm-e 4 3 fm-e 2 1 fm-e            1 fm-c 3 fm-c 5 fm-c     6 fm-f
  6  fm-row  6 5 fm-e 5 3 fm-e 4 3 fm-e 2 1 fm-e   1 fm-c 3 fm-c            6 fm-f
  7  fm-row  6 5 fm-e 5 3 fm-e 4 3 fm-e 2 1 fm-e   1 fm-c 3 fm-c            4 fm-f
  8  fm-row  6 5 fm-e 5 3 fm-e 4 3 fm-e 2 1 fm-e   1 fm-c 3 fm-c            2 fm-f
  9  fm-row  6 4 fm-e 5 4 fm-e 3 2 fm-e 2 1 fm-e   1 fm-c 4 fm-c            3 fm-f
  10 fm-row  6 4 fm-e 5 4 fm-e 3 2 fm-e 2 1 fm-e   1 fm-c 4 fm-c            6 fm-f
  11 fm-row  6 3 fm-e 5 3 fm-e 4 3 fm-e 2 1 fm-e   1 fm-c 3 fm-c            2 fm-f
  12 fm-row  6 3 fm-e 5 3 fm-e 4 3 fm-e 2 1 fm-e   1 fm-c 3 fm-c            6 fm-f
  13 fm-row  6 4 fm-e 5 4 fm-e 4 3 fm-e 2 1 fm-e   1 fm-c 3 fm-c            6 fm-f
  14 fm-row  6 4 fm-e 5 4 fm-e 4 3 fm-e 2 1 fm-e   1 fm-c 3 fm-c            2 fm-f
  15 fm-row  6 5 fm-e 4 3 fm-e 5 1 fm-e 3 1 fm-e 2 1 fm-e   1 fm-c          6 fm-f
  16 fm-row  6 5 fm-e 4 3 fm-e 5 1 fm-e 3 1 fm-e 2 1 fm-e   1 fm-c          2 fm-f
  17 fm-row  6 5 fm-e 5 4 fm-e 4 1 fm-e 3 1 fm-e 2 1 fm-e   1 fm-c          3 fm-f
  18 fm-row  6 5 fm-e 6 4 fm-e 3 2 fm-e 2 1 fm-e   1 fm-c 4 fm-c 5 fm-c     6 fm-f
  19 fm-row  6 4 fm-e 5 4 fm-e 3 2 fm-e 3 1 fm-e   1 fm-c 2 fm-c 4 fm-c     3 fm-f
  20 fm-row  6 5 fm-e 6 4 fm-e 3 2 fm-e 3 1 fm-e   1 fm-c 2 fm-c 4 fm-c 5 fm-c   3 fm-f
  21 fm-row  6 5 fm-e 6 4 fm-e 6 3 fm-e 2 1 fm-e   1 fm-c 3 fm-c 4 fm-c 5 fm-c   6 fm-f
  22 fm-row  6 5 fm-e 6 4 fm-e 3 2 fm-e          1 fm-c 2 fm-c 4 fm-c 5 fm-c     6 fm-f
  23 fm-row  6 5 fm-e 6 4 fm-e 6 3 fm-e          1 fm-c 2 fm-c 3 fm-c 4 fm-c 5 fm-c   6 fm-f
  24 fm-row  6 5 fm-e 6 4 fm-e                   1 fm-c 2 fm-c 3 fm-c 4 fm-c 5 fm-c   6 fm-f
  25 fm-row  6 4 fm-e 5 4 fm-e 3 2 fm-e          1 fm-c 2 fm-c 4 fm-c       6 fm-f
  26 fm-row  6 4 fm-e 5 4 fm-e 3 2 fm-e          1 fm-c 2 fm-c 4 fm-c       3 fm-f
  27 fm-row  5 4 fm-e 4 3 fm-e 2 1 fm-e          1 fm-c 3 fm-c 6 fm-c       5 fm-f
  28 fm-row  6 5 fm-e 4 3 fm-e                   1 fm-c 2 fm-c 3 fm-c 5 fm-c     6 fm-f
  29 fm-row  5 4 fm-e 4 3 fm-e                   1 fm-c 2 fm-c 3 fm-c 6 fm-c     5 fm-f
  30 fm-row  6 5 fm-e                            1 fm-c 2 fm-c 3 fm-c 4 fm-c 5 fm-c   6 fm-f
  31 fm-row                                      1 fm-c 2 fm-c 3 fm-c 4 fm-c 5 fm-c 6 fm-c   6 fm-f
  _fm86-t @64
;

( --- routing derive word (dsp: indexes the table, writes params) ----- )

( params derive-data -- : fill the voice routing from the ALGO row. Copies the
  15 upper-triangular weights, scales the 6 carrier flags by MASTER and the 6
  feedback flags by FEEDBACK. Flat (no call:) so the raw caller can build it. )
dsp: fm86-derive
  | params derive-data |
  params Fm86Params.algo@ 1.0 f- 48.0 f*   | rb |
  params Fm86Params.master@                | master |
  params Fm86Params.feedback@              | feedback |
  derive-data rb  1.0 f+ f@i params Fm86Params.w01-p f!64
  derive-data rb  2.0 f+ f@i params Fm86Params.w02-p f!64
  derive-data rb  3.0 f+ f@i params Fm86Params.w03-p f!64
  derive-data rb  4.0 f+ f@i params Fm86Params.w04-p f!64
  derive-data rb  5.0 f+ f@i params Fm86Params.w05-p f!64
  derive-data rb  8.0 f+ f@i params Fm86Params.w12-p f!64
  derive-data rb  9.0 f+ f@i params Fm86Params.w13-p f!64
  derive-data rb 10.0 f+ f@i params Fm86Params.w14-p f!64
  derive-data rb 11.0 f+ f@i params Fm86Params.w15-p f!64
  derive-data rb 15.0 f+ f@i params Fm86Params.w23-p f!64
  derive-data rb 16.0 f+ f@i params Fm86Params.w24-p f!64
  derive-data rb 17.0 f+ f@i params Fm86Params.w25-p f!64
  derive-data rb 22.0 f+ f@i params Fm86Params.w34-p f!64
  derive-data rb 23.0 f+ f@i params Fm86Params.w35-p f!64
  derive-data rb 29.0 f+ f@i params Fm86Params.w45-p f!64
  derive-data rb 36.0 f+ f@i master f* params Fm86Params.c0-p f!64
  derive-data rb 37.0 f+ f@i master f* params Fm86Params.c1-p f!64
  derive-data rb 38.0 f+ f@i master f* params Fm86Params.c2-p f!64
  derive-data rb 39.0 f+ f@i master f* params Fm86Params.c3-p f!64
  derive-data rb 40.0 f+ f@i master f* params Fm86Params.c4-p f!64
  derive-data rb 41.0 f+ f@i master f* params Fm86Params.c5-p f!64
  derive-data rb 42.0 f+ f@i feedback f* params Fm86Params.fb0-p f!64
  derive-data rb 43.0 f+ f@i feedback f* params Fm86Params.fb1-p f!64
  derive-data rb 44.0 f+ f@i feedback f* params Fm86Params.fb2-p f!64
  derive-data rb 45.0 f+ f@i feedback f* params Fm86Params.fb3-p f!64
  derive-data rb 46.0 f+ f@i feedback f* params Fm86Params.fb4-p f!64
  derive-data rb 47.0 f+ f@i feedback f* params Fm86Params.fb5-p f!64
  drop2 drop2 drop
;
