( comp.fy - stereo-linked feed-forward compressor, log-domain gain
  computer with a soft knee.

  Detection reads the host-filled detector buffer - per sample the max
  of abs of both input channels - so L and R always receive identical
  gain and the stereo image never wobbles [io.det, kernel ABI].
  The envelope follower is a branchless attack/release one-pole in the
  linear domain; the gain computer works in log2 units via the pow2
  primitives:

    l    = log2 env - log2 thresh
    over = 0                        below the knee
           [l + w/2]^2 / [2w]       inside the knee, width w
           l                        above the knee
    gain = exp2 [over * [1/ratio - 1]]

  Gain stages are split so the inlined log2/exp2 ladders never share one
  word's register budget.  Parallel MIX blends
  the compressed signal with dry for New-York-style drum smash.
  Probe case: comp-render - static curve + timing vs a Zig reference. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/pow2.fy"
include "../05-drums/decay.fy"

ustruct: CompState
  f64 env      ( linear envelope )
  f64 lvl-l2   ( log2 of envelope )
  f64 grl2     ( gain in log2 units, <= 0 )
  f64 gain     ( linear gain )
  f64 gr-db    ( gain reduction in dB, >= 0 - meter feed )
;

ustruct: CompParams
  ( user-facing )
  f64 thresh-db  ( -48..0 )
  f64 ratio      ( 1..20 )
  f64 knee-db    ( 0..18, total width )
  f64 atk-s
  f64 rel-s
  f64 makeup-db
  f64 mix
  ( derived - filled by comp-block-prepare )
  f64 thresh-l2
  f64 knee-l2
  f64 inv-knee2  ( 1 / [2 * knee-l2] )
  f64 slope      ( 1/ratio - 1 )
  f64 atk-c
  f64 rel-c
  f64 makeup-lin
;

( ctx state params -- : dB -> log2 units [1 dB = 0.16609640474 log2],
  envelope coefficients, linear makeup. )
dsp: comp-block-prepare
  | ctx:Ctx state params:CompParams |
  ctx.sr | sr |
  params.thresh-db 0.16609640474436813 f*
  -> params.thresh-l2
  ( bind the knee width - stores flush at word END, so reading the
    just-stored param back here would see the old value )
  params.knee-db 0.16609640474436813 f* 0.000001 4.0 fclamp | kw |
  kw -> params.knee-l2
  1.0  kw 2.0 f*  f/
  -> params.inv-knee2
  1.0 params.ratio f/ 1.0 f-
  -> params.slope
  params.atk-s sr decay-exp-coeff
  -> params.atk-c
  params.rel-s sr decay-exp-coeff
  -> params.rel-c
  params.makeup-db 0.16609640474436813 f* exp2-approx
  -> params.makeup-lin
;


( state params -- : envelope follower on the shared detector trace.
  Rising signal takes the attack coefficient, falling the release. )
dsp: comp-detect
  | io:Io state:CompState params:CompParams |
  io.det | d |
  state.env | e |
  e d  params.atk-c  params.rel-c  fsel-lt | c |
  d  e d f-  c f*  f+
  -> state.env
;

( state params -- : envelope into log2 units. )
dsp: comp-level
  | state:CompState params |
  state.env 0.000001 1000000.0 fclamp log2-approx
  -> state.lvl-l2
;

( state params -- : soft-knee overshoot and log2 gain. )
dsp: comp-knee
  | state:CompState params:CompParams |
  state.lvl-l2 params.thresh-l2 f- | l |
  params.knee-l2 0.5 f* | half |
  l half f+ | lh |
  lh lh f* params.inv-knee2 f* | qk |
  l half  qk  l  fsel-lt | sel |
  l  0.0 half f-  0.0  sel  fsel-lt
  params.slope f*
  -> state.grl2
;

( state params -- : back to linear, plus the dB meter cell. )
dsp: comp-gain
  | state:CompState params |
  state.grl2 exp2-approx
  -> state.gain
  state.grl2 -6.0205999132796239 f*
  -> state.gr-db
;

( out state params in -- : apply gain + makeup, parallel mix. )
dsp: comp-apply
  | out state:CompState params:CompParams in:Io |
  in.in-l | x |
  x state.gain f* params.makeup-lin f* | wet |
  x  1.0 params.mix f-  f*
  wet params.mix f*  f+
  out f!64
;

( io ctx state params -- : the full compressor tick, staged. )
dsp: k-comp-tick
  | io ctx state params |
  io state params call: comp-detect
  state params call: comp-level
  state params call: comp-knee
  state params call: comp-gain
  io state params io call: comp-apply
;
