( saturator.fy - the saturation box: five characters, 4x oversampled.

  in -> DRIVE -> up4 -> shape x4 -> dec4 -> DC block -> TONE -> OUT, MIX

  The curve is the parametric shaper in 02-shapers/shapers.fy; MODE picks
  its constants once per block:

    mode         bias  even  hard  knee  neg    character
    TUBE         0.25  0.15  1.0   1.0   1.0    asymmetric, even harmonics
    TAPE         0     0     1.0   0     1.0    soft algebraic shoulder
    XFMR         0.05  0.08  1.0   0.6   1.0    mild, fuller lows
    DIODE        0     0     2.0   1.0   0.45   hard knee, lopsided
    FUZZ         0.3   0.3   4.0   1.0   0.6    sulfur: square-ish, gated

  Oversampling keeps the harmonics of a hard drive from folding back as
  inharmonic grit; the DC blocker takes out what the asymmetric modes
  leave behind. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/math.fy"
include "../00-primitives/oversample.fy"
include "../02-shapers/shapers.fy"

ustruct: SatState
  f64 dc-x1   ( DC blocker previous input )
  f64 dc-y1   ( DC blocker previous output )
  f64 lp      ( tone lowpass state )
  Up4 up
  Dec4 dec
;

ustruct: SatParams
  ( user-facing )
  f64 drive-db   ( 0..36 )
  f64 mode       ( 0..4 switch )
  f64 tone-hz    ( tone lowpass cutoff )
  f64 mix        ( 0..1 )
  f64 out-db     ( -24..24 makeup )
  ( derived - filled by sat-block-prepare )
  f64 drive-lin
  f64 out-lin
  f64 tone-g
  Shape sh
;

( m a b c d e -- v : the mode's value of five. )
dsp: pick5 | m a b c d e -- v |
  m 0.5 a  m 1.5 b  m 2.5 c  m 3.5 d e  fsel-lt fsel-lt fsel-lt fsel-lt
;

( ctx state params -- : gains, tone coefficient, and the mode's curve.
  Heavier modes get a little less output so switching modes is fair. )
dsp: sat-block-prepare | ctx:Ctx state params:SatParams -- |
  params.drive-db db>lin -> params.drive-lin
  params.mode | m |
  params.out-db db>lin  m 0.7 1.0 1.0 1.2 1.0 pick5 f*  -> params.out-lin
  params.tone-hz 6.283185307179586 f* ctx.sr f/ 0.0 1.0 fclamp -> params.tone-g
  params.sh&
    m 0.25 0.0 0.05 0.0 0.3 pick5
    m 0.15 0.0 0.08 0.0 0.3 pick5
    m 1.0  1.0 1.0  2.0 4.0 pick5
    m 1.0  0.0 0.6  1.0 1.0 pick5
    m 1.0  1.0 1.0  0.45 0.6 pick5
  shape-set
;

( io ctx state params -- : one saturator sample. )
dsp: k-sat-tick | out:Io ctx state:SatState params:SatParams -- |
  out.in-l | dry |
  params.sh& | sh |
  state.up&  dry params.drive-lin f*  up4 | a b c d |
  state.dec&  a sh shape  b sh shape  c sh shape  d sh shape  dec4 | y |
  ( DC blocker: dcy = y - x1 + R*y1 )
  y state.dc-x1 f-  0.9995 state.dc-y1 f* f+ | dcy |
  y   -> state.dc-x1
  dcy -> state.dc-y1
  ( tone one-pole lowpass )
  state.lp  dcy state.lp f-  params.tone-g f*  f+ | toned |
  toned -> state.lp
  toned params.out-lin f*  params.mix f*
  dry  1.0 params.mix f-  f*  f+
  out f!64
;
