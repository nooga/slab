( verb1/verb1.fy -- Schroeder-style algorithmic reverb.
  Input allpass diffusion -> four damped feedback combs -> output diffusion
  with DC blocking and conservative bounds. )

include "../lib/machine.fy"

:: _lib "/usr/lib/libSystem.B.dylib" dl-open ;
:: _tanh _lib "tanh" dl-sym ;
noalloc: tanh _tanh bind: d:d ;

:: BUF_N 32768 ;
:: BUF_BYTES 131072 ;
:: AP1 347 ;
:: AP2 1139 ;
:: C1 4217 ;
:: C2 5051 ;
:: C3 5683 ;
:: C4 6317 ;
:: RC1 4451 ;
:: RC2 5237 ;
:: RC3 5953 ;
:: RC4 6761 ;
:: OUTAP 983 ;

:: ap1-buf BUF_BYTES alloc ;
:: ap2-buf BUF_BYTES alloc ;
:: outap-l-buf BUF_BYTES alloc ;
:: outap-r-buf BUF_BYTES alloc ;
:: c1-buf BUF_BYTES alloc ;
:: c2-buf BUF_BYTES alloc ;
:: c3-buf BUF_BYTES alloc ;
:: c4-buf BUF_BYTES alloc ;
:: r1-buf BUF_BYTES alloc ;
:: r2-buf BUF_BYTES alloc ;
:: r3-buf BUF_BYTES alloc ;
:: r4-buf BUF_BYTES alloc ;

:: idx-cell 4 alloc ; 0 idx-cell !32
:: sample-cell 4 alloc ; 0 sample-cell !32
:: fb-cell 4 alloc ; 0.78 fb-cell f!32
:: damp-cell 4 alloc ; 0.35 damp-cell f!32
:: mix-cell 4 alloc ; 0.42 mix-cell f!32
:: width-cell 4 alloc ; 0.9 width-cell f!32
:: level-cell 4 alloc ; 0.9 level-cell f!32
:: in-l-cell 4 alloc ; 0.0 in-l-cell f!32
:: in-r-cell 4 alloc ; 0.0 in-r-cell f!32
:: x-cell 4 alloc ; 0.0 x-cell f!32
:: ap-cell 4 alloc ; 0.0 ap-cell f!32
:: wet-l-cell 4 alloc ; 0.0 wet-l-cell f!32
:: wet-r-cell 4 alloc ; 0.0 wet-r-cell f!32
:: sum-l-cell 4 alloc ; 0.0 sum-l-cell f!32
:: sum-r-cell 4 alloc ; 0.0 sum-r-cell f!32
:: mid-cell 4 alloc ; 0.0 mid-cell f!32
:: side-cell 4 alloc ; 0.0 side-cell f!32
:: out-l-cell 4 alloc ; 0.0 out-l-cell f!32
:: out-r-cell 4 alloc ; 0.0 out-r-cell f!32

:: d1-cell 4 alloc ; 0.0 d1-cell f!32
:: d2-cell 4 alloc ; 0.0 d2-cell f!32
:: d3-cell 4 alloc ; 0.0 d3-cell f!32
:: d4-cell 4 alloc ; 0.0 d4-cell f!32
:: rd1-cell 4 alloc ; 0.0 rd1-cell f!32
:: rd2-cell 4 alloc ; 0.0 rd2-cell f!32
:: rd3-cell 4 alloc ; 0.0 rd3-cell f!32
:: rd4-cell 4 alloc ; 0.0 rd4-cell f!32
:: dc-xl-cell 4 alloc ; 0.0 dc-xl-cell f!32
:: dc-yl-cell 4 alloc ; 0.0 dc-yl-cell f!32
:: dc-xr-cell 4 alloc ; 0.0 dc-xr-cell f!32
:: dc-yr-cell 4 alloc ; 0.0 dc-yr-cell f!32

:: _lbl_vrb "VERB"  cstr-new ;
:: _lbl_siz "SIZE"  cstr-new ;
:: _lbl_dmp "DAMP"  cstr-new ;
:: _lbl_mix "MIX"   cstr-new ;
:: _lbl_wid "WIDE"  cstr-new ;
:: _lbl_lvl "LVL"   cstr-new ;

