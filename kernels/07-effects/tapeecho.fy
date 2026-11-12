( tapeecho.fy - a loop of tape past one record head and four playback
  heads: a multi-head echo, a sound-on-sound loop, a held loop.

  The loop is LENGTH long at SPEED 1; the four heads sit a quarter, a
  half, three quarters and the whole way round it.  H1-H4 switch which
  are heard.  MODE says what is recorded again:
    ECHO   head 4 only: the whole loop comes round REPEAT quieter each
           pass, the other heads are taps inside it.  A long LENGTH with
           REPEAT near 1 is sound on sound: play over what is there
           while it slowly goes.
    SWELL  every head that is on, shared between them: the repeats fall
           between each other and smear into a wash, the drum echo's
           stand-in for a reverb.

  Everything recorded passes the tape: a 40 Hz coupling cap, TONE's
  12 dB/oct rolloff [it follows SPEED, and WEAR pulls it down], the tape
  curve [DRIVE; unity for small signals], so each repeat is duller and
  rounder than the last, and REPEAT may pass 1: the loop howls, bounded.

  The motor has mass.  LENGTH and SPEED move the loop time through a
  quarter-second lag, so the sound on the tape bends in pitch until the
  motor settles.  WOW and FLUTTER move every head's read together [one
  tape], more at the far heads, and since the repeats are re-recorded
  the wobble compounds.  WEAR makes the wow wander, adds dropouts
  [dropout.fy] and dulls each pass.

  HISS is on the playback and, half as loud, on what is recorded, so a
  long REPEAT gathers it.  POPS are specks on the tape, a few a second
  at most, and the splice, which ticks once every pass of the loop.
  Hiss and pops follow the level in the machine [open above -36 dBFS,
  shut in silence], so an idle track goes quiet and the host can skip it.

  FREEZE lifts the record and erase heads: the loop plays as it is, the
  input does not reach it, and nothing is lost per pass [the copy is at
  a whole number of samples].  The heads still read through the wow, and
  at WEAR above 0 the tape still sheds a little every pass.

  Four kinds of stage through state [docs/18 Composition]: the transport
  and noise, one per head, the record head, the output. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../00-primitives/rand.fy"
include "delay.fy"     ( dl-read, dl-read-int, dl-osc, dl-osc-seed )
include "dropout.fy"

