( fm1/fm1.fy -- compact DX/OPL-ish phase-modulation synth.
  Four sine-table-style operators, simple algorithm select, feedback,
  and optional rectified/half-sine wave color. )

include "../lib/machine.fy"

:: _lib "/usr/lib/libSystem.B.dylib" dl-open ;
:: _sin  _lib "sin" dl-sym ;
:: _pow  _lib "pow" dl-sym ;
:: _exp  _lib "exp" dl-sym ;
:: _tanh _lib "tanh" dl-sym ;
noalloc: sin  _sin  bind: d:d ;
noalloc: pow  _pow  bind: dd:d ;
noalloc: exp  _exp  bind: d:d ;
noalloc: tanh _tanh bind: d:d ;

:: SR_DEFAULT 48000.0 ;
:: TWO_PI 6.283185307179586 ;
:: PI 3.141592653589793 ;

:: phase1-cell 4 alloc ; 0.0 phase1-cell f!32
:: phase2-cell 4 alloc ; 0.0 phase2-cell f!32
:: phase3-cell 4 alloc ; 0.0 phase3-cell f!32
:: phase4-cell 4 alloc ; 0.0 phase4-cell f!32
:: step1-cell 4 alloc ; 0.0 step1-cell f!32
:: step2-cell 4 alloc ; 0.0 step2-cell f!32
:: step3-cell 4 alloc ; 0.0 step3-cell f!32
:: step4-cell 4 alloc ; 0.0 step4-cell f!32
:: pitch-cell 4 alloc ; 60.0 pitch-cell f!32
:: vel-cell 4 alloc ; 1.0 vel-cell f!32
:: amp-cell 4 alloc ; 0.0 amp-cell f!32
:: stage-cell 4 alloc ; 0 stage-cell !32
:: fb-cell 4 alloc ; 0.0 fb-cell f!32
:: fb-prev-cell 4 alloc ; 0.0 fb-prev-cell f!32
:: fb-prev2-cell 4 alloc ; 0.0 fb-prev2-cell f!32
:: level-cell 4 alloc ; 0.45 level-cell f!32
:: alg-cell 4 alloc ; 0 alg-cell !32
:: op2-level-cell 4 alloc ; 1.2 op2-level-cell f!32
:: op3-level-cell 4 alloc ; 0.8 op3-level-cell f!32
:: op4-level-cell 4 alloc ; 0.0 op4-level-cell f!32
:: ratio2-cell 4 alloc ; 1.0 ratio2-cell f!32
:: ratio3-cell 4 alloc ; 2.0 ratio3-cell f!32
:: ratio4-cell 4 alloc ; 3.0 ratio4-cell f!32
:: attack-coeff-cell 4 alloc ; 0.0 attack-coeff-cell f!32
:: decay-coeff-cell 4 alloc ; 0.0 decay-coeff-cell f!32
:: release-coeff-cell 4 alloc ; 0.0 release-coeff-cell f!32
:: sustain-cell 4 alloc ; 0.7 sustain-cell f!32
:: wave-cell 4 alloc ; 0 wave-cell !32
:: op1-cell 4 alloc ; 0.0 op1-cell f!32
:: op2-cell 4 alloc ; 0.0 op2-cell f!32
:: op3-cell 4 alloc ; 0.0 op3-cell f!32
:: op4-cell 4 alloc ; 0.0 op4-cell f!32
:: mod-cell 4 alloc ; 0.0 mod-cell f!32
:: out-cell 4 alloc ; 0.0 out-cell f!32
:: idx-cell 4 alloc ; 0 idx-cell !32

:: _lbl_fm  "FM1" cstr-new ;
:: _lbl_lvl "LVL" cstr-new ;
:: _lbl_alg "ALG" cstr-new ;
:: _lbl_fb  "FB"  cstr-new ;
:: _lbl_m2  "M2"  cstr-new ;
:: _lbl_m3  "M3"  cstr-new ;
:: _lbl_m4  "M4"  cstr-new ;
:: _lbl_r2  "R2"  cstr-new ;
:: _lbl_r3  "R3"  cstr-new ;
:: _lbl_r4  "R4"  cstr-new ;
:: _lbl_atk "ATK" cstr-new ;
:: _lbl_dec "DEC" cstr-new ;
:: _lbl_sus "SUS" cstr-new ;
:: _lbl_rel "REL" cstr-new ;
:: _lbl_wav "WAV" cstr-new ;

