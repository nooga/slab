( Slab substrate smoke test — one-voice sine synth driven by the host.
  Audio thread calls `audio-fill` with ( buf frames -- ) each block.
  UI thread writes `freq-cell` and `play-cell` via `Fy.run`. )

( Inline libm:sin — we skip `import "libm"` to avoid a file-path dep
  when the program is embedded via @embedFile from the Zig host. )
:: _libm "/usr/lib/libSystem.B.dylib" dl-open ;
:: _sin  _libm "sin" dl-sym ;
: sin  _sin bind: d:d ;

:: TWO_PI 6.283185307179586 ;
:: SAMPLE_RATE 44100.0 ;

:: phase-cell 8 alloc ;
:: freq-cell  8 alloc ;
:: play-cell  4 alloc ;

0.0 phase-cell !64
440.0 freq-cell !64
0 play-cell !32

( -- sample-s16 )
: gen-sample
  phase-cell @64
  dup sin 0.25 f* 32000.0 f*
  f>i
  swap
  freq-cell @64 TWO_PI f* SAMPLE_RATE f/ f+
  dup TWO_PI f> [ TWO_PI f- ] [ ] ifte
  phase-cell !64
;

( buf frames -- )
: audio-fill
  0 swap
  [
    play-cell @32 [
      over over 2 * + gen-sample swap !16
    ] [
      over over 2 * + 0 swap !16
    ] ifte
    1+
  ] dotimes
  drop drop
;

( Leave the callback fptr on the data stack as the return value of Fy.run. )
callback: pi:v audio-fill
