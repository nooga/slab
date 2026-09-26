( limiter.fy - stereo-linked lookahead brickwall limiter with BS.1770
  LUFS metering.

  Gain reduction is computed from the host detector trace [max abs of
  both input channels, io.det] so L and R always receive
  identical gain and the stereo image stays put.  The audio is delayed
  through a host ring [manifest buffer] by the lookahead time, while the
  gain envelope is computed from the *un-delayed* detector with an attack
  whose time constant tracks the lookahead - so the reduction ramp lands
  on the peak as it emerges from the delay.  A final ceiling clamp makes
  it a true brickwall regardless of envelope overshoot.

  LUFS: each channel runs its K-weighting two-biquad chain [BS.1770-4
  48 kHz coefficients, supplied as const params] on the OUTPUT and
  accumulates mean-square into momentary [400 ms] / short-term [3 s]
  one-poles plus an integrated running sum.  The panel reads both
  channels' mean-square cells, sums them, and converts to LUFS / dB.

  Meter cells [panel reads, never written by the panel]:
    gmin  block-minimum linear gain  -> gain reduction
    ipk   block input peak  [post input-gain, linear]
    opk   block output peak [linear]
    msm/mss/msum/mn  LUFS mean-square accumulators

  All level/loudness logarithms live in the Zig panel; the kernel stays
  in linear units. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/math.fy"

ustruct: LimState
  f64 dline     ( host lookahead ring base pointer )
  f64 dline-len ( ring element count )
  f64 wpos      ( ring write head )
  f64 gain      ( gain envelope, linear, <= 1 )
  f64 gmin      ( block min gain - GR meter feed, reset per block to 1 )
  f64 ipk       ( block input peak  - reset per block to 0 )
  f64 opk       ( block output peak - reset per block to 0 )
  f64 k1z1      ( K-weight stage 1 transposed-DF2 state )
  f64 k1z2
  f64 k2z1      ( K-weight stage 2 state )
  f64 k2z2
  f64 msm       ( momentary mean-square, one-pole )
  f64 mss       ( short-term mean-square, one-pole )
  f64 msum      ( integrated: running sum of K-weighted square )
  f64 mn        ( integrated: sample count )
;

ustruct: LimParams
  ( user-facing )
  f64 gain-db   ( input drive, 0..24 )
  f64 ceil-db   ( output ceiling, -24..0 )
  f64 look-ms   ( lookahead, 0.1..10 ms )
  f64 rel-s     ( release, 0.01..1 s )
  ( derived - lim-block-prepare )
  f64 gain-lin
  f64 ceil-lin
  f64 look-spl  ( lookahead in samples )
  f64 atk-c     ( gain-decrease one-pole coeff, ~3/look-spl )
  f64 rel-c     ( gain-increase one-pole coeff )
  f64 msm-c     ( momentary one-pole coeff [~1/(0.4*sr)] )
  f64 mss-c     ( short-term one-pole coeff [~1/(3*sr)] )
  ( K-weighting biquad coefficients [const-f64, BS.1770-4 @ 48 kHz] )
  f64 k1b0 f64 k1b1 f64 k1b2 f64 k1a1 f64 k1a2
  f64 k2b0 f64 k2b1 f64 k2b2 f64 k2a1 f64 k2a2
;

( ctx state params -- : block-rate derived fill. )
dsp: lim-block-prepare
  | ctx:Ctx state params:LimParams |
  ctx.sr | sr |
  params.gain-db db>lin
  -> params.gain-lin
  params.ceil-db db>lin
  -> params.ceil-lin
  params.look-ms 0.001 f* sr f* 1.0 4800.0 fclamp | ls |
  ls -> params.look-spl
  3.0 ls f/ 0.0 1.0 fclamp
  -> params.atk-c
  1.0 params.rel-s sr f* f/ 0.0 1.0 fclamp
  -> params.rel-c
  1.0 0.4 sr f* f/
  -> params.msm-c
  1.0 3.0 sr f* f/
  -> params.mss-c
;

( ctx state params -- : per block - reset
  block meter accumulators, seed gain to unity on fresh [zeroed] state. )
dsp: lim-prepare
  | ctx:Ctx state:LimState params |
  ctx.sr | sr |
  1.0 -> state.gmin
  0.0 -> state.ipk
  0.0 -> state.opk
  state.gain 0.001 1.0 state.gain fsel-lt
  -> state.gain
;

( Gain computer.  Reads the shared detector trace, applies input drive,
  derives the target gain and slews the envelope. )
dsp: lim-gain | io:Io state:LimState params:LimParams -- g |
  io.det params.gain-lin f* | d |
  ( dc = max(d, 1e-9) )
  d 0.000000001 fmax | dc |
  ( gt = min(1, ceil/dc) )
  params.ceil-lin dc f/ | raw |
  raw 1.0 fmin | gt |
  state.gain | g0 |
  ( c = gt<g0 ? atk : rel )
  gt g0 params.atk-c params.rel-c fsel-lt | c |
  g0 gt g0 f- c f* f+ | g |
  g -> state.gain
  ( gmin = min(gmin, g) )
  state.gmin g fmin
  -> state.gmin
  g
;

( Input drive, lookahead delay, gain + ceiling clamp, output, and the
  block input/output peak meters.  io is both the input frame and the
  output cell [out-l at offset 0]. )
dsp: lim-io | io:Io state:LimState params:LimParams g -- y |
  state.dline& p@64 | buf |
  state.dline-len | len |
  io.in-l params.gain-lin f* | xg |
  state.wpos | w |
  xg buf w f!i
  ( delayed read at w - look, wrapped into 0..len )
  w params.look-spl f- | rp0 |
  rp0 0.0 rp0 len f+ rp0 fsel-lt | rp |
  buf rp f@i | xd |
  ( advance write head )
  w 1.0 f+ | w1 |
  w1 len w1 w1 len f- fsel-lt -> state.wpos
  ( apply gain, clamp to ceiling )
  xd g f* | y0 |
  y0 0.0 params.ceil-lin f- params.ceil-lin fclamp | y |
  y io f!64
  ( meters: |xg| -> ipk, |y| -> opk [block max] )
  xg fabs | axg |
  state.ipk axg fmax -> state.ipk
  y fabs | ay |
  state.opk ay fmax -> state.opk
  y
;

( BS.1770 K-weighting on the output sample x, mean-square accumulation
  [momentary / short-term one-poles + integrated sum]. )
dsp: lim-lufs | state:LimState params:LimParams x -- |
  ( stage 1 - transposed direct form II )
  params.k1b0 x f* state.k1z1 f+ | y1 |
  params.k1b1 x f* params.k1a1 y1 f* f- state.k1z2 f+ -> state.k1z1
  params.k1b2 x f* params.k1a2 y1 f* f- -> state.k1z2
  ( stage 2 )
  params.k2b0 y1 f* state.k2z1 f+ | y2 |
  params.k2b1 y1 f* params.k2a1 y2 f* f- state.k2z2 f+ -> state.k2z1
  params.k2b2 y1 f* params.k2a2 y2 f* f- -> state.k2z2
  ( mean-square )
  y2 y2 f* | p |
  state.msm p state.msm f- params.msm-c f* f+ -> state.msm
  state.mss p state.mss f- params.mss-c f* f+ -> state.mss
  state.msum p f+ -> state.msum
  state.mn 1.0 f+ -> state.mn
;

( io ctx state params -- : the full limiter tick. )
dsp: k-lim-tick | io ctx state params -- |
  io state params  io state params lim-gain  lim-io | y |
  state params y lim-lufs
;