struct: Fm1State u32 unused ;
struct: Fm1Params
  f32 level
  f32 algorithm
  f32 feedback
  f32 op2_level
  f32 op3_level
  f32 op4_level
  f32 op2_ratio
  f32 op3_ratio
  f32 op4_ratio
  f32 attack
  f32 decay
  f32 sustain
  f32 release
  f32 wave
;

noalloc: p-level slab:params f@32 ;
noalloc: p-alg   slab:params 4 + f@32 ;
noalloc: p-fb    slab:params 8 + f@32 ;
noalloc: p-m2    slab:params 12 + f@32 ;
noalloc: p-m3    slab:params 16 + f@32 ;
noalloc: p-m4    slab:params 20 + f@32 ;
noalloc: p-r2    slab:params 24 + f@32 ;
noalloc: p-r3    slab:params 28 + f@32 ;
noalloc: p-r4    slab:params 32 + f@32 ;
noalloc: p-attack slab:params 36 + f@32 ;
noalloc: p-decay  slab:params 40 + f@32 ;
noalloc: p-sustain slab:params 44 + f@32 ;
noalloc: p-release slab:params 48 + f@32 ;
noalloc: p-wave slab:params 52 + f@32 ;

: p-level! slab:params f!32 ;
: p-alg!   slab:params 4 + f!32 ;
: p-fb!    slab:params 8 + f!32 ;
: p-m2!    slab:params 12 + f!32 ;
: p-m3!    slab:params 16 + f!32 ;
: p-m4!    slab:params 20 + f!32 ;
: p-r2!    slab:params 24 + f!32 ;
: p-r3!    slab:params 28 + f!32 ;
: p-r4!    slab:params 32 + f!32 ;
: p-attack! slab:params 36 + f!32 ;
: p-decay!  slab:params 40 + f!32 ;
: p-sustain! slab:params 44 + f!32 ;
: p-release! slab:params 48 + f!32 ;
: p-wave! slab:params 52 + f!32 ;

noalloc: safe-sr
  slab:sr dup 1.0 f<
  [ drop SR_DEFAULT ] then
;

noalloc: midi-to-hz
  69.0 f- 12.0 f/ 2.0 swap pow 440.0 f*
;

noalloc: clamp01 fclamp01 ;

noalloc: env-coeff
  dup 0.001 f< [ drop 0.001 ] then
  safe-sr f*
  1.0 swap f/ fneg exp
  1.0 swap f-
;

noalloc: do-attack 1.0 attack-coeff-cell f@32 fslew ;
noalloc: do-decay sustain-cell f@32 decay-coeff-cell f@32 fslew ;
noalloc: do-release 0.0 release-coeff-cell f@32 fslew ;

noalloc: amp-env-tick
  stage-cell @32 0 =
  [ 0.0 ]
  [
    amp-cell f@32
    stage-cell @32 1 =
    [
      do-attack
      dup 0.995 f> [ 2 stage-cell !32 ] then
    ] then
    stage-cell @32 2 =
    [
      do-decay
      dup sustain-cell f@32 f> not [ 3 stage-cell !32 ] then
    ] then
    stage-cell @32 3 =
    [
      sustain-cell f@32 swap drop
    ] then
    stage-cell @32 4 =
    [
      do-release
      dup 0.0005 f< [ drop 0.0 0 stage-cell !32 ] then
    ] then
    dup amp-cell f!32
  ]
  ifte
;

noalloc: wrap-rad
  dup TWO_PI f> [ TWO_PI f- ] then
  dup 0.0 f< [ TWO_PI f+ ] then
;

noalloc: wave-sample  ( phase -- sample )
  wave-cell @32
  dup 0 =
  [ drop sin ]
  [
    dup 1 =
    [
      drop sin
      dup 0.0 f< [ drop 0.0 ] then
      2.0 f* 0.62 f-
    ]
    [
      dup 2 =
      [
        drop sin
        dup 0.0 f< [ fneg ] then
        2.0 f* 1.0 f-
      ]
      [
        drop sin 1.7 f* tanh
      ]
      ifte
    ]
    ifte
  ]
  ifte
;

