( fm86_voice.fy — the complete FM-86 (DX7) voice as ONE render word.

  The audio render path runs a single dsp2 word per sample (a pre-built JIT
  loop, FyRawMachine.renderVoiceSegment). The full voice is six per-operator
  envelopes plus the six-operator algorithm matrix — too deep for one word's
  32-register budget. So, exactly like the MS-20 voice
  (ms20_voice_probe.fy, k-ms20-voice-sample), it is composed from `call:`
  STAGES: each stage is a separate compiled word with a fresh register budget
  that hands off through state/params memory rather than the data stack.

  Layout trick: Fm86State's first 18 f64 are a Dx7VoiceState, and Fm86Params'
  first 39 are a Dx7VoiceParams, so the matrix stage is literally k-dx7-voice
  (no duplication). Each fm86-eg-opN advances one validated dx7-eg-step and
  writes gain*output-level into that operator's params `lvl` slot, which the
  matrix then reads. Both building blocks (dx7-eg-step, dx7-voice-step) are
  pinned sample-exact in the rig; this file only wires them. )

include "dx7_voice.fy"
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
  ( --- scratch --- )
  f64 gate                                   ( 1.0 held while the note is on )
;

ustruct: Fm86Params
  ( --- prefix: a Dx7VoiceParams --- )
  f64 inc0 f64 inc1 f64 inc2 f64 inc3 f64 inc4 f64 inc5   ( phase increments )
  f64 lvl0 f64 lvl1 f64 lvl2 f64 lvl3 f64 lvl4 f64 lvl5   ( env*outlevel, per sample )
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
  f64 note-hz f64 inv-sample-rate
;

( Per-operator EG stage: advance dx7-eg-step on op N's EG block (gate read
  from state scratch), scale by op N's output level, store into lvlN so the
  matrix reads the envelope-scaled level this sample. dx7-eg-step is inlined
  by name (it needs an f64 gate arg, which `call:` can't pass), but each of
  these words is itself a `call:` boundary, so one EG fits the budget. )
dsp2: fm86-eg-op0
  | state params |
  state Fm86State.eg0-value-p  params Fm86Params.eg0-s1-p  state Fm86State.gate@  dx7-eg-step
  params Fm86Params.ol0@ f*  params Fm86Params.lvl0-p f!64
  drop2
;
dsp2: fm86-eg-op1
  | state params |
  state Fm86State.eg1-value-p  params Fm86Params.eg1-s1-p  state Fm86State.gate@  dx7-eg-step
  params Fm86Params.ol1@ f*  params Fm86Params.lvl1-p f!64
  drop2
;
dsp2: fm86-eg-op2
  | state params |
  state Fm86State.eg2-value-p  params Fm86Params.eg2-s1-p  state Fm86State.gate@  dx7-eg-step
  params Fm86Params.ol2@ f*  params Fm86Params.lvl2-p f!64
  drop2
;
dsp2: fm86-eg-op3
  | state params |
  state Fm86State.eg3-value-p  params Fm86Params.eg3-s1-p  state Fm86State.gate@  dx7-eg-step
  params Fm86Params.ol3@ f*  params Fm86Params.lvl3-p f!64
  drop2
;
dsp2: fm86-eg-op4
  | state params |
  state Fm86State.eg4-value-p  params Fm86Params.eg4-s1-p  state Fm86State.gate@  dx7-eg-step
  params Fm86Params.ol4@ f*  params Fm86Params.lvl4-p f!64
  drop2
;
dsp2: fm86-eg-op5
  | state params |
  state Fm86State.eg5-value-p  params Fm86Params.eg5-s1-p  state Fm86State.gate@  dx7-eg-step
  params Fm86Params.ol5@ f*  params Fm86Params.lvl5-p f!64
  drop2
;

( out state params -- : one FM-86 voice sample. Six EG stages refresh the
  per-op levels, then the validated matrix sums the carriers. Each `call:` is
  a fresh register budget; the prefix-compatible layout lets k-dx7-voice read
  Fm86State/Fm86Params directly. )
dsp2: k-fm86-voice-sample
  | out state params |
  state params       call: fm86-eg-op0
  state params       call: fm86-eg-op1
  state params       call: fm86-eg-op2
  state params       call: fm86-eg-op3
  state params       call: fm86-eg-op4
  state params       call: fm86-eg-op5
  out state params   call: k-dx7-voice
