( saturator.fy - the saturation box: eight characters, 4x oversampled.

  in -> PRE -> DRIVE -> up4 -> shape x4 -> dec4 -> POST -> DC -> TONE -> OUT
                         |                ^                      MIX with dry
                         +-> |x| -> heat -+  SAG: bias shift

  The curve is the parametric shaper in 02-shapers/shapers.fy; MODE picks
  its constants once per block:

    mode    bias  even  hard  knee  neg   extra      character
    TUBE    0.25  0.15  1.0   1.0   1.0              asymmetric, even harmonics
    TAPE    0     0     1.0   0     1.0              soft algebraic shoulder
    XFMR    0.05  0.08  1.0   0.6   1.0              mild, fuller lows
    DIODE   0     0     2.0   1.0   0.45             hard knee, lopsided
    FUZZ    0.3   0.3   4.0   1.0   0.6              sulfur: square-ish, gated
    VALVE   -1.0              0.35 in  valve 1       the triode: hard top,
                                                     soft bottom
    RAIL    0.03  0     3.0   1.0   1.0   clip 0.22  tanh stage into the rails
    FOLD    0.1   0     1.0               fold 1     sine folder, buzz

  PRE and POST are the filtering around the nonlinearity, which is where
  most of each type's sound lives [a low shelf, a high shelf and a bell
  before; the shelves, a bell and a lowpass after].  COLOR scales them
  all, in dB; at 0 the box is wide band.  At COLOR 1:

    mode    pre                        post                      why
    TUBE    lows -4 dB < 150 Hz        lows +3, LP 12 k          cathode bypass, Miller
    TAPE    highs +8 dB > 3 kHz        highs -8, bump +3 @ 70,   pre/de-emphasis: highs
                                       LP 15 k                   saturate first; head bump
    XFMR    lows +10 dB < 180 Hz       lows -10, LP 16 k         flux: lows saturate first
    DIODE   lows -12 < 700, +4 @ 900   lows +6, LP 5 k           the Screamer's mid push
    FUZZ    -                          scoop -10 @ 900, LP 7 k   the Muff's tone stack
    VALVE   lows -6 dB < 250 Hz        lows +3, LP 9 k           coupling caps, Miller
    RAIL    lows -12 < 300, +6 @ 800   lows +6, scoop -8 @ 700,  tight high gain
                                       LP 7 k
    FOLD    -                          LP 14 k

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
include "../04-filters/tone.fy"   ( Pole, Shelf, Bell )

ustruct: SatState
  f64 dc-x1   ( DC blocker previous input )
  f64 dc-y1   ( DC blocker previous output )
  f64 lp      ( tone lowpass state )
  f64 heat    ( SAG: the smoothed driven level )
  f64 d1  f64 d2  f64 d3  f64 d4  f64 d5   ( dry, delayed to meet the wet )
  Pole pre-lo  Pole pre-hi  BellSt pre-bell
  Pole post-lo  Pole post-hi  BellSt post-bell  Pole post-lp
  Up4 up
  Dec4 dec
;

