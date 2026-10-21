( grind2.fy - Grinder: stacked distortion [docs/43 §Grinder].

  Ten curves from a rounded op-amp drive to a dead zone, stacked up to
  four times, with a bias that follows the playing, mirrored emphasis
  around the drive, zero-crossing sizzle, bass-driven flux and phase
  distortion.  4x oversampled; AUTO holds the level, CLIP the ceiling.
  The DSP is kernels/07-effects/grinder.fy. )

include "../../kernels/07-effects/grinder.fy"
include "../lib/manifest.fy"

: manifest
  "Grinder" effect-block machine*
  "k-grinder-tick" render!  "grinder-block-prepare" block-prepare!
  GrindState.size state-size!  GrindParams.size params-size!
  GrindParams.lat latency!
  640.0 panel-w!

  ( 60 ms PHASE ring per channel )
  "phase" GrindState.buf GrindState.buf-len 0.06 buffer

  "GRIND" "ALGO" "grind-algo" GrindParams.algo 0.0 switch
    "OVERDRIVE" 0.0 opt "RAT" 1.0 opt "FUZZ" 2.0 opt "SOFT" 3.0 opt "HARD" 4.0 opt
    "FOLD" 5.0 opt "SINE" 6.0 opt "CUBE" 7.0 opt "RECT" 8.0 opt "DEAD" 9.0 opt as-list span-rows
  "GRIND" "DRIVE" "grind-drive" GrindParams.drive-db 0.0 60.0 18.0 curve-lin knob
  "GRIND" "BIAS" "grind-bias" GrindParams.bias -1.0 1.0 0.0 curve-lin knob
  "GRIND" "STAGES" "grind-stages" GrindParams.stages 0.0 switch
    "1" 0.0 opt "2" 1.0 opt "3" 2.0 opt "4" 3.0 opt as-radio
  "EMPH" "LO HZ" "grind-lo-hz" GrindParams.lo-hz 40.0 800.0 120.0 curve-exp knob
  "EMPH" "LO DB" "grind-lo-db" GrindParams.lo-db -18.0 18.0 0.0 curve-lin knob
  "EMPH" "HI HZ" "grind-hi-hz" GrindParams.hi-hz 800.0 12000.0 3000.0 curve-exp knob
  "EMPH" "HI DB" "grind-hi-db" GrindParams.hi-db -18.0 18.0 0.0 curve-lin knob
  "TEXTURE" "SIZZLE" "grind-sizzle" GrindParams.sizzle 0.0 1.0 0.0 curve-pow knob
  "TEXTURE" "FLUX" "grind-flux" GrindParams.flux 0.0 1.0 0.0 curve-lin knob
  "TEXTURE" "PHASE" "grind-phase" GrindParams.phase 0.0 1.0 0.0 curve-lin knob
  "OUT" "TONE" "grind-tone" GrindParams.tone 500.0 20000.0 12000.0 curve-exp knob
  "OUT" "AUTO" "grind-auto" GrindParams.auto-on 1.0 switch
    "OFF" 0.0 opt "ON" 1.0 opt as-button
  "OUT" "CLIP" "grind-clip" GrindParams.clip 1.0 switch
    "OFF" 0.0 opt "SOFT" 1.0 opt "HARD" 2.0 opt as-radio
  "OUT" "MIX" "grind-mix" GrindParams.mix 0.0 1.0 1.0 curve-pow knob
  "OUT" "LEVEL" "grind-out" GrindParams.out-db -24.0 12.0 0.0 curve-lin knob
  "GRIND" 2 strip
  "EMPH" 2 strip
  "TEXTURE" 1 strip
  "OUT" 2 strip
  1.0 row
    1.6 cell "GRIND" 1.0 item
    1.0 cell "EMPH" 1.0 item
    0.6 cell "TEXTURE" 1.0 item
    1.0 cell "OUT" 1.0 item
  machine-desc
;
