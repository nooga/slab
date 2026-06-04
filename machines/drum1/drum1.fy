( drum1/drum1.fy -- synthesized x0x drum machine.
  MIDI map repeats by octave: C=BD, C#/D/E=SD, F/F#/G/G#=CH, A..B=OH. )

include "../lib/machine.fy"

:: _lib "/usr/lib/libSystem.B.dylib" dl-open ;
:: _sin  _lib "sin"  dl-sym ;
:: _exp  _lib "exp"  dl-sym ;
:: _tanh _lib "tanh" dl-sym ;
noalloc: sin  _sin  bind: d:d ;
noalloc: exp  _exp  bind: d:d ;
noalloc: tanh _tanh bind: d:d ;

:: TWO_PI 6.283185307179586 ;
:: PI 3.141592653589793 ;

( --- Voice state ------------------------------------------------ )
:: bd-amp-env-cell    4 alloc ; 0.0 bd-amp-env-cell    f!32
:: bd-pitch-env-cell  4 alloc ; 0.0 bd-pitch-env-cell  f!32
:: bd-click-env-cell  4 alloc ; 0.0 bd-click-env-cell  f!32
:: bd-phase-cell      4 alloc ; 0.0 bd-phase-cell      f!32
:: bd-vel-cell        4 alloc ; 1.0 bd-vel-cell        f!32

:: sd-body-env-cell   4 alloc ; 0.0 sd-body-env-cell   f!32
:: sd-noise-env-cell  4 alloc ; 0.0 sd-noise-env-cell  f!32
:: sd-tone-cell       4 alloc ; 0.0 sd-tone-cell       f!32
:: sd-noise-prev-cell 4 alloc ; 0.0 sd-noise-prev-cell f!32
:: sd-vel-cell        4 alloc ; 1.0 sd-vel-cell        f!32

:: ch-env-cell        4 alloc ; 0.0 ch-env-cell        f!32
:: ch-vel-cell        4 alloc ; 1.0 ch-vel-cell        f!32
:: oh-env-cell        4 alloc ; 0.0 oh-env-cell        f!32
:: oh-vel-cell        4 alloc ; 1.0 oh-vel-cell        f!32
:: hat-phase-a-cell   4 alloc ; 0.0 hat-phase-a-cell   f!32
:: hat-phase-b-cell   4 alloc ; 0.0 hat-phase-b-cell   f!32
:: hat-noise-prev-cell 4 alloc ; 0.0 hat-noise-prev-cell f!32

:: ev-pitch-cell      4 alloc ; 0.0 ev-pitch-cell      f!32
:: ev-vel-cell        4 alloc ; 1.0 ev-vel-cell        f!32
:: bd-out-cell        4 alloc ; 0.0 bd-out-cell        f!32
:: sd-out-cell        4 alloc ; 0.0 sd-out-cell        f!32
:: ch-out-cell        4 alloc ; 0.0 ch-out-cell        f!32
:: oh-out-cell        4 alloc ; 0.0 oh-out-cell        f!32
:: idx-cell           4 alloc ; 0   idx-cell           !32

( --- Params ----------------------------------------------------- )
:: bd-tune-cell    4 alloc ; 0.42 bd-tune-cell    f!32
:: bd-dec-cell     4 alloc ; 0.38 bd-dec-cell     f!32
:: bd-drive-cell   4 alloc ; 0.34 bd-drive-cell   f!32
:: sd-tone-param   4 alloc ; 0.48 sd-tone-param   f!32
:: sd-dec-cell     4 alloc ; 0.36 sd-dec-cell     f!32
:: sd-noise-param  4 alloc ; 0.58 sd-noise-param  f!32
:: hat-tone-cell   4 alloc ; 0.42 hat-tone-cell   f!32
:: hat-metal-cell  4 alloc ; 0.32 hat-metal-cell  f!32
:: hat-noise-cell  4 alloc ; 0.62 hat-noise-cell  f!32
:: ch-dec-cell     4 alloc ; 0.28 ch-dec-cell     f!32
:: oh-dec-cell     4 alloc ; 0.42 oh-dec-cell     f!32
:: mix-drive-cell  4 alloc ; 0.22 mix-drive-cell  f!32
:: level-cell      4 alloc ; 0.78 level-cell      f!32

( --- Labels ----------------------------------------------------- )
:: _lbl_d1  "DRUM1" cstr-new ;
:: _lbl_bd  "KICK"  cstr-new ;
:: _lbl_sd  "SNARE" cstr-new ;
:: _lbl_hat "HATS"  cstr-new ;
:: _lbl_mix "MIX"   cstr-new ;
:: _lbl_tun "TUN"   cstr-new ;
:: _lbl_dec "DEC"   cstr-new ;
:: _lbl_drv "DRV"   cstr-new ;
:: _lbl_ton "TON"   cstr-new ;
:: _lbl_nse "NSE"   cstr-new ;
:: _lbl_met "MET"   cstr-new ;
:: _lbl_ch  "CH"    cstr-new ;
:: _lbl_oh  "OH"    cstr-new ;
:: _lbl_lvl "LVL"   cstr-new ;

struct: Drum1State u32 unused ;
struct: Drum1Params f32 level ;

noalloc: time-coeff  ( sec -- coeff )
  slab:sr f* 1.0 swap f/ fneg exp
;

noalloc: vel-scale  ( vel -- amp )
  127.0 f/ 0.45 f* 0.55 f+
;

noalloc: wrap-phase  ( phase -- phase )
  dup TWO_PI f> [ TWO_PI f- ] then
  dup 0.0 f< [ TWO_PI f+ ] then
;

noalloc: square  ( phase -- sample )
  dup PI f< [ drop 1.0 ] [ drop -1.0 ] ifte
;

noalloc: softclip
  -2.0 2.0 fclamp
  dup dup f* 0.111111 f* 1.0 swap f- f*
;

noalloc: snare-noise  ( -- sample )
  slab:noise
  sd-noise-prev-cell f@32 0.72 f*
  over 0.28 f* f+
  dup sd-noise-prev-cell f!32
  swap drop
;

noalloc: hat-hp-noise  ( -- sample )
  slab:noise
  dup hat-noise-prev-cell f@32 f-
  swap hat-noise-prev-cell f!32
;

noalloc: trig-bd  ( -- )
  1.0 bd-amp-env-cell f!32
  1.0 bd-pitch-env-cell f!32
  1.0 bd-click-env-cell f!32
  0.0 bd-phase-cell f!32
;

noalloc: trig-sd  ( -- )
  1.0 sd-body-env-cell f!32
  1.0 sd-noise-env-cell f!32
  0.0 sd-tone-cell f!32
  0.0 sd-noise-prev-cell f!32
;

noalloc: trig-ch  ( -- )
  1.0 ch-env-cell f!32
  oh-env-cell f@32 0.22 f* oh-env-cell f!32
  0.0 hat-noise-prev-cell f!32
;

noalloc: trig-oh  ( -- )
  1.0 oh-env-cell f!32
  0.0 hat-noise-prev-cell f!32
;

noalloc: normalize-drum-pitch
  dup 83.5 f> [ 84.0 f- ] then
  dup 71.5 f> [ 72.0 f- ] then
  dup 59.5 f> [ 60.0 f- ] then
  dup 47.5 f> [ 48.0 f- ] then
  dup 35.5 f> [ 36.0 f- ] then
;

noalloc: route-drum-note
  ev-pitch-cell f@32 normalize-drum-pitch ev-pitch-cell f!32
  ev-pitch-cell f@32 1.0 f<
  [ ev-vel-cell f@32 bd-vel-cell f!32 trig-bd ]
  [
    ev-pitch-cell f@32 5.0 f<
    [ ev-vel-cell f@32 sd-vel-cell f!32 trig-sd ]
    [
      ev-pitch-cell f@32 9.0 f<
      [ ev-vel-cell f@32 ch-vel-cell f!32 trig-ch ]
      [
        ev-pitch-cell f@32 12.0 f<
        [ ev-vel-cell f@32 oh-vel-cell f!32 trig-oh ]
        [ ]
        ifte
      ]
      ifte
    ]
    ifte
  ]
  ifte
;

noalloc: process-notes
  0 slab:note-count
  [
    dup slab:note-kind 0 =
    [
      dup slab:note-pitch ev-pitch-cell f!32
      dup slab:note-vel vel-scale ev-vel-cell f!32
      route-drum-note
    ] then
    1+
  ] dotimes
  drop
;

noalloc: render-bd  ( -- )
  bd-amp-env-cell f@32
  dup 0.0005 f<
  [ drop 0.0 bd-out-cell f!32 ]
  [
    bd-phase-cell f@32 sin
    f*
    bd-vel-cell f@32 f*
    slab:noise bd-click-env-cell f@32 f* 0.090 f* f+
    bd-drive-cell f@32 4.2 f* 1.0 f+ f* tanh
    1.10 f*
    bd-out-cell f!32

    bd-amp-env-cell f@32
    bd-dec-cell f@32 0.034 f* 0.018 f+ time-coeff f*
    bd-amp-env-cell f!32
    bd-pitch-env-cell f@32 0.020 time-coeff f* bd-pitch-env-cell f!32
    bd-click-env-cell f@32 0.0028 time-coeff f* bd-click-env-cell f!32

    bd-phase-cell f@32
    TWO_PI
    bd-pitch-env-cell f@32 58.0 f*
    bd-tune-cell f@32 22.0 f* f+
    45.0 f+
    f* slab:sr f/ f+
    wrap-phase bd-phase-cell f!32
  ]
  ifte
;

noalloc: render-sd  ( -- )
  sd-body-env-cell f@32 sd-noise-env-cell f@32 f+
  dup 0.0005 f<
  [ drop 0.0 sd-out-cell f!32 ]
  [
    drop
    sd-tone-cell f@32 sin
    sd-body-env-cell f@32 f*
    sd-tone-param f@32 0.50 f* 0.36 f+ f*
    snare-noise
    sd-noise-env-cell f@32 f*
    sd-noise-param f@32 0.95 f* 0.28 f+ f*
    f+
    sd-vel-cell f@32 f*
    1.55 f*
    softclip
    sd-out-cell f!32

    sd-body-env-cell f@32 sd-dec-cell f@32 0.025 f* 0.015 f+ time-coeff f* sd-body-env-cell f!32
    sd-noise-env-cell f@32 sd-dec-cell f@32 0.035 f* 0.020 f+ time-coeff f* sd-noise-env-cell f!32
    sd-tone-cell f@32
    TWO_PI sd-tone-param f@32 115.0 f* 165.0 f+ f* slab:sr f/ f+
    wrap-phase sd-tone-cell f!32
  ]
  ifte
;

noalloc: advance-hat
  hat-phase-a-cell f@32
  TWO_PI hat-tone-cell f@32 2800.0 f* 2600.0 f+ f* slab:sr f/ f+
  wrap-phase hat-phase-a-cell f!32
  hat-phase-b-cell f@32
  TWO_PI hat-tone-cell f@32 3600.0 f* 4200.0 f+ f* slab:sr f/ f+
  wrap-phase hat-phase-b-cell f!32
;

noalloc: hat-metal  ( -- sample )
  hat-phase-a-cell f@32 sin 0.46 f*
  hat-phase-b-cell f@32 sin 0.30 f* f+
  hat-metal-cell f@32 0.58 f* 0.04 f+ f*
  hat-hp-noise
  hat-noise-cell f@32 0.62 f* 0.18 f+ f*
  f+
  1.16 f* softclip
;

noalloc: render-ch  ( -- )
  ch-env-cell f@32
  dup 0.0005 f<
  [ drop 0.0 ch-out-cell f!32 ]
  [
    hat-metal f*
    ch-vel-cell f@32 f*
    hat-tone-cell f@32 0.35 f* 0.68 f+ f*
    0.56 f*
    ch-out-cell f!32
    ch-env-cell f@32 ch-dec-cell f@32 0.035 f* 0.015 f+ time-coeff f* ch-env-cell f!32
  ]
  ifte
;

noalloc: render-oh  ( -- )
  oh-env-cell f@32
  dup 0.0005 f<
  [ drop 0.0 oh-out-cell f!32 ]
  [
    hat-metal f*
    oh-vel-cell f@32 f*
    hat-tone-cell f@32 0.32 f* 0.54 f+ f*
    0.44 f*
    oh-out-cell f!32
    oh-env-cell f@32 oh-dec-cell f@32 0.130 f* 0.045 f+ time-coeff f* oh-env-cell f!32
  ]
  ifte
;

noalloc: drum1-audio
  process-notes
  0 slab:block-size
  [
    idx-cell !32
    render-bd
    render-sd
    advance-hat
    render-ch
    render-oh
    bd-out-cell f@32
    sd-out-cell f@32 f+
    ch-out-cell f@32 f+
    oh-out-cell f@32 f+
    mix-drive-cell f@32 4.5 f* 1.0 f+ f* tanh
    level-cell f@32 f*
    idx-cell @32 slab:write-stereo
    idx-cell @32 1+
  ] dotimes
  drop
;

( --- UI --------------------------------------------------------- )
:: CW 52.0 ;
:: CG 53.0 ;
: g0x ( -- x ) slab:panel-x ;
: g1x ( -- x ) slab:panel-x 106.0 f+ ;
: g2x ( -- x ) slab:panel-x 212.0 f+ ;
: g3x ( -- x ) slab:panel-x 477.0 f+ ;
: k0x ( -- x ) slab:panel-x 4.0 f+ ;
: k1x ( -- x ) slab:panel-x 57.0 f+ ;
: k2x ( -- x ) slab:panel-x 110.0 f+ ;
: k3x ( -- x ) slab:panel-x 163.0 f+ ;
: k4x ( -- x ) slab:panel-x 216.0 f+ ;
: k5x ( -- x ) slab:panel-x 269.0 f+ ;
: k6x ( -- x ) slab:panel-x 322.0 f+ ;
: k7x ( -- x ) slab:panel-x 375.0 f+ ;
: k8x ( -- x ) slab:panel-x 428.0 f+ ;
: k9x ( -- x ) slab:panel-x 481.0 f+ ;
: k10x ( -- x ) slab:panel-x 534.0 f+ ;
: ky  ( -- y ) slab:panel-y 24.0 f+ ;
: kh  ( -- h ) 52.0 ;

: drum1-ui
  slab:panel-x slab:panel-y slab:panel-w 12.0 widget:bevel-raised
  slab:panel-x 4.0 f+ slab:panel-y _lbl_d1 widget:draw-label

  g0x slab:panel-y 12.0 f+ 106.0 60.0 widget:bevel-raised
  slab:panel-x 4.0 f+ slab:panel-y 14.0 f+ _lbl_bd widget:draw-label
  k0x ky CW kh _lbl_tun bd-tune-cell  f@32 widget:knob bd-tune-cell  f!32
  k1x ky CW kh _lbl_dec bd-dec-cell   f@32 widget:knob bd-dec-cell   f!32

  g1x slab:panel-y 12.0 f+ 106.0 60.0 widget:bevel-raised
  slab:panel-x 110.0 f+ slab:panel-y 14.0 f+ _lbl_sd widget:draw-label
  k2x ky CW kh _lbl_ton sd-tone-param  f@32 widget:knob sd-tone-param  f!32
  k3x ky CW kh _lbl_nse sd-noise-param f@32 widget:knob sd-noise-param f!32

  g2x slab:panel-y 12.0 f+ 265.0 60.0 widget:bevel-raised
  slab:panel-x 216.0 f+ slab:panel-y 14.0 f+ _lbl_hat widget:draw-label
  k4x ky CW kh _lbl_ch ch-dec-cell   f@32 widget:knob ch-dec-cell   f!32
  k5x ky CW kh _lbl_oh oh-dec-cell   f@32 widget:knob oh-dec-cell   f!32
  k6x ky CW kh _lbl_ton hat-tone-cell f@32 widget:knob hat-tone-cell f!32
  k7x ky CW kh _lbl_met hat-metal-cell f@32 widget:knob hat-metal-cell f!32
  k8x ky CW kh _lbl_nse hat-noise-cell f@32 widget:knob hat-noise-cell f!32

  g3x slab:panel-y 12.0 f+ 110.0 60.0 widget:bevel-raised
  slab:panel-x 481.0 f+ slab:panel-y 14.0 f+ _lbl_mix widget:draw-label
  k9x ky CW kh _lbl_drv mix-drive-cell f@32 widget:knob mix-drive-cell f!32
  k10x ky CW kh _lbl_lvl level-cell f@32 widget:knob level-cell f!32
;

: manifest
  \drum1-audio \drum1-ui
  Drum1State.size Drum1Params.size
  notes->audio
  Machine.new
;
