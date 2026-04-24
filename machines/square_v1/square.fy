( square_v1/square.fy — monophonic square-wave oscillator, note-driven. )

include "../lib/machine.fy"

:: _lib "/usr/lib/libSystem.B.dylib" dl-open ;
:: _pow  _lib "pow" dl-sym ;
noalloc: pow  _pow bind: dd:d ;

:: TWO_PI 6.283185307179586 ;
:: PI     3.141592653589793 ;

:: phase-cell 4 alloc ;  0.0  phase-cell f!32
:: gain-cell  4 alloc ;  0.2  gain-cell  f!32
:: pitch-cell 4 alloc ;  69.0 pitch-cell f!32
:: gate-cell  4 alloc ;  0    gate-cell  !32

:: _lbl_sq   "SQ"   cstr-new ;
:: _lbl_gain "GAIN" cstr-new ;

struct: SqState  f64 phase  f64 pitch  u32 gate ;
struct: SqParams f64 gain ;

noalloc: midi-to-hz  ( pitch -- hz )
  69.0 f-  12.0 f/  2.0 swap pow  440.0 f*
;

noalloc: process-notes
  0 slab:note-count
  [
    dup slab:note-kind 0 =
    [ dup slab:note-pitch pitch-cell f!32
      1 gate-cell !32 ] then
    dup slab:note-kind 1 =
    [ 0 gate-cell !32 ] then
    1+
  ] dotimes
  drop
;

noalloc: sq-sample  ( phase -- sample )
  PI f< [ 1.0 ] [ -1.0 ] ifte
;

noalloc: square-audio
  process-notes
  gate-cell @32 0 =
  [
    0 slab:block-size
    [
      dup 4 * slab:audio-l + 0.0 swap f!32
      dup 4 * slab:audio-r + 0.0 swap f!32
      1+
    ] dotimes
    drop
  ]
  [
    0 slab:block-size
    [
      phase-cell f@32 sq-sample gain-cell f@32 f*
      dup 2 pick 4 * slab:audio-l + f!32
      1 pick 4 * slab:audio-r + f!32
      phase-cell f@32
      TWO_PI pitch-cell f@32 midi-to-hz f* slab:sr f/ f+
      dup TWO_PI f> [ TWO_PI f- ] [ ] ifte
      phase-cell f!32
      1+
    ] dotimes
    drop
  ]
  ifte
;

: square-ui
  slab:panel-x slab:panel-y slab:panel-w 16.0 widget:bevel-raised
  slab:panel-x 4.0 f+ slab:panel-y 2.0 f+ _lbl_sq widget:draw-label
  slab:panel-x 2.0 f+
  slab:panel-y 18.0 f+
  52.0
  slab:panel-h 20.0 f-
  _lbl_gain
  gain-cell f@32
  widget:knob
  gain-cell f!32
;

: manifest
  \square-audio  \square-ui
  SqState.size  SqParams.size
  notes->audio
  Machine.new
;
