( fm86_voice.fy — the complete FM-86 (DX7) voice as ONE render word.

  The audio render path runs a single dsp word per sample (a pre-built JIT
  loop, FyRawMachine.renderVoiceSegment). k-fm86-voice-sample inlines the
  whole voice: six operators [fm-op-step], each with its own validated
  dx7-eg-step envelope, routed by the same upper-triangular matrix as
  dx7-voice-step [dx7_voice.fy]. Per-operator phase increments and
  envelope-scaled levels are values computed just before each operator
  runs; nothing hands off through memory. Measured in ReleaseFast this is
  ~40% cheaper than the old `call:` stages that passed inc/lvl through
  params scratch.

  Fm86Params starts with the routing block of a Dx7VoiceParams [fb, w, c;
  no inc/lvl], filled each block by fm86-derive [fm86_algo.fy]. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../01-oscillators/fm_operator.fy"
include "../03-envelopes/dx7_eg.fy"

ustruct: Fm86State
  ( --- prefix: a Dx7VoiceState (six operator phase accumulators) --- )
  f64 op0-phase f64 op0-fb1 f64 op0-fb2
  f64 op1-phase f64 op1-fb1 f64 op1-fb2
  f64 op2-phase f64 op2-fb1 f64 op2-fb2
  f64 op3-phase f64 op3-fb1 f64 op3-fb2
  f64 op4-phase f64 op4-fb1 f64 op4-fb2
  f64 op5-phase f64 op5-fb1 f64 op5-fb2
  ( --- six Dx7EgState blocks (value, stage, prev-gate) --- )
  f64 eg0-value f64 eg0-stage f64 eg0-pgate
  f64 eg1-value f64 eg1-stage f64 eg1-pgate
  f64 eg2-value f64 eg2-stage f64 eg2-pgate
  f64 eg3-value f64 eg3-stage f64 eg3-pgate
  f64 eg4-value f64 eg4-stage f64 eg4-pgate
  f64 eg5-value f64 eg5-stage f64 eg5-pgate
  ( --- per-voice note --- )
  f64 gate                                   ( 1.0 held while the note is on )
  f64 note-hz                                ( fundamental; per voice for polyphony )
;

ustruct: Fm86Params
  ( --- routing, filled by fm86-derive (Dx7VoiceParams minus inc/lvl) --- )
  f64 fb0  f64 fb1  f64 fb2  f64 fb3  f64 fb4  f64 fb5    ( per-op self feedback )
  f64 w01 f64 w02 f64 w03 f64 w04 f64 w05
  f64 w12 f64 w13 f64 w14 f64 w15
  f64 w23 f64 w24 f64 w25
  f64 w34 f64 w35
  f64 w45
  f64 c0 f64 c1 f64 c2 f64 c3 f64 c4 f64 c5
  ( --- six Dx7EgParams blocks (step1-4, l1-4, rate-scale) --- )
  f64 eg0-s1 f64 eg0-s2 f64 eg0-s3 f64 eg0-s4 f64 eg0-l1 f64 eg0-l2 f64 eg0-l3 f64 eg0-l4 f64 eg0-rs
  f64 eg1-s1 f64 eg1-s2 f64 eg1-s3 f64 eg1-s4 f64 eg1-l1 f64 eg1-l2 f64 eg1-l3 f64 eg1-l4 f64 eg1-rs
  f64 eg2-s1 f64 eg2-s2 f64 eg2-s3 f64 eg2-s4 f64 eg2-l1 f64 eg2-l2 f64 eg2-l3 f64 eg2-l4 f64 eg2-rs
  f64 eg3-s1 f64 eg3-s2 f64 eg3-s3 f64 eg3-s4 f64 eg3-l1 f64 eg3-l2 f64 eg3-l3 f64 eg3-l4 f64 eg3-rs
  f64 eg4-s1 f64 eg4-s2 f64 eg4-s3 f64 eg4-s4 f64 eg4-l1 f64 eg4-l2 f64 eg4-l3 f64 eg4-l4 f64 eg4-rs
  f64 eg5-s1 f64 eg5-s2 f64 eg5-s3 f64 eg5-s4 f64 eg5-l1 f64 eg5-l2 f64 eg5-l3 f64 eg5-l4 f64 eg5-rs
  ( --- per-operator output level (0..1) and frequency ratio --- )
  f64 ol0 f64 ol1 f64 ol2 f64 ol3 f64 ol4 f64 ol5
  f64 ratio0 f64 ratio1 f64 ratio2 f64 ratio3 f64 ratio4 f64 ratio5
  ( --- global / per-note --- )
  f64 algo f64 feedback f64 master
  f64 inv-sample-rate
;

( One operator's level this sample: advance its dx7-eg-step on its own EG
  block and scale the gain by the operator's output level. )
dsp: fm86-eg | eg egp gate ol -- lvl |
  eg egp gate dx7-eg-step ol f*
;

( One voice sample: the dx7-voice-step matrix with each operator's phase
  increment [ratio * note-hz / sr] and envelope-scaled level computed in
  place, just before the operator runs.  Operators evaluate high -> low, so
  each is modulated only by higher operators already computed; carriers
  sum into the output. )
dsp: fm86-voice-step | state:Fm86State params:Fm86Params -- out |
  state.gate | gate |
  state.note-hz params.inv-sample-rate f* | base |
  state.op5-phase&  params.ratio5 base f*
    0.0
    state.eg5-value& params.eg5-s1& gate params.ol5 fm86-eg
  params.fb5 fm-op-step | out5 |
  state.op4-phase&  params.ratio4 base f*
    params.w45 out5 f*
    state.eg4-value& params.eg4-s1& gate params.ol4 fm86-eg
  params.fb4 fm-op-step | out4 |
  state.op3-phase&  params.ratio3 base f*
    params.w34 out4 f* params.w35 out5 f* f+
    state.eg3-value& params.eg3-s1& gate params.ol3 fm86-eg
  params.fb3 fm-op-step | out3 |
  state.op2-phase&  params.ratio2 base f*
    params.w23 out3 f* params.w24 out4 f* f+ params.w25 out5 f* f+
    state.eg2-value& params.eg2-s1& gate params.ol2 fm86-eg
  params.fb2 fm-op-step | out2 |
  state.op1-phase&  params.ratio1 base f*
    params.w12 out2 f* params.w13 out3 f* f+ params.w14 out4 f* f+ params.w15 out5 f* f+
    state.eg1-value& params.eg1-s1& gate params.ol1 fm86-eg
  params.fb1 fm-op-step | out1 |
  state.op0-phase&  params.ratio0 base f*
    params.w01 out1 f* params.w02 out2 f* f+ params.w03 out3 f* f+ params.w04 out4 f* f+ params.w05 out5 f* f+
    state.eg0-value& params.eg0-s1& gate params.ol0 fm86-eg
  params.fb0 fm-op-step | out0 |
  params.c0 out0 f*
  params.c1 out1 f* f+
  params.c2 out2 f* f+
  params.c3 out3 f* f+
  params.c4 out4 f* f+
  params.c5 out5 f* f+
;

( io ctx state params -- : one FM-86 voice sample, ACCUMULATED into out.
  The host renders every voice into the same zeroed buffer, so voices must
  accumulate - a plain write would let the last/idle voice clobber the
  chord. )
dsp: k-fm86-voice-sample | io ctx state params -- |
  io f@64  state params fm86-voice-step  f+  io f!64
;

( ── machine wiring: prepare / note / block-prepare ───────────────────── )

( stage -- stage' : idle-init guard. A freshly created (zeroed) voice has
  stage 0, which the EG would treat as "ramp toward L1" — a drone before any
  note. Map stage 0 -> 4 (idle, holding silent); once a note has played the
  stage is >=1 and this is the identity, so it is safe to run every block. )
dsp: eg-idle-guard
  | s |
  s 0.5 4.0 s fsel-lt
;

( ctx state params -- : per-voice prepare (runs every block). Store
  1/sr for ratio->increment, and idle-init each operator envelope. )
dsp: fm86-prepare
  | ctx:Ctx state:Fm86State params:Fm86Params |
  ctx.sr | sample-rate |
  1.0 sample-rate f/ -> params.inv-sample-rate
  state.eg0-stage eg-idle-guard -> state.eg0-stage
  state.eg1-stage eg-idle-guard -> state.eg1-stage
  state.eg2-stage eg-idle-guard -> state.eg2-stage
  state.eg3-stage eg-idle-guard -> state.eg3-stage
  state.eg4-stage eg-idle-guard -> state.eg4-stage
  state.eg5-stage eg-idle-guard -> state.eg5-stage
;

( ctx state params -- : start a note. Store this voice's fundamental
  (per-voice, in state, so polyphony plays distinct pitches — the voice
  reads it each sample). Raise the gate and clear every envelope's prev-gate so
  the next sample sees a note-on edge (retrigger from current value, no click).
  Velocity is unused in Phase-1 — the MASTER knob sets level. )
dsp: fm86-note-on
  | ctx:Ctx state:Fm86State params |
  ctx.hz ctx.vel | hz velocity |
  hz   -> state.note-hz
  1.0  -> state.gate
  0.0  -> state.eg0-pgate
  0.0  -> state.eg1-pgate
  0.0  -> state.eg2-pgate
  0.0  -> state.eg3-pgate
  0.0  -> state.eg4-pgate
  0.0  -> state.eg5-pgate
;

( ctx state params -- : release. Drop the gate; the next sample's note-off edge
  sends every envelope to stage 4 (release toward L4). )
dsp: fm86-note-off
  | ctx state:Fm86State params |
  0.0 -> state.gate
;