struct: Verb1State u32 unused ;
struct: Verb1Params
  f32 size
  f32 damp
  f32 mix
  f32 width
  f32 level
;

noalloc: p-size slab:params f@32 ;
noalloc: p-damp slab:params 4 + f@32 ;
noalloc: p-mix slab:params 8 + f@32 ;
noalloc: p-width slab:params 12 + f@32 ;
noalloc: p-level slab:params 16 + f@32 ;

: p-size! slab:params f!32 ;
: p-damp! slab:params 4 + f!32 ;
: p-mix! slab:params 8 + f!32 ;
: p-width! slab:params 12 + f!32 ;
: p-level! slab:params 16 + f!32 ;

noalloc: clamp01 fclamp01 ;

noalloc: wrap-idx
  dup 0 < [ BUF_N + ] then
  dup BUF_N >= [ BUF_N - ] then
;

noalloc: read-pos idx-cell @32 swap - wrap-idx ;

noalloc: ap1@ read-pos 4 * ap1-buf + f@32 ;
noalloc: ap2@ read-pos 4 * ap2-buf + f@32 ;
noalloc: outap-l@ read-pos 4 * outap-l-buf + f@32 ;
noalloc: outap-r@ read-pos 4 * outap-r-buf + f@32 ;
noalloc: c1@ read-pos 4 * c1-buf + f@32 ;
noalloc: c2@ read-pos 4 * c2-buf + f@32 ;
noalloc: c3@ read-pos 4 * c3-buf + f@32 ;
noalloc: c4@ read-pos 4 * c4-buf + f@32 ;
noalloc: r1@ read-pos 4 * r1-buf + f@32 ;
noalloc: r2@ read-pos 4 * r2-buf + f@32 ;
noalloc: r3@ read-pos 4 * r3-buf + f@32 ;
noalloc: r4@ read-pos 4 * r4-buf + f@32 ;

noalloc: ap1! 4 * ap1-buf + f!32 ;
noalloc: ap2! 4 * ap2-buf + f!32 ;
noalloc: outap-l! 4 * outap-l-buf + f!32 ;
noalloc: outap-r! 4 * outap-r-buf + f!32 ;
noalloc: c1! 4 * c1-buf + f!32 ;
noalloc: c2! 4 * c2-buf + f!32 ;
noalloc: c3! 4 * c3-buf + f!32 ;
noalloc: c4! 4 * c4-buf + f!32 ;
noalloc: r1! 4 * r1-buf + f!32 ;
noalloc: r2! 4 * r2-buf + f!32 ;
noalloc: r3! 4 * r3-buf + f!32 ;
noalloc: r4! 4 * r4-buf + f!32 ;

noalloc: update-block-coeffs
  p-size clamp01 0.30 f* 0.66 f+ fb-cell f!32
  1.0 p-damp clamp01 f- 0.70 f* 0.08 f+ damp-cell f!32
  p-mix clamp01 mix-cell f!32
  p-width clamp01 1.45 f* width-cell f!32
  p-level clamp01 1.4 f* level-cell f!32
;

noalloc: softclip
  -2.0 2.0 fclamp
  0.85 f* tanh
;

noalloc: dc-l
  dup dc-xl-cell f@32 f-
  dc-yl-cell f@32 0.995 f* f+
  dup dc-yl-cell f!32
  swap dc-xl-cell f!32
;

noalloc: dc-r
  dup dc-xr-cell f@32 f-
  dc-yr-cell f@32 0.995 f* f+
  dup dc-yr-cell f!32
  swap dc-xr-cell f!32
;

noalloc: allpass1
  AP1 ap1@ ap-cell f!32
  x-cell f@32 ap-cell f@32 0.62 f* f+
  idx-cell @32 ap1!
  ap-cell f@32 x-cell f@32 0.62 f* f-
  x-cell f!32
;

