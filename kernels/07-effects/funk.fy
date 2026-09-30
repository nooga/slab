( funk.fy - FUNK OVERLOAD: an envelope wah that turns into an MS-20,
  on one knob.  RANGE [BASS / GTR / KEYS] sets where the filter sits.

    FUNK 0          bypass [the host runs k-funk-tick-thru, bit-exact]
    FUNK 0 .. 0.4   touch wah: the sweep grows to 2 octaves, the
                    response morphs from a peak on the dry signal into
                    a resonant lowpass
    FUNK .4 .. .75  squeeze: notes levelled before the filter, more
                    resonance, a faster envelope, 3 octaves
    FUNK .75 .. 1   overload: crossfades into the MS-20 HOT lowpass
                    [ms20_lpf.fy], drive 1 -> 2 and resonance 0.6 -> 1.6
                    [the ms20 machine's acid presets' range] - at the
                    top it self-oscillates and screams on every note

  Everything is relative to the input's own level, so the knob does the
  same thing to a part at -6 dBFS and at -24:

    ms-f   mean square of the louder channel, attack 1.5 ms, release REL
    ms-s   the same followed over 0.6 s - the part's running level
    r      = log2 of the amplitude ratio  sqrt[ms-f / ms-s]
    sweep  = [r + 1] / 2, clamped 0..1:  closed at 6 dB under the running
             level, fully open 6 dB over it.  A note opens the filter by
             how hard it hits compared to the notes around it.

  The filter morph uses the SVF identity  x = lp + k bp + hp:
  y = L lp + B k bp + H hp  is the input exactly at L = B = H = 1, and
  moves continuously to a resonant lowpass [H 0, B up] with no comb.
  RANGE also thins the low end at KEYS [L < 1] into a bandpass quack.

  The squeeze is a leveller on the same detector: above the running
  level it takes SQ log2 per log2 [0.75 at the top = 4:1, at most 12 dB
  over the level, so the first note after a rest isn't crushed],
  smoothed at 1.5 ms / 80 ms.

  The MS-20 is fed the input over its running level, so its drive is
  the knob's, not the track's; the output is scaled back.  The whole
  filter stage runs at 4x [up4 / dec4] - the MS-20 needs it, and the
  SVF runs alongside so the crossfade is phase-aligned.

  Auto-gain: 0.4 s mean squares of the input and the filter output set a
  gain [log2, followed at the same pace from unity, clamped +-12 dB,
  frozen under -70 dBFS so tails and noise stay put], so turning the
  knob changes the sound, not the level.  Measured on clav, bass and
  e-piano stems: within 1 dB at every setting and range.

  The output guard is a soft knee on the input's own peak envelope
  [instant attack, 50 ms release]: the output peaks at most 3 dB over
  the input's, so a note's onset - the filter sweeping open before the
  squeeze lands - can't click, and the MS-20's scream dies with the
  playing.  A last soft ceiling above -3 dBFS keeps a hot part legal.

  True stereo, one linked detector: L and R wah together. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/math.fy"
include "../00-primitives/oversample.fy"
include "../04-filters/coeffs.fy"   ( svf-g )
include "../04-filters/ms20_lpf.fy"

ustruct: FunkSvf f64 s1 f64 s2 ;

ustruct: FunkChan
  FunkSvf svf
  Ms20Lpf ms
  Up4 up
  Dec4 dn
;

ustruct: FunkState
  f64 ms-f     ( fast mean square, linked )
  f64 ms-s     ( slow mean square - the running level )
  f64 sweep    ( smoothed 0..1 )
  f64 sq       ( squeeze gain, log2, <= 0 )
  f64 ag-x     ( auto-gain: input mean square )
  f64 ag-y     ( ... filter output mean square )
  f64 ag-g     ( the gain, log2, smoothed from 0 )
  f64 pk       ( input peak envelope - the guard's )
  FunkChan l
  FunkChan r
;

ustruct: FunkParams
  ( user-facing )
  f64 funk     ( the macro, 0..1 )
  f64 range    ( 0 BASS, 1 GTR, 2 KEYS )
  ( derived - filled by funk-block-prepare )
  f64 osr
  f64 lat      ( latency: the 4x halfband pair's )
  f64 base-hz
  f64 oct      ( sweep depth, octaves )
  f64 k        ( SVF damping term, 1/Q )
  f64 wb       ( B k: the bandpass weight )
  f64 wh       ( H )
  f64 wl       ( L )
  f64 sq-k
  f64 atk-c
  f64 rel-c
  f64 slow-c
  f64 sm-c     ( sweep smoothing )
  f64 sqa-c
  f64 sqr-c
  f64 ag-c
  f64 pk-c
  f64 w3       ( MS-20 share )
  Ms20LpfProfile pr
;

:: FUNK-FLOOR 1.0e-9 ;      ( mean-square floor, -90 dBFS )
:: FUNK-AG-FLOOR 1.0e-7 ;   ( auto-gain freezes under -70 dBFS )
:: FUNK-AG-SEED 1.0e-5 ;    ( -50 dBFS in both means: the gain starts at 1 )
:: FUNK-MS-IN 0.2 ;        ( MS-20 input, x the running level's inverse )
:: FUNK-MS-OUT 3.0 ;        ( and back )
:: FUNK-FLUSH 1.0e-18 ;
:: FUNK-PK-FLOOR 1.0e-9 ;   ( the guard in silence: the MS-20 may still ring, nobody hears it )
:: FUNK-GUARD-SPAN 0.4125375446227544 ;   ( +3 dB over the input peak at most )
:: FUNK-CEIL 0.7079457843841379 ;   ( -3 dBFS )
:: FUNK-CEIL-SPAN 0.2920542156158621 ;

( t sr -- c : one-pole coefficient for time constant t [63 %]. )
dsp: funk-tau | t sr -- c |
  -1.0  t 0.00001 fmax sr f*  f/ exp
;

( m a b c -- x : the BASS, GTR or KEYS value for range m. )
dsp: funk-pick | m a b c -- x |
  m 0.5 a  m 1.5 b c fsel-lt  fsel-lt
;

( x lo span -- w : [x - lo] / span, clamped 0..1. )
dsp: funk-ramp | x lo span -- w |
  x lo f-  span f/  0.0 1.0 fclamp
;

( ctx state params -- : the knob and RANGE mapped onto the stages. )
dsp: funk-block-prepare | ctx:Ctx state params:FunkParams |
  ctx.sr | sr |
  4.0 sr f* | osr |
  osr -> params.osr
  OS4-LATENCY -> params.lat
  params.funk | f |
  params.range | m |
  f 0.0 0.4 funk-ramp | w1 |
  f 0.4 0.35 funk-ramp | w2 |
  f 0.75 0.25 funk-ramp | w3 |
  w3 -> params.w3
  m 180.0 400.0 700.0 funk-pick -> params.base-hz
  w1 2.0 f*  w2 f+  w3 0.5 f* f+ -> params.oct
  0.7071  w1 1.5 f* f+  w2 0.8 f* f+  w3 f+ | q |
  1.0 q f/ | k |
  k -> params.k
  1.0  w1 0.3 f* f+  k f* -> params.wb
  1.0  w1 0.8 f* f-  w2 0.2 f* f-  0.0 fmax -> params.wh
  1.0  1.0  m 1.0 0.7 0.4 funk-pick f-  w1 f*  f- -> params.wl
  w2 0.5 f*  w3 0.25 f* f+ -> params.sq-k
  0.0015 sr funk-tau -> params.atk-c
  0.12  w2 0.05 f* f-  w3 0.03 f* f-  sr funk-tau -> params.rel-c
  0.6 sr funk-tau -> params.slow-c
  0.003 sr funk-tau -> params.sm-c
  0.0015 sr funk-tau -> params.sqa-c
  0.08 sr funk-tau -> params.sqr-c
  0.4 sr funk-tau -> params.ag-c
  0.05 sr funk-tau -> params.pk-c
  params.pr&  1.0 w3 f+  0.6 w3 f+  0.0 osr  ms20-lpf-set
;

( st p q -- r : the linked detector; r = log2 [fast / running level]
  as amplitude. )
dsp: funk-detect | st:FunkState p:FunkParams q -- r |
  st.ms-f | f0 |
  f0 q p.rel-c p.atk-c fsel-lt | c |
  q  f0 q f-  c f*  f+ | mf |
  mf FUNK-FLUSH f+ FUNK-FLUSH f- -> st.ms-f
  mf  st.ms-s mf f-  p.slow-c f*  f+ | msl |
  msl FUNK-FLUSH f+ FUNK-FLUSH f- -> st.ms-s
  mf FUNK-FLOOR f+  msl FUNK-FLOOR f+  f/ log2 0.5 f*
;

( st p r -- g sq : the sweep's filter g at the 4x rate and the squeeze
  gain [linear]. )
dsp: funk-steer | st:FunkState p:FunkParams r -- g sq |
  ( closed in silence: there the ratio reads 0 dB, not "quiet" )
  st.ms-f FUNK-AG-FLOOR  0.0  r 1.0 f+ 0.5 f*  0.0 1.0 fclamp  fsel-lt | t |
  t  st.sweep t f-  p.sm-c f*  f+ | s |
  s -> st.sweep
  0.0  r 0.0 2.0 fclamp p.sq-k f*  f- | gt |
  st.sq | g0 |
  gt g0 p.sqa-c p.sqr-c fsel-lt | c |
  gt  g0 gt f-  c f*  f+ | gq |
  gq -> st.sq
  p.base-hz  p.oct s f* exp2  f*  p.osr svf-g
  gq exp2
;

( s x g k -- lp bp hp : one TPT SVF step at damping term k. )
dsp: funk-svf | s:FunkSvf x g k -- lp bp hp |
  s.s1 | s1 |
  s.s2 | s2 |
  x  k g f+ s1 f*  f-  s2 f-   1.0 k g f* f+  g g f* f+  f/ | hp |
  g hp f* | ghp |
  ghp s1 f+ | bp |
  g bp f* | gbp |
  gbp s2 f+ | lp |
  ghp bp f+  FUNK-FLUSH f+ FUNK-FLUSH f- -> s.s1
  gbp lp f+  FUNK-FLUSH f+ FUNK-FLUSH f- -> s.s2
  lp bp hp
;

( c p x g ref iref -- y : one 4x substep - the SVF morph and the MS-20,
  crossfaded. )
dsp: funk-sub | c:FunkChan p:FunkParams x g ref iref -- y |
  c.svf& x g p.k funk-svf | lp bp hp |
  lp p.wl f*  bp p.wb f* f+  hp p.wh f* f+ | y1 |
  ( the MS-20's share is 0 below FUNK 0.75: it doesn't run there, and
    rests at zero so it fades in from rest, not from a stale state )
  p.w3 0.0 f=
  [ c.ms& | m:Ms20Lpf |  0.0 -> m.ic1  0.0 -> m.ic2  0.0 -> m.fb-dc  0.0 -> m.out-dc
    y1 ]
  [ c.ms& p.pr&  x iref f* FUNK-MS-IN f*  g  ms20-lpf-step  ref f* FUNK-MS-OUT f* | y2 |
    y1  y2 y1 f-  p.w3 f*  f+ ]  ifte
;

( c p x g ref iref -- y : one channel, 1x in and out. )
dsp: funk-chan | c:FunkChan p:FunkParams x g ref iref -- y |
  c.up& x up4 | u0 u1 u2 u3 |
  c p u0 g ref iref funk-sub | y0 |
  c p u1 g ref iref funk-sub | y1 |
  c p u2 g ref iref funk-sub | y2 |
  c p u3 g ref iref funk-sub | y3 |
  c.dn& y0 y1 y2 y3 dec4
;

( st p xl xr yl yr -- g : the auto-gain. )
dsp: funk-level | st:FunkState p:FunkParams xl xr yl yr -- g |
  xl xl f*  xr xr f* f+  0.5 f* | qx |
  yl yl f*  yr yr f* f+  0.5 f* | qy |
  st.ag-x | ax0 |
  ( frozen while the input's fast level is under the floor )
  st.ms-f FUNK-AG-FLOOR  1.0 p.ag-c  fsel-lt | c |
  qx  ax0 qx f-  c f*  f+ | ax |
  qy  st.ag-y qy f-  c f*  f+ | ay |
  ax FUNK-FLUSH f+ FUNK-FLUSH f- -> st.ag-x
  ay FUNK-FLUSH f+ FUNK-FLUSH f- -> st.ag-y
  ax FUNK-AG-SEED f+  ay FUNK-AG-SEED f+  f/ log2 0.5 f*  -2.0 2.0 fclamp | gt |
  ( the gain itself follows at the same pace, from unity: the first
    milliseconds' ratio never reaches the output )
  gt  st.ag-g gt f-  c f*  f+ | g |
  g -> st.ag-g
  g exp2
;

( y t s -- z : a soft knee - untouched up to t, then a tanh-rational
  shoulder that reaches t + s far past it. )
dsp: funk-knee | y t s -- z |
  y fabs | a |
  a t f-  s f/  0.0 fmax tanh-rational s f*  t f+ | c |
  a t  a c fsel-lt | m |
  0.0 y  m 0.0 m f-  fsel-lt
;

( y pk -- z : the output guard, then the ceiling.  The guard follows the
  input's own peak envelope, so a note's onset - the filter sweeping open
  before the squeeze lands - peaks at most 3 dB over the input's; the
  ceiling leaves everything under -3 dBFS alone. )
dsp: funk-guard | y pk -- z |
  y  pk  pk FUNK-GUARD-SPAN f*  funk-knee  FUNK-CEIL FUNK-CEIL-SPAN funk-knee
;

( io ctx state params -- : one stereo FUNK OVERLOAD sample. )
dsp: k-funk-tick | io:Io ctx state:FunkState params:FunkParams -- |
  io.in-l | xl |
  io.in-r | xr |
  xl fabs xr fabs fmax | a |
  state params a a f* funk-detect | r |
  state params r funk-steer | g sq |
  state.ms-s FUNK-FLOOR f+ fsqrt | ref |
  1.0 ref f/ | iref |
  state.l& params xl sq f* g ref iref funk-chan | yl |
  state.r& params xr sq f* g ref iref funk-chan | yr |
  state params xl xr yl yr funk-level | ag |
  a  state.pk params.pk-c f*  fmax | pk |
  pk FUNK-FLUSH f+ FUNK-FLUSH f- -> state.pk
  pk FUNK-PK-FLOOR f+ | gp |
  yl ag f* gp funk-guard -> io.out-l
  yr ag f* gp funk-guard -> io.out-r
;

( io ctx state params -- : FUNK 0 - the input through untouched; the
  detector and the auto-gain's input side keep running so turning the
  knob up doesn't start from stale levels [render-lite]. )
dsp: k-funk-tick-thru | io:Io ctx state:FunkState params:FunkParams -- |
  io.in-l | xl |
  io.in-r | xr |
  xl fabs xr fabs fmax | a |
  state params a a f* funk-detect drop
  state params xl xr xl xr funk-level drop
  xl -> io.out-l
  xr -> io.out-r
;
