( ms20_hpf.fy - lean self-oscillating 2-pole high-pass for the MS-20
  HPF -> LPF series.

  A classic Chamberlin state-variable filter, high-pass tap, with a soft
  clip on the bandpass state so high resonance self-oscillates without
  blowing up. Ear-tuned (no oracle): unlike the g-wet low-pass this has no
  Python reference, so it is judged by listening, per docs/14.

  Plain fy, inlined into the voice word [no fused Zig op needed].

  coeffs: f = 2*tan(pi*fc/fs) ~ 2*svf-g(fc, fs) ; q = svf-damping(res).
  per sample (state lp,bp):
    lp' = lp + f*bp
    hp  = in - lp' - q*bp
    bp' = clip(bp + f*hp)        ( clip bounds self-oscillation )

  The clip is 2.5 tanh[x/2.5]: unity slope, headroom over the ~0.6 the
  mixer delivers.  Bounded at 1 it squashed the ringing of any real
  input and PEAK did nothing. )

include "../02-shapers/rational.fy"   ( tanh-rational )

ustruct: HpfState
  f64 lp
  f64 bp
;

( state f q input -- hp : one Chamberlin SVF sample, high-pass output. )
dsp: k-hpf
  | st:HpfState f q v0 |
  st.lp
  | lp |
  st.bp
  | bp |
  lp f bp f* f+
  | lp2 |
  v0 lp2 f- q bp f* f-
  | hp |
  bp f hp f* f+
  0.4 f* tanh-rational 2.5 f*
  | bp2 |
  lp2 -> st.lp
  bp2 -> st.bp
  hp
;
