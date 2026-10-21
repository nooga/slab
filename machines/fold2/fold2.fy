( fold2.fy - Folder: a wavefolder [docs/43 §Folder].

  Drive folds the wave back on itself instead of clipping it: FOLD adds
  folds, STAGES doubles them, SHAPE runs from the triangle's buzz to the
  sine's ring, SYMM brings in even harmonics, DYN lets the playing move
  it.  4x oversampled with antiderivative anti-aliasing; AUTO holds the
  level.  The DSP is kernels/07-effects/folder.fy. )

include "../../kernels/07-effects/folder.fy"
include "../lib/manifest.fy"

: manifest
  "Folder" effect-block machine*
  "k-folder-tick" render!  "folder-block-prepare" block-prepare!
  FoldState.size state-size!  FoldParams.size params-size!
  FoldParams.lat latency!
  480.0 panel-w!

  "FOLD" "FOLD" "fold-fold" FoldParams.fold-db 0.0 40.0 12.0 curve-lin knob
  "FOLD" "SYMM" "fold-symm" FoldParams.symm -1.0 1.0 0.0 curve-lin knob
  "FOLD" "SHAPE" "fold-shape" FoldParams.shape 0.0 1.0 0.0 curve-lin knob
  "FOLD" "DYN" "fold-dyn" FoldParams.dyn -1.0 1.0 0.0 curve-lin knob
  "FOLD" "STAGES" "fold-stages" FoldParams.stages 0.0 switch
    "1" 0.0 opt "2" 1.0 opt "3" 2.0 opt "4" 3.0 opt as-radio
  "VOICE" "TIGHT" "fold-tight" FoldParams.tight 10.0 500.0 20.0 curve-exp knob
  "VOICE" "TONE" "fold-tone" FoldParams.tone 500.0 20000.0 16000.0 curve-exp knob
  "OUT" "AUTO" "fold-auto" FoldParams.auto-on 1.0 switch
    "OFF" 0.0 opt "ON" 1.0 opt as-button
  "OUT" "MIX" "fold-mix" FoldParams.mix 0.0 1.0 1.0 curve-pow knob
  "OUT" "LEVEL" "fold-out" FoldParams.out-db -24.0 12.0 0.0 curve-lin knob
  "FOLD" 2 strip
  "VOICE" 1 strip
  "OUT" 1 strip
  1.0 row
    2.0 cell "FOLD" 1.0 item
    1.0 cell "VOICE" 1.0 item
    1.0 cell "OUT" 1.0 item
  machine-desc
;
