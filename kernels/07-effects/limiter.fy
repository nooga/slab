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
include "../00-primitives/pow2.fy"

ustruct: LimState
  f64 dline     ( host lookahead ring base pointer )
  f64 dline-len ( ring element count )
  f64 wpos      ( ring write head )
  f64 gain      ( gain envelope, linear, <= 1 )
  f64 gmin      ( block min gain - GR meter feed, reset per block to 1 )
  f64 ipk       ( block input peak  - reset per block to 0 )
  f64 opk       ( block output peak - reset per block to 0 )
  f64 ylast     ( last output sample, fed to the LUFS chain )
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
  | ctx state params |
  ctx Ctx.sr@ | sr |
  params LimParams.gain-db@ 0.16609640474436813 f* exp2-approx
  params LimParams.gain-lin-p f!64
  params LimParams.ceil-db@ 0.16609640474436813 f* exp2-approx
  params LimParams.ceil-lin-p f!64
  params LimParams.look-ms@ 0.001 f* sr f* 1.0 4800.0 fclamp | ls |
  ls params LimParams.look-spl-p f!64
  3.0 ls f/ 0.0 1.0 fclamp
  params LimParams.atk-c-p f!64
  1.0 params LimParams.rel-s@ sr f* f/ 0.0 1.0 fclamp
  params LimParams.rel-c-p f!64
  1.0 0.4 sr f* f/
  params LimParams.msm-c-p f!64
  1.0 3.0 sr f* f/
  params LimParams.mss-c-p f!64
  drop2 drop drop2
;

( ctx state params -- : per block - reset
  block meter accumulators, seed gain to unity on fresh [zeroed] state. )
dsp: lim-prepare
  | ctx state params |
  ctx Ctx.sr@ | sr |
  1.0 state LimState.gmin-p f!64
  0.0 state LimState.ipk-p f!64
  0.0 state LimState.opk-p f!64
  state LimState.gain@ 0.001 1.0 state LimState.gain@ fsel-lt
  state LimState.gain-p f!64
  drop2 drop drop
;

( state params -- : gain computer.  Reads the shared detector trace,
  applies input drive, derives the target gain and slews the envelope. )
dsp: lim-gain
  | io state params |
  io Io.det@ params LimParams.gain-lin@ f* | d |
  ( dc = max(d, 1e-9) )
  d 0.000000001 0.000000001 d fsel-lt | dc |
  ( gt = min(1, ceil/dc) )
  params LimParams.ceil-lin@ dc f/ | raw |
  raw 1.0 raw 1.0 fsel-lt | gt |
  state LimState.gain@ | g0 |
  ( c = gt<g0 ? atk : rel )
  gt g0 params LimParams.atk-c@ params LimParams.rel-c@ fsel-lt | c |
  g0 gt g0 f- c f* f+ | g |
  g state LimState.gain-p f!64
  ( gmin = min(gmin, g) )
  state LimState.gmin@ g state LimState.gmin@ g fsel-lt
  state LimState.gmin-p f!64
  ( drop all 11 bound locals: state params det i d dc raw gt g0 c g )
  drop2 drop2 drop2 drop2 drop2
;

( out state params in -- : input drive, lookahead delay, gain + ceiling
  clamp, output, and the block input/output peak meters. )
dsp: lim-io
  | out state params in |
  state LimState.dline-p p@64 | buf |
  state LimState.dline-len@ | len |
  in Io.in-l@ params LimParams.gain-lin@ f* | xg |
  state LimState.wpos@ | w |
  xg buf w f!i
  ( delayed read at w - look, wrapped into 0..len )
  w params LimParams.look-spl@ f- | rp0 |
  rp0 0.0 rp0 len f+ rp0 fsel-lt | rp |
  buf rp f@i | xd |
  ( advance write head )
  w 1.0 f+ | w1 |
  w1 len w1 w1 len f- fsel-lt state LimState.wpos-p f!64
  ( apply gain, clamp to ceiling )
  xd state LimState.gain@ f* | y0 |
  y0 0.0 params LimParams.ceil-lin@ f- params LimParams.ceil-lin@ fclamp | y |
  y out f!64
  y state LimState.ylast-p f!64
  ( meters: |xg| -> ipk, |y| -> opk [block max] )
  xg 0.0 0.0 xg f- xg fsel-lt | axg |
  state LimState.ipk@ axg axg state LimState.ipk@ fsel-lt state LimState.ipk-p f!64
  y 0.0 0.0 y f- y fsel-lt | ay |
  state LimState.opk@ ay ay state LimState.opk@ fsel-lt state LimState.opk-p f!64
  ( drop all 16 bound locals )
  drop2 drop2 drop2 drop2 drop2 drop2 drop2 drop2
;

( state params -- : BS.1770 K-weighting on the output, mean-square
  accumulation [momentary / short-term one-poles + integrated sum]. )
dsp: lim-lufs
  | state params |
  state LimState.ylast@ | x |
  ( stage 1 - transposed direct form II )
  params LimParams.k1b0@ x f* state LimState.k1z1@ f+ | y1 |
  params LimParams.k1b1@ x f* params LimParams.k1a1@ y1 f* f- state LimState.k1z2@ f+ state LimState.k1z1-p f!64
  params LimParams.k1b2@ x f* params LimParams.k1a2@ y1 f* f- state LimState.k1z2-p f!64
  ( stage 2 )
  params LimParams.k2b0@ y1 f* state LimState.k2z1@ f+ | y2 |
  params LimParams.k2b1@ y1 f* params LimParams.k2a1@ y2 f* f- state LimState.k2z2@ f+ state LimState.k2z1-p f!64
  params LimParams.k2b2@ y1 f* params LimParams.k2a2@ y2 f* f- state LimState.k2z2-p f!64
  ( mean-square )
  y2 y2 f* | p |
  state LimState.msm@ p state LimState.msm@ f- params LimParams.msm-c@ f* f+ state LimState.msm-p f!64
  state LimState.mss@ p state LimState.mss@ f- params LimParams.mss-c@ f* f+ state LimState.mss-p f!64
  state LimState.msum@ p f+ state LimState.msum-p f!64
  state LimState.mn@ 1.0 f+ state LimState.mn-p f!64
  ( drop all 6 bound locals: state params x y1 y2 p )
  drop2 drop2 drop2
;

( io ctx state params -- : the full limiter tick, staged so no single
  word blows the register budget. )
dsp: k-lim-tick
  | io ctx state params |
  io state params call: lim-gain
  io state params io call: lim-io
  state params call: lim-lufs
;
