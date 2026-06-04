( delay1/delay1.fy -- stereo delay with ping-pong, tone, and modulation. )

include "../lib/machine.fy"

:: _lib "/usr/lib/libSystem.B.dylib" dl-open ;
:: _sin  _lib "sin"  dl-sym ;
:: _tanh _lib "tanh" dl-sym ;
noalloc: sin  _sin  bind: d:d ;
noalloc: tanh _tanh bind: d:d ;

:: TWO_PI 6.283185307179586 ;
:: BUF_N 32768 ;
:: BUF_N_F 32768.0 ;
:: BUF_BYTES 131072 ;

:: dl-buf BUF_BYTES alloc ;
:: dr-buf BUF_BYTES alloc ;
:: idx-cell 4 alloc ; 0 idx-cell !32
:: sample-cell 4 alloc ; 0 sample-cell !32
:: frame-cell 4 alloc ; 0 frame-cell !32
:: phase-cell 4 alloc ; 0.0 phase-cell f!32
:: delay-cell 4 alloc ; 4800.0 delay-cell f!32
:: fb-cell 4 alloc ; 0.35 fb-cell f!32
:: mix-cell 4 alloc ; 0.35 mix-cell f!32
:: tone-cell 4 alloc ; 0.45 tone-cell f!32
:: ping-cell 4 alloc ; 0.0 ping-cell f!32
:: mod-cell 4 alloc ; 0.0 mod-cell f!32
:: level-cell 4 alloc ; 1.0 level-cell f!32
:: in-l-cell 4 alloc ; 0.0 in-l-cell f!32
:: in-r-cell 4 alloc ; 0.0 in-r-cell f!32
:: wet-l-cell 4 alloc ; 0.0 wet-l-cell f!32
:: wet-r-cell 4 alloc ; 0.0 wet-r-cell f!32
:: fb-l-cell 4 alloc ; 0.0 fb-l-cell f!32
:: fb-r-cell 4 alloc ; 0.0 fb-r-cell f!32
:: tone-l-cell 4 alloc ; 0.0 tone-l-cell f!32
:: tone-r-cell 4 alloc ; 0.0 tone-r-cell f!32
:: pos-cell 4 alloc ; 0.0 pos-cell f!32
:: frac-cell 4 alloc ; 0.0 frac-cell f!32
:: base-cell 4 alloc ; 0 base-cell !32
:: next-cell 4 alloc ; 0 next-cell !32
:: s0-cell 4 alloc ; 0.0 s0-cell f!32
:: out-l-cell 4 alloc ; 0.0 out-l-cell f!32
:: out-r-cell 4 alloc ; 0.0 out-r-cell f!32

:: _lbl_dly "DELAY" cstr-new ;
:: _lbl_tim "TIME"  cstr-new ;
:: _lbl_fb  "FB"    cstr-new ;
:: _lbl_mix "MIX"   cstr-new ;
:: _lbl_ton "TONE"  cstr-new ;
:: _lbl_png "PING"  cstr-new ;
:: _lbl_mod "MOD"   cstr-new ;
:: _lbl_lvl "LVL"   cstr-new ;

struct: Delay1State u32 unused ;
struct: Delay1Params
  f32 time
  f32 feedback
  f32 mix
  f32 tone
  f32 ping
  f32 mod
  f32 level
;

noalloc: p-time slab:params f@32 ;
noalloc: p-fb   slab:params 4 + f@32 ;
noalloc: p-mix  slab:params 8 + f@32 ;
noalloc: p-tone slab:params 12 + f@32 ;
noalloc: p-ping slab:params 16 + f@32 ;
noalloc: p-mod  slab:params 20 + f@32 ;
noalloc: p-level slab:params 24 + f@32 ;

: p-time! slab:params f!32 ;
: p-fb!   slab:params 4 + f!32 ;
: p-mix!  slab:params 8 + f!32 ;
: p-tone! slab:params 12 + f!32 ;
: p-ping! slab:params 16 + f!32 ;
: p-mod!  slab:params 20 + f!32 ;
: p-level! slab:params 24 + f!32 ;

noalloc: clamp01 fclamp01 ;

noalloc: delay-l@ 4 * dl-buf + f@32 ;
noalloc: delay-r@ 4 * dr-buf + f@32 ;
noalloc: delay-l! 4 * dl-buf + f!32 ;
noalloc: delay-r! 4 * dr-buf + f!32 ;

noalloc: wrap-idx
  dup 0 < [ BUF_N + ] then
  dup BUF_N >= [ BUF_N - ] then
;

noalloc: wrap-pos
  dup 0.0 f< [ BUF_N_F f+ ] then
  dup BUF_N_F f> [ BUF_N_F f- ] then
;

