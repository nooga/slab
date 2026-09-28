( multi.fy - three-band compressor [docs/24 §multi2].

  Crossover: Linkwitz-Riley 4th order at XLO and XHI, TPT SVFs at
  damping 1/sqrt2.  An LR4 low- and high-pass sum to the 2nd-order
  allpass  [s^2 - k s + 1] / [s^2 + k s + 1],  so

    x    -> SVF a        lp a -> SVF b lp  = low      [LR4 at XLO]
                         hp a -> SVF c hp  = rest
    low  -> SVF d        low - 2k bp d     = low, allpassed at XHI
    rest -> SVF e        lp e -> SVF f lp  = mid      [LR4 at XHI]
                         hp e -> SVF g hp  = high

  and low + mid + high = AP[XHI] AP[XLO] x: flat in magnitude, only the
  phase turns.  Seven SVFs a channel.

  Each band has its own detector [peak of the louder channel, a hold
  that decays over 20 / 5 / 2 ms, long enough to ride over one half-
  cycle of the band's lowest note], comp.fy's log-domain gain computer
  with a fixed 4 dB knee, and gain smoothing at ATK and REL scaled by
  band: x2 for the low band, x0.5 for the high one [a slow low band
  doesn't modulate its own waveform; a fast high band catches esses].

  UP adds upward compression under every band: below THRESH - 10 dB
  the band is lifted by UP x [the distance down], so UP 1 is 2:1
  upward, capped at +12 dB and faded out towards -60 dBFS so the noise
  floor stays put.  Downward above, upward below: the band's level is
  pulled towards a window around its threshold.

  MIX blends with the crossover's own sum [the dry path goes through the
  same allpasses, so a parallel mix doesn't comb at the crossovers]. )

include "comp.fy"   ( ctx, math, svf-g, comp-tau-coeff )

ustruct: MbSvf f64 s1 f64 s2 ;
ustruct: MbChan MbSvf a MbSvf b MbSvf c MbSvf d MbSvf e MbSvf f MbSvf g ;   ( one channel's crossover )

ustruct: MbBand
  f64 pk       ( detector hold, linear )
  f64 g        ( smoothed gain, log2 [> 0 when lifted] )
  f64 gr-db    ( gain reduction, dB [< 0 when lifted] - meter feed )
  f64 lvl      ( detector level, linear - display feed )
;

ustruct: MultiState
  MbChan l
  MbChan r
  MbBand lo
  MbBand mid
  MbBand hi
;

ustruct: MbBandP
  ( user-facing )
  f64 thresh-db
  f64 ratio
  f64 gain-db
  ( derived - filled by mb-band-prepare )
  f64 thresh-l2
  f64 uthr-l2   ( where upward compression starts )
  f64 slope     ( 1/ratio - 1 )
  f64 up-k
  f64 atk-c
  f64 rel-c
  f64 pk-c
  f64 gain-lin
;

ustruct: MultiParams
  MbBandP lo
  MbBandP mid
  MbBandP hi
  ( user-facing )
  f64 xlo-hz
  f64 xhi-hz
  f64 atk-s
  f64 rel-s
  f64 up       ( 0..1 )
  f64 mix
  f64 out-db
  ( derived )
  f64 g-lo
  f64 g-hi
  f64 out-lin
;

:: MB-K 1.4142135623730951 ;        ( SVF damping term 2d, Butterworth )
:: MB-2K 2.8284271247461903 ;
:: MB-KNEE 0.6643856189774725 ;     ( 4 dB in log2 units )
:: MB-KNEE-HALF 0.33219280948873625 ;
:: MB-INV-KNEE2 0.7525749891599529 ;   ( 1 / [2 * knee] )
:: MB-UP-BELOW 1.6609640474436813 ;    ( 10 dB )
:: MB-UP-CAP 1.9931568569324174 ;      ( 12 dB )
:: MB-FLOOR -9.965784284662087 ;       ( -60 dBFS )
:: MB-UP-SLOPE 0.5 ;                   ( UP 1 = 2:1 upward )
:: MB-FLUSH 1.0e-18 ;
:: MB-PK-LO 0.02 ;
:: MB-PK-MID 0.005 ;
:: MB-PK-HI 0.002 ;

( bp sr atk rel pk up -- : one band's derived coefficients. )
dsp: mb-band-prepare | bp:MbBandP sr atk rel pk up |
  bp.thresh-db 0.16609640474436813 f* | t |
  t -> bp.thresh-l2
  t MB-UP-BELOW f- -> bp.uthr-l2
  1.0 bp.ratio 1.0 fmax f/ 1.0 f- -> bp.slope
  up MB-UP-SLOPE f* -> bp.up-k
  atk sr comp-tau-coeff -> bp.atk-c
  rel sr comp-tau-coeff -> bp.rel-c
  pk sr comp-tau-coeff -> bp.pk-c
  bp.gain-db db>lin -> bp.gain-lin
;

( ctx state params -- )
dsp: k-multi-prepare | ctx:Ctx state params:MultiParams |
  ctx.sr | sr |
  params.atk-s | atk |
  params.rel-s | rel |
  params.up | up |
  params.lo&  sr atk 2.0 f* rel 2.0 f* MB-PK-LO  up mb-band-prepare
  params.mid& sr atk        rel        MB-PK-MID up mb-band-prepare
  params.hi&  sr atk 0.5 f* rel 0.5 f* MB-PK-HI  up mb-band-prepare
  params.xlo-hz sr svf-g -> params.g-lo
  params.xhi-hz sr svf-g -> params.g-hi
  params.out-db db>lin -> params.out-lin
;

( s x g -- lp bp hp : one Butterworth TPT SVF step [Zavalishin ch. 4]. )
dsp: mb-svf | s:MbSvf x g -- lp bp hp |
  s.s1 | s1 |
  s.s2 | s2 |
  1.0  MB-K g f*  f+  g g f*  f+ | den |
  x  MB-K g f+ s1 f*  f-  s2 f-  den f/ | hp |
  g hp f* | ghp |
  ghp s1 f+ | bp |
  g bp f* | gbp |
  gbp s2 f+ | lp |
  ( the states flushed below ~1e-34, so a decaying tail reaches 0
    instead of crawling through denormals )
  ghp bp f+  MB-FLUSH f+ MB-FLUSH f- -> s.s1
  gbp lp f+  MB-FLUSH f+ MB-FLUSH f- -> s.s2
  lp bp hp
;

( c x gl gh -- low mid high : one channel through the crossover. )
dsp: mb-split | c:MbChan x gl gh -- low mid high |
  c.a& x gl mb-svf nip | l0 h0 |
  c.b& l0 gl mb-svf drop drop | lraw |
  c.c& h0 gl mb-svf nip nip | rest |
  c.d& lraw gh mb-svf drop nip | bpd |
  lraw MB-2K bpd f* f- | low |
  c.e& rest gh mb-svf nip | m0 h1 |
  c.f& m0 gh mb-svf drop drop | mid |
  c.g& h1 gh mb-svf nip nip | high |
  low mid high
;

( b bp x -- gain : one band's detector, gain computer and smoothing;
  x = the louder channel's |sample|. )
dsp: mb-band | b:MbBand bp:MbBandP x -- gain |
  x  b.pk bp.pk-c f*  fmax | pk |
  pk -> b.pk
  pk -> b.lvl
  pk 0.000001 1000000.0 fclamp log2 | la |
  ( downward: comp.fy's soft knee )
  la bp.thresh-l2 f- | l |
  l MB-KNEE-HALF f+ | lh |
  lh lh f* MB-INV-KNEE2 f* | qk |
  l MB-KNEE-HALF  qk  l  fsel-lt | sel |
  l  0.0 MB-KNEE-HALF f-  0.0  sel  fsel-lt  bp.slope f* | down |
  ( upward: lift below uthr, capped, faded in from the floor )
  bp.uthr-l2 la f-  bp.up-k f* | lift0 |
  lift0  MB-UP-CAP fmin  la MB-FLOOR f-  fmin  0.0 fmax | lift |
  down lift f+ | gt |
  b.g | g0 |
  gt g0 bp.atk-c bp.rel-c fsel-lt | c |
  gt  g0 gt f-  c f*  f+ | g |
  g -> b.g
  g -6.0205999132796239 f* -> b.gr-db
  g exp2 bp.gain-lin f*
;

( io ctx state params -- : one stereo multi2 sample. )
dsp: k-multi-tick | io:Io ctx state:MultiState params:MultiParams -- |
  params.g-lo | gl |
  params.g-hi | gh |
  state.l& io.in-l gl gh mb-split | lol mdl hil |
  state.r& io.in-r gl gh mb-split | lor mdr hir |
  state.lo&  params.lo&  lol fabs lor fabs fmax  mb-band | klo |
  state.mid& params.mid& mdl fabs mdr fabs fmax  mb-band | kmd |
  state.hi&  params.hi&  hil fabs hir fabs fmax  mb-band | khi |
  params.out-lin params.mix f* | wet |
  1.0 params.mix f-  params.out-lin f* | dry |
  lol klo f*  mdl kmd f*  f+  hil khi f*  f+  wet f*
  lol mdl f+ hil f+  dry f*  f+ -> io.out-l
  lor klo f*  mdr kmd f*  f+  hir khi f*  f+  wet f*
  lor mdr f+ hir f+  dry f*  f+ -> io.out-r
;
