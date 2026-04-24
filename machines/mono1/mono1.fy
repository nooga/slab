( mono1/mono1.fy — monophonic subtractive synth.
  Signal chain: sawtooth → 1-pole LP filter → ADSR envelope → VCA. )

include "../lib/machine.fy"

( --- libm ------------------------------------------------------- )
:: _lib "/usr/lib/libSystem.B.dylib" dl-open ;
:: _pow _lib "pow" dl-sym ;
:: _exp _lib "exp" dl-sym ;
noalloc: pow  _pow bind: dd:d ;
noalloc: exp  _exp bind: d:d ;

( --- Constants -------------------------------------------------- )
:: TWO_PI 6.283185307179586 ;
:: PI     3.141592653589793 ;

( --- Voice state ------------------------------------------------ )
:: phase-cell  4 alloc ;  0.0  phase-cell  f!32
:: phase2-cell 4 alloc ;  0.0  phase2-cell f!32   ( second oscillator, detuned )
:: env-cell    4 alloc ;  0.0  env-cell    f!32
:: stage-cell  4 alloc ;  0    stage-cell  !32     ( 0=idle 1=att 2=dec 3=sus 4=rel )
:: filt-cell   4 alloc ;  0.0  filt-cell   f!32    ( 1-pole LP state )
:: pitch-cell  4 alloc ;  69.0 pitch-cell  f!32    ( MIDI pitch )
:: vel-cell    4 alloc ;  1.0  vel-cell    f!32    ( velocity 0..1 )
:: gate-cell   4 alloc ;  0    gate-cell   !32

( --- Param cells (knob-driven) ---------------------------------- )
:: attack-cell  4 alloc ;  0.01  attack-cell  f!32  ( seconds )
:: decay-cell   4 alloc ;  0.15  decay-cell   f!32
:: sustain-cell 4 alloc ;  0.6   sustain-cell f!32  ( 0..1 level )
:: release-cell 4 alloc ;  0.25  release-cell f!32  ( seconds )
:: cutoff-cell  4 alloc ;  0.25  cutoff-cell  f!32  ( 0..1 → 0..4000 Hz )
:: gain-cell    4 alloc ;  0.4   gain-cell    f!32

( --- Labels ----------------------------------------------------- )
:: _lbl_m1  "MONO1"   cstr-new ;
:: _lbl_att "ATK"     cstr-new ;
:: _lbl_dec "DEC"     cstr-new ;
:: _lbl_sus "SUS"     cstr-new ;
:: _lbl_rel "REL"     cstr-new ;
:: _lbl_cut "CUT"     cstr-new ;
:: _lbl_gn  "GAIN"    cstr-new ;

( --- Structs ---------------------------------------------------- )
struct: Mono1State  f64 phase  f32 env  u32 stage ;
struct: Mono1Params f32 attack  f32 decay  f32 sustain  f32 release  f32 cutoff  f32 gain ;

( --- Pitch → Hz ------------------------------------------------- )
noalloc: midi-to-hz  ( pitch -- hz )
  69.0 f-  12.0 f/  2.0 swap pow  440.0 f*
;

( --- Time (seconds) → one-pole coefficient ---------------------- )
noalloc: time-to-coeff  ( time-s -- coeff )
  ( reaches 0.001 (-60 dB) in exactly time-s seconds )
  slab:sr f*  6.9 swap f/  fneg exp  ( e^(-6.9/(time*sr)) )
  1.0 swap f-
;

( --- Sawtooth sample -------------------------------------------- )
noalloc: saw-sample  ( phase -- sample )
  TWO_PI f/  2.0 f*  1.0 f-
;

( --- ADSR envelope step words — (env -- env_new) ---------------- )
noalloc: do-attack   ( env -- env_new )
  1.0 over f-  attack-cell f@32 time-to-coeff f*  f+
;

noalloc: do-decay    ( env -- env_new )
  sustain-cell f@32 over f-  decay-cell f@32 time-to-coeff f*  f+
;

noalloc: do-release  ( env -- env_new )
  0.0 over f-  release-cell f@32 time-to-coeff f*  f+
;

( --- Envelope tick — call once per sample ----------------------- )
noalloc: adsr-tick  ( -- level )
  stage-cell @32 0 =
  [ 0.0 ]
  [
    env-cell f@32
    ( Attack )
    stage-cell @32 1 =
    [ do-attack
      dup 0.999 f< not  [ 2 stage-cell !32 ] then ] then
    ( Decay )
    stage-cell @32 2 =
    [ do-decay
      dup sustain-cell f@32 f> not  [ 3 stage-cell !32 ] then ] then
    ( Sustain — hold at sustain level )
    stage-cell @32 3 =
    [ sustain-cell f@32 swap drop ] then
    ( Release )
    stage-cell @32 4 =
    [ do-release
      dup 0.001 f<  [ 0 stage-cell !32 ] then ] then
    dup env-cell f!32
  ]
  ifte
