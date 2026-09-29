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
include "../../kernels/00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
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

( ctx state params -- : each block, the ALGO row into the routing
  params - the 15 upper-triangular weights, the carriers at VOLUME / 16
  [Dexed's output scale: one full carrier is 2 / 16], feedback on the
  row's operator at 2^(FEEDBACK - 8) [msfa: (y0 + y1) >> (9 - fb)] -
  and the LFO's per-sample rate, delay increments and depths
  [msfa Lfo::reset, Dx7Note::init].  Flat (no call:). )
dsp: fm86-derive
  | ctx:Ctx state params:Fm86Params |
  ctx.data& p@64 | derive-data |
  params.algo 1.0 f- 48.0 f*   | rb |
  params.volume 0.0625 f*      | vol |
  params.feedback 0.5 f<  0.0  params.feedback 8.0 f- exp2  select | fbk |
  derive-data rb  1.0 f+ f@i -> params.w01
  derive-data rb  2.0 f+ f@i -> params.w02
  derive-data rb  3.0 f+ f@i -> params.w03
  derive-data rb  4.0 f+ f@i -> params.w04
  derive-data rb  5.0 f+ f@i -> params.w05
  derive-data rb  8.0 f+ f@i -> params.w12
  derive-data rb  9.0 f+ f@i -> params.w13
  derive-data rb 10.0 f+ f@i -> params.w14
  derive-data rb 11.0 f+ f@i -> params.w15
  derive-data rb 15.0 f+ f@i -> params.w23
  derive-data rb 16.0 f+ f@i -> params.w24
  derive-data rb 17.0 f+ f@i -> params.w25
  derive-data rb 22.0 f+ f@i -> params.w34
  derive-data rb 23.0 f+ f@i -> params.w35
  derive-data rb 29.0 f+ f@i -> params.w45
  derive-data rb 36.0 f+ f@i vol f* -> params.c0
  derive-data rb 37.0 f+ f@i vol f* -> params.c1
  derive-data rb 38.0 f+ f@i vol f* -> params.c2
  derive-data rb 39.0 f+ f@i vol f* -> params.c3
  derive-data rb 40.0 f+ f@i vol f* -> params.c4
  derive-data rb 41.0 f+ f@i vol f* -> params.c5
  derive-data rb 42.0 f+ f@i fbk f* -> params.fb0
  derive-data rb 43.0 f+ f@i fbk f* -> params.fb1
  derive-data rb 44.0 f+ f@i fbk f* -> params.fb2
  derive-data rb 45.0 f+ f@i fbk f* -> params.fb3
  derive-data rb 46.0 f+ f@i fbk f* -> params.fb4
  derive-data rb 47.0 f+ f@i fbk f* -> params.fb5
  ( LFO: speed [lfoSource x 4437500000 / 2^32 Hz], delay [99 - DELAY
    counts up to the halfway point, then ramps the depth in] )
  ctx.sr | sr |
  dx-lfo params.lfo-speed f@i 1.0332 f* sr f/ -> params.lfo-inc
  99.0 params.lfo-delay f- | a |
  a 16.0 f/ floor | ah |
  a ah 16.0 f* f- 16.0 f+  1.0 ah f+ fexp2i f* | a1 |
  a1 128.0 f/ floor 128.0 f* 128.0 fmax | a2 |
  25190424.0 sr f/ 2.3283064365386963e-10 f* | unit |
  a 98.5 f>  2.0  unit a1 f*  select -> params.dl-inc1
  a 98.5 f>  2.0  unit a2 f*  select -> params.dl-inc2
  params.lfo-pmd 165.0 f* 64.0 f/ floor -> params.pmd
  params.lfo-amd 165.0 f* 64.0 f/ floor -> params.amd
  ( the DX7 engines: 12-bit operators and the gain-ranged DAC with a
    16 kHz filter [DX7], or 14-bit operators and a linear DAC with a
    20 kHz one [DX7 II]; the voice enters the DAC as its carriers
    divided by their count, full scale 2 )
  params.engine 1.5 f> mask>f | v2 |
  v2 -> params.v2
  v2 0.5 f>  16384.0  4096.0  select -> params.opbits
  derive-data rb 36.0 f+ f@i  derive-data rb 37.0 f+ f@i f+  derive-data rb 38.0 f+ f@i f+
  derive-data rb 39.0 f+ f@i f+  derive-data rb 40.0 f+ f@i f+  derive-data rb 41.0 f+ f@i f+
    1.0 fmax | ncar |
  vol 0.000000001 fmax 2.0 f* ncar f* | dsc |
  dsc -> params.dacout
  1.0 dsc f/ -> params.dacin
  v2 0.5 f>  20000.0  16000.0  select  sr 0.45 f* fmin | fc |
  fc sr f/ 3.141592653589793 f* tan-warp | k |
  k k f* | kk |
  ( 4-pole Butterworth: sections at Q 0.5412 and 1.3066 )
  1.0  1.0 k 0.5411961001461969 f/ f+ kk f+  f/ | n1 |
  kk n1 f* | b1 |
  b1 -> params.fa0  b1 2.0 f* -> params.fa1  b1 -> params.fa2
  kk 1.0 f- 2.0 f* n1 f* -> params.fa3
  1.0 k 0.5411961001461969 f/ f- kk f+ n1 f* -> params.fa4
  1.0  1.0 k 1.3065629648763766 f/ f+ kk f+  f/ | n2 |
  kk n2 f* | b2 |
  b2 -> params.fb0q  b2 2.0 f* -> params.fb1q  b2 -> params.fb2q
  kk 1.0 f- 2.0 f* n2 f* -> params.fb3q
  1.0 k 1.3065629648763766 f/ f- kk f+ n2 f* -> params.fb4q
  params.pms | ps |
  ps 0.5 0.0  ps 1.5 10.0  ps 2.5 20.0  ps 3.5 33.0  ps 4.5 55.0  ps 5.5 92.0  ps 6.5 153.0 255.0
    fsel-lt fsel-lt fsel-lt fsel-lt fsel-lt fsel-lt fsel-lt -> params.pmsv
;
