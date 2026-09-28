( comp.fy - stereo-linked feed-forward compressor: sidechain high-pass,
  peak or RMS detector, log-domain gain computer with a soft knee, and
  the attack/release smoothing on the gain, in log2 units - the
  "smooth branching" detector of Giannoulis, Massberg and Reiss 2012
  [docs/24 §comp2 revision].

  One true-stereo pass per sample.  The detector reads the host's signed
  sidechain pair [io.sc-l, io.sc-r: the key when keyed, else the input],
  high-passes both with a 12 dB/oct TPT SVF [off at the bottom of the
  knob], and takes the louder:

    x    = max |hp L| |hp R|
    lvl  = max [x, 5 ms decay of the last lvl]        PEAK
           sqrt [2 * mean of x^2, tau 10 ms]          RMS [a sine reads its peak]
    l    = log2 lvl - log2 thresh
    over = 0                        below the knee
           [l + w/2]^2 / [2w]       inside the knee, width w
           l                        above the knee
    gt   = over * [1/ratio - 1]     target gain, log2, <= 0
    g    = gt + [g - gt] * c        c = attack when gt < g [more reduction]

  so ATK and REL are the gain's own time constants [63 %], the same at
  every level, and nothing below the knee moves the gain.  Parallel MIX
  blends the compressed signal with dry for New-York-style smash.
  Bench: `zig build bench -- machines/comp2` - curve, step, lowsine,
  drums [docs/24 §Test plan]. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/math.fy"
include "../04-filters/coeffs.fy"   ( svf-g )

ustruct: CompState
  f64 g        ( smoothed gain, log2 units, <= 0 )
  f64 ms       ( detector mean square, RMS mode )
  f64 pk       ( detector peak, held across zero crossings )
  f64 hl1      ( sidechain high-pass integrators, left )
  f64 hl2
  f64 hr1      ( and right )
  f64 hr2
  f64 gr-db    ( gain reduction in dB, >= 0 - meter feed )
;

ustruct: CompParams
  ( user-facing )
  f64 thresh-db  ( -48..0 )
  f64 ratio      ( 1..20 )
  f64 knee-db    ( 0..18, total width )
  f64 atk-s      ( attack time constant )
  f64 rel-s      ( release time constant )
  f64 makeup-db
  f64 mix
  f64 hpf-hz     ( sidechain high-pass; the bottom of the knob is off )
  f64 det        ( 0 PEAK, 1 RMS )
  ( derived - filled by comp-block-prepare )
  f64 thresh-l2
  f64 knee-l2
  f64 inv-knee2  ( 1 / [2 * knee-l2] )
  f64 slope      ( 1/ratio - 1 )
  f64 atk-c
  f64 rel-c
  f64 makeup-lin
  f64 hpf-g
  f64 hpf-on     ( 1 when hpf-hz is above the off position )
  f64 rms-c
  f64 pk-c       ( the peak hold's decay )
;

:: COMP-HPF-OFF 21.0 ;   ( at or below this, the sidechain is unfiltered )
:: COMP-RMS-TAU 0.01 ;
:: COMP-PK-TAU 0.005 ;   ( fills the dips between half-cycles, not a release )

( t sr -- c : one-pole coefficient for time constant t [63 %]. )
dsp: comp-tau-coeff | t sr -- c |
  -1.0  t 0.00001 fmax sr f*  f/ exp
;

( ctx state params -- : dB -> log2 units [1 dB = 0.16609640474 log2],
  smoothing coefficients, linear makeup, sidechain filter. )
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
  params.atk-s sr comp-tau-coeff
  -> params.atk-c
  params.rel-s sr comp-tau-coeff
  -> params.rel-c
  params.makeup-db db>lin
  -> params.makeup-lin
  params.hpf-hz sr svf-g
  -> params.hpf-g
  COMP-HPF-OFF params.hpf-hz 1.0 0.0 fsel-lt
  -> params.hpf-on
  COMP-RMS-TAU sr comp-tau-coeff
  -> params.rms-c
  COMP-PK-TAU sr comp-tau-coeff
  -> params.pk-c
;

( s1p s2p x g -- hp : one Butterworth high-pass step of a TPT SVF
  [Zavalishin ch. 4, damping 1/sqrt2]; s1p / s2p point at the states. )
dsp: comp-hp-step | s1p s2p x g -- hp |
  s1p f@64 | s1 |
  s2p f@64 | s2 |
  1.4142135623730951 g f+ | a |
  1.0  1.4142135623730951 g f*  f+  g g f*  f+ | den |
  x  a s1 f*  f-  s2 f-  den f/ | hp |
  g hp f* | ghp |
  ghp s1 f+ | bp |
  ghp bp f+  s1p f!64
  g bp f*  s2 f+ | lp |
  g bp f* lp f+  s2p f!64
  hp
;

( The detector level: the louder sidechain channel, high-passed when
  the filter is on, peak or RMS. )
dsp: comp-detect | io:Io state:CompState params:CompParams -- lvl |
  state.hl1& state.hl2& io.sc-l params.hpf-g comp-hp-step | fl |
  state.hr1& state.hr2& io.sc-r params.hpf-g comp-hp-step | fr |
  io.sc-l fabs io.sc-r fabs fmax | raw |
  fl fabs fr fabs fmax | filt |
  params.hpf-on 0.5 raw filt fsel-lt | x |
  ( instant up, a short decay: a steady tone reads as its peak, not
    as a level that dips to zero every half-cycle )
  x  state.pk params.pk-c f*  fmax | pk |
  pk -> state.pk
  x x f* | p2 |
  p2  state.ms p2 f-  params.rms-c f*  f+ | ms |
  ms -> state.ms
  ms 2.0 f* fsqrt | rms |
  params.det 0.5 pk rms fsel-lt
;

( Level into log2 units. )
dsp: comp-level | lvl -- l2 |
  lvl 0.000001 1000000.0 fclamp log2
;

( Soft-knee overshoot and log2 target gain. )
dsp: comp-knee | params:CompParams l2 -- grl2 |
  l2 params.thresh-l2 f- | l |
  params.knee-l2 0.5 f* | half |
  l half f+ | lh |
  lh lh f* params.inv-knee2 f* | qk |
  l half  qk  l  fsel-lt | sel |
  l  0.0 half f-  0.0  sel  fsel-lt
  params.slope f*
;

( Smooth the target gain: attack while it falls [more reduction],
  release while it rises.  Stores the gain and the dB meter cell. )
dsp: comp-smooth | state:CompState params:CompParams gt -- g |
  state.g | g0 |
  gt g0 params.atk-c params.rel-c fsel-lt | c |
  gt  g0 gt f-  c f*  f+ | g |
  g -> state.g
  g -6.0205999132796239 f* -> state.gr-db
  g
;

( io ctx state params -- : the full compressor tick, both channels. )
dsp: k-comp-tick | io:Io ctx state params:CompParams -- |
  io state params comp-detect comp-level
  params swap comp-knee | gt |
  state params gt comp-smooth exp2 | gain |
  ( wet gain with makeup, blended with dry )
  gain params.makeup-lin f* params.mix f*  1.0 params.mix f-  f+ | k |
  io.in-l k f*  -> io.out-l
  io.in-r k f*  -> io.out-r
;
