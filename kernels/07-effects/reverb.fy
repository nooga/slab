( reverb.fy - Dattorro plate tank on one packed host buffer.

  Topology [Dattorro 1997, Effect Design part 1]: predelay -> bandwidth
  lowpass -> 4 series input diffusion allpasses -> figure-8 tank of two
  branches, each: decay-diffusion allpass with a slow modulated read tap,
  long delay, damping lowpass, decay gain, second allpass, second delay.
  Each branch is fed the diffused input plus decay times the other
  branch's final delay.  Output is seven taps summed off the tank rings.

  The whole structure lives in ONE host-allocated buffer per channel,
  carved into fixed-capacity regions sized for 96 kHz; the EFFECTIVE
  ring lengths scale with the actual sample rate at block-prepare so the
  reverb sounds identical at any rate.  All region base offsets below
  are compile-time literals - the capacity table:

    region        offset   cap     base-len at 29761 Hz
    predelay      0        12288   knob, up to 128 ms
    in-ap1        12288    480     142   g 0.75
    in-ap2        12768    360     107   g 0.75
    in-ap3        13128    1248    379   g 0.625
    in-ap4        14376    912     277   g 0.625
    a-ap1         15288    2304    672   g 0.70, modulated
    a-d1          17592    14400   4453
    a-ap2         31992    5824    1800  g 0.50
    a-d2          37816    12032   3720
    b-ap1         49848    3072    908   g 0.70, modulated
    b-d1          52920    13632   4217
    b-ap2         66552    8576    2656  g 0.50
    b-d2          75128    10240   3163
    total         85368             -> 0.9 s buffer at 96 kHz

  Dual mono with decorrelation: ctx.chan [0 L / 1 R] drives a per
  channel LFO phase and rate offset plus the L/R output tap sets, so the
  two tanks drift apart and the tail goes wide.  Probe case:
  reverb-render - impulse, RT60 + echo density ratchets, WAV.

  GATED mode is the 80s non-linear program [AMS RMX16 NonLin2, the SSL
  gated room]: the dry input keys a gate on the wet signal.  A hit over
  THRESH opens it; it stays open HOLD seconds after the last such
  sample, shaped over that window by SHAPE [-1 decaying, 0 flat, +1
  rising - the 'reverse' program], then shuts in about 10 ms.  Run
  DECAY high so the tank is still full when the gate cuts.  PLATE mode
  never touches the wet path. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/math.fy"

ustruct: VerbState
  f64 buf        ( host-injected ring base pointer )
  f64 buf-len    ( host-injected element count )
  f64 lfo-phase
  f64 seeded     ( 0 fresh state, 1 after first prepare )
  f64 in-lpf     ( bandwidth filter state )
  f64 damp-a-z   ( branch A damping state )
  f64 damp-b-z   ( branch B damping state )
  f64 mod-inc-ch ( per-channel LFO increment )
  f64 pre-pos
  f64 inap1-pos  f64 inap2-pos  f64 inap3-pos  f64 inap4-pos
  f64 a-ap1-pos  f64 a-d1-pos   f64 a-ap2-pos  f64 a-d2-pos
  f64 b-ap1-pos  f64 b-d1-pos   f64 b-ap2-pos  f64 b-d2-pos
  f64 tap-1  f64 tap-2  f64 tap-3  f64 tap-4
  f64 tap-5  f64 tap-6  f64 tap-7
  f64 gate-t     ( samples since the last sample over the threshold )
  f64 gate-g     ( smoothed wet gain in GATED mode )
;

ustruct: VerbParams
  ( user-facing )
  f64 predelay-s
  f64 decay      ( tank feedback gain, 0.3..0.97 )
  f64 damp-hz    ( tank damping lowpass cutoff )
  f64 bw-hz      ( input bandwidth lowpass cutoff )
  f64 mix
  f64 mod-depth  ( excursion in reference samples, const ~10 )
  f64 mod-rate   ( Hz, const ~1.2 )
  f64 mode       ( 0 plate, 1 gated )
  f64 gate-thr-db
  f64 gate-hold-s
  f64 gate-shape ( -1 decaying .. 0 flat .. +1 rising )
  ( derived - filled by verb-block-prepare )
  f64 scale      ( sr / 29761 )
  f64 pre-len
  f64 inap1-len  f64 inap2-len  f64 inap3-len  f64 inap4-len
  f64 a-ap1-len  f64 a-d1-len   f64 a-ap2-len  f64 a-d2-len
  f64 b-ap1-len  f64 b-d1-len   f64 b-ap2-len  f64 b-d2-len
  f64 bw-a
  f64 damp-a
  f64 mod-inc
  f64 mod-depth-spl
  f64 gate-thr   ( linear )
  f64 gate-hold  ( samples )
  f64 gate-atk   ( one-pole coefficients )
  f64 gate-rel
;

( --- ring helpers: inlined into the tick ------------------------- )

( buf off posp len x g -- y : one allpass ring tick.
  v = ring out, w = x - g*v written back, y = v + g*w. )
dsp: vb-ap
  | buf off posp len x g |
  posp f@64 | p |
  off p f+ | idx |
  buf idx f@i | v |
  x g v f* f- | w |
  w buf idx f!i
  p 1.0 f+ | p1 |
  p1 len  p1  p1 len f-  fsel-lt posp f!64
  v g w f* f+
;

( buf off posp len x g m -- y : allpass with a modulated fractional
  read tap.  The oldest sample sits just ahead of the write head, so the
  tap reads at p+1+m for an effective delay of len-1-m - the chorusing
  inside the tank. )
dsp: vb-apm
  | buf off posp len x g m |
  posp f@64 | p |
  p 1.0 f+ m f+ | r0 |
  r0 len  r0  r0 len f-  fsel-lt | r |
  buf off r f+ f@i | s0 |
  r 1.0 f+ | r1 |
  r1 len  r1  r1 len f-  fsel-lt | rw |
  buf off rw f+ f@i | s1 |
  s0  s1 s0 f-  r ffrac f*  f+ | v |
  x g v f* f- | w |
  w  buf off p f+  f!i
  p 1.0 f+ | p1 |
  p1 len  p1  p1 len f-  fsel-lt posp f!64
  v g w f* f+
;

( buf off posp len x -- y : plain delay ring tick. )
dsp: vb-dl
  | buf off posp len x |
  posp f@64 | p |
  off p f+ | idx |
  buf idx f@i | v |
  x buf idx f!i
  p 1.0 f+ | p1 |
  p1 len  p1  p1 len f-  fsel-lt posp f!64
  v
;

( buf off pos len tap -- v : static read tap behind the write head. )
dsp: vb-tap
  | buf off pos len tap |
  pos tap f- | i |
  i 0.0  i len f+  i fsel-lt | iw |
  buf  off iw f+  f@i
;

( --- block-rate fills ----------------------------------------------- )

( ctx state params -- : effective ring lengths + coefficients. )
dsp: verb-block-prepare
  | ctx:Ctx state params:VerbParams |
  ctx.sr | sr |
  sr 0.000033601021471 f* | scale |
  scale -> params.scale
  params.predelay-s sr f* 1.0 12287.0 fclamp
  dup ffrac f- -> params.pre-len
  142.0 scale f* dup ffrac f- -> params.inap1-len
  107.0 scale f* dup ffrac f- -> params.inap2-len
  379.0 scale f* dup ffrac f- -> params.inap3-len
  277.0 scale f* dup ffrac f- -> params.inap4-len
  672.0 scale f* dup ffrac f- -> params.a-ap1-len
  4453.0 scale f* dup ffrac f- -> params.a-d1-len
  1800.0 scale f* dup ffrac f- -> params.a-ap2-len
  3720.0 scale f* dup ffrac f- -> params.a-d2-len
  908.0 scale f* dup ffrac f- -> params.b-ap1-len
  4217.0 scale f* dup ffrac f- -> params.b-d1-len
  2656.0 scale f* dup ffrac f- -> params.b-ap2-len
  3163.0 scale f* dup ffrac f- -> params.b-d2-len
  params.bw-hz 6.2831853 f* sr f/ 0.0 1.0 fclamp
  -> params.bw-a
  params.damp-hz 6.2831853 f* sr f/ 0.0 1.0 fclamp
  -> params.damp-a
  params.mod-rate sr f/ -> params.mod-inc
  params.mod-depth scale f* -> params.mod-depth-spl
  params.gate-thr-db db>lin -> params.gate-thr
  params.gate-hold-s sr f* 1.0 fmax -> params.gate-hold
  ( ~1 ms open, ~10 ms shut: 1 - e^[-1/tau] ~ 1/tau at these rates )
  1.0 sr 0.001 f* f/ -> params.gate-atk
  1.0 sr 0.01 f* f/ -> params.gate-rel
;

( ctx state params -- : per-channel decorrelation, runs every
  block.  Seeds the LFO phase once, picks the L or R output tap set, and
  detunes the modulation rate on the right channel. )
dsp: verb-prepare
  | ctx:Ctx state:VerbState params:VerbParams |
  ctx.sr | sr |
  ctx.chan | chan |
  params.scale | scale |
  state.seeded 0.5
    0.123 chan 0.39 f* f+
    state.lfo-phase
  fsel-lt -> state.lfo-phase
  ( a fresh gate starts shut, not as if hit at sample 0 )
  state.seeded 0.5 1.0e9 state.gate-t fsel-lt -> state.gate-t
  1.0 -> state.seeded
  params.mod-inc 1.0 chan 0.17 f* f+ f*
  -> state.mod-inc-ch
  chan 0.5 266.0  353.0  fsel-lt scale f* -> state.tap-1
  chan 0.5 2974.0 3627.0 fsel-lt scale f* -> state.tap-2
  chan 0.5 1913.0 1228.0 fsel-lt scale f* -> state.tap-3
  chan 0.5 1996.0 2673.0 fsel-lt scale f* -> state.tap-4
  chan 0.5 1990.0 2111.0 fsel-lt scale f* -> state.tap-5
  chan 0.5 187.0  335.0  fsel-lt scale f* -> state.tap-6
  chan 0.5 1066.0 121.0  fsel-lt scale f* -> state.tap-7
;

( --- per-sample stages ----------------------------------------------- )

( Predelay ring + bandwidth lowpass -> diffuser input. )
dsp: verb-pre | state:VerbState params:VerbParams buf x -- d |
  buf 0.0 state.pre-pos& params.pre-len x vb-dl | v |
  state.in-lpf | z |
  z  v z f-  params.bw-a f*  f+ | zn |
  zn -> state.in-lpf
  zn
;

( Input diffusion allpasses 1+2, g 0.75. )
dsp: verb-in-ap12 | state:VerbState params:VerbParams buf x -- y |
  buf 12288.0 state.inap1-pos& params.inap1-len
    x 0.75 vb-ap | y1 |
  buf 12768.0 state.inap2-pos& params.inap2-len
    y1 0.75 vb-ap
;

( Input diffusion allpasses 3+4, g 0.625. )
dsp: verb-in-ap34 | state:VerbState params:VerbParams buf x -- y |
  buf 13128.0 state.inap3-pos& params.inap3-len
    x 0.625 vb-ap | y3 |
  buf 14376.0 state.inap4-pos& params.inap4-len
    y3 0.625 vb-ap
;

( Advance the tank LFO, derive both mod offsets [samples]. )
dsp: verb-lfo | state:VerbState params:VerbParams -- ma mb |
  state.lfo-phase state.mod-inc-ch f+ ffrac | ph |
  ph -> state.lfo-phase
  params.mod-depth-spl | dep |
  dep 0.5 0.5 ph sin2pi f* f+ f*
  dep 0.5 0.5 ph 0.25 f+ sin2pi f* f+ f*
;

( Branch A front half - feedback from branch B's last delay, modulated
  decay-diffusion allpass, first long delay. )
dsp: verb-tank-a-in | state:VerbState params:VerbParams buf d m -- ta |
  buf 75128.0 state.b-d2-pos params.b-d2-len 0.0 vb-tap
  params.decay f*
  d f+ | fba |
  buf 15288.0 state.a-ap1-pos& params.a-ap1-len
    fba 0.70 m vb-apm | y |
  buf 17592.0 state.a-d1-pos& params.a-d1-len y vb-dl
;

( Branch A back half - damping, decay, second allpass, second delay. )
dsp: verb-tank-a-out | state:VerbState params:VerbParams buf ta -- |
  state.damp-a-z | z |
  z  ta z f-  params.damp-a f*  f+ | zn |
  zn -> state.damp-a-z
  buf 31992.0 state.a-ap2-pos& params.a-ap2-len
    zn params.decay f* 0.50 vb-ap | y |
  buf 37816.0 state.a-d2-pos& params.a-d2-len y vb-dl
  drop
;

( Branch B front half, fed from branch A's last delay. )
dsp: verb-tank-b-in | state:VerbState params:VerbParams buf d m -- tb |
  buf 37816.0 state.a-d2-pos params.a-d2-len 0.0 vb-tap
  params.decay f*
  d f+ | fbb |
  buf 49848.0 state.b-ap1-pos& params.b-ap1-len
    fbb 0.70 m vb-apm | y |
  buf 52920.0 state.b-d1-pos& params.b-d1-len y vb-dl
;

( Branch B back half. )
dsp: verb-tank-b-out | state:VerbState params:VerbParams buf tb -- |
  state.damp-b-z | z |
  z  tb z f-  params.damp-a f*  f+ | zn |
  zn -> state.damp-b-z
  buf 66552.0 state.b-ap2-pos& params.b-ap2-len
    zn params.decay f* 0.50 vb-ap | y |
  buf 75128.0 state.b-d2-pos& params.b-d2-len y vb-dl
  drop
;

( The GATED mode's wet gain for this sample, keyed by the dry input. )
dsp: verb-gate | state:VerbState params:VerbParams x -- g |
  x fabs params.gate-thr  state.gate-t 1.0 f+  0.0  fsel-lt | t |
  t -> state.gate-t
  t params.gate-hold f/ | u |
  params.gate-shape | sh |
  ( ramp over the window: 1 - u decaying, u rising )
  sh 0.0  1.0 u f-  u  fsel-lt | r |
  1.0  sh fabs  r 1.0 f-  f*  f+ | w |
  u 1.0 w 0.0 fsel-lt | target |
  state.gate-g | g |
  g target params.gate-atk params.gate-rel fsel-lt | k |
  g  target g f-  k f*  f+ | gn |
  gn -> state.gate-g
  gn
;

( Seven output taps, dry/wet mix. )
dsp: verb-out | out state:VerbState params:VerbParams buf x -- |
  buf 52920.0 state.b-d1-pos params.b-d1-len
    state.tap-1 vb-tap
  buf 52920.0 state.b-d1-pos params.b-d1-len
    state.tap-2 vb-tap f+
  buf 66552.0 state.b-ap2-pos params.b-ap2-len
    state.tap-3 vb-tap f-
  buf 75128.0 state.b-d2-pos params.b-d2-len
    state.tap-4 vb-tap f+
  buf 17592.0 state.a-d1-pos params.a-d1-len
    state.tap-5 vb-tap f-
  buf 31992.0 state.a-ap2-pos params.a-ap2-len
    state.tap-6 vb-tap f-
  buf 37816.0 state.a-d2-pos params.a-d2-len
    state.tap-7 vb-tap f-
  0.6 f* | wet0 |
  state params x verb-gate | gg |
  ( plate mode leaves the wet path untouched, bit for bit )
  params.mode 0.5 wet0 wet0 gg f* fsel-lt | wet |
  x  1.0 params.mix f-  f*
  wet params.mix f*  f+
  out f!64
;

( io ctx state params -- : the full plate tick.  Ring writes [f!i] land
  at the end of the word; no read in a later stage hits the slot an
  earlier stage wrote this sample [taps sit >= 1 sample behind the
  write head], so that ordering is unobservable. )
dsp: k-verb-tick | io:Io ctx state:VerbState params -- |
  state.buf& p@64 | buf |
  io.in-l | x |
  state params buf x verb-pre | d0 |
  state params buf d0 verb-in-ap12 | d1 |
  state params buf d1 verb-in-ap34 | d |
  state params verb-lfo | ma mb |
  state params buf  state params buf d ma verb-tank-a-in  verb-tank-a-out
  state params buf  state params buf d mb verb-tank-b-in  verb-tank-b-out
  io state params buf x verb-out
;