;

( --- 1-pole LP filter ------------------------------------------- )
noalloc: lp-filter  ( sample -- filtered )
  ( y_new = y + coeff*(x - y)  where coeff = TWO_PI * cutoff_hz / sr )
  dup filt-cell f@32 f-                             ( sample delta=x-y )
  TWO_PI cutoff-cell f@32 4000.0 f* slab:sr f/ f*   ( sample delta coeff )
  f*                                                ( sample delta*coeff )
  filt-cell f@32 f+                                 ( sample new_filt )
  swap drop                                         ( new_filt )
  dup filt-cell f!32
;

( --- Note event processing -------------------------------------- )
noalloc: process-notes
  0 slab:note-count
  [
    dup slab:note-kind 0 =
    [ dup slab:note-pitch pitch-cell f!32
      dup slab:note-vel   vel-cell   f!32
      0.0 phase-cell  f!32
      0.0 phase2-cell f!32
      1 gate-cell !32
      1 stage-cell !32 ] then
    dup slab:note-kind 1 =
    [ 4 stage-cell !32 ] then
    1+
  ] dotimes
  drop
;

( --- Audio entrypoint ------------------------------------------- )
noalloc: mono1-audio
  process-notes
  0 slab:block-size
  [
    adsr-tick   ( counter level )
    dup 0.001 f<
    [
      ( silence )
      drop
      dup 4 * slab:audio-l + 0.0 swap f!32
      dup 4 * slab:audio-r + 0.0 swap f!32
    ]
    [
      vel-cell f@32 f*                      ( counter vca )
      phase-cell  f@32 saw-sample
      phase2-cell f@32 saw-sample
      f+ 0.5 f*                             ( counter vca mixed_saw )
      lp-filter
      f*
      gain-cell f@32 f*                     ( counter output )
      dup 2 pick 4 * slab:audio-l + f!32
      1 pick 4 * slab:audio-r + f!32
      ( advance osc 1 )
      phase-cell f@32
      TWO_PI pitch-cell f@32 midi-to-hz f* slab:sr f/ f+
      dup TWO_PI f> [ TWO_PI f- ] [ ] ifte
      phase-cell f!32
      ( advance osc 2 — 7 cents sharp for classic detune )
      phase2-cell f@32
      TWO_PI pitch-cell f@32 midi-to-hz 1.004 f* f* slab:sr f/ f+
      dup TWO_PI f> [ TWO_PI f- ] [ ] ifte
      phase2-cell f!32
    ]
    ifte
    1+
  ] dotimes
  drop
;

( --- UI: 6 knobs in a row --------------------------------------- )
( Cell geometry — 52px wide, 1px gap between cells )
:: CW 52.0 ;    ( cell width )
:: CG 53.0 ;    ( cell stride = width + 1px gap )

: cy   ( -- y )  slab:panel-y 18.0 f+ ;
: ch   ( -- h )  slab:panel-h 20.0 f- ;
: cx0  ( -- x )  slab:panel-x 2.0 f+ ;
: cx1  ( -- x )  slab:panel-x 2.0 f+ CG f+ ;
: cx2  ( -- x )  slab:panel-x 2.0 f+ CG 2.0 f* f+ ;
: cx3  ( -- x )  slab:panel-x 2.0 f+ CG 3.0 f* f+ ;
: cx4  ( -- x )  slab:panel-x 2.0 f+ CG 4.0 f* f+ ;
: cx5  ( -- x )  slab:panel-x 2.0 f+ CG 5.0 f* f+ ;

: mono1-ui
  slab:panel-x slab:panel-y slab:panel-w 16.0 widget:bevel-raised
  slab:panel-x 4.0 f+ slab:panel-y 2.0 f+ _lbl_m1 widget:draw-label

  cx0 cy CW ch _lbl_att attack-cell  f@32 widget:knob attack-cell  f!32
  cx1 cy CW ch _lbl_dec decay-cell   f@32 widget:knob decay-cell   f!32
  cx2 cy CW ch _lbl_sus sustain-cell f@32 widget:knob sustain-cell f!32
  cx3 cy CW ch _lbl_rel release-cell f@32 widget:knob release-cell f!32
  cx4 cy CW ch _lbl_cut cutoff-cell  f@32 widget:knob cutoff-cell  f!32
  cx5 cy CW ch _lbl_gn  gain-cell    f@32 widget:knob gain-cell    f!32
;

( --- Manifest --------------------------------------------------- )
: manifest
  \mono1-audio  \mono1-ui
  Mono1State.size  Mono1Params.size
  notes->audio
  Machine.new
;
