( comp.fy - stereo-linked feed-forward compressor, log-domain gain
  computer with a soft knee.

  Detection reads the host-filled detector buffer - per sample the max
  of abs of both input channels - so L and R always receive identical
  gain and the stereo image never wobbles [manifest detector-cell].
  The envelope follower is a branchless attack/release one-pole in the
  linear domain; the gain computer works in log2 units via the pow2
  primitives:

    l    = log2 env - log2 thresh
    over = 0                        below the knee
           [l + w/2]^2 / [2w]       inside the knee, width w
           l                        above the knee
    gain = exp2 [over * [1/ratio - 1]]

  Gain stages are split so the inlined log2/exp2 ladders never share one
  word's register budget.  comp-prepare zeroes the detector index every
  block - prepare runs once per block per channel.  Parallel MIX blends
  the compressed signal with dry for New-York-style drum smash.
  Probe case: comp-render - static curve + timing vs a Zig reference. )

include "../00-primitives/pow2.fy"
include "../05-drums/decay.fy"

ustruct: CompState
  f64 det      ( host-injected detector buffer pointer )
  f64 idx      ( sample index into det, zeroed per block )
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

( params sample-rate -- : dB -> log2 units [1 dB = 0.16609640474 log2],
  envelope coefficients, linear makeup. )
dsp: comp-block-prepare
  | params sr |
  params CompParams.thresh-db@ 0.16609640474436813 f*
  params CompParams.thresh-l2-p f!64
  ( bind the knee width - stores flush at word END, so reading the
    just-stored param back here would see the old value )
  params CompParams.knee-db@ 0.16609640474436813 f* 0.000001 4.0 fclamp | kw |
  kw params CompParams.knee-l2-p f!64
  1.0  kw 2.0 f*  f/
  params CompParams.inv-knee2-p f!64
  1.0 params CompParams.ratio@ f/ 1.0 f-
  params CompParams.slope-p f!64
  params CompParams.atk-s@ sr decay-exp-coeff
  params CompParams.atk-c-p f!64
  params CompParams.rel-s@ sr decay-exp-coeff
  params CompParams.rel-c-p f!64
  params CompParams.makeup-db@ 0.16609640474436813 f* exp2-approx
  params CompParams.makeup-lin-p f!64
  drop2 drop
;

( state params sample-rate -- : per block - rewind the detector index. )
dsp: comp-prepare
  | state params sr |
  0.0 state CompState.idx-p f!64
  drop2 drop
;

( state params -- : envelope follower on the shared detector trace.
  Rising signal takes the attack coefficient, falling the release. )
dsp: comp-detect
  | state params |
  state CompState.det-p p@64 | det |
  state CompState.idx@ | i |
  det i f@i | d |
  i 1.0 f+ state CompState.idx-p f!64
  state CompState.env@ | e |
  e d  params CompParams.atk-c@  params CompParams.rel-c@  fsel-lt | c |
  d  e d f-  c f*  f+
  state CompState.env-p f!64
  drop2 drop2 drop2 drop
;

( state params -- : envelope into log2 units. )
dsp: comp-level
  | state params |
  state CompState.env@ 0.000001 1000000.0 fclamp log2-approx
  state CompState.lvl-l2-p f!64
  drop2
;

( state params -- : soft-knee overshoot and log2 gain. )
dsp: comp-knee
  | state params |
  state CompState.lvl-l2@ params CompParams.thresh-l2@ f- | l |
  params CompParams.knee-l2@ 0.5 f* | half |
  l half f+ | lh |
  lh lh f* params CompParams.inv-knee2@ f* | qk |
  l half  qk  l  fsel-lt | sel |
  l  0.0 half f-  0.0  sel  fsel-lt
  params CompParams.slope@ f*
  state CompState.grl2-p f!64
  drop2 drop2 drop2 drop
;

( state params -- : back to linear, plus the dB meter cell. )
dsp: comp-gain
  | state params |
  state CompState.grl2@ exp2-approx
  state CompState.gain-p f!64
  state CompState.grl2@ -6.0205999132796239 f*
  state CompState.gr-db-p f!64
  drop2
;

( out state params in -- : apply gain + makeup, parallel mix. )
dsp: comp-apply
  | out state params in |
  in f@64 | x |
  x state CompState.gain@ f* params CompParams.makeup-lin@ f* | wet |
  x  1.0 params CompParams.mix@ f-  f*
  wet params CompParams.mix@ f*  f+
  out f!64
  drop2 drop2 drop2
;

( out state params in -- : the full compressor tick, staged. )
dsp: k-comp-tick
  | out state params in |
  state params call: comp-detect
  state params call: comp-level
  state params call: comp-knee
  state params call: comp-gain
  out state params in call: comp-apply
;
