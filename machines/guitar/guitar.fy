( guitar.fy - Fretwire Guitar: a waveguide electric guitar.

  The same plucked string as the bass [kernels/06-voices/string.fy], strung
  as a six-string guitar: six voices, one per string, and its own tuning,
  stiffness and pickups.  Fitted against Karoryfer's Emily [flatwounds,
  both pickups, direct] with tools/fit/string_fit.py.  Pitch curves bend
  or slide [MOTION].  Put Ampstack after it. )

include "../../kernels/06-voices/string_body.fy"
include "../lib/manifest.fy"

: manifest
  "Fretwire Guitar" voice-sample machine*
  "k-string-voice"       render!
  "string-note-on"       note-on!
  "string-note-off"      note-off!
  "string-note-expr"     note-expr!
  "string-block-prepare" block-prepare!
  "string-control" 64    control!
  6 voices!
  ( overlapping single notes up to a fourth apart: hammer-ons, pull-offs )
  5.0 legato-span!
  StringState.size  state-size!
  StringParams.size params-size!
  ( the bridge, body and wiring all strings share [string_body.fy] )
  FwBody.size FW-RING-BYTES + shared-size!
  "fw-body-render" 1 shared!
  StringState.tens voice-level!
  "ring" StringState.buf StringState.buf-len 0.03 buffer
  ( a six-string guitar in standard tuning; HF DEC, SOFT, THUMP and B
    are stated at its low E )
  StringParams.ref-hz 82.41 const-f64
  StringParams.b-ref 82.41 const-f64
  StringParams.hf-track 0.0 const-f64
  StringParams.out-g 0.75 const-f64
  StringParams.o1 82.41 const-f64   StringParams.o2 110.0 const-f64
  StringParams.o3 146.83 const-f64  StringParams.o4 196.0 const-f64
  StringParams.o5 246.94 const-f64  StringParams.o6 329.63 const-f64
  StringParams.n-str 6.0 const-f64
  StringParams.body-base 0.0 const-f64
  StringParams.coil-k 1.0 const-f64
  ( a Strat-type single coil: 2.5 H, 6 k; a 22 nF tone cap )
  StringParams.l-coil 2.5 const-f64
  StringParams.r-coil 6000.0 const-f64
  StringParams.c-tone 2.2e-08 const-f64
  520.0 panel-w!

  "STRING" "DECAY"   "gt-decay"   StringParams.decay    0.3 40.0 12.0 curve-exp knob
  "STRING" "HF DEC"  "gt-hfdec"   StringParams.hf-decay 0.05 10.0 0.8 curve-exp knob
  "STRING" "KNEE"    "gt-knee"    StringParams.knee     1.0 32.0 5.0  curve-exp knob
  "STRING" "STIFF"   "gt-stiff"   StringParams.stiff    0.0 10.0 1.2  curve-lin knob
  "STRING" "RELEASE" "gt-release" StringParams.release  0.02 2.0 0.12 curve-exp knob
  "STRING" 3 strip

  "PLUCK" "POS"    "gt-pos"    StringParams.pos    0.04 0.5 0.17 curve-lin knob
  "PLUCK" "SOFT"   "gt-soft"   StringParams.soft   0.05 6.0 1.0  curve-exp knob
  "PLUCK" "SHAPE"  "gt-shape"  StringParams.shape  0.0 1.0 0.4   curve-lin knob
  "PLUCK" "NOISE"  "gt-noise"  StringParams.noise  0.0 1.0 0.15  curve-pow knob
  "PLUCK" "HAND" "gt-hand"   StringParams.hand   0.0 12.0 0.0  curve-lin knob
  "PLUCK" 3 strip

  "PICKUPS" "NECK"  "gt-pickup" StringParams.pickup 0.04 0.5 0.24  curve-lin knob
  "PICKUPS" "BRIDGE" "gt-pickup-b" StringParams.pickup-b 0.04 0.5 0.07 curve-lin knob
  "PICKUPS" "SELECT" "gt-sel" StringParams.sel 0.0 switch
    "NECK" 0.0 opt  "BOTH" 1.0 opt  "BRIDGE" 2.0 opt  "OUT" 3.0 opt  as-list span-rows
  "PICKUPS" "N TYPE" "gt-type-n" StringParams.type-n 0.0 switch
    "SINGLE" 0.0 opt  "P-90" 1.0 opt  "HUMBUCK" 2.0 opt  as-list
  "PICKUPS" "B TYPE" "gt-type-b" StringParams.type-b 0.0 switch
    "SINGLE" 0.0 opt  "P-90" 1.0 opt  "HUMBUCK" 2.0 opt  as-list
  "PICKUPS" "HEIGHT" "gt-height" StringParams.height 0.0 1.0 0.0 curve-lin knob
  "PICKUPS" 3 strip

  "WIRING" "RESO" "gt-tone"   StringParams.tone   300.0 12000.0 4500.0 curve-exp knob
  "WIRING" "PEAK"  "gt-res"    StringParams.res    0.0 1.0 0.4   curve-lin knob
  "WIRING" "TONE" "gt-tpot" StringParams.tpot 0.0 1.0 1.0 curve-lin knob
  "WIRING" "VOL"  "gt-vol"  StringParams.vol  0.0 1.0 1.0 curve-lin knob
  "WIRING" 2 strip

  "BODY" "BODY" "gt-body" StringParams.body 0.0 switch
    "SOLID" 0.0 opt  "SEMI" 1.0 opt  "HOLLOW" 2.0 opt  "ACOUSTIC" 3.0 opt  as-list span-rows
  "BODY" "COUPLE" "gt-couple" StringParams.couple 0.0 2.0 1.0 curve-lin knob
  "BODY" "AIR"    "gt-air"    StringParams.air    0.0 1.0 0.0 curve-pow knob
  "BODY" "PIEZO"  "gt-piezo"  StringParams.piezo  0.0 1.0 0.0 curve-pow knob
  "BODY" "SYMP"   "gt-symp"   StringParams.symp   0.0 1.0 0.0 curve-lin knob
  "BODY" 2 strip

  "FEEL" "THUMP" "gt-thump" StringParams.thump 0.0 1.0 0.3 curve-lin knob
  "FEEL" "BUZZ"  "gt-buzz"  StringParams.buzz  0.0 1.0 0.0 curve-lin knob
  "FEEL" "MOTION" "gt-motion" StringParams.motion 0.0 switch
    "AUTO" 0.0 opt  "BEND" 1.0 opt  "SLIDE" 2.0 opt  as-list
  "FEEL" "SLIDE" "gt-slide" StringParams.slide 0.0 1.0 0.4 curve-lin knob
  "FEEL" "LEVEL" "gt-level" StringParams.level 0.0 1.0 0.5 curve-pow knob
  "FEEL" 3 strip

  "VIBRATO" "RATE"  "gt-vibrate"  StringParams.vib-rate  2.0 9.0 5.0 curve-lin knob
  "VIBRATO" "DEPTH" "gt-vibdepth" StringParams.vib-depth 0.0 2.0 0.8 curve-lin knob
  "VIBRATO" 1 strip

  "PLAY" page
    1.0 row
      1.0 cell  "STRING" 1.0 item
      1.0 cell  "PLUCK" 1.0 item
    1.0 row
      1.0 cell  "FEEL" 1.0 item
      0.5 cell  "VIBRATO" 1.0 item
  "GUITAR" page
    1.0 row
      1.2 cell  "PICKUPS" 1.0 item
      0.8 cell  "WIRING" 1.0 item
    1.0 row
      1.0 cell  "BODY" 1.0 item

  machine-desc
;
