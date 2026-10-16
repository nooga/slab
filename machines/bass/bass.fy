( bass.fy — Fretwire: a waveguide electric bass.

  The voice is the plucked-string waveguide in kernels/06-voices/string.fy;
  this file declares the machine.  Every voice owns a string: its delay
  loop is a host buffer, one per voice.

  Panel: STRING [how it rings] | PLUCK [how it is played] | PICKUP [where
  it is heard] | FEEL. )

include "../../kernels/06-voices/string_body.fy"
include "../lib/manifest.fy"

: manifest
  "Fretwire" voice-sample machine*
  "k-string-voice"       render!
  "string-note-on"       note-on!
  "string-note-off"      note-off!
  "string-note-expr"     note-expr!
  "string-block-prepare" block-prepare!
  "string-control" 64    control!
  4 voices!
  ( overlapping single notes up to a fourth apart: hammer-ons, pull-offs )
  5.0 legato-span!
  StringState.size  state-size!
  StringParams.size params-size!
  ( the bridge, body and wiring all strings share [string_body.fy] )
  FwBody.size FW-RING-BYTES + shared-size!
  "fw-body-render" 1 shared!
  StringState.tens voice-level!
  "ring" StringState.buf StringState.buf-len 0.045 buffer
  ( a four-string bass in standard tuning; B, HF DEC, SOFT, THUMP stated at its low end )
  StringParams.ref-hz 41.2 const-f64
  StringParams.b-ref 36.71 const-f64
  StringParams.hf-track 0.75 const-f64
  StringParams.out-g 2.25 const-f64
  StringParams.o1 41.2 const-f64   StringParams.o2 55.0 const-f64
  StringParams.o3 73.42 const-f64  StringParams.o4 98.0 const-f64
  StringParams.o5 1000000000.0 const-f64  StringParams.o6 1000000000.0 const-f64
  StringParams.n-str 4.0 const-f64
  StringParams.body-base 4.0 const-f64
  ( a 34-inch scale: coils and their spacing are a smaller share of it )
  StringParams.coil-k 0.75 const-f64
  ( a Jazz-type single coil: 3.5 H, 7.5 k; a 47 nF tone cap )
  StringParams.l-coil 3.5 const-f64
  StringParams.r-coil 7500.0 const-f64
  StringParams.c-tone 4.7e-08 const-f64
  520.0 panel-w!

  "STRING" "DECAY"   "bs-decay"   StringParams.decay    0.3 40.0 12.0 curve-exp knob
  "STRING" "HF DEC"  "bs-hfdec"   StringParams.hf-decay 0.05 10.0 1.2 curve-exp knob
  "STRING" "KNEE"    "bs-knee"    StringParams.knee     1.0 32.0 9.0  curve-exp knob
  "STRING" "STIFF"   "bs-stiff"   StringParams.stiff    0.0 10.0 4.0  curve-lin knob
  "STRING" "RELEASE" "bs-release" StringParams.release  0.02 2.0 0.12 curve-exp knob
  "STRING" 3 strip

  "PLUCK" "POS"    "bs-pos"    StringParams.pos    0.04 0.5 0.14 curve-lin knob
  "PLUCK" "SOFT"   "bs-soft"   StringParams.soft   0.05 6.0 2.0  curve-exp knob
  "PLUCK" "SHAPE"  "bs-shape"  StringParams.shape  0.0 1.0 0.0   curve-lin knob
  "PLUCK" "NOISE"  "bs-noise"  StringParams.noise  0.0 1.0 0.15  curve-pow knob
  "PLUCK" "HAND" "bs-hand"   StringParams.hand   0.0 12.0 5.0  curve-lin knob
  "PLUCK" 3 strip

  "PICKUPS" "NECK"  "bs-pickup" StringParams.pickup 0.04 0.5 0.2   curve-lin knob
  "PICKUPS" "BRIDGE" "bs-pickup-b" StringParams.pickup-b 0.04 0.5 0.1 curve-lin knob
  "PICKUPS" "SELECT" "bs-sel" StringParams.sel 0.0 switch
    "NECK" 0.0 opt  "BOTH" 1.0 opt  "BRIDGE" 2.0 opt  "OUT" 3.0 opt  as-list span-rows
  "PICKUPS" "N TYPE" "bs-type-n" StringParams.type-n 0.0 switch
    "SINGLE" 0.0 opt  "SPLIT" 3.0 opt  "HUMBUCK" 2.0 opt  as-list
  "PICKUPS" "B TYPE" "bs-type-b" StringParams.type-b 0.0 switch
    "SINGLE" 0.0 opt  "SPLIT" 3.0 opt  "HUMBUCK" 2.0 opt  as-list
  "PICKUPS" "HEIGHT" "bs-height" StringParams.height 0.0 1.0 0.0 curve-lin knob
  "PICKUPS" 3 strip

  "WIRING" "RESO" "bs-tone"   StringParams.tone   300.0 12000.0 3200.0 curve-exp knob
  "WIRING" "PEAK"  "bs-res"    StringParams.res    0.0 1.0 0.3   curve-lin knob
  "WIRING" "TONE" "bs-tpot" StringParams.tpot 0.0 1.0 1.0 curve-lin knob
  "WIRING" "VOL"  "bs-vol"  StringParams.vol  0.0 1.0 1.0 curve-lin knob
  "WIRING" 2 strip

  "BODY" "BODY" "bs-body" StringParams.body 0.0 switch
    "SOLID" 0.0 opt  "HOLLOW" 1.0 opt  "ACOUSTIC" 2.0 opt  as-list span-rows
  "BODY" "COUPLE" "bs-couple" StringParams.couple 0.0 2.0 1.0 curve-lin knob
  "BODY" "AIR"    "bs-air"    StringParams.air    0.0 1.0 0.0 curve-pow knob
  "BODY" "PIEZO"  "bs-piezo"  StringParams.piezo  0.0 1.0 0.0 curve-pow knob
  "BODY" "SYMP"   "bs-symp"   StringParams.symp   0.0 1.0 0.0 curve-lin knob
  "BODY" 2 strip

  "FEEL" "THUMP" "bs-thump" StringParams.thump 0.0 1.0 0.5 curve-lin knob
  "FEEL" "BUZZ"  "bs-buzz"  StringParams.buzz  0.0 1.0 0.0 curve-lin knob
  "FEEL" "MOTION" "bs-motion" StringParams.motion 0.0 switch
    "AUTO" 0.0 opt  "BEND" 1.0 opt  "SLIDE" 2.0 opt  as-list
  "FEEL" "SLIDE" "bs-slide" StringParams.slide 0.0 1.0 0.4 curve-lin knob
  "FEEL" "LEVEL" "bs-level" StringParams.level 0.0 1.0 0.55 curve-pow knob
  "FEEL" 3 strip

  "VIBRATO" "RATE"  "bs-vibrate"  StringParams.vib-rate  2.0 9.0 5.0 curve-lin knob
  "VIBRATO" "DEPTH" "bs-vibdepth" StringParams.vib-depth 0.0 2.0 0.5 curve-lin knob
  "VIBRATO" 1 strip

  "PLAY" page
    1.0 row
      1.0 cell  "STRING" 1.0 item
      1.0 cell  "PLUCK" 1.0 item
    1.0 row
      1.0 cell  "FEEL" 1.0 item
      0.5 cell  "VIBRATO" 1.0 item
  "BASS" page
    1.0 row
      1.2 cell  "PICKUPS" 1.0 item
      0.8 cell  "WIRING" 1.0 item
    1.0 row
      1.0 cell  "BODY" 1.0 item

  machine-desc
;
