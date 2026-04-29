( drum1/drum1.fy — compact synthesized x0x drum machine.
  MIDI map: 36=BD, 38/40=SD, 42/44=CH, 46+=OH. )

include "../lib/machine.fy"

:: _lib "/usr/lib/libSystem.B.dylib" dl-open ;
:: _sin  _lib "sin"  dl-sym ;
:: _exp  _lib "exp"  dl-sym ;
:: _tanh _lib "tanh" dl-sym ;
noalloc: sin  _sin  bind: d:d ;
noalloc: exp  _exp  bind: d:d ;
noalloc: tanh _tanh bind: d:d ;

:: TWO_PI 6.283185307179586 ;

( --- Voice state ------------------------------------------------ )
:: bd-env-cell    4 alloc ; 0.0 bd-env-cell    f!32
:: bd-phase-cell  4 alloc ; 0.0 bd-phase-cell  f!32
:: bd-vel-cell    4 alloc ; 1.0 bd-vel-cell    f!32
:: sd-env-cell    4 alloc ; 0.0 sd-env-cell    f!32
:: sd-tone-cell   4 alloc ; 0.0 sd-tone-cell   f!32
:: sd-noise-cell  4 alloc ; 0.0 sd-noise-cell  f!32
:: sd-vel-cell    4 alloc ; 1.0 sd-vel-cell    f!32
:: hat-noise-cell 4 alloc ; 0.0 hat-noise-cell f!32
:: ch-env-cell    4 alloc ; 0.0 ch-env-cell    f!32
:: ch-phase-cell  4 alloc ; 0.0 ch-phase-cell  f!32
:: ch-vel-cell    4 alloc ; 1.0 ch-vel-cell    f!32
:: oh-env-cell    4 alloc ; 0.0 oh-env-cell    f!32
:: oh-phase-cell  4 alloc ; 0.0 oh-phase-cell  f!32
:: oh-vel-cell    4 alloc ; 1.0 oh-vel-cell    f!32
:: ev-pitch-cell  4 alloc ; 0.0 ev-pitch-cell  f!32
:: ev-vel-cell    4 alloc ; 1.0 ev-vel-cell    f!32
:: bd-out-cell    4 alloc ; 0.0 bd-out-cell    f!32
:: sd-out-cell    4 alloc ; 0.0 sd-out-cell    f!32
:: ch-out-cell    4 alloc ; 0.0 ch-out-cell    f!32
:: oh-out-cell    4 alloc ; 0.0 oh-out-cell    f!32
:: out-cell       4 alloc ; 0.0 out-cell       f!32
:: idx-cell       4 alloc ; 0   idx-cell       !32

( --- Params ----------------------------------------------------- )
:: bd-tune-cell  4 alloc ; 0.35 bd-tune-cell  f!32
:: bd-dec-cell   4 alloc ; 0.45 bd-dec-cell   f!32
:: bd-drive-cell 4 alloc ; 0.35 bd-drive-cell f!32
:: sd-tone-param 4 alloc ; 0.45 sd-tone-param f!32
:: sd-dec-cell   4 alloc ; 0.35 sd-dec-cell   f!32
:: sd-noise-param 4 alloc ; 0.70 sd-noise-param f!32
:: hat-tone-cell 4 alloc ; 0.55 hat-tone-cell f!32
:: ch-dec-cell   4 alloc ; 0.18 ch-dec-cell   f!32
:: oh-dec-cell   4 alloc ; 0.55 oh-dec-cell   f!32
:: mix-drive-cell 4 alloc ; 0.20 mix-drive-cell f!32
:: level-cell    4 alloc ; 0.70 level-cell    f!32

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
:: _lbl_ch  "CH"    cstr-new ;
:: _lbl_oh  "OH"    cstr-new ;
:: _lbl_lvl "LVL"   cstr-new ;

struct: Drum1State u32 unused ;
struct: Drum1Params f32 level ;

noalloc: time-coeff  ( sec -- coeff )
  slab:sr f* 1.0 swap f/ fneg exp
;

noalloc: vel-scale  ( vel -- amp )
  127.0 f/ 0.35 f* 0.65 f+
;

noalloc: wrap-phase  ( phase -- phase )
  dup TWO_PI f> [ TWO_PI f- ] [ ] ifte
;

noalloc: square  ( phase -- sample )
  dup 3.141592653589793 f< [ drop 1.0 ] [ drop -1.0 ] ifte
;

noalloc: trig-bd  ( -- )
  1.0 bd-env-cell f!32
  0.0 bd-phase-cell f!32
;

noalloc: trig-sd  ( -- )
  1.0 sd-env-cell f!32
  0.0 sd-tone-cell f!32
  0.0 sd-noise-cell f!32
;

noalloc: trig-ch  ( -- )
  1.0 ch-env-cell f!32
  0.0 ch-phase-cell f!32
  0.0 hat-noise-cell f!32
;

noalloc: trig-oh  ( -- )
  1.0 oh-env-cell f!32
  0.0 oh-phase-cell f!32
  0.0 hat-noise-cell f!32
;

