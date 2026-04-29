( chorus1/chorus1.fy — Juno-style mono/stereo widening chorus.
  Two BBD-like modulated delay lines with fixed I / II / I+II modes. )

include "../lib/machine.fy"

:: _lib "/usr/lib/libSystem.B.dylib" dl-open ;
:: _sin  _lib "sin"  dl-sym ;
:: _tanh _lib "tanh" dl-sym ;
noalloc: sin  _sin  bind: d:d ;
noalloc: tanh _tanh bind: d:d ;

:: TWO_PI 6.283185307179586 ;
:: BUF_N 4096 ;
:: BUF_N_F 4096.0 ;
:: BUF_BYTES 16384 ;
:: DELAY_OFFSET 256.0 ;

:: dl-buf BUF_BYTES alloc ;
:: dr-buf BUF_BYTES alloc ;
:: frame-cell 4 alloc ; 0 frame-cell !32
:: idx-cell 4 alloc ; 0 idx-cell !32
:: phase-cell 4 alloc ; 0.0 phase-cell f!32
:: mode-cell 4 alloc ; 0 mode-cell !32
:: rate-inc-cell 4 alloc ; 0.0 rate-inc-cell f!32
:: depth-cell 4 alloc ; 0.0 depth-cell f!32
:: base-delay-cell 4 alloc ; 0.0 base-delay-cell f!32
:: mix-cell 4 alloc ; 0.0 mix-cell f!32
:: noise-gain-cell 4 alloc ; 0.0 noise-gain-cell f!32
:: level-cell 4 alloc ; 1.0 level-cell f!32

:: inl-cell 4 alloc ; 0.0 inl-cell f!32
:: inr-cell 4 alloc ; 0.0 inr-cell f!32
:: mono-cell 4 alloc ; 0.0 mono-cell f!32
:: drive-l-cell 4 alloc ; 0.0 drive-l-cell f!32
:: drive-r-cell 4 alloc ; 0.0 drive-r-cell f!32
:: pre-l-cell 4 alloc ; 0.0 pre-l-cell f!32
:: pre-r-cell 4 alloc ; 0.0 pre-r-cell f!32
:: wet-l-cell 4 alloc ; 0.0 wet-l-cell f!32
:: wet-r-cell 4 alloc ; 0.0 wet-r-cell f!32
:: post-l-cell 4 alloc ; 0.0 post-l-cell f!32
:: post-r-cell 4 alloc ; 0.0 post-r-cell f!32
:: dc-xl-cell 4 alloc ; 0.0 dc-xl-cell f!32
:: dc-yl-cell 4 alloc ; 0.0 dc-yl-cell f!32
:: dc-xr-cell 4 alloc ; 0.0 dc-xr-cell f!32
:: dc-yr-cell 4 alloc ; 0.0 dc-yr-cell f!32
:: lfo-cell 4 alloc ; 0.0 lfo-cell f!32
:: delay-l-cell 4 alloc ; 0.0 delay-l-cell f!32
:: delay-r-cell 4 alloc ; 0.0 delay-r-cell f!32
:: pos-cell 4 alloc ; 0.0 pos-cell f!32
:: frac-cell 4 alloc ; 0.0 frac-cell f!32
:: base-cell 4 alloc ; 0 base-cell !32
:: next-cell 4 alloc ; 0 next-cell !32
:: s0-cell 4 alloc ; 0.0 s0-cell f!32
:: outl-cell 4 alloc ; 0.0 outl-cell f!32
:: outr-cell 4 alloc ; 0.0 outr-cell f!32

:: _lbl_c1    "CHORUS" cstr-new ;
:: _lbl_mode  "MODE"   cstr-new ;
:: _lbl_i     "I"      cstr-new ;
:: _lbl_ii    "II"     cstr-new ;
:: _lbl_iii   "I+II"   cstr-new ;
:: _lbl_mix   "MIX"    cstr-new ;
:: _lbl_noise "NOISE"  cstr-new ;
:: _lbl_lvl   "LEVEL"  cstr-new ;

struct: Chorus1State u32 unused ;
struct: Chorus1Params
  f32 mode  f32 mix  f32 noise  f32 level
;

noalloc: p-mode  slab:params f@32 ;
noalloc: p-mix   slab:params 4 + f@32 ;
noalloc: p-noise slab:params 8 + f@32 ;
noalloc: p-level slab:params 12 + f@32 ;

: p-mode!  slab:params f!32 ;
: p-mix!   slab:params 4 + f!32 ;
: p-noise! slab:params 8 + f!32 ;
: p-level! slab:params 12 + f!32 ;

noalloc: clamp01
  dup 0.0 f< [ drop 0.0 ] then
  dup 1.0 f> [ drop 1.0 ] then
;

noalloc: mode-param-i
  p-mode 0.5 f+ f>i
  dup 0 < [ drop 0 ] then
  dup 2 > [ drop 2 ] then
;

noalloc: mode-i
  mode-cell @32
;

