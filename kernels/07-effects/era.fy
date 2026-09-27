( era.fy - a sample-era converter as an insert effect.

  in -> IN -> anti-alias LP -> clip -> sample & hold at RATE, quantized
     to BITS [MODE] -> reconstruction LP [FILTER, RES] -> DC block -> OUT, MIX

  The hold and quantizers are 09-digital/digital.fy.  Both filters are
  4-pole lowpasses, two TPT SVFs at Butterworth damping; RES pulls the
  second stage's damping down toward the resonant peak the SSM-type
  output filters had.  With AA off the input folds at RATE/2 - the
  SP-1200 grit.  AA on puts the corner at 0.45 RATE, a clean converter.

  The host runs the render once per channel against per-channel state
  and one shared params block; era-block-prepare derives the
  coefficients each block. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/math.fy"
include "../04-filters/coeffs.fy"
include "../04-filters/tpt_svf.fy"
include "../09-digital/digital.fy"

ustruct: EraState
  f64 aa1  f64 aa2  f64 aa3  f64 aa4   ( anti-alias SVF integrators )
  f64 rc1  f64 rc2  f64 rc3  f64 rc4   ( reconstruction SVF integrators )
  f64 dc-x1
  f64 dc-y1
  Zoh zoh
;

ustruct: EraParams
  ( user-facing )
  f64 in-db      ( -12..24 into the converter's full scale )
  f64 aa         ( 0 OFF / 1 ON )
  f64 rate       ( converter rate, Hz )
  f64 bits       ( 1..16, fractional allowed )
  f64 mode       ( 0 ROUND / 1 TRUNC / 2 MU-LAW )
  f64 filter-hz  ( reconstruction lowpass corner )
  f64 res        ( 0..1 )
  f64 mix        ( 0..1 )
  f64 out-db     ( -24..24 )
  ( derived - filled by era-block-prepare )
  f64 in-lin
  f64 out-lin
  f64 dt
  f64 step
  f64 aa-g
  f64 rc-g
  f64 rc-d
;

:: BW-D1 0.9238795325112867 ;   ( 4-pole Butterworth: 1 / 2Q per stage )
:: BW-D2 0.3826834323650898 ;

( ctx state params -- )
dsp: era-block-prepare | ctx:Ctx state params:EraParams -- |
  params.in-db db>lin -> params.in-lin
  params.out-db db>lin -> params.out-lin
  params.rate 200.0 ctx.sr fclamp ctx.sr f/ -> params.dt
  1.0 params.bits 1.0 16.0 fclamp f- exp2 -> params.step
  params.rate 0.45 f*  ctx.sr svf-g -> params.aa-g
  params.filter-hz ctx.sr svf-g -> params.rc-g
  BW-D2  1.0 params.res 0.0 1.0 fclamp 0.92 f* f-  f* -> params.rc-d
;

( io ctx state params -- : one converter sample. )
dsp: k-era-tick | out:Io ctx state:EraState params:EraParams -- |
  out.in-l | dry |
  dry params.in-lin f* | x |
  state.aa1& state.aa2& x params.aa-g BW-D1 tpt-svf-lp-step | a |
  state.aa3& state.aa4& a params.aa-g BW-D2 tpt-svf-lp-step | aa |
  params.aa 0.5  x  aa  fsel-lt  -1.0 1.0 fclamp | xin |
  state.zoh& xin params.dt params.step params.mode zoh-tick | h |
  state.rc1& state.rc2& h params.rc-g BW-D1 tpt-svf-lp-step | r |
  state.rc3& state.rc4& r params.rc-g params.rc-d tpt-svf-lp-step | y |
  ( DC blocker: the truncating modes sit half an LSB low )
  y state.dc-x1 f-  0.9995 state.dc-y1 f* f+ | dcy |
  y   -> state.dc-x1
  dcy -> state.dc-y1
  dcy params.out-lin f*  params.mix f*
  dry  1.0 params.mix f-  f*  f+
  out f!64
;
