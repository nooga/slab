( eq.fy - 5-band parametric mixing EQ from RBJ-cookbook biquads.

  Stages, in series: high-pass (12 dB, Q~0.7, switchable) -> low shelf
  -> low-mid peak -> high-mid peak -> high shelf.  Each stage is one
  biquad run as a transposed Direct-Form-II sample (two state cells,
  z1/z2), which is the numerically friendly form for time-varying
  coefficients.  The DAW and the rig share this one kernel.

  Coefficients are computed per block in fy from the raw controls, with
  no libm: sin/cos come from kernels/00-primitives/trig.fy (range-reduced
  Taylor) and A = 10^(dB/40) from exp2-approx (kernels/00-primitives/
  pow2.fy).  Because each band's coefficient math is heavy (two
  transcendentals + several products) the five bands are split into
  separate `call:` stages so each gets a fresh 32-register budget - the
  same discipline that fixed the FM-86 matrix.  `call:` can only pass
  pointer args, so the coefficient fill lives in the `derive` hook
  (params derive-data --, all pointers); the sample-rate it needs is
  stashed into params by eq-block-prepare, which the host runs right
  after derive every block (sr is constant, so derive reads the value
  block-prepare wrote last time - correct from the first audio block on).

  Per stage, transposed DF2 with a0 normalized out in the coeff fill:
    y   = b0*x + z1
    z1' = b1*x - a1*y + z2
    z2' = b2*x - a2*y

  Probe case: eq-render - a known curve over an impulse/sweep, peak/rms
  and a non-finite count. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/pow2.fy"
include "../00-primitives/trig.fy"

