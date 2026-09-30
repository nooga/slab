( verb2.fy — stereo reverb machine: a Dattorro plate and an 8-line FDN
  for rooms and halls.

  The DSP lives in the kernels rig [kernels/07-effects/reverb.fy]; this
  file declares the machine.  One true-stereo pass on one packed buffer:
  ALGO picks the tank, DECAY is in seconds, BASS/XOVER set the low decay,
  EARLY adds reflections, GATE is the 80s non-linear program. )

include "../../kernels/07-effects/reverb.fy"
include "../lib/manifest.fy"

: manifest
  "Verb" effect-block machine*
  "k-verb-tick"        render!
  "verb-prepare"       prepare!
  "verb-block-prepare" block-prepare!
  VerbState.size  state-size!
  VerbParams.size params-size!
  720.0 panel-w!
  stereo
  sidechain

  ( one packed buffer, region table in reverb.fy )
  "tank" VerbState.buf VerbState.buf-len 2.37 buffer

  "SPACE" "ALGO" "verb-algo" VerbParams.algo 0.0 switch
    "PLATE" 0.0 opt  "ROOM" 1.0 opt  "HALL" 2.0 opt  as-vradio
  "SPACE" "SIZE"  "verb-size"  VerbParams.space  0.5  1.5  1.0  curve-lin knob
  "SPACE" "DECAY" "verb-decay" VerbParams.decay  0.2  40.0 3.0  curve-exp knob
  "SPACE" "DIFF"  "verb-diff"  VerbParams.diff   0.0  1.0  1.0  curve-lin knob
  "SPACE" 4 strip

  "INPUT" "PREDLY" "verb-predelay" VerbParams.predelay-s 0.001 0.25 0.02 curve-exp knob
  "INPUT" "SYNC" "verb-pre-sync" VerbParams.pre-sync 0.0 switch
    "FREE" 0.0 opt  "1/64" 0.0625 opt  "1/32" 0.125 opt  "1/16" 0.25 opt
    "1/8" 0.5 opt  as-display
  "INPUT" "LO CUT" "verb-lowcut" VerbParams.lowcut-hz 20.0   1000.0  20.0   curve-exp knob
  "INPUT" "HI CUT" "verb-tone"   VerbParams.bw-hz     1000.0 18000.0 9000.0 curve-exp knob
  "INPUT" 4 strip

  "TONE" "DAMP"  "verb-damp"  VerbParams.damp-hz  1000.0 16000.0 5000.0 curve-exp knob
  "TONE" "BASS"  "verb-bass"  VerbParams.bass     0.5    2.5     1.0    curve-lin knob
  "TONE" "XOVER" "verb-xover" VerbParams.xover-hz 100.0  1500.0  400.0  curve-exp knob
  "TONE" 3 strip

  "MOD" "DEPTH" "verb-mod"      VerbParams.mod-depth 0.0 24.0 10.0 curve-lin knob
  "MOD" "RATE"  "verb-mod-rate" VerbParams.mod-rate  0.1 5.0  1.2  curve-exp knob
  "MOD" 2 strip

  "OUT" "EARLY" "verb-early" VerbParams.early 0.0 1.0 0.0  curve-lin knob
  "OUT" "WIDTH" "verb-width" VerbParams.width 0.0 1.5 1.0  curve-lin knob
  "OUT" "MIX"   "verb-mix"   VerbParams.mix   0.0 1.0 0.30 curve-pow knob
  "OUT" 3 strip

  ( GATED: the dry input keys a gate on the wet tail - the 80s
    non-linear drum room [reverb.fy header] )
  "GATE" "GATE"   "verb-mode"       VerbParams.mode        0.0 switch
    "OFF" 0.0 opt  "GATED" 1.0 opt  as-button
  "GATE" "THRESH" "verb-gate-thr"   VerbParams.gate-thr-db -60.0 0.0 -30.0 curve-lin knob
  "GATE" "HOLD"   "verb-gate-hold"  VerbParams.gate-hold-s 0.05 1.0 0.35 curve-exp knob
  "GATE" "SHAPE"  "verb-gate-shape" VerbParams.gate-shape  -1.0 1.0 0.0 curve-lin knob
  "GATE" 4 strip

  "DECAY" "verb" decay-display

  ( the decay curves beside the space and input; tone, modulation,
    output and the gate under them )
  1.0 row
    1.4 cell  "DECAY" 1.0 item
    1.0 cell  "SPACE" 1.0 item
    1.0 cell  "INPUT" 1.0 item
  1.0 row
    0.75 cell  "TONE" 1.0 item
    0.5 cell  "MOD" 1.0 item
    0.75 cell  "OUT" 1.0 item
    1.0 cell  "GATE" 1.0 item

  machine-desc
;
