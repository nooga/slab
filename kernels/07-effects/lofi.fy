( lofi.fy - the cheap-gear stage: noise that pumps, sample-and-hold,
  bit depth, crunch, a coupling cap and a band limit.  Reusable: char2
  runs it after its compressor; a tape or sampler machine can too.

    TYPE    hold                bits        crunch         band
    ANALOG  -                   -           cubic, biased  HP 7 -> 63 Hz,
                                                           LP 20 -> 5 kHz
    90s     32 -> 16 kHz        16 -> 12    -              HP 10 Hz,
                                                           LP 0.45 hold
    80s     26.04 -> 13 kHz     12 -> 8     -              same
            [the SP-1200]

  across AMOUNT.  The digital types have no anti-alias filter in front
  of the hold: the aliasing is the sound.  ANALOG's crunch is a cubic
  soft clip run off-centre, f[u + b] - f[b], so it makes even harmonics
  as well as odd [the tanh + offset of a tube stage]; the coupling cap
  after it takes the DC that leaves, and closes in with AMOUNT the way
  small transformers and speakers lose the lows.

  NOISE is hiss added by lofi-noise wherever the owner wants it - char2
  adds it before its gain, so the compressor pumps it.  It is gated by a
  0.5 s follower of a level the owner passes, so the machine still goes
  idle, and runs only while AMOUNT is up.

  Off [AMOUNT 0] both words are skipped [ifte] and hold their state. )

include "../00-primitives/math.fy"
include "../04-filters/coeffs.fy"   ( svf-g )
include "../00-primitives/rand.fy"

