( delay.fy - stereo delay: two host-allocated rings, three routings,
  three characters.

  One true-stereo pass [manifest `stereo`] per sample.  The left and right
  rings share a write head.  The left tap sits at TIME [or the synced
  division]; the right at TIME * RATIO + OFFSET, so 1/8 against a dotted
  1/8 is RATIO 3:2, and a few ms of OFFSET is a Haas spread.

  MODE routes the rings:
    STEREO  L into the left ring, R into the right, each feeding back on
            itself - two independent delays.
    PING    the mono sum into the left ring only; the left ring's
            feedback goes to the right ring and the right's back to the
            left, so repeats bounce L, R, L ...
    WIDE    the mono sum into the left ring; the right output is a second
            tap on the same ring, at the right time.

  The feedback path per ring: LOW CUT one-pole highpass, HI CUT one-pole
  lowpass [DAMP], then the character stage on the write.  CHAR:
    DIGITAL  clean; a TIME change crossfades to the new tap over 30 ms,
             the way a digital delay jumps.  DRIVE above 0 adds a tanh
             stage in the loop.
    TAPE     the time slews [a TIME move bends pitch], wow and flutter on
             the read, tanh saturation and a 12 kHz rolloff on every pass.
    BBD      the time slews, no wow, saturation, and a lowpass that falls
             as the delay gets longer [a bucket brigade's clock slows].
  With saturation in the loop FB may pass 1 and self-oscillate, bounded;
  DIGITAL without DRIVE caps it at 0.99.

  MOD / RATE: a sine on the read time, quadrature between L and R.
  FREEZE: the input is muted and each ring loops its own contents at the
  integer delay, unfiltered.  DUCK pulls the wet down while the input
  [io.det, or a sidechain key] is loud.  WIDTH is mid/side on the wet.

  Every switch is an ifte on params [docs/05 §Branching]: only the chosen
  routing and character run.  Ring writes [f!i] stay outside the arms, so
  --no-branches if-converts cleanly. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/math.fy"  ( exp, for the rolloff coefficient )

( One ring and its filter states. )
ustruct: DlChan
  f64 buf      ( host-injected ring base pointer )
  f64 buf-len  ( host-injected element count )
  f64 ta       ( DIGITAL: time of the sounding tap, samples )
  f64 tb       ( DIGITAL: time of the tap being faded in )
  f64 fx       ( DIGITAL: fade progress 0..1, 1 = settled on tb )
  f64 tz       ( TAPE/BBD: slewed time, samples )
  f64 hp-z     ( LOW CUT state )
  f64 lp-z     ( HI CUT state )
  f64 d1       ( TAPE/BBD rolloff, two one-poles )
  f64 d2
;

ustruct: DelayState
  DlChan l
  DlChan r
  f64 wpos     ( shared write head, 0..len )
  f64 mod-s    ( MOD quadrature oscillator [magic circle] )
  f64 mod-c
  f64 wow-s    ( wow )
  f64 wow-c
  f64 fl-s     ( flutter )
  f64 fl-c
  f64 duck-e   ( DUCK envelope )
;

ustruct: DelayParams
  ( user-facing )
  f64 time-s    ( left time, s - used when sync is off )
  f64 feedback  ( 0..1.1 )
  f64 mix       ( dry/wet 0..1 )
  f64 damp-hz   ( HI CUT in the feedback path )
  f64 sync      ( switch: 0 free / 1 tempo-synced )
  f64 div       ( switch option value: beat multiplier, quarter = 1.0 )
  f64 mode      ( 0 STEREO, 1 PING, 2 WIDE )
  f64 ratio     ( right time / left time )
  f64 offset-s  ( added to the right time, s )
  f64 lowcut-hz ( LOW CUT in the feedback path )
  f64 drive     ( 0..1 loop saturation )
  f64 char      ( 0 DIGITAL, 1 TAPE, 2 BBD )
  f64 mod       ( 0..1 read modulation depth )
  f64 rate      ( modulation rate, Hz )
  f64 duck      ( 0..1 )
  f64 freeze    ( switch 0/1 )
  f64 width     ( wet mid/side width, 1 = as is )
  ( derived - filled by delay-block-prepare )
  f64 tl-spl    ( left time, samples )
  f64 tr-spl    ( right time, samples )
  f64 fb-eff
  f64 hp-a
  f64 damp-a
  f64 sat-g     ( loop drive gain and its inverse )
  f64 sat-ig
  f64 dark-a    ( TAPE/BBD rolloff one-pole coefficient )
  f64 mod-spl   ( MOD excursion, samples )
  f64 mod-k     ( oscillator steps, 2 pi f / sr )
  f64 wow-k
  f64 flut-k
  f64 wow-spl
  f64 flut-spl
  f64 xf-inc    ( DIGITAL crossfade step )
  f64 duck-atk
  f64 duck-rel
  f64 sr
;


( ctx state params -- : block-rate derived fill.  bpm is clamped to
  20..999 first so a zero/garbage tempo can't produce inf*0 = NaN. )
dsp: delay-block-prepare
  | ctx:Ctx state params:DelayParams |
  ctx.sr | sr |
  sr -> params.sr
  60.0 ctx.tempo 20.0 999.0 fclamp f/ | beat |
  params.sync 0.5 f<
    params.time-s
    beat params.div f* 0.02 1.5 fclamp
  select | tl |
  tl sr f* -> params.tl-spl
  tl params.ratio f* params.offset-s f+ 0.0 fmax sr f* -> params.tr-spl
  ( DIGITAL with no DRIVE has nothing to bound a runaway loop )
  params.char 0.5 f<  params.drive 0.0 f<=  and
    params.feedback 0.99 fmin  params.feedback  select
  -> params.fb-eff
  params.lowcut-hz 6.2831853 f* sr f/ 0.0 1.0 fclamp -> params.hp-a
  params.damp-hz 6.2831853 f* sr f/ 0.0 1.0 fclamp -> params.damp-a
  params.drive 3.5 f* 0.5 f+ | g |
  g -> params.sat-g
  1.0 g f/ -> params.sat-ig
  ( TAPE 12 kHz; BBD 683 Hz*s / time - a 4096-stage chip's clock/3 )
  params.char 1.5 f<
    12000.0
    683.0 tl 0.001 fmax f/ 1500.0 9000.0 fclamp
  select | fc |
  1.0  -6.2831853 fc f* sr f/ exp  f- -> params.dark-a
  params.mod 0.0015 f* sr f* -> params.mod-spl
  params.rate 6.2831853 f* sr f/ -> params.mod-k
  3.4557519 sr f/ -> params.wow-k    ( 0.55 Hz )
  39.584067 sr f/ -> params.flut-k   ( 6.3 Hz )
  params.char 0.5 f>  params.char 1.5 f<  and | tape |
  tape 0.0006 sr f* 0.0 select -> params.wow-spl
  tape 0.00005 sr f* 0.0 select -> params.flut-spl
  1.0 0.03 sr f* f/ -> params.xf-inc
  1.0 0.005 sr f* f/ -> params.duck-atk
  1.0 0.25 sr f* f/ -> params.duck-rel
;

( ctx state params -- : runs every block.  Seeds the taps at their
  targets on the first run after reset - a live time is always >= 4, so
  < 1 means fresh state, and the ramp-from-zero chirp is skipped. )
dsp: dl-seed | c:DlChan t -- |
  c.ta 1.0 f< | fa |
  fa t c.ta select -> c.ta
  fa t c.tb select -> c.tb
  fa 1.0 c.fx select -> c.fx
  c.tz 1.0 f<  t c.tz select -> c.tz
;

( c -- buf len : a ring's host-injected pointer and length. )
dsp: dl-ring | c:DlChan -- buf len |
  c.buf& p@64  c.buf-len
;

( s c -- c' : start a fresh oscillator at [0, 1]. )
dsp: dl-osc-seed | s c -- c1 |
  s fabs c fabs f+ 1.0e-9 f<  1.0 c  select
;

dsp: delay-prepare
  | ctx state:DelayState params:DelayParams |
  state.l& params.tl-spl dl-seed
  state.r& params.tr-spl dl-seed
  state.mod-s state.mod-c dl-osc-seed -> state.mod-c
  state.wow-s state.wow-c dl-osc-seed -> state.wow-c
  state.fl-s state.fl-c dl-osc-seed -> state.fl-c
;

( --- ring reads --------------------------------------------------------- )

( buf len w t -- y : 4-point Hermite read t samples behind the write head.
  t is clamped to 4 .. len-8, so every index is a live, already-written
  cell and none is the one this sample writes. )
dsp: dl-read | buf len w t -- y |
  t 4.0 len 8.0 f- fclamp | tc |
  w tc f- | p0 |
  p0 0.0  p0 len f+  p0 fsel-lt | p |
  p floor | i0 |
  p i0 f- | f |
  i0 1.0 f- | a0 |
  a0 0.0  a0 len f+  a0 fsel-lt | a |
  i0 1.0 f+ | b0 |
  b0 len  b0  b0 len f-  fsel-lt | b |
  i0 2.0 f+ | c0 |
  c0 len  c0  c0 len f-  fsel-lt | c |
  buf a f@i | xm |
  buf i0 f@i | x0 |
  buf b f@i | x1 |
  buf c f@i | x2 |
  x1 xm f- 0.5 f* | c1 |
  xm  x0 2.5 f* f-  x1 2.0 f* f+  x2 0.5 f* f- | c2 |
  x2 xm f- 0.5 f*  x0 x1 f- 1.5 f*  f+ | c3 |
  c3 f f* c2 f+ f f* c1 f+ f f* x0 f+
;

( buf len w t -- y : the cell exactly floor[t] behind the head, for FREEZE. )
dsp: dl-read-int | buf len w t -- y |
  t 4.0 len 8.0 f- fclamp floor | tc |
  w tc f- | p0 |
  buf  p0 0.0  p0 len f+  p0 fsel-lt  f@i
;

( c buf len w dt m -- y : DIGITAL.  When the target moves off the settled
  tap, start a 30 ms crossfade from the old tap to the new one; a target
  that keeps moving is picked up again once the fade completes. )
dsp: dl-read-digital | c:DlChan params:DelayParams buf len w dt m -- y |
  c.ta | ta |
  c.fx | fx |
  fx 1.0 f>=  dt ta f- fabs 0.5 f>  and | st |
  st dt c.tb select | tb |
  st 0.0 fx select params.xf-inc f+ 1.0 fmin | fx1 |
  tb -> c.tb
  fx1 -> c.fx
  fx1 1.0 f>= tb ta select -> c.ta
  buf len w ta m f+ dl-read | ya |
  buf len w tb m f+ dl-read | yb |
  ya  yb ya f-  fx1 f*  f+
;

( c buf len w dt m -- y : TAPE/BBD.  The time slews toward the target, so
  a TIME move bends pitch. )
dsp: dl-read-bend | c:DlChan buf len w dt m -- y |
  c.tz | tz0 |
  tz0  dt tz0 f- 0.0008 f*  f+ | tz |
  tz -> c.tz
  buf len w tz m f+ dl-read
;

( --- feedback path ------------------------------------------------------ )

( c params y -- f : LOW CUT then HI CUT on a ring's output. )
dsp: dl-fb-filter | c:DlChan params:DelayParams y -- f |
  c.hp-z | h0 |
  h0  y h0 f-  params.hp-a f*  f+ | h |
  h -> c.hp-z
  y h f- | hp |
  c.lp-z | z0 |
  z0  hp z0 f-  params.damp-a f*  f+ | z |
  z -> c.lp-z
  z
;

( params x -- y : loop saturation, unity gain for small signals. )
dsp: dl-sat | params:DelayParams x -- y |
  x params.sat-g f* tanh-fast params.sat-ig f*
;

( c params x -- y : TAPE/BBD write - saturation then the rolloff. )
dsp: dl-analog-write | c:DlChan params:DelayParams x -- y |
  params x dl-sat | s |
  c.d1 | a0 |
  a0  s a0 f-  params.dark-a f*  f+ | a |
  a -> c.d1
  c.d2 | b0 |
  b0  a b0 f-  params.dark-a f*  f+ | b |
  b -> c.d2
  b
;

( --- the tick ----------------------------------------------------------- )

( The LFOs are magic-circle oscillators: s += k c, c -= k s gives a
  quadrature pair for four flops, where sin2pi costs ten times that.
  Offsets are >= 0, added to the times. )

( s c k -- s1 c1 )
dsp: dl-osc | s c k -- s1 c1 |
  s k c f* f+ | s1 |
  s1  c k s1 f* f-
;

( state params -- ml mr : MOD in quadrature, wow and flutter shared
  [one tape]. )
dsp: dl-lfo-analog | state:DelayState params:DelayParams -- ml mr |
  state.mod-s state.mod-c params.mod-k dl-osc | ms mc |
  ms -> state.mod-s  mc -> state.mod-c
  state.wow-s state.wow-c params.wow-k dl-osc | ws wc |
  ws -> state.wow-s  wc -> state.wow-c
  state.fl-s state.fl-c params.flut-k dl-osc | fs fc |
  fs -> state.fl-s  fc -> state.fl-c
  ws 1.0 f+ params.wow-spl f*  fs 1.0 f+ params.flut-spl f*  f+ | wf |
  ms 1.0 f+ params.mod-spl f* wf f+
  mc 1.0 f+ params.mod-spl f* wf f+
;

dsp: dl-lfo-digital | state:DelayState params:DelayParams -- ml mr |
  state.mod-s state.mod-c params.mod-k dl-osc | ms mc |
  ms -> state.mod-s  mc -> state.mod-c
  ms 1.0 f+ params.mod-spl f*
  mc 1.0 f+ params.mod-spl f*
;

( io ctx state params -- : one stereo delay sample. )
dsp: k-delay-tick | io:Io ctx state:DelayState params:DelayParams -- |
  state.l& | cl |
  state.r& | cr |
  cl dl-ring | bl len |
  cr dl-ring drop | br |
  state.wpos | w |
  io.in-l | xl |
  io.in-r | xr |
  xl xr f+ 0.5 f* | xm |
  params.fb-eff | fb |
  ( reads: the character picks the tap behaviour )
  params.char 0.5 f<
  [ state params dl-lfo-digital | ml mr |
    cl params bl len w params.tl-spl ml dl-read-digital
    params.mode 1.5 f>
    [ cr params bl len w params.tr-spl mr dl-read-digital ]
    [ cr params br len w params.tr-spl mr dl-read-digital ]
    ifte ]
  [ state params dl-lfo-analog | ml mr |
    cl bl len w params.tl-spl ml dl-read-bend
    params.mode 1.5 f>
    [ cr bl len w params.tr-spl mr dl-read-bend ]
    [ cr br len w params.tr-spl mr dl-read-bend ]
    ifte ]
  ifte | yl yr |
  ( what goes back into the rings )
  params.freeze 0.5 f<
  [ cl params yl dl-fb-filter fb f* | fl |
    cr params yr dl-fb-filter fb f* | fr |
    params.mode 0.5 f<
    [ xl fl f+  xr fr f+ ]
    [ params.mode 1.5 f<
      [ xm fr f+  fl ]
      [ xm fl f+  0.0 ]
      ifte ]
    ifte | il ir |
    params.char 0.5 f<
    [ params.drive 0.0 f>
      [ params il dl-sat  params ir dl-sat ]
      [ il ir ]
      ifte ]
    [ cl params il dl-analog-write  cr params ir dl-analog-write ]
    ifte ]
  [ bl len w params.tl-spl dl-read-int | hl |
    br len w params.tr-spl dl-read-int | hr |
    params.mode 0.5 f<
    [ hl hr ]
    [ params.mode 1.5 f<  [ hr hl ]  [ hl 0.0 ]  ifte ]
    ifte ]
  ifte | wl wr |
  wl bl w f!i
  wr br w f!i
  w 1.0 f+ | w1 |
  w1 len  w1  0.0  fsel-lt -> state.wpos
  ( DUCK: a fast-attack follower on the dry level )
  io.det | det |
  state.duck-e | e0 |
  e0 det params.duck-atk params.duck-rel fsel-lt | k |
  e0  det e0 f-  k f*  f+ | e |
  e -> state.duck-e
  1.0  params.duck  e 3.0 f* 1.0 fmin  f*  f- params.mix f* | wg |
  ( WIDTH, mid/side )
  yl yr f+ 0.5 f* | m |
  yl yr f- 0.5 f* params.width f* | s |
  1.0 params.mix f- | dg |
  xl dg f*  m s f+ wg f*  f+ -> io.out-l
  xr dg f*  m s f- wg f*  f+ -> io.out-r
;
