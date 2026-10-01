( bus.fy - SSL-style glue compressor [docs/24 §bus2]: comp.fy's detector
  and gain computer, then what makes a bus compressor glue:

  AUTO release, two followers on the target gain gt [log2]:
    fast  g  attack ATK, release 0.1 s      single hits come back fast
    slow  s  charge 0.4 s, release 1.2 s    remembers sustained squash
    gain  min g s                            the deeper of the two
  A lone hit barely charges s, so it releases at 0.1 s; after a loud
  passage s holds the reduction and lets go over a second - a floor of
  gain reduction under the per-hit dips, which is the glue.  A fixed
  REL is the fast follower alone.

  COLOR, the distortion growing with the squash.  With u the wet signal
  over the threshold level T, the added term is

    e = T u^2 / [1 + u^2] * [a2 - a3 u]

  even and odd harmonics that grow as u^2, u^3 for small u and level off
  [the curve stays monotonic], scaled by the gain reduction [full at
  12 dB, none below threshold].  Made at 2x so the low harmonics don't
  fold back, then DC-blocked.  COLOR 1 at 12 dB GR on a sine 5 dB over
  T: 2nd -23 dB, 3rd -28 dB; COLOR 0 is bit-clean [e is exactly 0].

  Layout: CompState then BusState; CompParams then BusParams, so the
  comp words run on the same pointers and the bus words on the tails. )

include "comp.fy"
include "../00-primitives/oversample.fy"

ustruct: BusDc f64 x f64 y ;   ( DC blocker: last input, last output )

