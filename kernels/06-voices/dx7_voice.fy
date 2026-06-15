( dx7_voice.fy - a 6-operator DX7 voice: the algorithm matrix.

  Data-driven so one kernel covers all 32 DX7 algorithms. Operators are
  indexed 0..5 and evaluated high->low (5 first), so an operator is only ever
  modulated by higher-indexed operators already computed this sample. Routing
  is an upper-triangular weight matrix w_ij (operator j modulates operator i,
  j>i); per-operator feedback handles the single self-loop; carrier flags
  select which operator outputs sum to the voice output. The host fills these
  params from the 32-algorithm table + the patch (ratios->inc, env*outlevel->
  level). Each operator is the validated fm-op-step. )

include "../01-oscillators/fm_operator.fy"

ustruct: Dx7VoiceState
  f64 op0-phase f64 op0-fb1 f64 op0-fb2
  f64 op1-phase f64 op1-fb1 f64 op1-fb2
  f64 op2-phase f64 op2-fb1 f64 op2-fb2
  f64 op3-phase f64 op3-fb1 f64 op3-fb2
  f64 op4-phase f64 op4-fb1 f64 op4-fb2
  f64 op5-phase f64 op5-fb1 f64 op5-fb2
;

ustruct: Dx7VoiceParams
  f64 inc0 f64 inc1 f64 inc2 f64 inc3 f64 inc4 f64 inc5   ( phase increments )
  f64 lvl0 f64 lvl1 f64 lvl2 f64 lvl3 f64 lvl4 f64 lvl5   ( env * output level )
  f64 fb0  f64 fb1  f64 fb2  f64 fb3  f64 fb4  f64 fb5    ( per-op self feedback )
  f64 w01 f64 w02 f64 w03 f64 w04 f64 w05                 ( upper-tri routing )
  f64 w12 f64 w13 f64 w14 f64 w15
  f64 w23 f64 w24 f64 w25
  f64 w34 f64 w35
  f64 w45
  f64 c0 f64 c1 f64 c2 f64 c3 f64 c4 f64 c5               ( carrier sum weights )
;

( state params -- out : one voice sample. Each op modulated only by higher
  ops already computed; carriers summed. )
dsp2: dx7-voice-step
  | state params |
  ( op5: no modulators )
  state Dx7VoiceState.op5-phase-p params Dx7VoiceParams.inc5@ 0.0 params Dx7VoiceParams.lvl5@ params Dx7VoiceParams.fb5@ fm-op-step
  | out5 |
  ( op4: w45*out5 )
  state Dx7VoiceState.op4-phase-p params Dx7VoiceParams.inc4@
    params Dx7VoiceParams.w45@ out5 f*
  params Dx7VoiceParams.lvl4@ params Dx7VoiceParams.fb4@ fm-op-step
  | out4 |
  ( op3: w34*out4 + w35*out5 )
  state Dx7VoiceState.op3-phase-p params Dx7VoiceParams.inc3@
    params Dx7VoiceParams.w34@ out4 f* params Dx7VoiceParams.w35@ out5 f* f+
  params Dx7VoiceParams.lvl3@ params Dx7VoiceParams.fb3@ fm-op-step
  | out3 |
  ( op2: w23*out3 + w24*out4 + w25*out5 )
  state Dx7VoiceState.op2-phase-p params Dx7VoiceParams.inc2@
    params Dx7VoiceParams.w23@ out3 f* params Dx7VoiceParams.w24@ out4 f* f+ params Dx7VoiceParams.w25@ out5 f* f+
  params Dx7VoiceParams.lvl2@ params Dx7VoiceParams.fb2@ fm-op-step
  | out2 |
  ( op1: w12*out2 + w13*out3 + w14*out4 + w15*out5 )
  state Dx7VoiceState.op1-phase-p params Dx7VoiceParams.inc1@
    params Dx7VoiceParams.w12@ out2 f* params Dx7VoiceParams.w13@ out3 f* f+ params Dx7VoiceParams.w14@ out4 f* f+ params Dx7VoiceParams.w15@ out5 f* f+
  params Dx7VoiceParams.lvl1@ params Dx7VoiceParams.fb1@ fm-op-step
  | out1 |
  ( op0: w01*out1 + w02*out2 + w03*out3 + w04*out4 + w05*out5 )
  state Dx7VoiceState.op0-phase-p params Dx7VoiceParams.inc0@
    params Dx7VoiceParams.w01@ out1 f* params Dx7VoiceParams.w02@ out2 f* f+ params Dx7VoiceParams.w03@ out3 f* f+ params Dx7VoiceParams.w04@ out4 f* f+ params Dx7VoiceParams.w05@ out5 f* f+
  params Dx7VoiceParams.lvl0@ params Dx7VoiceParams.fb0@ fm-op-step
  | out0 |
  ( voice output = sum of carriers )
  params Dx7VoiceParams.c0@ out0 f*
  params Dx7VoiceParams.c1@ out1 f* f+
  params Dx7VoiceParams.c2@ out2 f* f+
  params Dx7VoiceParams.c3@ out3 f* f+
  params Dx7VoiceParams.c4@ out4 f* f+
  params Dx7VoiceParams.c5@ out5 f* f+
  ( out on top; drop the 8 named slots )
  nip nip nip nip nip nip nip nip
;

( out state params -- : raw probe entry, one voice sample to out. )
dsp2: k-dx7-voice
  | out state params |
  state params dx7-voice-step
  out f!64
  drop2 drop
;