( five biquads' z-state. )
ustruct: EqState
  f64 hpf-z1  f64 hpf-z2
  f64 ls-z1   f64 ls-z2
  f64 p1-z1   f64 p1-z2
  f64 p2-z1   f64 p2-z2
  f64 hs-z1   f64 hs-z2
;

ustruct: EqParams
  ( user-facing )
  f64 hpf-hz  f64 hpf-on
  f64 ls-hz   f64 ls-db
  f64 p1-hz   f64 p1-db  f64 p1-q
  f64 p2-hz   f64 p2-db  f64 p2-q
  f64 hs-hz   f64 hs-db
  ( stashed by eq-block-prepare for the derive stages )
  f64 sr
  ( derived coeffs: 5 stages x {b0,b1,b2,a1,a2}, a0 normalized to 1 )
  f64 hpf-b0  f64 hpf-b1  f64 hpf-b2  f64 hpf-a1  f64 hpf-a2
  f64 ls-b0   f64 ls-b1   f64 ls-b2   f64 ls-a1   f64 ls-a2
  f64 p1-b0   f64 p1-b1   f64 p1-b2   f64 p1-a1   f64 p1-a2
  f64 p2-b0   f64 p2-b1   f64 p2-b2   f64 p2-a1   f64 p2-a2
  f64 hs-b0   f64 hs-b1   f64 hs-b2   f64 hs-a1   f64 hs-a2
;

( ---- coefficient fill (one band per call: stage, fresh budget) ------ )

( params -- : high-pass, RBJ, fixed Q=1/sqrt2.  When hpf-on < 0.5 the
  stage is forced to passthrough (b0=1, rest 0) with a per-coeff fsel so
  the audio path never branches. )
dsp: eq-coef-hpf
  | params:EqParams |
  params.hpf-hz 10.0 20000.0 fclamp 6.283185307179586 f*
  params.sr f/ 0.0 3.0 fclamp | w |
  w cos-approx | cw |
  w sin-approx 0.7071067811865476 f* | alpha |   ( sw/(2Q), Q=1/sqrt2 )
  1.0 alpha f+ | a0 |
  1.0 a0 f/ | inv |
  1.0 cw f+ | omc |                              ( 1 + cos w )
  params.hpf-on | on |
  ( b0 = (1+cw)/2 * inv, else 1 )
  0.5 on  omc 0.5 f* inv f*  1.0  fsel-lt -> params.hpf-b0
  ( b1 = -(1+cw) * inv, else 0 )
  0.5 on  0.0 omc f- inv f*  0.0  fsel-lt -> params.hpf-b1
  ( b2 = (1+cw)/2 * inv, else 0 )
  0.5 on  omc 0.5 f* inv f*  0.0  fsel-lt -> params.hpf-b2
  ( a1 = -2 cw * inv, else 0 )
  0.5 on  -2.0 cw f* inv f*  0.0  fsel-lt -> params.hpf-a1
  ( a2 = (1-alpha) * inv, else 0 )
  0.5 on  1.0 alpha f- inv f*  0.0  fsel-lt -> params.hpf-a2
  ( locals: params w cw alpha a0 inv omc on = 8 )
;

( params -- : peaking EQ for band 1 (low-mid). )
dsp: eq-coef-p1
  | params:EqParams |
  params.p1-hz 10.0 20000.0 fclamp 6.283185307179586 f*
  params.sr f/ 0.0 3.0 fclamp | w |
  w cos-approx | cw |
  params.p1-db 0.08304820237218405 f* exp2-approx | a |
  w sin-approx  params.p1-q 0.05 24.0 fclamp 2.0 f* f/ | alpha |
  1.0 alpha a f/ f+ | a0 |
  1.0 a0 f/ | inv |
  1.0 alpha a f* f+ inv f* -> params.p1-b0
  -2.0 cw f* inv f* -> params.p1-b1
  1.0 alpha a f* f- inv f* -> params.p1-b2
  -2.0 cw f* inv f* -> params.p1-a1
  1.0 alpha a f/ f- inv f* -> params.p1-a2
  ( locals: params w cw a alpha a0 inv = 7 )
;

( params -- : peaking EQ for band 2 (high-mid). )
dsp: eq-coef-p2
  | params:EqParams |
  params.p2-hz 10.0 20000.0 fclamp 6.283185307179586 f*
  params.sr f/ 0.0 3.0 fclamp | w |
  w cos-approx | cw |
  params.p2-db 0.08304820237218405 f* exp2-approx | a |
  w sin-approx  params.p2-q 0.05 24.0 fclamp 2.0 f* f/ | alpha |
  1.0 alpha a f/ f+ | a0 |
  1.0 a0 f/ | inv |
  1.0 alpha a f* f+ inv f* -> params.p2-b0
  -2.0 cw f* inv f* -> params.p2-b1
  1.0 alpha a f* f- inv f* -> params.p2-b2
  -2.0 cw f* inv f* -> params.p2-a1
  1.0 alpha a f/ f- inv f* -> params.p2-a2
  ( locals: params w cw a alpha a0 inv = 7 )
;

( params -- : low shelf, RBJ, slope S=1 so the shelf alpha term reduces
  to 2*sqrt(A)*alpha = sqrt(A)*sw*sqrt(2). )
dsp: eq-coef-ls
  | params:EqParams |
  params.ls-hz 10.0 20000.0 fclamp 6.283185307179586 f*
  params.sr f/ 0.0 3.0 fclamp | w |
  w cos-approx | cw |
  params.ls-db 0.08304820237218405 f* exp2-approx | a |
  params.ls-db 0.04152410118609203 f* exp2-approx | sqa |
  w sin-approx sqa f* 1.4142135623730951 f* | beta |   ( 2*sqrt(A)*alpha )
  a 1.0 f+ | ap1 |
  a 1.0 f- | am1 |
  ( a0 = ap1 + am1*cw + beta )
  ap1 am1 cw f* f+ beta f+ | a0 |
  1.0 a0 f/ | inv |
  a  ap1 am1 cw f* f- beta f+  f* inv f* -> params.ls-b0
  2.0 a f*  am1 ap1 cw f* f-  f* inv f* -> params.ls-b1
  a  ap1 am1 cw f* f- beta f-  f* inv f* -> params.ls-b2
  -2.0  am1 ap1 cw f* f+  f* inv f* -> params.ls-a1
  ap1 am1 cw f* f+ beta f-  inv f* -> params.ls-a2
  ( locals: params w cw a sqa beta ap1 am1 a0 inv = 10 )
;

( params -- : high shelf, RBJ, slope S=1. )
dsp: eq-coef-hs
  | params:EqParams |
  params.hs-hz 10.0 20000.0 fclamp 6.283185307179586 f*
  params.sr f/ 0.0 3.0 fclamp | w |
  w cos-approx | cw |
  params.hs-db 0.08304820237218405 f* exp2-approx | a |
  params.hs-db 0.04152410118609203 f* exp2-approx | sqa |
  w sin-approx sqa f* 1.4142135623730951 f* | beta |
  a 1.0 f+ | ap1 |
  a 1.0 f- | am1 |
  ( a0 = ap1 - am1*cw + beta )
  ap1 am1 cw f* f- beta f+ | a0 |
  1.0 a0 f/ | inv |
  a  ap1 am1 cw f* f+ beta f+  f* inv f* -> params.hs-b0
  -2.0 a f*  am1 ap1 cw f* f+  f* inv f* -> params.hs-b1
  a  ap1 am1 cw f* f+ beta f-  f* inv f* -> params.hs-b2
  2.0  am1 ap1 cw f* f-  f* inv f* -> params.hs-a1
  ap1 am1 cw f* f- beta f-  inv f* -> params.hs-a2
  ( locals: params w cw a sqa beta ap1 am1 a0 inv = 10 )
;

( ctx state params -- : fill every band's coefficients.  derive-data is
  unused; each stage gets its own register budget. )
dsp: eq-derive | ctx state params -- |
  params eq-coef-hpf
  params eq-coef-ls
  params eq-coef-p1
  params eq-coef-p2
  params eq-coef-hs
;

( ctx state params -- : stash sr for the derive stages.  No coefficient
  math here - derive owns that. )
dsp: eq-block-prepare
  | ctx:Ctx state params:EqParams |
  ctx.sr | sr |
  sr -> params.sr
;

( ---- per-sample biquad stages ---------------------------------------- )

( High-pass. )
dsp: eq-tick-hpf | state:EqState params:EqParams x -- y |
  params.hpf-b0 x f* state.hpf-z1 f+ | y |
  params.hpf-b1 x f*  params.hpf-a1 y f* f-  state.hpf-z2 f+
  -> state.hpf-z1
  params.hpf-b2 x f*  params.hpf-a2 y f* f-
  -> state.hpf-z2
  y
;

( Low shelf. )
dsp: eq-tick-ls | state:EqState params:EqParams x -- y |
  params.ls-b0 x f* state.ls-z1 f+ | y |
  params.ls-b1 x f*  params.ls-a1 y f* f-  state.ls-z2 f+
  -> state.ls-z1
  params.ls-b2 x f*  params.ls-a2 y f* f-
  -> state.ls-z2
  y
;

( Low-mid peak. )
dsp: eq-tick-p1 | state:EqState params:EqParams x -- y |
  params.p1-b0 x f* state.p1-z1 f+ | y |
  params.p1-b1 x f*  params.p1-a1 y f* f-  state.p1-z2 f+
  -> state.p1-z1
  params.p1-b2 x f*  params.p1-a2 y f* f-
  -> state.p1-z2
  y
;

( High-mid peak. )
dsp: eq-tick-p2 | state:EqState params:EqParams x -- y |
  params.p2-b0 x f* state.p2-z1 f+ | y |
  params.p2-b1 x f*  params.p2-a1 y f* f-  state.p2-z2 f+
  -> state.p2-z1
  params.p2-b2 x f*  params.p2-a2 y f* f-
  -> state.p2-z2
  y
;

( High shelf. )
dsp: eq-tick-hs | state:EqState params:EqParams x -- y |
  params.hs-b0 x f* state.hs-z1 f+ | y |
  params.hs-b1 x f*  params.hs-a1 y f* f-  state.hs-z2 f+
  -> state.hs-z1
  params.hs-b2 x f*  params.hs-a2 y f* f-
  -> state.hs-z2
  y
;

( io ctx state params -- : the full EQ tick, five biquads in series. )
dsp: k-eq-tick | io:Io ctx state params -- |
  state params
  state params
  state params
  state params
  state params io.in-l eq-tick-hpf
  eq-tick-ls eq-tick-p1 eq-tick-p2 eq-tick-hs
  io f!64
;
