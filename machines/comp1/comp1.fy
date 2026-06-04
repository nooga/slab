( comp1/comp1.fy -- small stereo compressor for drums and instruments. )

include "../lib/machine.fy"

:: _lib "/usr/lib/libSystem.B.dylib" dl-open ;
:: _exp  _lib "exp"  dl-sym ;
:: _tanh _lib "tanh" dl-sym ;
noalloc: exp  _exp  bind: d:d ;
noalloc: tanh _tanh bind: d:d ;

struct: Comp1State u32 unused ;
struct: Comp1Params
  f32 threshold f32 ratio f32 attack f32 release
  f32 makeup f32 mix f32 drive
;

:: env-cell      4 alloc ; 0.0 env-cell      f!32
:: gain-cell     4 alloc ; 1.0 gain-cell     f!32
:: idx-cell      4 alloc ; 0   idx-cell      !32
:: in-l-cell     4 alloc ; 0.0 in-l-cell     f!32
:: in-r-cell     4 alloc ; 0.0 in-r-cell     f!32
:: det-cell      4 alloc ; 0.0 det-cell      f!32
:: thr-cell      4 alloc ; 0.50 thr-cell     f!32
:: ratio-cell    4 alloc ; 4.0 ratio-cell    f!32
:: attack-cell   4 alloc ; 0.10 attack-cell  f!32
:: release-cell  4 alloc ; 0.02 release-cell f!32
:: makeup-cell   4 alloc ; 1.0 makeup-cell   f!32
:: mix-cell      4 alloc ; 0.70 mix-cell      f!32
:: drive-cell    4 alloc ; 1.0 drive-cell    f!32
:: target-cell   4 alloc ; 1.0 target-cell   f!32
:: wet-l-cell    4 alloc ; 0.0 wet-l-cell    f!32
:: wet-r-cell    4 alloc ; 0.0 wet-r-cell    f!32

:: _lbl_c1   "COMP1" cstr-new ;
:: _lbl_thr  "THR"   cstr-new ;
:: _lbl_rat  "RAT"   cstr-new ;
:: _lbl_atk  "ATK"   cstr-new ;
:: _lbl_rel  "REL"   cstr-new ;
:: _lbl_mak  "MAKE"  cstr-new ;
:: _lbl_mix  "MIX"   cstr-new ;
:: _lbl_drv  "DRV"   cstr-new ;

noalloc: p-threshold slab:params f@32 ;
noalloc: p-ratio     slab:params 4 + f@32 ;
noalloc: p-attack    slab:params 8 + f@32 ;
noalloc: p-release   slab:params 12 + f@32 ;
noalloc: p-makeup    slab:params 16 + f@32 ;
noalloc: p-mix       slab:params 20 + f@32 ;
noalloc: p-drive     slab:params 24 + f@32 ;

: p-threshold! slab:params f!32 ;
: p-ratio!     slab:params 4 + f!32 ;
: p-attack!    slab:params 8 + f!32 ;
: p-release!   slab:params 12 + f!32 ;
: p-makeup!    slab:params 16 + f!32 ;
: p-mix!       slab:params 20 + f!32 ;
: p-drive!     slab:params 24 + f!32 ;

noalloc: absf
  dup 0.0 f< [ fneg ] then
;

noalloc: follow-coeff  ( seconds -- coeff )
  slab:sr f* 1.0 swap f/ fneg exp
  1.0 swap f-
;

noalloc: update-param-cache
  p-threshold fclamp01 0.87 f* 0.05 f+ thr-cell f!32
  p-ratio fclamp01 11.0 f* 1.0 f+ ratio-cell f!32
  p-attack fclamp01 0.055 f* 0.001 f+ follow-coeff attack-cell f!32
  p-release fclamp01 0.45 f* 0.035 f+ follow-coeff release-cell f!32
  p-makeup fclamp01 2.0 f* 0.5 f+ makeup-cell f!32
  p-mix fclamp01 mix-cell f!32
  p-drive fclamp01 5.0 f* 1.0 f+ drive-cell f!32
;

noalloc: max2
  over over f<
  [ swap ] then
  drop
;

noalloc: detector
  in-l-cell f@32 absf
  in-r-cell f@32 absf
  max2
;

noalloc: compute-gain  ( env -- gain )
  dup thr-cell f@32 f<
  [ drop 1.0 ]
  [
    dup
    thr-cell f@32 f-
    ratio-cell f@32 f/
    thr-cell f@32 f+
    swap f/
    0.0 1.0 fclamp
  ]
  ifte
;

noalloc: comp-sample
  idx-cell @32 slab:input-l@ in-l-cell f!32
  idx-cell @32 slab:input-r@ in-r-cell f!32

  detector det-cell f!32
  env-cell f@32
  det-cell f@32
  det-cell f@32 env-cell f@32 f>
  [ attack-cell f@32 ] [ release-cell f@32 ] ifte
  fslew
  env-cell f!32

  env-cell f@32 compute-gain target-cell f!32
  gain-cell f@32 target-cell f@32 0.18 fslew gain-cell f!32

  in-l-cell f@32 gain-cell f@32 f* makeup-cell f@32 f* drive-cell f@32 f* tanh wet-l-cell f!32
  in-r-cell f@32 gain-cell f@32 f* makeup-cell f@32 f* drive-cell f@32 f* tanh wet-r-cell f!32

  in-l-cell f@32 wet-l-cell f@32 in-l-cell f@32 f- mix-cell f@32 f* f+
  idx-cell @32 slab:write-l
  in-r-cell f@32 wet-r-cell f@32 in-r-cell f@32 f- mix-cell f@32 f* f+
  idx-cell @32 slab:write-r
;

noalloc: comp1-audio
  update-param-cache
  0 slab:block-size
  [
    idx-cell !32
    comp-sample
    idx-cell @32 1+
  ] dotimes
  drop
;

noalloc: comp1-reset
  0.0 env-cell f!32
  1.0 gain-cell f!32
  0 idx-cell !32
  0.0 in-l-cell f!32
  0.0 in-r-cell f!32
  0.0 det-cell f!32
  1.0 target-cell f!32
  0.0 wet-l-cell f!32
  0.0 wet-r-cell f!32
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

: comp1-ui
  slab:panel-x slab:panel-y slab:panel-w 12.0 widget:bevel-raised
  slab:panel-x 4.0 f+ slab:panel-y _lbl_c1 widget:draw-label
  k0x ky CW kh _lbl_thr p-threshold widget:knob p-threshold!
  k1x ky CW kh _lbl_rat p-ratio widget:knob p-ratio!
  k2x ky CW kh _lbl_atk p-attack widget:knob p-attack!
  k3x ky CW kh _lbl_rel p-release widget:knob p-release!
  k4x ky CW kh _lbl_mak p-makeup widget:knob p-makeup!
  k5x ky CW kh _lbl_mix p-mix widget:knob p-mix!
  k6x ky CW kh _lbl_drv p-drive widget:knob p-drive!
;

: manifest
  \comp1-audio \comp1-ui
  Comp1State.size Comp1Params.size
  audio->audio
  Machine.new
;
