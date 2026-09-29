( fm86.fy - FM-7.11 [codename FM-86], a DX7: six operators, 32
  algorithms, and the DX7's own parameters, 0..99 as on the panel, so a
  voice from a .syx cartridge means what it meant on the instrument
  [machines/fm86/tools/dx7_import.py].  The engine follows Dexed's msfa
  [kernels/06-voices/fm86_voice.fy]: envelopes with rate and level
  scaling, velocity, detune and fixed frequencies, the pitch EG, the LFO
  with its delay and PMD / AMD / PMS / AMS.

  Pages: VOICE [algorithm, feedback, the six operators' level and
  frequency], one per operator [envelope, keyboard scaling,
  sensitivities], MOD [LFO and pitch EG]. )

include "../../kernels/06-voices/fm86_voice.fy"
include "../lib/manifest.fy"
include "fm86_algo.fy"

: manifest
  "FM-7.11" voice-sample machine*
  "k-fm86-voice-sample" render!
  "fm86-note-on"        note-on!
  "fm86-note-expr"      note-expr!
  "fm86-note-off"       note-off!
  "fm86-derive"         derive!
  fm86-algo-table       derive-data!
  Fm86State.size  state-size!
  Fm86Params.size params-size!
  8 voices!
  700.0 panel-w!

  ( ── global ───────────────────────────────────────────────────────── )
  "GLOBAL" "ALGO"  "algo"      Fm86Params.algo      1.0 32.0 1.0 int-step as-display
  "GLOBAL" "FBK"   "feedback"  Fm86Params.feedback  0.0 7.0 0.0 int-step
  "GLOBAL" "TRNSP" "transpose" Fm86Params.transpose -24.0 24.0 0.0 int-step
  "GLOBAL" "KSYNC" "oks"       Fm86Params.oks 1.0 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "GLOBAL" "VOL"   "volume"    Fm86Params.volume 0.0 2.0 1.0 curve-pow knob
  ( ── operator 1 ── )
  "OP1" "LEVEL"  "op1-ol"     Fm86Params.op1 DxOpP.ol +     0.0 99.0 99.0 int-step
  "OP1" "COARSE" "op1-coarse" Fm86Params.op1 DxOpP.coarse + 0.0 31.0 1.0 int-step
  "OP1" "FINE"   "op1-fine"   Fm86Params.op1 DxOpP.fine +   0.0 99.0 0.0 int-step
  "OP1" "DETUNE" "op1-det"    Fm86Params.op1 DxOpP.det +   -7.0 7.0 0.0 int-step
  "OP1" "MODE"   "op1-mode"   Fm86Params.op1 DxOpP.mode + 0.0 switch  "RATIO" 0.0 opt  "FIXED" 1.0 opt
  "EG1" "R1" "op1-r1" Fm86Params.op1 DxOpP.r1 + 0.0 99.0 99.0 int-step
  "EG1" "R2" "op1-r2" Fm86Params.op1 DxOpP.r2 + 0.0 99.0 99.0 int-step
  "EG1" "R3" "op1-r3" Fm86Params.op1 DxOpP.r3 + 0.0 99.0 99.0 int-step
  "EG1" "R4" "op1-r4" Fm86Params.op1 DxOpP.r4 + 0.0 99.0 99.0 int-step
  "EG1" "L1" "op1-l1" Fm86Params.op1 DxOpP.l1 + 0.0 99.0 99.0 int-step
  "EG1" "L2" "op1-l2" Fm86Params.op1 DxOpP.l2 + 0.0 99.0 99.0 int-step
  "EG1" "L3" "op1-l3" Fm86Params.op1 DxOpP.l3 + 0.0 99.0 99.0 int-step
  "EG1" "L4" "op1-l4" Fm86Params.op1 DxOpP.l4 + 0.0 99.0 0.0 int-step
  "KS1" "BREAK" "op1-bp" Fm86Params.op1 DxOpP.bp + 0.0 99.0 39.0 int-step
  "KS1" "L DEP" "op1-ld" Fm86Params.op1 DxOpP.ld + 0.0 99.0 0.0 int-step
  "KS1" "R DEP" "op1-rd" Fm86Params.op1 DxOpP.rd + 0.0 99.0 0.0 int-step
  "KS1" "L CRV" "op1-lc" Fm86Params.op1 DxOpP.lc + 0.0 switch  "-LIN" 0.0 opt  "-EXP" 1.0 opt  "+EXP" 2.0 opt  "+LIN" 3.0 opt
  "KS1" "R CRV" "op1-rc" Fm86Params.op1 DxOpP.rc + 0.0 switch  "-LIN" 0.0 opt  "-EXP" 1.0 opt  "+EXP" 2.0 opt  "+LIN" 3.0 opt
  "KS1" "RATE" "op1-rs" Fm86Params.op1 DxOpP.rs + 0.0 7.0 0.0 int-step
  "SENS1" "VEL" "op1-kvs" Fm86Params.op1 DxOpP.kvs + 0.0 7.0 0.0 int-step
  "SENS1" "AMS" "op1-ams" Fm86Params.op1 DxOpP.ams + 0.0 3.0 0.0 int-step
  ( ── operator 2 ── )
  "OP2" "LEVEL"  "op2-ol"     Fm86Params.op2 DxOpP.ol +     0.0 99.0 0.0 int-step
  "OP2" "COARSE" "op2-coarse" Fm86Params.op2 DxOpP.coarse + 0.0 31.0 1.0 int-step
  "OP2" "FINE"   "op2-fine"   Fm86Params.op2 DxOpP.fine +   0.0 99.0 0.0 int-step
  "OP2" "DETUNE" "op2-det"    Fm86Params.op2 DxOpP.det +   -7.0 7.0 0.0 int-step
  "OP2" "MODE"   "op2-mode"   Fm86Params.op2 DxOpP.mode + 0.0 switch  "RATIO" 0.0 opt  "FIXED" 1.0 opt
  "EG2" "R1" "op2-r1" Fm86Params.op2 DxOpP.r1 + 0.0 99.0 99.0 int-step
  "EG2" "R2" "op2-r2" Fm86Params.op2 DxOpP.r2 + 0.0 99.0 99.0 int-step
  "EG2" "R3" "op2-r3" Fm86Params.op2 DxOpP.r3 + 0.0 99.0 99.0 int-step
  "EG2" "R4" "op2-r4" Fm86Params.op2 DxOpP.r4 + 0.0 99.0 99.0 int-step
  "EG2" "L1" "op2-l1" Fm86Params.op2 DxOpP.l1 + 0.0 99.0 99.0 int-step
  "EG2" "L2" "op2-l2" Fm86Params.op2 DxOpP.l2 + 0.0 99.0 99.0 int-step
  "EG2" "L3" "op2-l3" Fm86Params.op2 DxOpP.l3 + 0.0 99.0 99.0 int-step
  "EG2" "L4" "op2-l4" Fm86Params.op2 DxOpP.l4 + 0.0 99.0 0.0 int-step
  "KS2" "BREAK" "op2-bp" Fm86Params.op2 DxOpP.bp + 0.0 99.0 39.0 int-step
  "KS2" "L DEP" "op2-ld" Fm86Params.op2 DxOpP.ld + 0.0 99.0 0.0 int-step
  "KS2" "R DEP" "op2-rd" Fm86Params.op2 DxOpP.rd + 0.0 99.0 0.0 int-step
  "KS2" "L CRV" "op2-lc" Fm86Params.op2 DxOpP.lc + 0.0 switch  "-LIN" 0.0 opt  "-EXP" 1.0 opt  "+EXP" 2.0 opt  "+LIN" 3.0 opt
  "KS2" "R CRV" "op2-rc" Fm86Params.op2 DxOpP.rc + 0.0 switch  "-LIN" 0.0 opt  "-EXP" 1.0 opt  "+EXP" 2.0 opt  "+LIN" 3.0 opt
  "KS2" "RATE" "op2-rs" Fm86Params.op2 DxOpP.rs + 0.0 7.0 0.0 int-step
  "SENS2" "VEL" "op2-kvs" Fm86Params.op2 DxOpP.kvs + 0.0 7.0 0.0 int-step
  "SENS2" "AMS" "op2-ams" Fm86Params.op2 DxOpP.ams + 0.0 3.0 0.0 int-step
  ( ── operator 3 ── )
  "OP3" "LEVEL"  "op3-ol"     Fm86Params.op3 DxOpP.ol +     0.0 99.0 0.0 int-step
  "OP3" "COARSE" "op3-coarse" Fm86Params.op3 DxOpP.coarse + 0.0 31.0 1.0 int-step
  "OP3" "FINE"   "op3-fine"   Fm86Params.op3 DxOpP.fine +   0.0 99.0 0.0 int-step
  "OP3" "DETUNE" "op3-det"    Fm86Params.op3 DxOpP.det +   -7.0 7.0 0.0 int-step
  "OP3" "MODE"   "op3-mode"   Fm86Params.op3 DxOpP.mode + 0.0 switch  "RATIO" 0.0 opt  "FIXED" 1.0 opt
  "EG3" "R1" "op3-r1" Fm86Params.op3 DxOpP.r1 + 0.0 99.0 99.0 int-step
  "EG3" "R2" "op3-r2" Fm86Params.op3 DxOpP.r2 + 0.0 99.0 99.0 int-step
  "EG3" "R3" "op3-r3" Fm86Params.op3 DxOpP.r3 + 0.0 99.0 99.0 int-step
  "EG3" "R4" "op3-r4" Fm86Params.op3 DxOpP.r4 + 0.0 99.0 99.0 int-step
  "EG3" "L1" "op3-l1" Fm86Params.op3 DxOpP.l1 + 0.0 99.0 99.0 int-step
  "EG3" "L2" "op3-l2" Fm86Params.op3 DxOpP.l2 + 0.0 99.0 99.0 int-step
  "EG3" "L3" "op3-l3" Fm86Params.op3 DxOpP.l3 + 0.0 99.0 99.0 int-step
  "EG3" "L4" "op3-l4" Fm86Params.op3 DxOpP.l4 + 0.0 99.0 0.0 int-step
  "KS3" "BREAK" "op3-bp" Fm86Params.op3 DxOpP.bp + 0.0 99.0 39.0 int-step
  "KS3" "L DEP" "op3-ld" Fm86Params.op3 DxOpP.ld + 0.0 99.0 0.0 int-step
  "KS3" "R DEP" "op3-rd" Fm86Params.op3 DxOpP.rd + 0.0 99.0 0.0 int-step
  "KS3" "L CRV" "op3-lc" Fm86Params.op3 DxOpP.lc + 0.0 switch  "-LIN" 0.0 opt  "-EXP" 1.0 opt  "+EXP" 2.0 opt  "+LIN" 3.0 opt
  "KS3" "R CRV" "op3-rc" Fm86Params.op3 DxOpP.rc + 0.0 switch  "-LIN" 0.0 opt  "-EXP" 1.0 opt  "+EXP" 2.0 opt  "+LIN" 3.0 opt
  "KS3" "RATE" "op3-rs" Fm86Params.op3 DxOpP.rs + 0.0 7.0 0.0 int-step
  "SENS3" "VEL" "op3-kvs" Fm86Params.op3 DxOpP.kvs + 0.0 7.0 0.0 int-step
  "SENS3" "AMS" "op3-ams" Fm86Params.op3 DxOpP.ams + 0.0 3.0 0.0 int-step
  ( ── operator 4 ── )
  "OP4" "LEVEL"  "op4-ol"     Fm86Params.op4 DxOpP.ol +     0.0 99.0 0.0 int-step
  "OP4" "COARSE" "op4-coarse" Fm86Params.op4 DxOpP.coarse + 0.0 31.0 1.0 int-step
  "OP4" "FINE"   "op4-fine"   Fm86Params.op4 DxOpP.fine +   0.0 99.0 0.0 int-step
  "OP4" "DETUNE" "op4-det"    Fm86Params.op4 DxOpP.det +   -7.0 7.0 0.0 int-step
  "OP4" "MODE"   "op4-mode"   Fm86Params.op4 DxOpP.mode + 0.0 switch  "RATIO" 0.0 opt  "FIXED" 1.0 opt
  "EG4" "R1" "op4-r1" Fm86Params.op4 DxOpP.r1 + 0.0 99.0 99.0 int-step
  "EG4" "R2" "op4-r2" Fm86Params.op4 DxOpP.r2 + 0.0 99.0 99.0 int-step
  "EG4" "R3" "op4-r3" Fm86Params.op4 DxOpP.r3 + 0.0 99.0 99.0 int-step
  "EG4" "R4" "op4-r4" Fm86Params.op4 DxOpP.r4 + 0.0 99.0 99.0 int-step
  "EG4" "L1" "op4-l1" Fm86Params.op4 DxOpP.l1 + 0.0 99.0 99.0 int-step
  "EG4" "L2" "op4-l2" Fm86Params.op4 DxOpP.l2 + 0.0 99.0 99.0 int-step
  "EG4" "L3" "op4-l3" Fm86Params.op4 DxOpP.l3 + 0.0 99.0 99.0 int-step
  "EG4" "L4" "op4-l4" Fm86Params.op4 DxOpP.l4 + 0.0 99.0 0.0 int-step
  "KS4" "BREAK" "op4-bp" Fm86Params.op4 DxOpP.bp + 0.0 99.0 39.0 int-step
  "KS4" "L DEP" "op4-ld" Fm86Params.op4 DxOpP.ld + 0.0 99.0 0.0 int-step
  "KS4" "R DEP" "op4-rd" Fm86Params.op4 DxOpP.rd + 0.0 99.0 0.0 int-step
  "KS4" "L CRV" "op4-lc" Fm86Params.op4 DxOpP.lc + 0.0 switch  "-LIN" 0.0 opt  "-EXP" 1.0 opt  "+EXP" 2.0 opt  "+LIN" 3.0 opt
  "KS4" "R CRV" "op4-rc" Fm86Params.op4 DxOpP.rc + 0.0 switch  "-LIN" 0.0 opt  "-EXP" 1.0 opt  "+EXP" 2.0 opt  "+LIN" 3.0 opt
  "KS4" "RATE" "op4-rs" Fm86Params.op4 DxOpP.rs + 0.0 7.0 0.0 int-step
  "SENS4" "VEL" "op4-kvs" Fm86Params.op4 DxOpP.kvs + 0.0 7.0 0.0 int-step
  "SENS4" "AMS" "op4-ams" Fm86Params.op4 DxOpP.ams + 0.0 3.0 0.0 int-step
  ( ── operator 5 ── )
  "OP5" "LEVEL"  "op5-ol"     Fm86Params.op5 DxOpP.ol +     0.0 99.0 0.0 int-step
  "OP5" "COARSE" "op5-coarse" Fm86Params.op5 DxOpP.coarse + 0.0 31.0 1.0 int-step
  "OP5" "FINE"   "op5-fine"   Fm86Params.op5 DxOpP.fine +   0.0 99.0 0.0 int-step
  "OP5" "DETUNE" "op5-det"    Fm86Params.op5 DxOpP.det +   -7.0 7.0 0.0 int-step
  "OP5" "MODE"   "op5-mode"   Fm86Params.op5 DxOpP.mode + 0.0 switch  "RATIO" 0.0 opt  "FIXED" 1.0 opt
  "EG5" "R1" "op5-r1" Fm86Params.op5 DxOpP.r1 + 0.0 99.0 99.0 int-step
  "EG5" "R2" "op5-r2" Fm86Params.op5 DxOpP.r2 + 0.0 99.0 99.0 int-step
  "EG5" "R3" "op5-r3" Fm86Params.op5 DxOpP.r3 + 0.0 99.0 99.0 int-step
  "EG5" "R4" "op5-r4" Fm86Params.op5 DxOpP.r4 + 0.0 99.0 99.0 int-step
  "EG5" "L1" "op5-l1" Fm86Params.op5 DxOpP.l1 + 0.0 99.0 99.0 int-step
  "EG5" "L2" "op5-l2" Fm86Params.op5 DxOpP.l2 + 0.0 99.0 99.0 int-step
  "EG5" "L3" "op5-l3" Fm86Params.op5 DxOpP.l3 + 0.0 99.0 99.0 int-step
  "EG5" "L4" "op5-l4" Fm86Params.op5 DxOpP.l4 + 0.0 99.0 0.0 int-step
  "KS5" "BREAK" "op5-bp" Fm86Params.op5 DxOpP.bp + 0.0 99.0 39.0 int-step
  "KS5" "L DEP" "op5-ld" Fm86Params.op5 DxOpP.ld + 0.0 99.0 0.0 int-step
  "KS5" "R DEP" "op5-rd" Fm86Params.op5 DxOpP.rd + 0.0 99.0 0.0 int-step
  "KS5" "L CRV" "op5-lc" Fm86Params.op5 DxOpP.lc + 0.0 switch  "-LIN" 0.0 opt  "-EXP" 1.0 opt  "+EXP" 2.0 opt  "+LIN" 3.0 opt
  "KS5" "R CRV" "op5-rc" Fm86Params.op5 DxOpP.rc + 0.0 switch  "-LIN" 0.0 opt  "-EXP" 1.0 opt  "+EXP" 2.0 opt  "+LIN" 3.0 opt
  "KS5" "RATE" "op5-rs" Fm86Params.op5 DxOpP.rs + 0.0 7.0 0.0 int-step
  "SENS5" "VEL" "op5-kvs" Fm86Params.op5 DxOpP.kvs + 0.0 7.0 0.0 int-step
  "SENS5" "AMS" "op5-ams" Fm86Params.op5 DxOpP.ams + 0.0 3.0 0.0 int-step
  ( ── operator 6 ── )
  "OP6" "LEVEL"  "op6-ol"     Fm86Params.op6 DxOpP.ol +     0.0 99.0 0.0 int-step
  "OP6" "COARSE" "op6-coarse" Fm86Params.op6 DxOpP.coarse + 0.0 31.0 1.0 int-step
  "OP6" "FINE"   "op6-fine"   Fm86Params.op6 DxOpP.fine +   0.0 99.0 0.0 int-step
  "OP6" "DETUNE" "op6-det"    Fm86Params.op6 DxOpP.det +   -7.0 7.0 0.0 int-step
  "OP6" "MODE"   "op6-mode"   Fm86Params.op6 DxOpP.mode + 0.0 switch  "RATIO" 0.0 opt  "FIXED" 1.0 opt
  "EG6" "R1" "op6-r1" Fm86Params.op6 DxOpP.r1 + 0.0 99.0 99.0 int-step
  "EG6" "R2" "op6-r2" Fm86Params.op6 DxOpP.r2 + 0.0 99.0 99.0 int-step
  "EG6" "R3" "op6-r3" Fm86Params.op6 DxOpP.r3 + 0.0 99.0 99.0 int-step
  "EG6" "R4" "op6-r4" Fm86Params.op6 DxOpP.r4 + 0.0 99.0 99.0 int-step
  "EG6" "L1" "op6-l1" Fm86Params.op6 DxOpP.l1 + 0.0 99.0 99.0 int-step
  "EG6" "L2" "op6-l2" Fm86Params.op6 DxOpP.l2 + 0.0 99.0 99.0 int-step
  "EG6" "L3" "op6-l3" Fm86Params.op6 DxOpP.l3 + 0.0 99.0 99.0 int-step
  "EG6" "L4" "op6-l4" Fm86Params.op6 DxOpP.l4 + 0.0 99.0 0.0 int-step
  "KS6" "BREAK" "op6-bp" Fm86Params.op6 DxOpP.bp + 0.0 99.0 39.0 int-step
  "KS6" "L DEP" "op6-ld" Fm86Params.op6 DxOpP.ld + 0.0 99.0 0.0 int-step
  "KS6" "R DEP" "op6-rd" Fm86Params.op6 DxOpP.rd + 0.0 99.0 0.0 int-step
  "KS6" "L CRV" "op6-lc" Fm86Params.op6 DxOpP.lc + 0.0 switch  "-LIN" 0.0 opt  "-EXP" 1.0 opt  "+EXP" 2.0 opt  "+LIN" 3.0 opt
  "KS6" "R CRV" "op6-rc" Fm86Params.op6 DxOpP.rc + 0.0 switch  "-LIN" 0.0 opt  "-EXP" 1.0 opt  "+EXP" 2.0 opt  "+LIN" 3.0 opt
  "KS6" "RATE" "op6-rs" Fm86Params.op6 DxOpP.rs + 0.0 7.0 0.0 int-step
  "SENS6" "VEL" "op6-kvs" Fm86Params.op6 DxOpP.kvs + 0.0 7.0 0.0 int-step
  "SENS6" "AMS" "op6-ams" Fm86Params.op6 DxOpP.ams + 0.0 3.0 0.0 int-step
  ( ── LFO and pitch EG ── )
  "LFO" "SPEED" "lfo-speed" Fm86Params.lfo-speed 0.0 99.0 35.0 int-step
  "LFO" "DELAY" "lfo-delay" Fm86Params.lfo-delay 0.0 99.0 0.0 int-step
  "LFO" "PMD"   "lfo-pmd"   Fm86Params.lfo-pmd   0.0 99.0 0.0 int-step
  "LFO" "AMD"   "lfo-amd"   Fm86Params.lfo-amd   0.0 99.0 0.0 int-step
  "LFO" "PMS"   "pms"       Fm86Params.pms       0.0 7.0 3.0 int-step
  "LFO" "SYNC"  "lfo-sync"  Fm86Params.lfo-sync 1.0 switch  "OFF" 0.0 opt  "ON" 1.0 opt
  "LFO" "WAVE"  "lfo-wave"  Fm86Params.lfo-wave 0.0 switch
    "TRI" 0.0 opt  "SAW-" 1.0 opt  "SAW+" 2.0 opt  "SQR" 3.0 opt  "SIN" 4.0 opt  "S/H" 5.0 opt
  "PEG" "R1" "pr1" Fm86Params.pr1 0.0 99.0 99.0 int-step
  "PEG" "R2" "pr2" Fm86Params.pr2 0.0 99.0 99.0 int-step
  "PEG" "R3" "pr3" Fm86Params.pr3 0.0 99.0 99.0 int-step
  "PEG" "R4" "pr4" Fm86Params.pr4 0.0 99.0 99.0 int-step
  "PEG" "L1" "pl1" Fm86Params.pl1 0.0 99.0 50.0 int-step
  "PEG" "L2" "pl2" Fm86Params.pl2 0.0 99.0 50.0 int-step
  "PEG" "L3" "pl3" Fm86Params.pl3 0.0 99.0 50.0 int-step
  "PEG" "L4" "pl4" Fm86Params.pl4 0.0 99.0 50.0 int-step

  ( ── strips ──────────────────────────────────────────────────────── )
  "GLOBAL" 5 strip
  "OP1" 5 strip  "EG1" 4 strip  "KS1" 3 strip  "SENS1" 2 strip
  "OP2" 5 strip  "EG2" 4 strip  "KS2" 3 strip  "SENS2" 2 strip
  "OP3" 5 strip  "EG3" 4 strip  "KS3" 3 strip  "SENS3" 2 strip
  "OP4" 5 strip  "EG4" 4 strip  "KS4" 3 strip  "SENS4" 2 strip
  "OP5" 5 strip  "EG5" 4 strip  "KS5" 3 strip  "SENS5" 2 strip
  "OP6" 5 strip  "EG6" 4 strip  "KS6" 3 strip  "SENS6" 2 strip
  "LFO" 4 strip  "PEG" 4 strip

  ( ── displays: the ALGO row of fm86-algo-table [6 ops, 48 f64 per row:
     matrix at 0, carriers at 36, feedback at 42] and each envelope ─── )
  "ROUTING" "algo" 6 48 0 36 42 algo-display
  "EG1 CURVE" "EG1" eg4-display
  "EG2 CURVE" "EG2" eg4-display
  "EG3 CURVE" "EG3" eg4-display
  "EG4 CURVE" "EG4" eg4-display
  "EG5 CURVE" "EG5" eg4-display
  "EG6 CURVE" "EG6" eg4-display
  "PEG CURVE" "PEG" eg4-display

  ( ── pages ── )
  "VOICE" page
    1.0 row  1.0 cell  "GLOBAL" 1.0 item  1.0 cell  "ROUTING" 1.0 item
    1.0 row  1.0 cell  "OP1" 1.0 item  1.0 cell  "OP2" 1.0 item  1.0 cell  "OP3" 1.0 item
    1.0 row  1.0 cell  "OP4" 1.0 item  1.0 cell  "OP5" 1.0 item  1.0 cell  "OP6" 1.0 item
  "OP 1" page
    1.0 row  1.0 cell  "EG1" 1.0 item  1.2 cell  "EG1 CURVE" 1.0 item
    1.0 row  1.0 cell  "KS1" 1.0 item  0.7 cell  "SENS1" 1.0 item
  "OP 2" page
    1.0 row  1.0 cell  "EG2" 1.0 item  1.2 cell  "EG2 CURVE" 1.0 item
    1.0 row  1.0 cell  "KS2" 1.0 item  0.7 cell  "SENS2" 1.0 item
  "OP 3" page
    1.0 row  1.0 cell  "EG3" 1.0 item  1.2 cell  "EG3 CURVE" 1.0 item
    1.0 row  1.0 cell  "KS3" 1.0 item  0.7 cell  "SENS3" 1.0 item
  "OP 4" page
    1.0 row  1.0 cell  "EG4" 1.0 item  1.2 cell  "EG4 CURVE" 1.0 item
    1.0 row  1.0 cell  "KS4" 1.0 item  0.7 cell  "SENS4" 1.0 item
  "OP 5" page
    1.0 row  1.0 cell  "EG5" 1.0 item  1.2 cell  "EG5 CURVE" 1.0 item
    1.0 row  1.0 cell  "KS5" 1.0 item  0.7 cell  "SENS5" 1.0 item
  "OP 6" page
    1.0 row  1.0 cell  "EG6" 1.0 item  1.2 cell  "EG6 CURVE" 1.0 item
    1.0 row  1.0 cell  "KS6" 1.0 item  0.7 cell  "SENS6" 1.0 item
  "MOD" page
    1.0 row  1.0 cell  "LFO" 1.0 item
    1.0 row  1.0 cell  "PEG" 1.0 item  1.2 cell  "PEG CURVE" 1.0 item

  machine-desc
;
