( dx7_eg.fy - DX7-style 4-rate / 4-level operator envelope.

  Unlike our ADSR kernels this is rate-based and stateful: the level lives in
  a dB-domain position `value` in 0..1 (1 = 0 dB, 0 = -96 dB). Each of the four
  segments ramps `value` LINEARLY toward its target level at a per-sample step,
  which is exponential in amplitude - the DX7 characteristic. Stages 1->2->3
  advance as each target is reached; stage 3 holds at L3 (sustain) until
  note-off, which jumps to stage 4 -> L4. A note-on edge restarts at stage 1
  from the current value (retrigger, no click). Branchless via fsel-lt.

  v1: the per-segment `step` values are supplied precomputed in params (the
  rate->time curve and key-scaling tables are phase 3); `rate-scale` multiplies
  every step (the key-rate-scaling hook). The output is the exponential gain. )

include "../00-primitives/pow2.fy"

ustruct: Dx7EgState
  f64 value        ( dB-domain envelope position, 0..1; 1 = 0 dB )
  f64 stage        ( 1..4 segment index )
  f64 prev-gate    ( previous gate, for edge detection )
;

ustruct: Dx7EgParams
  f64 step1 f64 step2 f64 step3 f64 step4   ( per-sample dB-domain increments )
  f64 l1 f64 l2 f64 l3 f64 l4               ( normalized segment targets 0..1 )
  f64 rate-scale                            ( key rate scaling, multiplies steps )
;

( state params gate -- gain : advance one sample, return exponential gain. )
dsp: dx7-eg-step
  | state params gate |
  state Dx7EgState.value@     | value |
  state Dx7EgState.stage@     | stage |
  state Dx7EgState.prev-gate@ | pgate |
  ( edges: note-on = gate>0.5 & prev<0.5 ; note-off = gate<0.5 & prev>0.5 )
  0.5 gate 1.0 0.0 fsel-lt   pgate 0.5 1.0 0.0 fsel-lt   f*   | onedge |
  gate 0.5 1.0 0.0 fsel-lt   0.5 pgate 1.0 0.0 fsel-lt   f*   | offedge |
  ( current segment after edges: off->4, else on->1, else hold )
  0.5 offedge 4.0   0.5 onedge 1.0 stage fsel-lt   fsel-lt   | stageb |
  ( target level for this segment )
  stageb 1.5 params Dx7EgParams.l1@
    stageb 2.5 params Dx7EgParams.l2@
      stageb 3.5 params Dx7EgParams.l3@ params Dx7EgParams.l4@ fsel-lt
    fsel-lt
  fsel-lt   | target |
  ( per-sample step for this segment, scaled )
  stageb 1.5 params Dx7EgParams.step1@
    stageb 2.5 params Dx7EgParams.step2@
      stageb 3.5 params Dx7EgParams.step3@ params Dx7EgParams.step4@ fsel-lt
    fsel-lt
  fsel-lt   params Dx7EgParams.rate-scale@ f*   | step |
  ( ramp value toward target by +-step; snap when within one step )
  target value f-   | diff |
  0.0 diff diff   0.0 diff f-   fsel-lt   | adiff |
  0.0 diff step   0.0 step f-   fsel-lt   | sstep |
  step adiff 0.0 1.0 fsel-lt   | reached |
  0.5 reached target   value sstep f+   fsel-lt   0.0 1.0 fclamp   | newval |
  ( advance stage when reached and stage < 3 (segments 1,2 only) )
  0.5   reached stageb 2.5 1.0 0.0 fsel-lt f*   stageb 1.0 f+   stageb   fsel-lt
  state Dx7EgState.stage-p f!64
  newval state Dx7EgState.value-p f!64
  gate state Dx7EgState.prev-gate-p f!64
  ( exponential gain: 2^((value-1)*16) -> 1.0 at 0 dB, ~1.5e-5 at -96 dB )
  newval 1.0 f- 16.0 f* exp2-approx
  nip nip nip nip nip nip nip nip nip nip nip nip nip nip nip nip
;

( out state params gate -- : raw probe entry, one envelope sample to out. )
dsp: k-dx7-eg
  | out state params gate |
  state params gate dx7-eg-step
  out f!64
  drop2 drop2
;
