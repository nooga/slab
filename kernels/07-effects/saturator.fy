( saturator.fy - the saturation box: six characters, 4x oversampled.

  in -> DRIVE -> up4 -> shape x4 -> dec4 -> DC block -> TONE -> OUT, MIX
                  |                ^
                  +-> |x| -> heat -+  SAG: bias shift

  The curve is the parametric shaper in 02-shapers/shapers.fy; MODE picks
  its constants once per block:

    mode         bias  even  hard  knee  neg    character
    TUBE         0.25  0.15  1.0   1.0   1.0    asymmetric, even harmonics
    TAPE         0     0     1.0   0     1.0    soft algebraic shoulder
    XFMR         0.05  0.08  1.0   0.6   1.0    mild, fuller lows
    DIODE        0     0     2.0   1.0   0.45   hard knee, lopsided
    FUZZ         0.3   0.3   4.0   1.0   0.6    sulfur: square-ish, gated
    VALVE        the triode curve [shapers.fy]        hard top, soft bottom

  SAG is the valve's memory: the driven level, rectified and smoothed
  [20 ms up, 150 ms down, the grid charging its coupling cap fast and
  leaking slowly], moves the operating point down the curve.  A loud
  passage then plays lower on the curve - more asymmetric, thicker, and
  quieter [the sag] - and recovers over a few hundred ms after it.  The
  move is not renormalized; the DC blocker takes the offset it leaves.
  Each mode has its depth: FUZZ's starves the stage into gating and
  sputter, VALVE's [scaled by its 0.35 input] runs toward blocking. 

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
  f64 heat    ( SAG: the smoothed driven level )
  f64 d1  f64 d2  f64 d3  f64 d4  f64 d5   ( dry, delayed to meet the wet )
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
  f64 sag        ( 0..1 )
  ( derived - filled by sat-block-prepare )
  f64 drive-lin
  f64 out-lin
  f64 tone-g
  f64 heat-up    ( heat follower coefficients, per sample )
  f64 heat-down
  f64 sag-depth  ( SAG times the mode's depth, negative: down the curve )
  f64 lat        ( latency: the 4x halfband pair's, while any wet is mixed in )
  Shape sh
;

( m a b c d e f -- v : the mode's value of six. )
dsp: pick6 | m a b c d e f -- v |
  m 0.5 a  m 1.5 b  m 2.5 c  m 3.5 d  m 4.5 e f  fsel-lt fsel-lt fsel-lt fsel-lt fsel-lt
;

( tau sr -- k : one-pole coefficient for a time constant in seconds. )
dsp: sat-coef | tau sr -- k |  1.0  -1.0 tau sr f* f/ exp  f- ;

( ctx state params -- : gains, tone coefficient, and the mode's curve.
  Heavier modes get a little less output so switching modes is fair. )
dsp: sat-block-prepare | ctx:Ctx state params:SatParams -- |
  params.drive-db db>lin -> params.drive-lin
  params.mode | m |
  params.out-db db>lin  m 0.7 1.0 1.0 1.2 1.0 0.5 pick6 f*  -> params.out-lin
  params.tone-hz 6.283185307179586 f* ctx.sr f/ 0.0 1.0 fclamp -> params.tone-g
  0.020 ctx.sr sat-coef -> params.heat-up
  0.150 ctx.sr sat-coef -> params.heat-down
  params.sag  m 0.5 0.3 0.4 0.5 1.0 1.4 pick6 f*  -1.0 f* -> params.sag-depth
  0.0 params.mix  OS4-LATENCY 0.0  fsel-lt -> params.lat
  params.sh&
    m 0.25 0.0 0.05 0.0 0.3 -1.0 pick6
    m 0.15 0.0 0.08 0.0 0.3 0.0 pick6
    m 1.0  1.0 1.0  2.0 4.0 0.35 pick6
    m 1.0  0.0 0.6  1.0 1.0 1.0 pick6
    m 1.0  1.0 1.0  0.45 0.6 1.0 pick6
    m 0.0  0.0 0.0  0.0 0.0 1.0 pick6
  shape-set
;

( io ctx state params -- : one saturator sample. )
dsp: k-sat-tick | out:Io ctx state:SatState params:SatParams -- |
  out.in-l | dry |
  params.sh& | sh |
  dry params.drive-lin f* | x |
  ( SAG: follow the driven level, rising faster than it falls )
  x fabs | lvl |
  state.heat lvl  params.heat-up params.heat-down  fsel-lt | hk |
  state.heat  lvl state.heat f-  hk f*  f+ | heat |
  heat -> state.heat
  heat tanh-fast  params.sag-depth f* | off |
  0.0 off f+ sh shape-raw | y0 |
  state.up&  x  up4 | a b c d |
  state.dec&  a off y0 sh shape-at  b off y0 sh shape-at
              c off y0 sh shape-at  d off y0 sh shape-at  dec4 | y |
  ( DC blocker: dcy = y - x1 + R*y1 )
  y state.dc-x1 f-  0.9995 state.dc-y1 f* f+ | dcy |
  y   -> state.dc-x1
  dcy -> state.dc-y1
  ( tone one-pole lowpass )
  state.lp  dcy state.lp f-  params.tone-g f*  f+ | toned |
  toned -> state.lp
  ( the dry waits for the halfbands while any wet is mixed in )
  0.0 params.mix  state.d5  dry  fsel-lt | dly |
  state.d4 -> state.d5
  state.d3 -> state.d4
  state.d2 -> state.d3
  state.d1 -> state.d2
  dry -> state.d1
  toned params.out-lin f*  params.mix f*
  dly  1.0 params.mix f-  f*  f+
  out f!64
;