noalloc: allpass2
  AP2 ap2@ ap-cell f!32
  x-cell f@32 ap-cell f@32 0.56 f* f+
  idx-cell @32 ap2!
  ap-cell f@32 x-cell f@32 0.56 f* f-
  x-cell f!32
;

noalloc: output-allpass-l
  OUTAP outap-l@ ap-cell f!32
  wet-l-cell f@32 ap-cell f@32 0.45 f* f+
  idx-cell @32 outap-l!
  ap-cell f@32 wet-l-cell f@32 0.45 f* f-
  wet-l-cell f!32
;

noalloc: output-allpass-r
  OUTAP outap-r@ ap-cell f!32
  wet-r-cell f@32 ap-cell f@32 0.45 f* f+
  idx-cell @32 outap-r!
  ap-cell f@32 wet-r-cell f@32 0.45 f* f-
  wet-r-cell f!32
;

noalloc: damp1
  d1-cell f@32 C1 c1@ d1-cell f@32 f- damp-cell f@32 f* f+
  dup d1-cell f!32
;

noalloc: damp2
  d2-cell f@32 C2 c2@ d2-cell f@32 f- damp-cell f@32 f* f+
  dup d2-cell f!32
;

noalloc: damp3
  d3-cell f@32 C3 c3@ d3-cell f@32 f- damp-cell f@32 f* f+
  dup d3-cell f!32
;

noalloc: damp4
  d4-cell f@32 C4 c4@ d4-cell f@32 f- damp-cell f@32 f* f+
  dup d4-cell f!32
;

noalloc: rdamp1
  rd1-cell f@32 RC1 r1@ rd1-cell f@32 f- damp-cell f@32 f* f+
  dup rd1-cell f!32
;

noalloc: rdamp2
  rd2-cell f@32 RC2 r2@ rd2-cell f@32 f- damp-cell f@32 f* f+
  dup rd2-cell f!32
;

noalloc: rdamp3
  rd3-cell f@32 RC3 r3@ rd3-cell f@32 f- damp-cell f@32 f* f+
  dup rd3-cell f!32
;

noalloc: rdamp4
  rd4-cell f@32 RC4 r4@ rd4-cell f@32 f- damp-cell f@32 f* f+
  dup rd4-cell f!32
;

noalloc: combs-left
  damp1 sum-l-cell f!32
  x-cell f@32 sum-l-cell f@32 fb-cell f@32 f* f+ softclip idx-cell @32 c1!
  damp2 sum-l-cell f@32 f+ sum-l-cell f!32
  x-cell f@32 sum-l-cell f@32 fb-cell f@32 0.94 f* f* f+ softclip idx-cell @32 c2!
  damp3 sum-l-cell f@32 f+ sum-l-cell f!32
  x-cell f@32 sum-l-cell f@32 fb-cell f@32 0.88 f* f* f+ softclip idx-cell @32 c3!
  damp4 sum-l-cell f@32 f+ sum-l-cell f!32
  x-cell f@32 sum-l-cell f@32 fb-cell f@32 0.82 f* f* f+ softclip idx-cell @32 c4!
  sum-l-cell f@32 0.25 f*
;

noalloc: combs-right
  rdamp1 sum-r-cell f!32
  x-cell f@32 sum-r-cell f@32 fb-cell f@32 f* f+ softclip idx-cell @32 r1!
  rdamp2 sum-r-cell f@32 f+ sum-r-cell f!32
  x-cell f@32 sum-r-cell f@32 fb-cell f@32 0.93 f* f* f+ softclip idx-cell @32 r2!
  rdamp3 sum-r-cell f@32 f+ sum-r-cell f!32
  x-cell f@32 sum-r-cell f@32 fb-cell f@32 0.87 f* f* f+ softclip idx-cell @32 r3!
  rdamp4 sum-r-cell f@32 f+ sum-r-cell f!32
  x-cell f@32 sum-r-cell f@32 fb-cell f@32 0.81 f* f* f+ softclip idx-cell @32 r4!
  sum-r-cell f@32 0.25 f*
;