;

( ── machine wiring: prepare / note / block-prepare ───────────────────── )

( stage -- stage' : idle-init guard. A freshly created (zeroed) voice has
  stage 0, which the EG would treat as "ramp toward L1" — a drone before any
  note. Map stage 0 -> 4 (idle, holding silent); once a note has played the
  stage is >=1 and this is the identity, so it is safe to run every block. )
dsp2: eg-idle-guard
  | s |
  s 0.5 4.0 s fsel-lt
  nip
;

( state params sample-rate -- : per-voice prepare (runs every block). Store
  1/sr for ratio->increment, and idle-init each operator envelope. )
dsp2: fm86-prepare
  | state params sample-rate |
  1.0 sample-rate f/ params Fm86Params.inv-sample-rate-p f!64
  state Fm86State.eg0-stage@ eg-idle-guard state Fm86State.eg0-stage-p f!64
  state Fm86State.eg1-stage@ eg-idle-guard state Fm86State.eg1-stage-p f!64
  state Fm86State.eg2-stage@ eg-idle-guard state Fm86State.eg2-stage-p f!64
  state Fm86State.eg3-stage@ eg-idle-guard state Fm86State.eg3-stage-p f!64
  state Fm86State.eg4-stage@ eg-idle-guard state Fm86State.eg4-stage-p f!64
  state Fm86State.eg5-stage@ eg-idle-guard state Fm86State.eg5-stage-p f!64
  drop2 drop
;

( state params hz velocity -- : start a note. Store the fundamental and set
  each operator's phase increment immediately (ratio * hz / sr) — note-on runs
  inside the block, after block-prepare has already filled increments from the
  *previous* note-hz, so the attack block would otherwise be silent (inc 0).
  Raise the gate and clear every envelope's prev-gate so the next sample sees a
  note-on edge (retrigger from current value, no click). Velocity is unused in
  Phase-1 — the MASTER knob sets level. )
dsp2: fm86-note-on
  | state params hz velocity |
  hz params Fm86Params.note-hz-p f!64
  hz params Fm86Params.inv-sample-rate@ f*   | base |
  params Fm86Params.ratio0@ base f* params Fm86Params.inc0-p f!64
  params Fm86Params.ratio1@ base f* params Fm86Params.inc1-p f!64
  params Fm86Params.ratio2@ base f* params Fm86Params.inc2-p f!64
  params Fm86Params.ratio3@ base f* params Fm86Params.inc3-p f!64
  params Fm86Params.ratio4@ base f* params Fm86Params.inc4-p f!64
  params Fm86Params.ratio5@ base f* params Fm86Params.inc5-p f!64
  1.0  state Fm86State.gate-p f!64
  0.0  state Fm86State.eg0-pgate-p f!64
  0.0  state Fm86State.eg1-pgate-p f!64
  0.0  state Fm86State.eg2-pgate-p f!64
  0.0  state Fm86State.eg3-pgate-p f!64
  0.0  state Fm86State.eg4-pgate-p f!64
  0.0  state Fm86State.eg5-pgate-p f!64
  drop2 drop2 drop
;

( state params -- : release. Drop the gate; the next sample's note-off edge
  sends every envelope to stage 4 (release toward L4). )
dsp2: fm86-note-off
  | state params |
  0.0 state Fm86State.gate-p f!64
  drop2
;

( params sample-rate -- : per-block fill. Each operator's phase increment is
  ratio * fundamental / sample-rate. Routing (w/c/fb) is filled host-side from
  the validated 32-algorithm table when ALGO changes. )
dsp2: fm86-block-prepare
  | params sample-rate |
  params Fm86Params.note-hz@ 1.0 sample-rate f/ f*   | base |
  params Fm86Params.ratio0@ base f* params Fm86Params.inc0-p f!64
  params Fm86Params.ratio1@ base f* params Fm86Params.inc1-p f!64
  params Fm86Params.ratio2@ base f* params Fm86Params.inc2-p f!64
  params Fm86Params.ratio3@ base f* params Fm86Params.inc3-p f!64
  params Fm86Params.ratio4@ base f* params Fm86Params.inc4-p f!64
  params Fm86Params.ratio5@ base f* params Fm86Params.inc5-p f!64
  drop2 drop
;