noalloc: ratio-map  ( 0..1 -- ratio )
  clamp01
  dup 0.125 f<
  [ drop 0.5 ]
  [
    dup 0.250 f<
    [ drop 1.0 ]
    [
      dup 0.375 f<
      [ drop 1.5 ]
      [
        dup 0.500 f<
        [ drop 2.0 ]
        [
          dup 0.625 f<
          [ drop 3.0 ]
          [
            dup 0.750 f<
            [ drop 4.0 ]
            [
              dup 0.875 f<
              [ drop 6.0 ]
              [ drop 8.0 ]
              ifte
            ]
            ifte
          ]
          ifte
        ]
        ifte
      ]
      ifte
    ]
    ifte
  ]
  ifte
;

noalloc: calc-steps
  pitch-cell f@32 midi-to-hz safe-sr f/ TWO_PI f*
  dup step1-cell f!32
  dup ratio2-cell f@32 f* step2-cell f!32
  dup ratio3-cell f@32 f* step3-cell f!32
  ratio4-cell f@32 f* step4-cell f!32
;

noalloc: note-on
  dup slab:note-pitch pitch-cell f!32
  slab:note-vel vel-cell f!32
  calc-steps
  0.0 phase1-cell f!32
  0.0 phase2-cell f!32
  0.0 phase3-cell f!32
  0.0 phase4-cell f!32
  0.0 fb-prev-cell f!32
  0.0 fb-prev2-cell f!32
  1 stage-cell !32
;

noalloc: note-off
  drop
  stage-cell @32 0 = not
  [ 4 stage-cell !32 ] then
;

noalloc: process-notes
  0 slab:note-count
  [
    dup slab:note-kind 0 = [ dup note-on ] then
    dup slab:note-kind 1 = [ dup note-off ] then
    1+
  ] dotimes
  drop
;

noalloc: update-block-coeffs
  p-level clamp01 level-cell f!32
  p-alg clamp01 2.999 f* f>i alg-cell !32
  p-fb clamp01 6.0 f* fb-cell f!32
  p-m2 clamp01 7.0 f* op2-level-cell f!32
  p-m3 clamp01 7.0 f* op3-level-cell f!32
  p-m4 clamp01 7.0 f* op4-level-cell f!32
  p-r2 ratio-map ratio2-cell f!32
  p-r3 ratio-map ratio3-cell f!32
  p-r4 ratio-map ratio4-cell f!32
  p-sustain clamp01 sustain-cell f!32
  p-attack env-coeff attack-coeff-cell f!32
  p-decay env-coeff decay-coeff-cell f!32
  p-release env-coeff release-coeff-cell f!32
  p-wave clamp01 3.999 f* f>i wave-cell !32
  calc-steps
;

noalloc: advance-phases
  phase1-cell f@32 step1-cell f@32 f+ wrap-rad phase1-cell f!32
  phase2-cell f@32 step2-cell f@32 f+ wrap-rad phase2-cell f!32
  phase3-cell f@32 step3-cell f@32 f+ wrap-rad phase3-cell f!32
  phase4-cell f@32 step4-cell f@32 f+ wrap-rad phase4-cell f!32
;

noalloc: render-op4
  phase4-cell f@32
  fb-prev-cell f@32 fb-prev2-cell f@32 f+ 0.5 f* fb-cell f@32 f* f+
  wave-sample
  dup fb-prev-cell f@32 fb-prev2-cell f!32
  fb-prev-cell f!32
  op4-level-cell f@32 f*
  amp-cell f@32 f*
  op4-cell f!32
;

noalloc: render-alg0
  render-op4
  phase3-cell f@32 op4-cell f@32 f+ wave-sample op3-level-cell f@32 f* amp-cell f@32 f* op3-cell f!32
  phase2-cell f@32 op3-cell f@32 f+ wave-sample op2-level-cell f@32 f* amp-cell f@32 f* op2-cell f!32
  phase1-cell f@32 op2-cell f@32 f+ wave-sample op1-cell f!32
;

noalloc: render-alg1
  render-op4
  phase3-cell f@32 wave-sample op3-level-cell f@32 f* amp-cell f@32 f* op3-cell f!32
  phase2-cell f@32 wave-sample op2-level-cell f@32 f* amp-cell f@32 f* op2-cell f!32
  op2-cell f@32 op3-cell f@32 f+ op4-cell f@32 f+ mod-cell f!32
  phase1-cell f@32 mod-cell f@32 f+ wave-sample op1-cell f!32
;