ustruct: BusState   ( after CompState )
  f64 gf       ( fast follower, log2 )
  f64 gs       ( slow follower, log2 - AUTO's memory )
  f64 gr-db    ( gain reduction applied, dB >= 0 - meter feed )
  Up2 ul
  Up2 ur
  Dec2 dl
  Dec2 dr
  BusDc dcl
  BusDc dcr
;

ustruct: BusParams  ( after CompParams )
  ( user-facing )
  f64 color    ( 0..1 )
  ( derived - filled by bus-block-prepare )
  f64 auto-on
  f64 atk-c
  f64 rel-c    ( REL, or AUTO's fast release )
  f64 chg-c
  f64 slow-c
  f64 k2
  f64 k3
  f64 t-lin    ( threshold, linear )
  f64 inv-t
;

:: BUS-AUTO-FAST 0.1 ;
:: BUS-AUTO-CHARGE 0.4 ;
:: BUS-AUTO-SLOW 1.2 ;
:: BUS-AUTO-BELOW 0.05 ;     ( REL values under this mean AUTO [the switch stores 0] )
:: BUS-COLOR-2 0.3 ;
:: BUS-COLOR-3 0.3 ;         ( < 0.89 keeps the curve monotonic )
:: BUS-COLOR-FULL 0.08333333333333333 ;   ( 1 / 12 dB )
:: BUS-DC-R 0.9987 ;
:: BUS-FLUSH 1.0e-18 ;         ( ~10 Hz at 48 kHz )

( sr thresh rel atk bp -- : the followers' coefficients and the color. )
dsp: bus-prepare | sr thresh rel atk bp:BusParams |
  rel BUS-AUTO-BELOW 1.0 0.0 fsel-lt -> bp.auto-on
  atk sr comp-tau-coeff -> bp.atk-c
  rel BUS-AUTO-BELOW BUS-AUTO-FAST rel fsel-lt  sr comp-tau-coeff -> bp.rel-c
  BUS-AUTO-CHARGE sr comp-tau-coeff -> bp.chg-c
  BUS-AUTO-SLOW sr comp-tau-coeff -> bp.slow-c
  bp.color BUS-COLOR-2 f* -> bp.k2
  bp.color BUS-COLOR-3 f* -> bp.k3
  thresh db>lin | t |
  t -> bp.t-lin
  1.0 t f/ -> bp.inv-t
;

( ctx state params -- )
dsp: bus-block-prepare | ctx:Ctx state params:CompParams |
  ctx state params comp-block-prepare
  ctx.sr params.thresh-db params.rel-s params.atk-s  params CompParams.size ptr+  bus-prepare
;

( u a2 a3 -- e/T : the color term at one sample, u = w / T. )
dsp: bus-shape | u a2 a3 -- e |
  u u f* | q |
  q  1.0 q f+  f/  a2 a3 u f* f-  f*
;

( up dn dc w a2 a3 t inv-t -- y : w plus its color, made at 2x and
  brought back, DC-blocked. )
dsp: bus-color | up:Up2 dn:Dec2 dc:BusDc w a2 a3 t inv-t -- y |
  up w up2 | w0 w1 |
  w0 inv-t f* a2 a3 bus-shape t f* | e0 |
  w1 inv-t f* a2 a3 bus-shape t f* | e1 |
  dn e0 e1 dec2 | e |
  e dc.x f-  BUS-DC-R dc.y f*  f+ | h |
  ( flushed below ~1e-34: the blocker's tail reaches 0, not denormals )
  e BUS-FLUSH f+ BUS-FLUSH f- -> dc.x
  h BUS-FLUSH f+ BUS-FLUSH f- -> dc.y
  w h f+
;

( bs bp gt -- g : the fast and slow followers, and the gain they give
  [log2]; stores the meter cell. )
dsp: bus-follow | bs:BusState bp:BusParams gt -- g |
  bs.gf | f0 |
  gt f0 bp.atk-c bp.rel-c fsel-lt | cf |
  gt  f0 gt f-  cf f*  f+ | gf |
  gf -> bs.gf
  bs.gs | s0 |
  gt s0 bp.chg-c bp.slow-c fsel-lt | cs |
  gt  s0 gt f-  cs f*  f+ | gs |
  gs -> bs.gs
  bp.auto-on 0.5  gf  gf gs fmin  fsel-lt | g |
  g -6.0205999132796239 f* -> bs.gr-db
  g
;

( io cp yl yr -- : makeup and mix against the dry input. )
dsp: bus-out | io:Io cp:CompParams yl yr |
  cp.makeup-lin cp.mix f* | wet |
  1.0 cp.mix f- | dry |
  yl wet f*  io.in-l dry f*  f+ -> io.out-l
  yr wet f*  io.in-r dry f*  f+ -> io.out-r
;

( io bs bp cp gt -- : follow the target gain, color, makeup and mix. )
dsp: bus-apply | io:Io bs:BusState bp:BusParams cp:CompParams gt |
  bs bp gt bus-follow | g |
  g -6.0205999132796239 f* | gr |
  g exp2 | gain |
  gr BUS-COLOR-FULL f* 0.0 1.0 fclamp | amt |
  bp.k2 amt f* | a2 |
  bp.k3 amt f* | a3 |
  bp.t-lin | t |
  bp.inv-t | it |
  bs.ul& bs.dl& bs.dcl&  io.in-l gain f*  a2 a3 t it bus-color | yl |
  bs.ur& bs.dr& bs.dcr&  io.in-r gain f*  a2 a3 t it bus-color | yr |
  io cp yl yr bus-out
;

( io ctx state params -- : one stereo bus2 sample. )
dsp: k-bus-tick | io:Io ctx state params:CompParams -- |
  io state params comp-detect comp-level
  params swap comp-knee | gt |
  io  state CompState.size ptr+  params CompParams.size ptr+  params  gt  bus-apply
;

( io ctx state params -- : the same at COLOR 0, without the 2x color
  stage [its term is exactly 0 there] - the host runs it for those
  blocks [render-lite]. Turning COLOR to 0 drops the color's DC-blocker
  tail at once, a residue far under the signal. )
dsp: k-bus-tick-clean | io:Io ctx state params:CompParams -- |
  io state params comp-detect comp-level
  params swap comp-knee | gt |
  state CompState.size ptr+  params CompParams.size ptr+  gt  bus-follow exp2 | gain |
  io params  io.in-l gain f*  io.in-r gain f*  bus-out
;