noalloc: interp-l@  ( delay-samples -- sample )
  idx-cell @32 i>f swap f- wrap-pos pos-cell f!32
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
  idx-cell @32 i>f swap f- wrap-pos pos-cell f!32
  pos-cell f@32 f>i base-cell !32
  pos-cell f@32 base-cell @32 i>f f- frac-cell f!32
  base-cell @32 1+ wrap-idx next-cell !32
  base-cell @32 delay-r@ s0-cell f!32
  next-cell @32 delay-r@
  s0-cell f@32 f-
  frac-cell f@32 f*
  s0-cell f@32 f+
;

noalloc: time-samples
  p-time clamp01
  dup f*
  30000.0 f*
  240.0 f+
;

noalloc: update-block-coeffs
  time-samples delay-cell f!32
  p-fb clamp01 0.88 f* fb-cell f!32
  p-mix clamp01 mix-cell f!32
  p-tone clamp01 0.92 f* 0.04 f+ tone-cell f!32
  p-ping clamp01 ping-cell f!32
  p-mod clamp01 24.0 f* mod-cell f!32
  p-level clamp01 1.4 f* level-cell f!32
;

noalloc: advance-lfo
  phase-cell f@32
  0.19 slab:sr f/ f+
  dup 1.0 f> [ 1.0 f- ] then
  phase-cell f!32
;

noalloc: current-delay
  phase-cell f@32 TWO_PI f* sin
  mod-cell f@32 f*
  delay-cell f@32 f+
  8.0 32000.0 fclamp
;

noalloc: tone-l  ( x -- y )
  tone-l-cell f@32 swap tone-l-cell f@32 f- tone-cell f@32 f* f+
  dup tone-l-cell f!32
;

noalloc: tone-r  ( x -- y )
  tone-r-cell f@32 swap tone-r-cell f@32 f- tone-cell f@32 f* f+
  dup tone-r-cell f!32
;

noalloc: softclip
  -2.0 2.0 fclamp
  dup 0.8 f* tanh
;

noalloc: delay-sample
  sample-cell @32 slab:input-l@ in-l-cell f!32
  sample-cell @32 slab:input-r@ in-r-cell f!32

  current-delay
  dup interp-l@ wet-l-cell f!32
  interp-r@ wet-r-cell f!32

  wet-l-cell f@32 tone-l fb-l-cell f!32
  wet-r-cell f@32 tone-r fb-r-cell f!32

  in-l-cell f@32
  fb-l-cell f@32 1.0 ping-cell f@32 f- f*
  fb-r-cell f@32 ping-cell f@32 f*
  f+ fb-cell f@32 f* f+ softclip
  idx-cell @32 delay-l!

  in-r-cell f@32
  fb-r-cell f@32 1.0 ping-cell f@32 f- f*
  fb-l-cell f@32 ping-cell f@32 f*
  f+ fb-cell f@32 f* f+ softclip
  idx-cell @32 delay-r!

  in-l-cell f@32 wet-l-cell f@32 in-l-cell f@32 f- mix-cell f@32 f* f+
  level-cell f@32 f* out-l-cell f!32
  in-r-cell f@32 wet-r-cell f@32 in-r-cell f@32 f- mix-cell f@32 f* f+
  level-cell f@32 f* out-r-cell f!32

  out-l-cell f@32 sample-cell @32 slab:write-l
  out-r-cell f@32 sample-cell @32 slab:write-r
  advance-lfo
;

noalloc: delay1-audio
  update-block-coeffs
  0 slab:block-size
  [
    sample-cell !32
    delay-sample
    idx-cell @32 1+ wrap-idx idx-cell !32
    frame-cell @32 1+ frame-cell !32
    sample-cell @32 1+
  ] dotimes
  drop
;

noalloc: delay1-reset
  0 idx-cell !32
  0 sample-cell !32
  0 frame-cell !32
  0.0 phase-cell f!32
  0.0 tone-l-cell f!32
  0.0 tone-r-cell f!32
  0 BUF_N
  [
    dup 0.0 swap delay-l!
    dup 0.0 swap delay-r!
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
: k5x ( -- x ) slab:panel-x 269.0 f+ ;
: k6x ( -- x ) slab:panel-x 322.0 f+ ;
: ky  ( -- y ) slab:panel-y 24.0 f+ ;
: kh  ( -- h ) 52.0 ;

: delay1-ui
  slab:panel-x slab:panel-y slab:panel-w 12.0 widget:bevel-raised
  slab:panel-x 4.0 f+ slab:panel-y _lbl_dly widget:draw-label
  k0x ky CW kh _lbl_tim p-time widget:knob p-time!
  k1x ky CW kh _lbl_fb  p-fb widget:knob p-fb!
  k2x ky CW kh _lbl_mix p-mix widget:knob p-mix!
  k3x ky CW kh _lbl_ton p-tone widget:knob p-tone!
  k4x ky CW kh _lbl_png p-ping widget:knob p-ping!
  k5x ky CW kh _lbl_mod p-mod widget:knob p-mod!
  k6x ky CW kh _lbl_lvl p-level widget:knob p-level!
;

: manifest
  \delay1-audio \delay1-ui
  Delay1State.size Delay1Params.size
  audio->audio
  Machine.new
;