noalloc: mode-rate
  mode-i
  dup 0 = [ drop 0.5 ]
  [ dup 1 = [ drop 0.8 ] [ drop 1.0 ] ifte ] ifte
;

noalloc: mode-depth
  mode-i
  dup 0 = [ drop 115.0 ]
  [ dup 1 = [ drop 175.0 ] [ drop 68.0 ] ifte ] ifte
;

noalloc: mode-base-delay
  mode-i
  dup 0 = [ drop 540.0 ]
  [ dup 1 = [ drop 600.0 ] [ drop 520.0 ] ifte ] ifte
;

noalloc: wrap-idx
  dup 0 < [ BUF_N + ] then
  dup BUF_N >= [ BUF_N - ] then
;

noalloc: wrap-pos
  dup 0.0 f< [ BUF_N_F f+ ] then
  dup BUF_N_F f> [ BUF_N_F f- ] then
;

noalloc: delay-l@
  4 * dl-buf + f@32
;

noalloc: delay-r@
  4 * dr-buf + f@32
;

noalloc: delay-l!
  4 * dl-buf + f!32
;

noalloc: delay-r!
  4 * dr-buf + f!32
;

noalloc: interp-l@  ( delay-samples -- sample )
  idx-cell @32 i>f swap f- DELAY_OFFSET f+ wrap-pos pos-cell f!32
  pos-cell f@32 f>i base-cell !32
  pos-cell f@32 base-cell @32 i>f f- frac-cell f!32
  base-cell @32 1+ wrap-idx next-cell !32
  base-cell @32 delay-l@ s0-cell f!32
  next-cell @32 delay-l@
  s0-cell f@32 f-
  frac-cell f@32 f*
  s0-cell f@32 f+
;

noalloc: interp-r@  ( delay-samples -- sample )
  idx-cell @32 i>f swap f- DELAY_OFFSET f+ wrap-pos pos-cell f!32
  pos-cell f@32 f>i base-cell !32
  pos-cell f@32 base-cell @32 i>f f- frac-cell f!32
  base-cell @32 1+ wrap-idx next-cell !32
  base-cell @32 delay-r@ s0-cell f!32
  next-cell @32 delay-r@
  s0-cell f@32 f-
  frac-cell f@32 f*
  s0-cell f@32 f+
;

noalloc: tri-lfo  ( phase 0..1 -- -1..1 )
  dup 0.5 f<
  [ 4.0 f* 1.0 f- ]
  [ 4.0 f* 3.0 swap f- ]
  ifte
;

noalloc: current-lfo
  phase-cell f@32 tri-lfo
  mode-i 2 = [ 0.65 f* ] then
;

noalloc: advance-lfo
  phase-cell f@32 rate-inc-cell f@32 f+
  dup 1.0 f>
  [ 1.0 f- ] then
  phase-cell f!32
;

noalloc: dc-l  ( x -- y )
  dup dc-xl-cell f@32 f-
  dc-yl-cell f@32 0.995 f* f+
  dup dc-yl-cell f!32
  swap dc-xl-cell f!32
  dc-yl-cell f@32
;

noalloc: dc-r  ( x -- y )
  dup dc-xr-cell f@32 f-
  dc-yr-cell f@32 0.995 f* f+
  dup dc-yr-cell f!32
  swap dc-xr-cell f!32
  dc-yr-cell f@32
;

noalloc: make-input
  inl-cell f@32 inr-cell f@32 f+ 0.5 f* mono-cell f!32
  inl-cell f@32 0.65 f* mono-cell f@32 0.35 f* f+ drive-l-cell f!32
  inr-cell f@32 0.65 f* mono-cell f@32 0.35 f* f+ drive-r-cell f!32
;

noalloc: softclip
  dup -2.0 f< [ drop -2.0 ] then
  dup 2.0 f> [ drop 2.0 ] then
  dup dup f* 0.111111 f* 1.0 swap f- f*
;

noalloc: pre-color
  pre-l-cell f@32 drive-l-cell f@32 pre-l-cell f@32 f- 0.28 f* f+ pre-l-cell f!32
  pre-r-cell f@32 drive-r-cell f@32 pre-r-cell f@32 f- 0.28 f* f+ pre-r-cell f!32
  pre-l-cell f@32 1.15 f* softclip
  slab:noise noise-gain-cell f@32 f* f+
  idx-cell @32 delay-l!
  pre-r-cell f@32 1.15 f* softclip
  slab:noise noise-gain-cell f@32 f* f+
  idx-cell @32 delay-r!
;

noalloc: calc-delays
  current-lfo lfo-cell f!32
  base-delay-cell f@32 lfo-cell f@32 depth-cell f@32 f* f+ delay-l-cell f!32
  mode-i 2 =
  [
    base-delay-cell f@32 42.0 f+ lfo-cell f@32 depth-cell f@32 f* f+ delay-r-cell f!32
  ]
  [
    base-delay-cell f@32 42.0 f+ lfo-cell f@32 depth-cell f@32 f* f- delay-r-cell f!32
  ]
  ifte
