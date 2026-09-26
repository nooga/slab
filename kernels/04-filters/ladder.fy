( ladder.fy - clean linear ZDF / TPT 4-pole lowpass ladder.

  The Roland-ish voice filter: a zero-delay-feedback cascade of four
  one-pole TPT lowpasses with a global resonance feedback, solved
  implicitly each sample (no unit-delay in the loop). Unlike the MS-20
  nonlinear MS-20 filter [ms20_ota.fy] this one is LINEAR - no internal
  saturation - so cutoff sweeps are perfectly smooth and there is no
  aliasing. Resonance runs up to just under self-oscillation; it stays
  stable because the feedback k is capped below 4 (the linear ladder's
  oscillation threshold).

  Per sample, with g = tan(pi*fc/sr), G = g/(1+g):
    Si    = si / (1+g)                         (state contribution / stage)
    Sigma = G^3*S1 + G^2*S2 + G*S3 + S4
    y4    = (G^4*u + Sigma) / (1 + k*G^4)      (implicit feedback solve)
    x0    = u - k*y4                           (filter input after feedback)
    then a forward TPT pass through the four stages updates s1..s4 and
    reproduces y4. Reference: Zavalishin, "The Art of VA Filter Design".

  g is supplied by the caller (svf-g gives the tiny-angle tan); k is the
  resonance feedback. Both the rig probe [k-ladder4] and the Juno VCF
  inline ladder4-core, so authoring and the DAW share one filter. )

include "../00-primitives/math.fy"   ( tanh-fast for ladder4-sat )

ustruct: LadderState
  f64 s1
  f64 s2
  f64 s3
  f64 s4
;

( lstate input g k -- y : one linear ZDF 4-pole ladder sample. lstate
  points at four contiguous f64 integrator cells. Leaves y on the stack
  for inlining. )
dsp: ladder4-core
  | lstate:LadderState input g k |
  1.0 g f+ | d |
  g d f/ | G |
  G G f* | G2 |
  G2 G f* | G3 |
  G3 G f* | G4 |
  1.0 d f/ | id |
  lstate.s1 id f* | S1 |
  lstate.s2 id f* | S2 |
  lstate.s3 id f* | S3 |
  lstate.s4 id f* | S4 |
  G3 S1 f* G2 S2 f* f+ G S3 f* f+ S4 f+ | sig |
  G4 input f* sig f+ 1.0 k G4 f* f+ f/ | y4 |
  input k y4 f* f- | x0 |
  ( forward TPT pass, updating s1..s4 )
  x0 lstate.s1 f- G f* | v1 |
  v1 lstate.s1 f+ | y1 |
  y1 v1 f+ -> lstate.s1
  y1 lstate.s2 f- G f* | v2 |
  v2 lstate.s2 f+ | y2 |
  y2 v2 f+ -> lstate.s2
  y2 lstate.s3 f- G f* | v3 |
  v3 lstate.s3 f+ | y3 |
  y3 v3 f+ -> lstate.s3
  y3 lstate.s4 f- G f* | v4 |
  v4 lstate.s4 f+ | y4f |
  y4f v4 f+ -> lstate.s4
  y4f
;

( out lstate input g k -- : probe/raw entry - write one ladder sample. )
dsp: k-ladder4
  | out lstate input g k |
  lstate input g k ladder4-core
  out f!64
;

( lstate input g k drive -- y : the same ladder with the input
  differential pair modelled - the feedback-summed input goes through
  tanh[drive x]/drive before the stages.  Small signals pass unchanged;
  resonance compresses instead of running away, so k may pass 4 and the
  filter self-oscillates at a level set by drive, the IR3109 way.  The
  implicit solve still assumes the linear loop, then the forward pass
  uses the saturated input: one tanh per sample, no oversampling. )
dsp: ladder4-sat
  | lstate:LadderState input g k drive |
  1.0 g f+ | d |
  g d f/ | G |
  G G f* | G2 |
  G2 G f* | G3 |
  G3 G f* | G4 |
  1.0 d f/ | id |
  lstate.s1 id f* | S1 |
  lstate.s2 id f* | S2 |
  lstate.s3 id f* | S3 |
  lstate.s4 id f* | S4 |
  G3 S1 f* G2 S2 f* f+ G S3 f* f+ S4 f+ | sig |
  G4 input f* sig f+ 1.0 k G4 f* f+ f/ | y4 |
  input k y4 f* f-  drive f* tanh-fast  drive f/ | x0 |
  x0 lstate.s1 f- G f* | v1 |
  v1 lstate.s1 f+ | y1 |
  y1 v1 f+ -> lstate.s1
  y1 lstate.s2 f- G f* | v2 |
  v2 lstate.s2 f+ | y2 |
  y2 v2 f+ -> lstate.s2
  y2 lstate.s3 f- G f* | v3 |
  v3 lstate.s3 f+ | y3 |
  y3 v3 f+ -> lstate.s3
  y3 lstate.s4 f- G f* | v4 |
  v4 lstate.s4 f+ | y4f |
  y4f v4 f+ -> lstate.s4
  y4f
;