ustruct: LofiState
  f64 nzl      ( noise generators, left and right )
  f64 nzr
  f64 nenv     ( noise gate: follower of the owner's level )
  f64 hph      ( sample-and-hold phase, 0..1 )
  f64 hl       ( held samples )
  f64 hr
  f64 cl       ( coupling-cap integrators )
  f64 cr
  f64 lp1l     ( low-pass integrators )
  f64 lp2l
  f64 lp1r
  f64 lp2r
;

ustruct: LofiParams
  ( user-facing )
  f64 amount   ( 0..1 )
  f64 type     ( 0 ANALOG, 1 90s, 2 80s )
  f64 noise    ( 0..1 )
  ( derived - lofi-prepare )
  f64 on
  f64 n-lvl    ( noise amplitude )
  f64 nenv-c
  f64 hold-r   ( hold rate / sample rate, 1 = no hold )
  f64 q        ( quantizer step, and its inverse )
  f64 iq
  f64 qmix     ( 1 quantize, 0 not )
  f64 cr-d     ( crunch drive, its inverse, and 1 = crunch on )
  f64 cr-id
  f64 cr-b     ( crunch bias, and the curve's value there )
  f64 cr-f0
  f64 cmix
  f64 hp-G     ( coupling cap, TPT one-pole gain )
  f64 lp-g
;

:: LOFI-NOISE-TAU 0.5 ;
:: LOFI-NOISE-OPEN 16.0 ;   ( the gate is fully open above -24 dBFS )
:: LOFI-BIAS 0.15 ;
:: LOFI-FLUSH 1.0e-18 ;

( t a n e -- x : the ANALOG, 90s or 80s value for type t. )
dsp: lofi-pick | t a n e -- x |
  t 0.5 a  t 1.5 n e fsel-lt  fsel-lt
;

( u -- y : the cubic soft clip, flat at +-2/3 past |u| = 1. )
dsp: lofi-cubic | u -- y |
  u -1.0 1.0 fclamp | c |
  c  c c f* c f* 0.3333333333333333 f*  f-
;

( sr lp -- )
dsp: lofi-prepare | sr lp:LofiParams |
  lp.amount | a |
  lp.type | ty |
  0.0 a f< 1.0 0.0 select -> lp.on
  ( noise: -72 dB at the bottom of the knob, -30 at the top, off at 0 )
  0.0 lp.noise f<  lp.noise 42.0 f* -72.0 f+ db>lin  0.0  select -> lp.n-lvl
  -1.0  LOFI-NOISE-TAU sr f*  f/ exp -> lp.nenv-c
  ( the hold rate halves across the knob; ANALOG doesn't hold )
  0.5 a pow | half |
  ty 0.0 32000.0 26040.0 lofi-pick half f* | fh |
  fh sr f/ 1.0 fmin | hr |
  ty 1.0 hr hr lofi-pick -> lp.hold-r
  ty 24.0  16.0 a 4.0 f* f-  12.0 a 4.0 f* f-  lofi-pick | bits |
  2.0  1.0 bits f-  pow | q |
  q -> lp.q
  1.0 q f/ -> lp.iq
  ty 0.0 1.0 1.0 lofi-pick -> lp.qmix
  1.0 a 3.0 f* f+ | d |
  d -> lp.cr-d
  1.0 d f/ -> lp.cr-id
  LOFI-BIAS -> lp.cr-b
  LOFI-BIAS lofi-cubic -> lp.cr-f0
  ty 1.0 0.0 0.0 lofi-pick -> lp.cmix
  ty  7.0 1.0 a 8.0 f* f+ f*  10.0 10.0 lofi-pick  3.141592653589793 f* sr f/ tan | hg |
  hg  1.0 hg f+  f/ -> lp.hp-G
  ( ANALOG closes 20 kHz -> 5 kHz; the digital types reconstruct at
    0.45 of their hold rate )
  ty  20000.0 0.25 a pow f*  fh 0.45 f*  fh 0.45 f*  lofi-pick  sr svf-g -> lp.lp-g
;

( ls lp lvl xl xr -- yl yr : the gated hiss added to a pair; lvl is
  the level that opens the gate [a detector, an envelope]. )
dsp: lofi-noise | ls:LofiState lp:LofiParams lvl xl xr -- yl yr |
  lp.on 0.5 f<
  [ xl xr ]
  [ ls.nenv LOFI-NOISE-OPEN f* 1.0 fmin lp.n-lvl f* | na |
    lvl  ls.nenv lp.nenv-c f*  fmax | ne |
    ne 1.0e-7 f<  0.0 ne select -> ls.nenv
    xl  ls.nzl& 12345.0 rand-b na f*  f+
    xr  ls.nzr& 67891.0 rand-b na f*  f+ ]
  ifte
;

( s1p s2p x g -- lp : one Butterworth low-pass step of a TPT SVF,
  states flushed below ~1e-34. )
dsp: lofi-lp-step | s1p s2p x g -- lp |
  s1p f@64 | s1 |
  s2p f@64 | s2 |
  1.4142135623730951 g f+ | a |
  1.0  1.4142135623730951 g f*  f+  g g f*  f+ | den |
  x  a s1 f*  f-  s2 f-  den f/ | hp |
  g hp f* | ghp |
  ghp s1 f+ | bp |
  ghp bp f+ LOFI-FLUSH f+ LOFI-FLUSH f-  s1p f!64
  g bp f*  s2 f+ | y |
  g bp f* y f+ LOFI-FLUSH f+ LOFI-FLUSH f-  s2p f!64
  y
;

( sp x G -- hp : the coupling cap, x minus a TPT one-pole low-pass. )
dsp: lofi-cap | sp x G -- y |
  sp f@64 | s |
  x s f- G f* | v |
  v s f+ | l |
  l v f+ LOFI-FLUSH f+ LOFI-FLUSH f-  sp f!64
  x l f-
;

( lp x -- y : quantize, then crunch; each is exactly x when off. )
dsp: lofi-crush | lp:LofiParams x -- y |
  x lp.iq f* 0.5 f+ floor lp.q f* | xq |
  x  xq x f-  lp.qmix f*  f+ | y1 |
  y1 lp.cr-d f* lp.cr-b f+ lofi-cubic  lp.cr-f0 f-  lp.cr-id f* | s |
  y1  s y1 f-  lp.cmix f*  f+
;

( ls lp xl xr -- yl yr : hold, crush, coupling cap, band limit. )
dsp: lofi-run | ls:LofiState lp:LofiParams xl xr -- yl yr |
  lp.on 0.5 f<
  [ xl xr ]
  [ ls.hph lp.hold-r f+ | p0 |
    p0 1.0 f>= | wrap |
    wrap  p0 1.0 f-  p0  select -> ls.hph
    wrap xl ls.hl select | hl |
    wrap xr ls.hr select | hr |
    hl -> ls.hl
    hr -> ls.hr
    ls.cl&  lp hl lofi-crush  lp.hp-G lofi-cap | cl |
    ls.cr&  lp hr lofi-crush  lp.hp-G lofi-cap | cr |
    ls.lp1l& ls.lp2l& cl lp.lp-g lofi-lp-step
    ls.lp1r& ls.lp2r& cr lp.lp-g lofi-lp-step ]
  ifte
;