noalloc: render-alg2
  render-op4
  phase3-cell f@32 op4-cell f@32 f+ wave-sample op3-level-cell f@32 f* amp-cell f@32 f* op3-cell f!32
  phase2-cell f@32 wave-sample op2-level-cell f@32 f* amp-cell f@32 f* op2-cell f!32
  phase1-cell f@32 op2-cell f@32 f+ wave-sample
  phase1-cell f@32 op3-cell f@32 f+ wave-sample
  f+ 0.5 f*
  op1-cell f!32
;

noalloc: render-alg3
  render-op4
  phase3-cell f@32 op4-cell f@32 f+ wave-sample op3-level-cell f@32 f* amp-cell f@32 f* op3-cell f!32
  phase2-cell f@32 op3-cell f@32 f+ wave-sample op2-level-cell f@32 f* amp-cell f@32 f* op2-cell f!32
  phase1-cell f@32 op2-cell f@32 f+ wave-sample
  op3-cell f@32 0.22 f* f+
  op4-cell f@32 0.12 f* f+
  op1-cell f!32
;

noalloc: fm-sample
  amp-env-tick drop
  alg-cell @32
  dup 0 = [ drop render-alg0 ]
  [
    dup 1 = [ drop render-alg1 ]
    [
      dup 2 = [ drop render-alg2 ] [ drop render-alg3 ] ifte
    ]
    ifte
  ]
  ifte
  op1-cell f@32
  amp-cell f@32 f*
  vel-cell f@32 f*
  level-cell f@32 f*
  1.35 f*
  tanh
  out-cell f!32
  advance-phases
;

noalloc: fm1-audio
  update-block-coeffs
  process-notes
  0 slab:block-size
  [
    idx-cell !32
    fm-sample
    out-cell f@32 idx-cell @32 slab:write-stereo
    idx-cell @32 1+
  ] dotimes
  drop
;

noalloc: fm1-reset
  0.0 phase1-cell f!32
  0.0 phase2-cell f!32
  0.0 phase3-cell f!32
  0.0 phase4-cell f!32
  0.0 amp-cell f!32
  0 stage-cell !32
  0.0 fb-prev-cell f!32
  0.0 fb-prev2-cell f!32
  0.0 out-cell f!32
;

:: CW 52.0 ;
: k0x ( -- x ) slab:panel-x 4.0 f+ ;
: k1x ( -- x ) slab:panel-x 57.0 f+ ;
: k2x ( -- x ) slab:panel-x 110.0 f+ ;
: k3x ( -- x ) slab:panel-x 163.0 f+ ;
: k4x ( -- x ) slab:panel-x 216.0 f+ ;
: k5x ( -- x ) slab:panel-x 269.0 f+ ;
: k6x ( -- x ) slab:panel-x 322.0 f+ ;
: k7x ( -- x ) slab:panel-x 375.0 f+ ;
: ky0 ( -- y ) slab:panel-y 24.0 f+ ;
: ky1 ( -- y ) slab:panel-y 80.0 f+ ;
: kh  ( -- h ) 52.0 ;

: fm1-ui
  slab:panel-x slab:panel-y slab:panel-w 12.0 widget:bevel-raised
  slab:panel-x 4.0 f+ slab:panel-y _lbl_fm widget:draw-label
  k0x ky0 CW kh _lbl_lvl p-level widget:knob p-level!
  k1x ky0 CW kh _lbl_alg p-alg widget:knob p-alg!
  k2x ky0 CW kh _lbl_fb  p-fb widget:knob p-fb!
  k3x ky0 CW kh _lbl_m2  p-m2 widget:knob p-m2!
  k4x ky0 CW kh _lbl_m3  p-m3 widget:knob p-m3!
  k5x ky0 CW kh _lbl_m4  p-m4 widget:knob p-m4!
  k6x ky0 CW kh _lbl_wav p-wave widget:knob p-wave!
  k0x ky1 CW kh _lbl_r2  p-r2 widget:knob p-r2!
  k1x ky1 CW kh _lbl_r3  p-r3 widget:knob p-r3!
  k2x ky1 CW kh _lbl_r4  p-r4 widget:knob p-r4!
  k3x ky1 CW kh _lbl_atk p-attack widget:knob p-attack!
  k4x ky1 CW kh _lbl_dec p-decay widget:knob p-decay!
  k5x ky1 CW kh _lbl_sus p-sustain widget:knob p-sustain!
  k6x ky1 CW kh _lbl_rel p-release widget:knob p-release!
;

: manifest
  \fm1-audio \fm1-ui
  Fm1State.size Fm1Params.size
  notes->audio
  Machine.new
;
