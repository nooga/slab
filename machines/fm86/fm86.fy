( fm86.fy — FM-86, a DX7-architecture 6-operator FM voice.

  The DSP is the validated rig stack: each operator is a phase-mod sine with
  two-sample feedback (fm_operator.fy), each has a 4-rate/4-level dB-domain
  envelope (dx7_eg.fy), and the 32 algorithms route them through the matrix
  (dx7_voice.fy). fm86_voice.fy composes the whole voice into one render word
  via `call:` stages. This file is just the machine: entry words, sizes, the
  tabbed panel, and offsets from Fm86Params introspection.

  ALGO selects one of the 32 DX7 algorithms; the fy `derive` word (fm86_algo.fy)
  expands it into the w/c/fb routing params from a fy-built table each block.
  Per operator: RATIO (x fundamental), LEVEL (output), and the envelope
  R1-4 (per-sample dB steps) / L1-4 (segment targets). )

include "../../kernels/06-voices/fm86_voice.fy"
include "../lib/manifest.fy"
include "fm86_algo.fy"

: manifest
  "FM-86" voice-sample machine*
  "k-fm86-voice-sample" render!
  "fm86-prepare"        prepare!
  "fm86-note-on"        note-on!
  "fm86-note-off"       note-off!
  "fm86-block-prepare"  block-prepare!
  "fm86-derive"         derive!
  fm86-algo-table       derive-data!
  Fm86State.size  state-size!
  Fm86Params.size params-size!
  480.0 panel-w!

  ( ── global ───────────────────────────────────────────────────────── )
  "GLOBAL" "ALGO"   "algo"     Fm86Params.algo     1.0 32.0 1.0 int-step
  "GLOBAL" "FBK"    "feedback" Fm86Params.feedback 0.0 3.0  0.0 curve-lin knob
  "GLOBAL" "MASTER" "master"   Fm86Params.master   0.0 1.0  0.7 curve-pow knob

  ( ── operator 1 (carrier in alg 1) ────────────────────────────────── )
  "OP1" "RATIO" "op1-ratio" Fm86Params.ratio0 0.25 32.0 1.0 curve-lin knob
  "OP1" "LEVEL" "op1-level" Fm86Params.ol0    0.0 2.5 1.0 curve-pow knob
  "OP1" "R1" "op1-r1" Fm86Params.eg0-s1 0.00001 0.08 0.012 curve-exp knob
  "OP1" "R2" "op1-r2" Fm86Params.eg0-s2 0.00001 0.08 0.008 curve-exp knob
  "OP1" "R3" "op1-r3" Fm86Params.eg0-s3 0.00001 0.08 0.004 curve-exp knob
  "OP1" "R4" "op1-r4" Fm86Params.eg0-s4 0.00001 0.08 0.010 curve-exp knob
  "OP1" "L1" "op1-l1" Fm86Params.eg0-l1 0.0 1.0 1.0  curve-lin knob
  "OP1" "L2" "op1-l2" Fm86Params.eg0-l2 0.0 1.0 0.95 curve-lin knob
  "OP1" "L3" "op1-l3" Fm86Params.eg0-l3 0.0 1.0 0.90 curve-lin knob
  "OP1" "L4" "op1-l4" Fm86Params.eg0-l4 0.0 1.0 0.0  curve-lin knob

  ( ── operator 2 ──────────────────────────────────────────────────── )
  "OP2" "RATIO" "op2-ratio" Fm86Params.ratio1 0.25 32.0 1.0 curve-lin knob
  "OP2" "LEVEL" "op2-level" Fm86Params.ol1    0.0 2.5 0.6 curve-pow knob
  "OP2" "R1" "op2-r1" Fm86Params.eg1-s1 0.00001 0.08 0.012 curve-exp knob
  "OP2" "R2" "op2-r2" Fm86Params.eg1-s2 0.00001 0.08 0.008 curve-exp knob
  "OP2" "R3" "op2-r3" Fm86Params.eg1-s3 0.00001 0.08 0.004 curve-exp knob
  "OP2" "R4" "op2-r4" Fm86Params.eg1-s4 0.00001 0.08 0.010 curve-exp knob
  "OP2" "L1" "op2-l1" Fm86Params.eg1-l1 0.0 1.0 1.0  curve-lin knob
  "OP2" "L2" "op2-l2" Fm86Params.eg1-l2 0.0 1.0 0.95 curve-lin knob
  "OP2" "L3" "op2-l3" Fm86Params.eg1-l3 0.0 1.0 0.90 curve-lin knob
  "OP2" "L4" "op2-l4" Fm86Params.eg1-l4 0.0 1.0 0.0  curve-lin knob

  ( ── operator 3 (carrier in alg 1) ────────────────────────────────── )
  "OP3" "RATIO" "op3-ratio" Fm86Params.ratio2 0.25 32.0 1.0 curve-lin knob
  "OP3" "LEVEL" "op3-level" Fm86Params.ol2    0.0 2.5 1.0 curve-pow knob
  "OP3" "R1" "op3-r1" Fm86Params.eg2-s1 0.00001 0.08 0.012 curve-exp knob
  "OP3" "R2" "op3-r2" Fm86Params.eg2-s2 0.00001 0.08 0.008 curve-exp knob
  "OP3" "R3" "op3-r3" Fm86Params.eg2-s3 0.00001 0.08 0.004 curve-exp knob
  "OP3" "R4" "op3-r4" Fm86Params.eg2-s4 0.00001 0.08 0.010 curve-exp knob
  "OP3" "L1" "op3-l1" Fm86Params.eg2-l1 0.0 1.0 1.0  curve-lin knob
  "OP3" "L2" "op3-l2" Fm86Params.eg2-l2 0.0 1.0 0.95 curve-lin knob
  "OP3" "L3" "op3-l3" Fm86Params.eg2-l3 0.0 1.0 0.90 curve-lin knob
  "OP3" "L4" "op3-l4" Fm86Params.eg2-l4 0.0 1.0 0.0  curve-lin knob

  ( ── operator 4 ──────────────────────────────────────────────────── )
  "OP4" "RATIO" "op4-ratio" Fm86Params.ratio3 0.25 32.0 1.0 curve-lin knob
  "OP4" "LEVEL" "op4-level" Fm86Params.ol3    0.0 2.5 0.6 curve-pow knob
  "OP4" "R1" "op4-r1" Fm86Params.eg3-s1 0.00001 0.08 0.012 curve-exp knob
  "OP4" "R2" "op4-r2" Fm86Params.eg3-s2 0.00001 0.08 0.008 curve-exp knob
  "OP4" "R3" "op4-r3" Fm86Params.eg3-s3 0.00001 0.08 0.004 curve-exp knob
  "OP4" "R4" "op4-r4" Fm86Params.eg3-s4 0.00001 0.08 0.010 curve-exp knob
  "OP4" "L1" "op4-l1" Fm86Params.eg3-l1 0.0 1.0 1.0  curve-lin knob
  "OP4" "L2" "op4-l2" Fm86Params.eg3-l2 0.0 1.0 0.95 curve-lin knob
  "OP4" "L3" "op4-l3" Fm86Params.eg3-l3 0.0 1.0 0.90 curve-lin knob
  "OP4" "L4" "op4-l4" Fm86Params.eg3-l4 0.0 1.0 0.0  curve-lin knob

  ( ── operator 5 ──────────────────────────────────────────────────── )
  "OP5" "RATIO" "op5-ratio" Fm86Params.ratio4 0.25 32.0 1.0 curve-lin knob
  "OP5" "LEVEL" "op5-level" Fm86Params.ol4    0.0 2.5 0.5 curve-pow knob
  "OP5" "R1" "op5-r1" Fm86Params.eg4-s1 0.00001 0.08 0.012 curve-exp knob
  "OP5" "R2" "op5-r2" Fm86Params.eg4-s2 0.00001 0.08 0.008 curve-exp knob
  "OP5" "R3" "op5-r3" Fm86Params.eg4-s3 0.00001 0.08 0.004 curve-exp knob
  "OP5" "R4" "op5-r4" Fm86Params.eg4-s4 0.00001 0.08 0.010 curve-exp knob
  "OP5" "L1" "op5-l1" Fm86Params.eg4-l1 0.0 1.0 1.0  curve-lin knob
  "OP5" "L2" "op5-l2" Fm86Params.eg4-l2 0.0 1.0 0.95 curve-lin knob
  "OP5" "L3" "op5-l3" Fm86Params.eg4-l3 0.0 1.0 0.90 curve-lin knob
  "OP5" "L4" "op5-l4" Fm86Params.eg4-l4 0.0 1.0 0.0  curve-lin knob

  ( ── operator 6 (feedback op in alg 1) ────────────────────────────── )
  "OP6" "RATIO" "op6-ratio" Fm86Params.ratio5 0.25 32.0 1.0 curve-lin knob
  "OP6" "LEVEL" "op6-level" Fm86Params.ol5    0.0 2.5 0.5 curve-pow knob
  "OP6" "R1" "op6-r1" Fm86Params.eg5-s1 0.00001 0.08 0.012 curve-exp knob
  "OP6" "R2" "op6-r2" Fm86Params.eg5-s2 0.00001 0.08 0.008 curve-exp knob
  "OP6" "R3" "op6-r3" Fm86Params.eg5-s3 0.00001 0.08 0.004 curve-exp knob
  "OP6" "R4" "op6-r4" Fm86Params.eg5-s4 0.00001 0.08 0.010 curve-exp knob
  "OP6" "L1" "op6-l1" Fm86Params.eg5-l1 0.0 1.0 1.0  curve-lin knob
  "OP6" "L2" "op6-l2" Fm86Params.eg5-l2 0.0 1.0 0.95 curve-lin knob
  "OP6" "L3" "op6-l3" Fm86Params.eg5-l3 0.0 1.0 0.90 curve-lin knob
  "OP6" "L4" "op6-l4" Fm86Params.eg5-l4 0.0 1.0 0.0  curve-lin knob

  ( rate-scale = 1.0 for every operator (key rate scaling is phase 3). )
  Fm86Params.eg0-rs 1.0 const-f64  Fm86Params.eg1-rs 1.0 const-f64
  Fm86Params.eg2-rs 1.0 const-f64  Fm86Params.eg3-rs 1.0 const-f64
  Fm86Params.eg4-rs 1.0 const-f64  Fm86Params.eg5-rs 1.0 const-f64

  ( ── strips: one beveled box per tab's controls ───────────────────── )
  "GLOBAL" 3 strip
  "OP1" 5 strip  "OP2" 5 strip  "OP3" 5 strip
  "OP4" 5 strip  "OP5" 5 strip  "OP6" 5 strip

  ( ── tabbed panel: a page per operator plus globals ───────────────── )
  "GLOBAL" page  1.0 row  1.0 cell  "GLOBAL" 1.0 item
  "OP 1"   page  1.0 row  1.0 cell  "OP1"    1.0 item
  "OP 2"   page  1.0 row  1.0 cell  "OP2"    1.0 item
  "OP 3"   page  1.0 row  1.0 cell  "OP3"    1.0 item
  "OP 4"   page  1.0 row  1.0 cell  "OP4"    1.0 item
  "OP 5"   page  1.0 row  1.0 cell  "OP5"    1.0 item
  "OP 6"   page  1.0 row  1.0 cell  "OP6"    1.0 item

  machine-desc
;
