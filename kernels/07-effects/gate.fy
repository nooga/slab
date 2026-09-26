( gate.fy - stereo-linked noise gate / downward expander.

  Below THRESH the gate closes and attenuates by RANGE (the floor gain);
  above it the gate opens to unity.  HOLD keeps it open for a while after
  the signal drops, ATK/REL set how fast it opens/closes.  Like the
  compressor it reads the host's shared detector trace [max abs of both
  channels, io.det] so L and R gate together and the
  stereo image never wobbles - what makes it usable on a drum bus, not
  just a mono insert.  The DAW and rig share this kernel.

  The detector trace is smoothed by a fast peak follower [instant attack,
  ~10 ms release] into `level`; `level` vs THRESH decides open/closed; a
  sample-counted HOLD bridges short dips; the gain slews toward its target
  [1 open, floor closed] with the ATK or REL coefficient.  Branch-free via
  fsel-lt.  Stages are value-returning words inlined into one tick. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/math.fy"
include "../05-drums/decay.fy"

ustruct: GateState
  f64 level    ( detector peak-follower envelope )
  f64 gain     ( current gate gain, floor..1 )
  f64 hold-ctr ( samples left before the gate may start closing )
;

ustruct: GateParams
  ( user-facing )
  f64 thresh-db  ( -60..0 )
  f64 range-db   ( -80..0, attenuation when closed; 0 = off )
  f64 atk-s
  f64 hold-s
  f64 rel-s
  ( derived - filled by gate-block-prepare )
  f64 thresh-lin
  f64 floor-lin
  f64 atk-c
  f64 rel-c
  f64 det-rel-c  ( fixed ~10 ms detector release )
  f64 hold-spl
;

( ctx state params -- : dB thresholds to linear, slew coefficients. )
dsp: gate-block-prepare
  | ctx:Ctx state params:GateParams |
  ctx.sr | sr |
  params.thresh-db db>lin
  -> params.thresh-lin
  params.range-db db>lin
  -> params.floor-lin
  params.atk-s sr decay-exp-coeff
  -> params.atk-c
  params.rel-s sr decay-exp-coeff
  -> params.rel-c
  0.01 sr decay-exp-coeff
  -> params.det-rel-c
  params.hold-s sr f*
  -> params.hold-spl
;


( Peak-follower on the shared detector trace.  Instant attack to a higher
  peak, exponential release otherwise. )
dsp: gate-detect | io:Io state:GateState params:GateParams -- lv |
  io.det | d |
  state.level | lv0 |
  lv0 d  d  d  lv0 d f- params.det-rel-c f* f+  fsel-lt | lv |
  lv -> state.level
  lv
;

( Open/hold/close decision -> target gain + hold counter.
  open  = thresh < level ; gateon = open OR hold-ctr > 0 ;
  target = floor + gateon*(1-floor) ; new hold = open ? hold-spl : max(hold-1,0). )
dsp: gate-decide | state:GateState params:GateParams lv -- target |
  params.thresh-lin lv 1.0 0.0 fsel-lt | open |
  state.hold-ctr | hold |
  0.5  open  0.0 hold 1.0 0.0 fsel-lt  f+  1.0 0.0 fsel-lt | gateon |
  params.floor-lin  gateon 1.0 params.floor-lin f- f*  f+ | target |
  open 0.5  hold 1.0 f- 0.0 0.0 hold 1.0 f- fsel-lt  params.hold-spl  fsel-lt
  -> state.hold-ctr
  target
;

( Slew the gain toward the target [attack opening, release closing]. )
dsp: gate-slew | state:GateState params:GateParams target -- g |
  state.gain | g0 |
  g0 target params.atk-c params.rel-c fsel-lt | c |
  target  g0 target f-  c f*  f+ | g |
  g -> state.gain
  g
;

( io ctx state params -- : the full gate tick. )
dsp: k-gate-tick | io:Io ctx state params -- |
  io state params gate-detect | lv |
  state params lv gate-decide | target |
  state params target gate-slew | g |
  io.in-l g f*
  io f!64
;