noalloc: process-notes
  10 slab:debug-mark
  0 slab:note-count
  [
    dup slab:note-kind 0 =
    [
      dup slab:note-pitch ev-pitch-cell f!32
      dup slab:note-vel vel-scale ev-vel-cell f!32
      ( Repeat a four-lane drum map in each octave:
        C=BD, C#/D/E=SD, F/F#/G/G#=CH, A..B=OH. )
      ev-pitch-cell f@32
      dup 83.5 f> [ 84.0 f- ] then
      dup 71.5 f> [ 72.0 f- ] then
      dup 59.5 f> [ 60.0 f- ] then
      dup 47.5 f> [ 48.0 f- ] then
      dup 35.5 f> [ 36.0 f- ] then
      ev-pitch-cell f!32
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
    ] then
    1+
  ] dotimes
  drop
  19 slab:debug-mark
;

noalloc: render-bd  ( -- )
  bd-env-cell f@32
  dup 0.0005 f<
  [ drop 0.0 bd-out-cell f!32 ]
  [
    bd-phase-cell f@32 sin
    f*
    bd-vel-cell f@32 f*
    bd-drive-cell f@32 5.0 f* 1.0 f+ f* tanh
    bd-out-cell f!32
    bd-env-cell f@32
    bd-dec-cell f@32 0.55 f* 0.08 f+ time-coeff f*
    bd-env-cell f!32
    bd-phase-cell f@32
    TWO_PI bd-env-cell f@32 90.0 f* bd-tune-cell f@32 55.0 f* f+ 40.0 f+ f* slab:sr f/ f+
    wrap-phase bd-phase-cell f!32
  ]
  ifte
;

noalloc: sd-noise  ( -- sample )
  slab:noise
;

noalloc: hat-noise  ( -- sample )
  slab:noise
;

noalloc: render-sd  ( -- )
  sd-env-cell f@32
  dup 0.0005 f<
  [ drop 0.0 sd-out-cell f!32 ]
  [
    sd-noise sd-noise-param f@32 1.1 f* 0.35 f+ f*
    sd-tone-cell f@32 sin sd-tone-param f@32 0.18 f* f*
    f+
    f*
    sd-vel-cell f@32 f*
    1.25 f*
    sd-out-cell f!32
    sd-env-cell f@32 sd-dec-cell f@32 0.18 f* 0.045 f+ time-coeff f* sd-env-cell f!32
    sd-tone-cell f@32 TWO_PI 180.0 f* slab:sr f/ f+ wrap-phase sd-tone-cell f!32
  ]
  ifte
;

noalloc: render-ch  ( -- )
  ch-env-cell f@32
  dup 0.0005 f<
  [ drop 0.0 ch-out-cell f!32 ]
  [
    hat-noise
    f*
    ch-vel-cell f@32 f*
    hat-tone-cell f@32 0.45 f* 0.7 f+ f*
    0.55 f*
    ch-out-cell f!32
    ch-env-cell f@32 ch-dec-cell f@32 0.035 f* 0.010 f+ time-coeff f* ch-env-cell f!32
  ]
  ifte
;

noalloc: render-oh  ( -- )
  oh-env-cell f@32
  dup 0.0005 f<
  [ drop 0.0 oh-out-cell f!32 ]
  [
    hat-noise
    f*
    oh-vel-cell f@32 f*
    hat-tone-cell f@32 0.4 f* 0.55 f+ f*
    0.45 f*
    oh-out-cell f!32
    oh-env-cell f@32 oh-dec-cell f@32 0.26 f* 0.06 f+ time-coeff f* oh-env-cell f!32
  ]
  ifte
;

noalloc: drum1-audio
  100 slab:debug-mark
  process-notes
  101 slab:debug-mark
  0 slab:block-size
  [
    idx-cell !32
    render-bd
    render-sd
    render-ch
    render-oh
    bd-out-cell f@32
    sd-out-cell f@32 f+
    ch-out-cell f@32 f+
    oh-out-cell f@32 f+
    mix-drive-cell f@32 4.0 f* 1.0 f+ f* tanh
    level-cell f@32 f*
    idx-cell @32 slab:write-stereo
    idx-cell @32 1+
  ] dotimes
  drop
  199 slab:debug-mark
;

( --- UI --------------------------------------------------------- )
:: CW 52.0 ;
:: CG 53.0 ;
: g0x ( -- x ) slab:panel-x ;
: g1x ( -- x ) slab:panel-x 106.0 f+ ;
: g2x ( -- x ) slab:panel-x 212.0 f+ ;
: g3x ( -- x ) slab:panel-x 318.0 f+ ;
: k0x ( -- x ) slab:panel-x 4.0 f+ ;
: k1x ( -- x ) slab:panel-x 57.0 f+ ;
: k2x ( -- x ) slab:panel-x 110.0 f+ ;
: k3x ( -- x ) slab:panel-x 163.0 f+ ;
: k4x ( -- x ) slab:panel-x 216.0 f+ ;
: k5x ( -- x ) slab:panel-x 269.0 f+ ;
: k6x ( -- x ) slab:panel-x 322.0 f+ ;
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

  g2x slab:panel-y 12.0 f+ 106.0 60.0 widget:bevel-raised
  slab:panel-x 216.0 f+ slab:panel-y 14.0 f+ _lbl_hat widget:draw-label
  k4x ky CW kh _lbl_ch ch-dec-cell   f@32 widget:knob ch-dec-cell   f!32
  k5x ky CW kh _lbl_oh oh-dec-cell   f@32 widget:knob oh-dec-cell   f!32

  g3x slab:panel-y 12.0 f+ 110.0 60.0 widget:bevel-raised
  slab:panel-x 322.0 f+ slab:panel-y 14.0 f+ _lbl_mix widget:draw-label
  k6x ky CW kh _lbl_drv mix-drive-cell f@32 widget:knob mix-drive-cell f!32
  slab:panel-x 375.0 f+ ky CW kh _lbl_lvl level-cell f@32 widget:knob level-cell f!32
;

: manifest
  \drum1-audio \drum1-ui
  Drum1State.size Drum1Params.size
  notes->audio
  Machine.new
;
