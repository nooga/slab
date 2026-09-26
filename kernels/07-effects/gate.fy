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
  fsel-lt.  Stages are split into call: words so each gets a fresh
  register budget [same discipline as comp.fy]. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/pow2.fy"
include "../05-drums/decay.fy"

ustruct: GateState
  f64 level    ( detector peak-follower envelope )
  f64 gain     ( current gate gain, floor..1 )
  f64 hold-ctr ( samples left before the gate may start closing )
  f64 tgt      ( target gain for this sample - scratch between stages )
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
  params.thresh-db 0.16609640474436813 f* exp2-approx
  -> params.thresh-lin
  params.range-db 0.16609640474436813 f* exp2-approx
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


( state params -- : peak-follower on the shared detector trace.  Instant
  attack to a higher peak, exponential release otherwise. )
dsp: gate-detect
  | io:Io state:GateState params:GateParams |
  io.det | d |
  state.level | lv |
  lv d  d  d  lv d f- params.det-rel-c f* f+  fsel-lt
  -> state.level
;

( state params -- : open/hold/close decision -> target gain + hold counter.
  open  = thresh < level ; gateon = open OR hold-ctr > 0 ;
  target = floor + gateon*(1-floor) ; new hold = open ? hold-spl : max(hold-1,0). )
dsp: gate-decide
  | state:GateState params:GateParams |
  state.level | lv |
  params.thresh-lin lv 1.0 0.0 fsel-lt | open |
  state.hold-ctr | hold |
  0.5  open  0.0 hold 1.0 0.0 fsel-lt  f+  1.0 0.0 fsel-lt | gateon |
  params.floor-lin  gateon 1.0 params.floor-lin f- f*  f+
  -> state.tgt
  open 0.5  hold 1.0 f- 0.0 0.0 hold 1.0 f- fsel-lt  params.hold-spl  fsel-lt
  -> state.hold-ctr
;

( state params -- : slew the gain toward the target [attack opening,
  release closing]. )
dsp: gate-slew
  | state:GateState params:GateParams |
  state.gain | g |
  state.tgt | target |
  g target params.atk-c params.rel-c fsel-lt | c |
  target  g target f-  c f*  f+
  -> state.gain
;

( out state params in -- : apply the gate gain. )
dsp: gate-apply
  | out state:GateState params in:Io |
  in.in-l state.gain f*
  out f!64
;

( io ctx state params -- : the full gate tick, staged. )
dsp: k-gate-tick
  | io ctx state params |
  io state params call: gate-detect
  state params call: gate-decide
  state params call: gate-slew
  io state params io call: gate-apply
;