:: TE-OPEN 64.0 ;      ( the noise gate is fully open above -36 dBFS )
:: TE-WOW-DEV 0.012 ;  ( pitch deviation at WOW 1, at the wow rate )
:: TE-FL-DEV 0.006 ;   ( ... at FLUTTER 1, at the flutter rate )
:: TE-WOW-HZ 0.7 ;
:: TE-FL-HZ 7.3 ;
:: TE-HISS-G 0.012 ;   ( white noise peak at HISS 1 )
:: TE-POP-G 0.06 ;     ( a speck's click at POPS 1 )

ustruct: TeState
  f64 bl  f64 bl-len  f64 br  f64 br-len   ( host-injected rings )
  f64 wpos
  f64 tz        ( the loop time the motor has reached, samples )
  f64 lph       ( where the splice is, 0..1 round the loop )
  f64 ws f64 wc f64 fs f64 fc              ( wow and flutter )
  f64 rng
  f64 d1 f64 d2                            ( the wow's wander )
  f64 md        ( the heads' displacement this sample, samples )
  f64 wl f64 wr ( what the heads hear, panned )
  f64 fl f64 fr ( what goes round again )
  f64 zl f64 zr ( FREEZE: the loop one whole pass ago )
  f64 nl f64 nr ( hiss and pops this sample )
  f64 hzl f64 hzr
  f64 pe f64 pz ( a pop's decay and its softening )
  f64 env       ( the level in the machine )
  f64 hpl f64 hpr f64 a1l f64 a2l f64 a1r f64 a2r   ( the record path )
  DropState drop
;

ustruct: TeParams
  f64 length f64 sync f64 div f64 speed
  f64 h1 f64 h2 f64 h3 f64 h4 f64 mode
  f64 repeat f64 tone f64 drive
  f64 wow f64 flutter f64 hiss f64 pops f64 wear
  f64 spread f64 mix f64 freeze
  ( derived - tapeecho-block-prepare )
  f64 t-spl     ( the loop time asked for, whole samples )
  f64 slew
  f64 wk f64 fk f64 wspl f64 fspl f64 da f64 dn
  f64 r1 f64 r2 f64 r3 f64 r4       ( a head is read: heard, or recorded again )
  f64 g1l f64 g1r f64 g2l f64 g2r f64 g3l f64 g3r f64 g4l f64 g4r
  f64 f1 f64 f2 f64 f3 f64 f4       ( its share of what is recorded again )
  f64 fb f64 hp-a f64 lp-a f64 sat-g f64 sat-ig
  f64 fz-w f64 fz-g f64 fz-a
  f64 hiss-g f64 pop-p f64 pop-g f64 splice-g f64 noise-on
  f64 env-c
  f64 drops-on
  DropParams dp
;

( on spread pos -- gl gr : a head's place in the stereo field. )
dsp: te-pan | on spread pos -- gl gr |
  pos spread f* | x |
  on 0.5 f> mask>f | g |
  1.0 x 0.0 fmax f- g f*
  1.0 x 0.0 fmin f+ g f*
;

dsp: tapeecho-block-prepare | ctx:Ctx state params:TeParams |
  ctx.sr | sr |
  60.0 ctx.tempo 20.0 999.0 fclamp f/ | beat |
  params.sync 0.5 f<  params.length  beat params.div f*  select | len |
  len params.speed f/ 0.02 8.0 fclamp sr f* 0.5 f+ floor -> params.t-spl
  1.0  -1.0 0.25 sr f* f/ exp  f- -> params.slew
  ( a deviation dev at f Hz is a swing of dev / [2 pi f] seconds )
  TE-WOW-HZ 6.283185307179586 f* sr f/ -> params.wk
  TE-FL-HZ 6.283185307179586 f* sr f/ -> params.fk
  params.wow dup f* TE-WOW-DEV f*  TE-WOW-HZ 6.283185307179586 f* f/  sr f* -> params.wspl
  params.flutter dup f* TE-FL-DEV f*  TE-FL-HZ 6.283185307179586 f* f/  sr f* -> params.fspl
  ( the wander: noise through two one-poles at the wow rate, brought to
    about unit deviation, more of it as the tape wears )
  1.0  TE-WOW-HZ -6.283185307179586 f* sr f/ exp  f- | da |
  da -> params.da
  ( uniform noise through two equal one-poles has variance a / 12 )
  0.3 params.wear 1.2 f* f+  12.0 da f/ fsqrt f* -> params.dn
  ( heads: 1 left, 2 right, 3 half left, 4 in the middle, by SPREAD )
  params.mode 0.5 f> | swell |
  params.h1 0.5 f> mask>f | o1 |  params.h2 0.5 f> mask>f | o2 |
  params.h3 0.5 f> mask>f | o3 |  params.h4 0.5 f> mask>f | o4 |
  o1 o2 f+ o3 f+ o4 f+ 1.0 fmax | n |
  swell o1 n f/ 0.0 select -> params.f1
  swell o2 n f/ 0.0 select -> params.f2
  swell o3 n f/ 0.0 select -> params.f3
  swell o4 n f/ 1.0 select -> params.f4
  o1 -> params.r1  o2 -> params.r2  o3 -> params.r3
  swell o4 1.0 select -> params.r4
  params.h1 params.spread -1.0 te-pan -> params.g1r -> params.g1l
  params.h2 params.spread 1.0 te-pan -> params.g2r -> params.g2l
  params.h3 params.spread -0.5 te-pan -> params.g3r -> params.g3l
  params.h4 params.spread 0.0 te-pan -> params.g4r -> params.g4l
  ( the record path )
  params.repeat -> params.fb
  40.0 6.283185307179586 f* sr f/ -> params.hp-a
  params.tone  params.speed f*  1.0 params.wear 0.5 f* f-  f*  300.0 18000.0 fclamp | fc |
  1.0  fc -6.283185307179586 f* sr f/ exp  f- -> params.lp-a
  params.drive 3.5 f* 0.5 f+ | g |
  g -> params.sat-g
  1.0 g f/ -> params.sat-ig
  ( a held loop: what a pass sheds at WEAR )
  params.wear 0.12 f* -> params.fz-w
  1.0 params.wear 0.01 f* f- -> params.fz-g
  1.0  5000.0 -6.283185307179586 f* sr f/ exp  f- -> params.fz-a
  ( noise )
  params.hiss dup f* TE-HISS-G f* -> params.hiss-g
  params.pops dup f* 4.0 f* sr f/ -> params.pop-p
  params.pops TE-POP-G f* -> params.pop-g
  params.pops 0.7 f* -> params.splice-g
  params.hiss 0.0 f>  params.pops 0.0 f>  or  mask>f -> params.noise-on
  -1.0 0.3 sr f* f/ exp -> params.env-c
  params.dp& | dp:DropParams |
  params.wear dup f* 2.5 f* -> dp.rate
  0.25 params.wear 0.6 f* f+ -> dp.depth
  sr dp drop-prepare
  params.wear 0.0 f> mask>f -> params.drops-on
;

( runs every block: start the oscillators at [0, 1] and seed the noise
  on fresh state. )
dsp: tapeecho-prepare | ctx state:TeState params:TeParams |
  state.ws state.wc dl-osc-seed -> state.wc
  state.fs state.fc dl-osc-seed -> state.fc
  state.rng& 3.0 rand-seed-once
  state.drop& 11.0 rand-seed-once   ( DropState.rng is its first cell )
;

( the transport: the motor, the wobble, the splice; the noise; clears
  the head sums. )
dsp: te-transport | io ctx s:TeState p:TeParams |
  ( fresh state starts at speed: a live loop time is never under 1 )
  s.tz 1.0 f<  p.t-spl s.tz select | tz0 |
  tz0  p.t-spl tz0 f- p.slew f*  f+ | tz1 |
  p.t-spl tz1 f- fabs 0.01 f<  p.t-spl tz1 select | tz |
  tz -> s.tz
  s.ws s.wc p.wk dl-osc | ws wc |
  ws -> s.ws  wc -> s.wc
  s.fs s.fc p.fk dl-osc | fs fc |
  fs -> s.fs  fc -> s.fc
  s.d1  s.rng& rand-b s.d1 f- p.da f*  f+ | d1 |
  s.d2  d1 s.d2 f- p.da f*  f+ | d2 |
  d1 -> s.d1  d2 -> s.d2
  ws d2 p.dn f* f+ p.wspl f*  fs p.fspl f*  f+ -> s.md
  s.lph 1.0 tz f/ f+ | ph |
  ph 1.0 f>= | splice |
  ph ffrac -> s.lph
  0.0 -> s.wl  0.0 -> s.wr  0.0 -> s.fl  0.0 -> s.fr
  s.bl& p@64 s.bl-len s.wpos tz dl-read-int -> s.zl
  s.br& p@64 s.br-len s.wpos tz dl-read-int -> s.zr
  p.noise-on 0.5 f>
  [ s.env TE-OPEN f* 1.0 fmin | gate |
    s.rng& rand-u | r |
    r p.pop-p f< | hit |
    r p.pop-p 1.0e-30 f+ f/ 0.0 1.0 fclamp 2.0 f* 1.0 f- | amp |
    hit  amp p.pop-g f*
      splice  p.splice-g p.pop-g f*  s.pe 0.86 f*  select
    select | pe |
    pe -> s.pe
    s.pz  pe s.pz f- 0.3 f*  f+ | pz |
    pz -> s.pz
    s.hzl  s.rng& rand-b s.hzl f- 0.7 f*  f+ | hl |
    s.hzr  s.rng& rand-b s.hzr f- 0.7 f*  f+ | hr |
    hl -> s.hzl  hr -> s.hzr
    hl p.hiss-g f* pz f+ gate f*
    hr p.hiss-g f* pz f+ gate f* ]
  [ 0.0 0.0 ]
  ifte -> s.nr -> s.nl
;

( state on gl gr f q -- : one head, q of the way round the loop. )
dsp: te-head | s:TeState gl gr f q -- |
  s.tz s.md f+ q f* | t |
  s.bl& p@64 s.bl-len s.wpos t dl-read | a |
  s.br& p@64 s.br-len s.wpos t dl-read | b |
  s.wl a gl f* f+ -> s.wl
  s.wr b gr f* f+ -> s.wr
  s.fl a f f* f+ -> s.fl
  s.fr b f f* f+ -> s.fr
;

dsp: te-head-1 | io ctx s:TeState p:TeParams |
  p.r1 0.5 f> [ s p.g1l p.g1r p.f1 0.25 te-head ] [ ] ifte ;
dsp: te-head-2 | io ctx s:TeState p:TeParams |
  p.r2 0.5 f> [ s p.g2l p.g2r p.f2 0.5 te-head ] [ ] ifte ;
dsp: te-head-3 | io ctx s:TeState p:TeParams |
  p.r3 0.5 f> [ s p.g3l p.g3r p.f3 0.75 te-head ] [ ] ifte ;
dsp: te-head-4 | io ctx s:TeState p:TeParams |
  p.r4 0.5 f> [ s p.g4l p.g4r p.f4 1.0 te-head ] [ ] ifte ;

( a state that has decayed to nothing is nothing: no denormals )
dsp: te-flush | x -- y |  x fabs 1.0e-18 f<  0.0 x select ;

( hp a1 a2 params x -- y : the tape, one channel: coupling cap, TONE
  twice, the curve. )
dsp: te-tape | hp a1 a2 p:TeParams x -- y |
  hp f@64  x hp f@64 f-  p.hp-a f*  f+ te-flush | h |
  h hp f!64
  x h f- | v |
  a1 f@64  v a1 f@64 f-  p.lp-a f*  f+ te-flush | a |
  a a1 f!64
  a2 f@64  a a2 f@64 f-  p.lp-a f*  f+ te-flush | b |
  b a2 f!64
  b p.sat-g f* -4.0 4.0 fclamp tanh-fast p.sat-ig f*
;

( the record head, and the write. )
dsp: te-record | io:Io ctx s:TeState p:TeParams |
  p.freeze 0.5 f<
  [ s.hpl& s.a1l& s.a2l& p  io.in-l  s.fl p.fb f* f+  s.nl 0.5 f* f+  te-tape
    s.hpr& s.a1r& s.a2r& p  io.in-r  s.fr p.fb f* f+  s.nr 0.5 f* f+  te-tape ]
  [ s.a1l  s.zl s.a1l f- p.fz-a f*  f+ | ll |
    s.a1r  s.zr s.a1r f- p.fz-a f*  f+ | lr |
    ll -> s.a1l  lr -> s.a1r
    s.zl  ll s.zl f- p.fz-w f*  f+ p.fz-g f*
    s.zr  lr s.zr f- p.fz-w f*  f+ p.fz-g f* ]
  ifte | xl xr |
  s.wpos | w |
  xl s.bl& p@64 w f!i
  xr s.br& p@64 w f!i
  w 1.0 f+ | w1 |
  w1 s.bl-len  w1  0.0  fsel-lt -> s.wpos
;

( dropouts, noise, the level the noise follows, the mix. )
dsp: te-out | io:Io ctx s:TeState p:TeParams |
  p.drops-on 0.5 f>
  [ s.drop& p.dp& s.wl s.wr drop-tick drop ]
  [ s.wl s.wr ]
  ifte | wl wr |
  io.in-l fabs io.in-r fabs fmax  wl fabs fmax  wr fabs fmax | lvl |
  lvl  s.env p.env-c f*  fmax | e |
  e 1.0e-7 f<  0.0 e select -> s.env
  1.0 p.mix f- | dry |
  io.in-l dry f*  wl s.nl f+ p.mix f*  f+ -> io.out-l
  io.in-r dry f*  wr s.nr f+ p.mix f*  f+ -> io.out-r
;

dsp: k-tapeecho-tick | io ctx state params |
  io ctx state params call: te-transport
  io ctx state params call: te-head-1
  io ctx state params call: te-head-2
  io ctx state params call: te-head-3
  io ctx state params call: te-head-4
  io ctx state params call: te-record
  io ctx state params call: te-out
;