noalloc: verb-sample
  sample-cell @32 slab:input-l@ in-l-cell f!32
  sample-cell @32 slab:input-r@ in-r-cell f!32
  in-l-cell f@32 in-r-cell f@32 f+ 0.5 f* 0.65 f* x-cell f!32

  allpass1
  allpass2

  combs-left wet-l-cell f!32
  combs-right wet-r-cell f!32

  output-allpass-l
  output-allpass-r
  wet-l-cell f@32 dc-l wet-l-cell f!32
  wet-r-cell f@32 dc-r wet-r-cell f!32

  wet-l-cell f@32 wet-r-cell f@32 f+ 0.5 f* mid-cell f!32
  wet-l-cell f@32 wet-r-cell f@32 f- 0.5 f* width-cell f@32 f* side-cell f!32
  mid-cell f@32 side-cell f@32 f+ 1.4 f* wet-l-cell f!32
  mid-cell f@32 side-cell f@32 f- 1.4 f* wet-r-cell f!32

  in-l-cell f@32 wet-l-cell f@32 in-l-cell f@32 f- mix-cell f@32 f* f+
  level-cell f@32 f* out-l-cell f!32
  in-r-cell f@32 wet-r-cell f@32 in-r-cell f@32 f- mix-cell f@32 f* f+
  level-cell f@32 f* out-r-cell f!32
  out-l-cell f@32 sample-cell @32 slab:write-l
  out-r-cell f@32 sample-cell @32 slab:write-r
;

noalloc: verb1-audio
  update-block-coeffs
  0 slab:block-size
  [
    sample-cell !32
    verb-sample
    idx-cell @32 1+ wrap-idx idx-cell !32
    sample-cell @32 1+
  ] dotimes
  drop
;

noalloc: verb1-reset
  0 idx-cell !32
  0 sample-cell !32
  0.0 d1-cell f!32
  0.0 d2-cell f!32
  0.0 d3-cell f!32
  0.0 d4-cell f!32
  0.0 rd1-cell f!32
  0.0 rd2-cell f!32
  0.0 rd3-cell f!32
  0.0 rd4-cell f!32
  0.0 dc-xl-cell f!32
  0.0 dc-yl-cell f!32
  0.0 dc-xr-cell f!32
  0.0 dc-yr-cell f!32
  0 BUF_N
  [
    dup 0.0 swap ap1!
    dup 0.0 swap ap2!
    dup 0.0 swap outap-l!
    dup 0.0 swap outap-r!
    dup 0.0 swap c1!
    dup 0.0 swap c2!
    dup 0.0 swap c3!
    dup 0.0 swap c4!
    dup 0.0 swap r1!
    dup 0.0 swap r2!
    dup 0.0 swap r3!
    dup 0.0 swap r4!
    1+
  ] dotimes
  drop
;

:: CW 52.0 ;
: k0x ( -- x ) slab:panel-x 4.0 f+ ;
: k1x ( -- x ) slab:panel-x 57.0 f+ ;
: k2x ( -- x ) slab:panel-x 110.0 f+ ;
: k3x ( -- x ) slab:panel-x 163.0 f+ ;
: k4x ( -- x ) slab:panel-x 216.0 f+ ;
: ky  ( -- y ) slab:panel-y 24.0 f+ ;
: kh  ( -- h ) 52.0 ;

: verb1-ui
  slab:panel-x slab:panel-y slab:panel-w 12.0 widget:bevel-raised
  slab:panel-x 4.0 f+ slab:panel-y _lbl_vrb widget:draw-label
  k0x ky CW kh _lbl_siz p-size widget:knob p-size!
  k1x ky CW kh _lbl_dmp p-damp widget:knob p-damp!
  k2x ky CW kh _lbl_mix p-mix widget:knob p-mix!
  k3x ky CW kh _lbl_wid p-width widget:knob p-width!
  k4x ky CW kh _lbl_lvl p-level widget:knob p-level!
;

: manifest
  \verb1-audio \verb1-ui
  Verb1State.size Verb1Params.size
  audio->audio
  Machine.new
;
