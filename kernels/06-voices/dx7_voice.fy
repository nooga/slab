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
dsp: dx7-voice-step
  | state:Dx7VoiceState params:Dx7VoiceParams |
  ( op5: no modulators )
  state.op5-phase& params.inc5 0.0 params.lvl5 params.fb5 fm-op-step
  | out5 |
  ( op4: w45*out5 )
  state.op4-phase& params.inc4
    params.w45 out5 f*
  params.lvl4 params.fb4 fm-op-step
  | out4 |
  ( op3: w34*out4 + w35*out5 )
  state.op3-phase& params.inc3
    params.w34 out4 f* params.w35 out5 f* f+
  params.lvl3 params.fb3 fm-op-step
  | out3 |
  ( op2: w23*out3 + w24*out4 + w25*out5 )
  state.op2-phase& params.inc2
    params.w23 out3 f* params.w24 out4 f* f+ params.w25 out5 f* f+
  params.lvl2 params.fb2 fm-op-step
  | out2 |
  ( op1: w12*out2 + w13*out3 + w14*out4 + w15*out5 )
  state.op1-phase& params.inc1
    params.w12 out2 f* params.w13 out3 f* f+ params.w14 out4 f* f+ params.w15 out5 f* f+
  params.lvl1 params.fb1 fm-op-step
  | out1 |
  ( op0: w01*out1 + w02*out2 + w03*out3 + w04*out4 + w05*out5 )
  state.op0-phase& params.inc0
    params.w01 out1 f* params.w02 out2 f* f+ params.w03 out3 f* f+ params.w04 out4 f* f+ params.w05 out5 f* f+
  params.lvl0 params.fb0 fm-op-step
  | out0 |
  ( voice output = sum of carriers )
  params.c0 out0 f*
  params.c1 out1 f* f+
  params.c2 out2 f* f+
  params.c3 out3 f* f+
  params.c4 out4 f* f+
  params.c5 out5 f* f+
  ( out on top; drop the 8 named slots )
;

( out state params -- : raw probe entry, one voice sample to out. )
dsp: k-dx7-voice
  | out state params |
  state params dx7-voice-step
  out f!64
;