;

noalloc: post-color
  delay-l-cell f@32 interp-l@ dc-l wet-l-cell f!32
  delay-r-cell f@32 interp-r@ dc-r wet-r-cell f!32
  post-l-cell f@32 wet-l-cell f@32 post-l-cell f@32 f- 0.22 f* f+ post-l-cell f!32
  post-r-cell f@32 wet-r-cell f@32 post-r-cell f@32 f- 0.22 f* f+ post-r-cell f!32
;

noalloc: write-output
  inl-cell f@32 1.0 mix-cell f@32 f- f*
  post-l-cell f@32 mix-cell f@32 f* f+
  level-cell f@32 f*
  outl-cell f!32
  outl-cell f@32 frame-cell @32 slab:write-l

  inr-cell f@32 1.0 mix-cell f@32 f- f*
  post-r-cell f@32 mix-cell f@32 f* f+
  level-cell f@32 f*
  outr-cell f!32
  outr-cell f@32 frame-cell @32 slab:write-r
;

noalloc: update-block-coeffs
  mode-param-i mode-cell !32
  mode-rate slab:sr f/ rate-inc-cell f!32
  mode-depth depth-cell f!32
  mode-base-delay base-delay-cell f!32
  p-mix clamp01 mix-cell f!32
  p-noise clamp01 0.006 f* noise-gain-cell f!32
  p-level level-cell f!32
;

noalloc: bump-write-idx
  idx-cell @32 1+
  dup BUF_N =
  [ drop 0 ] then
  idx-cell !32
;

noalloc: chorus-sample  ( frame-idx -- )
  dup frame-cell !32
  dup slab:input-l@ inl-cell f!32
  dup slab:input-r@ inr-cell f!32
  mix-cell f@32 0.001 f<
  [
    inl-cell f@32 frame-cell @32 slab:write-l
    inr-cell f@32 frame-cell @32 slab:write-r
  ]
  [
    make-input
    calc-delays
    post-color
    pre-color
    write-output
    bump-write-idx
    advance-lfo
  ]
  ifte
  frame-cell @32
;

noalloc: chorus1-audio
  update-block-coeffs
  slab:input-l 0 =
  [
    0 slab:block-size
    [
      dup 0.0 swap slab:write-l
      dup 0.0 swap slab:write-r
      1+
    ] dotimes
    drop
  ]
  [
    0 slab:block-size
    [
      chorus-sample
      1+
    ] dotimes
    drop
  ]
  ifte
;

noalloc: chorus1-reset
  0 idx-cell !32
  0.0 phase-cell f!32
  0 mode-cell !32
  0.0 rate-inc-cell f!32
  0.0 depth-cell f!32
  0.0 base-delay-cell f!32
  0.0 mix-cell f!32
  0.0 noise-gain-cell f!32
  1.0 level-cell f!32
  0.0 inl-cell f!32
  0.0 inr-cell f!32
  0.0 mono-cell f!32
  0.0 drive-l-cell f!32
  0.0 drive-r-cell f!32
  0.0 pre-l-cell f!32
  0.0 pre-r-cell f!32
  0.0 wet-l-cell f!32
  0.0 wet-r-cell f!32
  0.0 post-l-cell f!32
  0.0 post-r-cell f!32
  0.0 dc-xl-cell f!32
  0.0 dc-yl-cell f!32
  0.0 dc-xr-cell f!32
  0.0 dc-yr-cell f!32
  0.0 lfo-cell f!32
  0.0 delay-l-cell f!32
  0.0 delay-r-cell f!32
  0.0 outl-cell f!32
  0.0 outr-cell f!32
;

:: CW 52.0 ;
:: CG 53.0 ;
: header-h 12.0 ;
: body-y slab:panel-y header-h f+ ;
: body-h 64.0 ;
: ky body-y 11.0 f+ ;
: kh 52.0 ;
: mode-x slab:panel-x 4.0 f+ ;
: k0x slab:panel-x 108.0 f+ ;
: k1x k0x CG f+ ;
: k2x k0x CG 2.0 f* f+ ;

: chorus1-ui
  slab:panel-x slab:panel-y slab:panel-w header-h widget:bevel-raised
  slab:panel-x 4.0 f+ slab:panel-y _lbl_c1 widget:draw-label
  slab:panel-x body-y slab:panel-w body-h widget:bevel-raised
  mode-x ky 96.0 kh _lbl_mode _lbl_i _lbl_ii _lbl_iii p-mode widget:switch3 p-mode!
  k0x ky CW kh _lbl_mix p-mix widget:knob p-mix!
  k1x ky CW kh _lbl_noise p-noise widget:knob p-noise!
  k2x ky CW kh _lbl_lvl p-level widget:knob p-level!
;

: manifest
  \chorus1-audio \chorus1-ui
  Chorus1State.size Chorus1Params.size
  audio->audio
  Machine.new
;