ustruct: SatParams
  ( user-facing )
  f64 drive-db   ( 0..48 )
  f64 mode       ( 0..7 switch )
  f64 tone-hz    ( tone lowpass cutoff )
  f64 mix        ( 0..1 )
  f64 out-db     ( -24..24 makeup )
  f64 sag        ( 0..1 )
  f64 color      ( 0..1: the mode's filtering )
  ( derived - filled by sat-block-prepare )
  f64 drive-lin
  f64 out-lin
  f64 tone-g
  f64 heat-up    ( heat follower coefficients, per sample )
  f64 heat-down
  f64 sag-depth  ( SAG times the mode's depth, negative: down the curve )
  f64 lat        ( latency: the 4x halfband pair's, while any wet is mixed in )
  Shelf pre-lo  Shelf pre-hi  Shelf post-lo  Shelf post-hi
  f64 lp-G
  Bell pre-bell
  Bell post-bell
  Shape sh
;

( m a b c d e f g h -- v : the mode's value of eight. )
dsp: pick8 | m a b c d e f g h -- v |
  m 0.5 a  m 1.5 b  m 2.5 c  m 3.5 d  m 4.5 e  m 5.5 f  m 6.5 g h
  fsel-lt fsel-lt fsel-lt fsel-lt fsel-lt fsel-lt fsel-lt
;

( tau sr -- k : one-pole coefficient for a time constant in seconds. )
dsp: sat-coef | tau sr -- k |  1.0  -1.0 tau sr f* f/ exp  f- ;

( ctx state params -- : gains, filters, and the mode's curve.  The
  makeup evens the modes out at the default drive. )
dsp: sat-block-prepare | ctx:Ctx state params:SatParams -- |
  params.drive-db db>lin -> params.drive-lin
  params.mode | m |
  params.color | c |
  ctx.sr | sr |
  params.out-db db>lin  m 0.7 0.795 0.741 0.73 1.62 0.538 3.424 0.794 pick8 f*  -> params.out-lin
  params.tone-hz 6.283185307179586 f* sr f/ 0.0 1.0 fclamp -> params.tone-g
  0.020 sr sat-coef -> params.heat-up
  0.150 sr sat-coef -> params.heat-down
  params.sag  m 0.5 0.3 0.4 0.5 1.0 1.4 0.6 0.8 pick8 f*  -1.0 f* -> params.sag-depth
  0.0 params.mix  OS4-LATENCY 0.0  fsel-lt -> params.lat
  ( filters )
  m 150.0 100.0 180.0 700.0 150.0 250.0 300.0 150.0 pick8 | lo-f |
  params.pre-lo&   lo-f  m -4.0 0.0 10.0 -12.0 0.0 -6.0 -12.0 0.0 pick8 c f*  0.0 sr shelf-set
  params.post-lo&  lo-f  m 3.0 0.0 -10.0 6.0 0.0 3.0 6.0 0.0 pick8 c f*  0.0 sr shelf-set
  params.pre-hi&   3000.0  m 0.0 8.0 0.0 0.0 0.0 0.0 0.0 0.0 pick8 c f*  1.0 sr shelf-set
  params.post-hi&  3000.0  m 0.0 -8.0 0.0 0.0 0.0 0.0 0.0 0.0 pick8 c f*  1.0 sr shelf-set
  params.pre-bell&
    m 1000.0 1000.0 1000.0 900.0 1000.0 1000.0 800.0 1000.0 pick8
    m 0.0 0.0 0.0 4.0 0.0 0.0 6.0 0.0 pick8 c f*
    0.7 sr bell-set
  params.post-bell&
    m 1000.0 70.0 1000.0 1000.0 900.0 1000.0 700.0 1000.0 pick8
    m 0.0 3.0 0.0 0.0 -10.0 0.0 -8.0 0.0 pick8 c f*
    0.7 sr bell-set
  m 12000.0 15000.0 16000.0 5000.0 7000.0 9000.0 7000.0 14000.0 pick8 sr pole-G -> params.lp-G
  params.sh&
    m 0.25 0.0 0.05 0.0 0.3 -1.0 0.03 0.1 pick8
    m 0.15 0.0 0.08 0.0 0.3 0.0 0.0 0.0 pick8
    m 1.0  1.0 1.0  2.0 4.0 0.35 3.0 1.0 pick8
    m 1.0  0.0 0.6  1.0 1.0 1.0 1.0 1.0 pick8
    m 1.0  1.0 1.0  0.45 0.6 1.0 1.0 1.0 pick8
    m 0.0  0.0 0.0  0.0 0.0 1.0 0.0 0.0 pick8
    m 0.0  0.0 0.0  0.0 0.0 0.0 0.0 1.0 pick8
    m 1000000.0 1000000.0 1000000.0 1000000.0 1000000.0 1000000.0 0.22 1000000.0 pick8
  shape-set
;

( state params x -- y : the mode's filtering before the drive. )
dsp: sat-pre | state:SatState params:SatParams x -- y |
  params.pre-lo& x state.pre-lo& shelf-lo | x1 |
  params.pre-hi& x1 state.pre-hi& shelf-hi | x2 |
  state.pre-bell& params.pre-bell& x2 bell-tick
;

( state params y -- z : and after the shaper. )
dsp: sat-post | state:SatState params:SatParams y -- z |
  params.post-lo& y state.post-lo& shelf-lo | y1 |
  params.post-hi& y1 state.post-hi& shelf-hi | y2 |
  state.post-bell& params.post-bell& y2 bell-tick | y3 |
  y3  state.post-lp& params.lp-G y3 pole-lp y3 f-  params.color f*  f+
;

( io ctx state params -- : one saturator sample.  The shaper runs four
  times a sample at 4x, and once more for SAG's rest point: 75% of the
  cost, the halfbands 13%.  Both are branches on params: SAG at 0 needs
  no bias shift and no rest point, and the shaper computes only its
  mode's curve [shape-raw]. )
dsp: k-sat-tick | out:Io ctx state:SatState params:SatParams -- |
  out.in-l | dry |
  params.sh& | sh |
  state params dry sat-pre  params.drive-lin f* | x |
  ( SAG: follow the driven level, rising faster than it falls )
  x fabs | lvl |
  state.heat lvl  params.heat-up params.heat-down  fsel-lt | hk |
  state.heat  lvl state.heat f-  hk f*  f+ | heat |
  heat -> state.heat
  state.up&  x  up4 | a b c d |
  ( with SAG at 0 the shift is -0.0 and x + -0.0 is x: the plain curve,
    resting where shape-set left it )
  params.sag-depth 0.0 f=
  [ sh shape-rest | y0 |
    state.dec&  a y0 sh shape-at0  b y0 sh shape-at0
                c y0 sh shape-at0  d y0 sh shape-at0  dec4 ]
  [ heat tanh-fast  params.sag-depth f* | off |
    0.0 off f+ sh shape-raw | y0 |
    state.dec&  a off y0 sh shape-at  b off y0 sh shape-at
                c off y0 sh shape-at  d off y0 sh shape-at  dec4 ]  ifte | yd |
  state params yd sat-post | y |
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
