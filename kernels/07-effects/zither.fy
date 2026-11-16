( zither.fy - ten steel strings over a pickup, driven three ways: by the
  input through a coil under all of them, and by two spinning discs of
  magnets held over them.

  A string is eight modes, each a two-pole resonator at k f0 with a
  little stiffness, heard as velocity at the pickup's point.  A mode's
  input is scaled by sin w, so a unit impulse rings at unit amplitude at
  any pitch.

  A disc's magnets pass the string one after another, so its pull is a
  train of narrow bumps at SPIN passes a second.  A slow disc makes long
  bumps that reach only the low modes; a fast one reaches the high ones.
  Where a harmonic of the pass rate lands on a mode, that string blooms.
  Each pass pulls a little differently and the motor wanders, which
  leaves a broadband part that keeps every string under the disc faintly
  alive.  HEIGHT sets the pull [inverse square], ACROSS which strings the
  disc sits over, ALONG where on their length.

  A string that is ringing hard takes less from what drives it [the
  drive falls with the string's own energy], so the level follows the
  cube root of the pull and nothing runs away at resonance.

  The render is four stages through state [docs/18 Composition]: the
  drives, strings 0-4, strings 5-9, the output. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../00-primitives/rand.fy"

:: Z-LIM 600.0 ;      ( how hard a ringing string refuses its drive )
:: Z-DISC-G 0.02 ;   ( a disc's pull at HEIGHT 0, per unit bump )
:: Z-COIL-G 0.05 ;   ( the coil at COIL 1 )
:: Z-WET-G 1.0 ;
:: Z-PLUCK-G 0.8 ;   ( a full-velocity pluck, per mode )
:: Z-DAMP 0.0012 ;   ( a damped string loses this share a sample )

ustruct: ZDisc f64 ph f64 amp f64 hp f64 wob ;

ustruct: ZState
  f64 y1 80  f64 y2 80
  f64 env 10
  ZDisc da  ZDisc db
  f64 rng
  f64 xc f64 fa f64 fb
  f64 accl f64 accr
  f64 tl f64 tr
  ( coefficients, set by block-prepare; too many for the params block )
  f64 c1 80  f64 c2 80  f64 win 80  f64 wa 80  f64 wb 80  f64 pk 80
  f64 gl 10  f64 gr 10
  f64 sa 8  f64 sb 8  f64 sp 8  f64 sc 8
  ( the played instrument [machines/zither]: each string's note, a pluck
    waiting for it, how hard a finger damps it, and the pluck's weights )
  f64 note 10  f64 pl 10  f64 dm 10
  f64 wpl 80  f64 sq 8
;

( a key of the played instrument: the string it plucked )
ustruct: ZVoice f64 si f64 age ;

ustruct: ZParams
  f64 tuning f64 root f64 ring f64 tone f64 coil
  f64 a-on f64 a-spin f64 a-height f64 a-across f64 a-along
  f64 b-on f64 b-spin f64 b-height f64 b-across f64 b-along
  f64 mix f64 out
  f64 pluck f64 damp
  ( derived )
  f64 a-inc f64 a-pull f64 b-inc f64 b-pull
  f64 coil-g f64 tone-k f64 gain f64 env-k
;

( tun a b c d e f g -- note : one string's note in the chosen tuning. )
dsp: z-tun | tun a b c d e f g -- n |
  tun 0.5 f< a  tun 1.5 f< b  tun 2.5 f< c  tun 3.5 f< d
  tun 4.5 f< e  tun 5.5 f< f  g
  select select select select select select
;

( ctx state params -- : what every string shares: the mode shapes at the
  discs, the pickup and the coil, the discs' rates and pulls, the gains. )
dsp: z-prep-misc | ctx:Ctx s:ZState p:ZParams |
  0.3 p.tone 0.22 f* f- | pp |
  0.0 8 [ | n |
    n 1.0 f+ | k |
    k p.a-along f* sinpi s.sa& n f!i
    k p.b-along f* sinpi s.sb& n f!i
    k pp f* sinpi s.sp& n f!i
    k 0.21 f* sinpi s.sc& n f!i
    ( the plectrum: near the bridge it reaches every mode, toward the
      middle the upper ones fall away )
    k  0.07 p.pluck 0.38 f* f+  f* sinpi  k  p.pluck 1.2 f* 0.3 f+  fneg pow  f* s.sq& n f!i
    n 1.0 f+ ] times drop
  p.a-spin ctx.inv-sr f* -> p.a-inc
  p.b-spin ctx.inv-sr f* -> p.b-inc
  Z-DISC-G  p.a-height 5.0 f* 1.0 f+ dup f*  f/ -> p.a-pull
  Z-DISC-G  p.b-height 5.0 f* 1.0 f+ dup f*  f/ -> p.b-pull
  p.coil dup f* Z-COIL-G f* -> p.coil-g
  1.0  p.tone 3.7 f* exp2 1200.0 f* -6.283185307179586 f* ctx.inv-sr f* exp  f- -> p.tone-k
  p.out db>lin -> p.gain
  ctx.inv-sr 20.0 f* -> p.env-k
;

( ctx state params si note -- : one string's eight modes.  Modes above 0.45 sr
  are left out, not folded. )
dsp: z-str-prep | ctx:Ctx s:ZState p:ZParams si note -- |
  note p.root 0.5 f+ floor f+ | note |
  note s.note& si f!i
  note 69.0 f- 12.0 f/ exp2 440.0 f* | f0 |
  ctx.sr | sr |
  f0 110.0 f/ fsqrt 0.0001 f* | bb |
  110.0 f0 f/ fsqrt fsqrt p.ring f* | t0 |
  si 9.0 f/ | pos |
  pos p.a-across f- | da |  da da f* -19.5 f* exp | wa |
  pos p.b-across f- | db |  db db f* -19.5 f* exp | wb |
  pos 0.5 f- 0.7 f* 0.5 f+ | pan |
  1.0 pan f- fsqrt s.gl& si f!i
  pan fsqrt s.gr& si f!i
  0.0 8 [ | n |
    n 1.0 f+ | k |
    si 8.0 f* n f+ | j |
    k k f* bb f* 1.0 f+ fsqrt k f* f0 f* | f |
    f sr 0.45 f* f< | ok |
    f sr 0.45 f* fmin 6.283185307179586 f* sr f/ | w |
    t0  n 0.1 f* 1.0 f+  n n f* 0.02 f* f+  f/ | t60 |
    -6.907755278982137 t60 sr f* f/ exp | r |
    w sin | sw |
    ok  r w cos f* 2.0 f*  0.0 select s.c1& j f!i
    ok  r r f* fneg  0.0 select s.c2& j f!i
    ok  s.sc& n f@i sw f*  0.0 select s.win& j f!i
    ok  s.sa& n f@i sw f* wa f*  0.0 select s.wa& j f!i
    ok  s.sb& n f@i sw f* wb f*  0.0 select s.wb& j f!i
    ok  s.sq& n f@i sw f*  0.0 select s.wpl& j f!i
    ( velocity at the pickup: the difference of two samples, brought back
      to the mode's own amplitude; the upper modes a little forward )
    ok  s.sp& n f@i k fsqrt f* 0.33 f*  w 0.5 f* sin 2.0 f* f/  0.0 select s.pk& j f!i
    n 1.0 f+ ] times drop
;

( The tunings, low string to high, as MIDI notes at ROOT 0:
  OPEN D, MINOR, PENTA, 5THS, LYDIAN, CLUSTER, and HARM - partials 2 to
  11 of D1, just. )
dsp: z-prep-0 | ctx:Ctx s:ZState p:ZParams |
  ctx s p 0.0  p.tuning 38.0 38.0 43.0 31.0 41.0 50.0 38.0 z-tun  z-str-prep ;
dsp: z-prep-1 | ctx:Ctx s:ZState p:ZParams |
  ctx s p 1.0  p.tuning 45.0 45.0 45.0 38.0 48.0 51.0 45.01955 z-tun  z-str-prep ;
dsp: z-prep-2 | ctx:Ctx s:ZState p:ZParams |
  ctx s p 2.0  p.tuning 50.0 50.0 48.0 43.0 53.0 53.0 50.0 z-tun  z-str-prep ;
dsp: z-prep-3 | ctx:Ctx s:ZState p:ZParams |
  ctx s p 3.0  p.tuning 57.0 53.0 50.0 50.0 55.0 55.0 53.86314 z-tun  z-str-prep ;
dsp: z-prep-4 | ctx:Ctx s:ZState p:ZParams |
  ctx s p 4.0  p.tuning 62.0 57.0 52.0 55.0 57.0 56.0 57.01955 z-tun  z-str-prep ;
dsp: z-prep-5 | ctx:Ctx s:ZState p:ZParams |
  ctx s p 5.0  p.tuning 66.0 60.0 55.0 62.0 59.0 58.0 59.68826 z-tun  z-str-prep ;
dsp: z-prep-6 | ctx:Ctx s:ZState p:ZParams |
  ctx s p 6.0  p.tuning 69.0 62.0 57.0 67.0 60.0 60.0 62.0 z-tun  z-str-prep ;
dsp: z-prep-7 | ctx:Ctx s:ZState p:ZParams |
  ctx s p 7.0  p.tuning 74.0 65.0 60.0 74.0 64.0 62.0 64.0391 z-tun  z-str-prep ;
dsp: z-prep-8 | ctx:Ctx s:ZState p:ZParams |
  ctx s p 8.0  p.tuning 78.0 69.0 62.0 79.0 67.0 63.0 65.86314 z-tun  z-str-prep ;
dsp: z-prep-9 | ctx:Ctx s:ZState p:ZParams |
  ctx s p 9.0  p.tuning 81.0 74.0 64.0 86.0 72.0 65.0 67.51318 z-tun  z-str-prep ;

dsp: zither-block-prepare | ctx state params |
  ctx state params call: z-prep-misc
  ctx state params call: z-prep-0
  ctx state params call: z-prep-1
  ctx state params call: z-prep-2
  ctx state params call: z-prep-3
  ctx state params call: z-prep-4
  ctx state params call: z-prep-5
  ctx state params call: z-prep-6
  ctx state params call: z-prep-7
  ctx state params call: z-prep-8
  ctx state params call: z-prep-9
;

( disc rng inc pull -- force : one disc's pull this sample.  The bump is
  [1 - u^2]^2 over an eighth of the pass either side of its centre; the
  steady part of the pull only bends the string, so it is taken out. )
dsp: z-disc | d:ZDisc rng inc pull -- f |
  d.wob  rng rand-b 0.0002 f* f+  d.wob 0.0005 f* f- | wob |
  wob -> d.wob
  d.ph  inc 1.0 wob f+ f*  f+ | ph |
  ph 1.0 f>= | wrap |
  ph ffrac | ph |
  ph -> d.ph
  wrap  rng rand-b 0.45 f* 1.0 f+  d.amp  select | amp |
  amp -> d.amp
  ph 0.5 f- 8.0 f* -1.0 1.0 fclamp | u |
  1.0 u u f* f- dup f* amp f* | b |
  d.hp  b d.hp f- 0.002 f* f+ | hp |
  hp -> d.hp
  b hp f- pull f*
;

dsp: z-drive | io:Io ctx s:ZState p:ZParams |
  io.in-l io.in-r f+ 0.5 f* p.coil-g f* -> s.xc
  p.a-on 0.5 f> [ s.da& s.rng& p.a-inc p.a-pull z-disc ] [ 0.0 ] ifte -> s.fa
  p.b-on 0.5 f> [ s.db& s.rng& p.b-inc p.b-pull z-disc ] [ 0.0 ] ifte -> s.fb
;

( state params xc fa fb al ar si -- al' ar' : string si, one sample,
  added into the left and right sums. )
dsp: z-string | s:ZState p:ZParams xc fa fb al ar si -- al2 ar2 |
  s.env& si f@i | env |
  1.0  env Z-LIM f* 1.0 f+  f/ | g |
  xc g f* | xg |  fa g f* | fg |  fb g f* | hg |
  s.pl& si f@i | pl |
  1.0 s.dm& si f@i f- | keep |
  0.0 0.0 8 [ | d n |
    si 8.0 f* n f+ | j |
    s.y1& j f@i | y1 |
    s.c1& j f@i y1 f*  s.c2& j f@i s.y2& j f@i f*  f+
      s.win& j f@i xg f* f+  s.wa& j f@i fg f* f+  s.wb& j f@i hg f* f+
      keep f*  s.wpl& j f@i pl f* f+ | y |
    y s.y1& j f!i  y1 s.y2& j f!i
    y y1 f- s.pk& j f@i f* d f+
    n 1.0 f+ ] times drop | d |
  env  d d f* env f- p.env-k f*  f+ s.env& si f!i
  0.0 s.pl& si f!i
  al  d s.gl& si f@i f*  f+
  ar  d s.gr& si f@i f*  f+
;

dsp: z-strings-a | io ctx s:ZState p:ZParams |
  s.xc s.fa s.fb | xc fa fb |
  s.accl s.accr 0.0 5 [ | al ar si |  s p xc fa fb al ar si z-string  si 1.0 f+ ] times drop
  | al ar |  al -> s.accl  ar -> s.accr
;
dsp: z-strings-b | io ctx s:ZState p:ZParams |
  s.xc s.fa s.fb | xc fa fb |
  s.accl s.accr 5.0 5 [ | al ar si |  s p xc fa fb al ar si z-string  si 1.0 f+ ] times drop
  | al ar |  al -> s.accl  ar -> s.accr
;

( the pickup's tone, a soft ceiling, the mix; clears the sample's sums. )
dsp: z-out | io:Io ctx s:ZState p:ZParams |
  s.tl  s.accl s.tl f- p.tone-k f*  f+ | tl |
  s.tr  s.accr s.tr f- p.tone-k f*  f+ | tr |
  tl -> s.tl  tr -> s.tr
  tl Z-WET-G f* -4.0 4.0 fclamp tanh-fast | wl |
  tr Z-WET-G f* -4.0 4.0 fclamp tanh-fast | wr |
  io.in-l 1.0 p.mix f- f*  wl p.mix f*  f+ p.gain f* -> io.out-l
  io.in-r 1.0 p.mix f- f*  wr p.mix f*  f+ p.gain f* -> io.out-r
  0.0 -> s.accl  0.0 -> s.accr
;

dsp: k-zither-tick | io ctx state params |
  io ctx state params call: z-drive
  io ctx state params call: z-strings-a
  io ctx state params call: z-strings-b
  io ctx state params call: z-out
;

( --- the played instrument [machines/zither] ------------------------
  The strings live in the machine's shared region [docs/04 Shared
  state]; a key is a voice that only plucks.  A note plucks the string
  nearest its pitch, harder with velocity; with DAMP on, letting go
  lays a finger on it. )

dsp: zither-note-on | ctx:Ctx v:ZVoice p:ZParams |
  ctx.shared& p@64 | s:ZState |
  ctx.pitch | pt |
  0.0 1000.0 0.0 10 [ | best bd i |
    s.note& i f@i pt f- fabs | d |
    d bd f<  i best select
    d bd fmin
    i 1.0 f+ ] times drop2 | si |
  si -> v.si
  s.pl& si f@i  ctx.vel dup f* Z-PLUCK-G f*  f+  s.pl& si f!i
  0.0 s.dm& si f!i
;

dsp: zither-note-off | ctx:Ctx v:ZVoice p:ZParams |
  ctx.shared& p@64 | s:ZState |
  p.damp 0.5 f>  Z-DAMP  s.dm& v.si f@i  select  s.dm& v.si f!i
;

( a key makes no sound of its own )
dsp: k-zither-voice | io ctx v:ZVoice params |  v.age 1.0 f+ -> v.age ;

dsp: zi-prep-misc | ctx:Ctx st p |  ctx ctx.shared& p@64 p z-prep-misc ;
dsp: zi-prep-0 | ctx:Ctx st p |  ctx ctx.shared& p@64 p z-prep-0 ;
dsp: zi-prep-1 | ctx:Ctx st p |  ctx ctx.shared& p@64 p z-prep-1 ;
dsp: zi-prep-2 | ctx:Ctx st p |  ctx ctx.shared& p@64 p z-prep-2 ;
dsp: zi-prep-3 | ctx:Ctx st p |  ctx ctx.shared& p@64 p z-prep-3 ;
dsp: zi-prep-4 | ctx:Ctx st p |  ctx ctx.shared& p@64 p z-prep-4 ;
dsp: zi-prep-5 | ctx:Ctx st p |  ctx ctx.shared& p@64 p z-prep-5 ;
dsp: zi-prep-6 | ctx:Ctx st p |  ctx ctx.shared& p@64 p z-prep-6 ;
dsp: zi-prep-7 | ctx:Ctx st p |  ctx ctx.shared& p@64 p z-prep-7 ;
dsp: zi-prep-8 | ctx:Ctx st p |  ctx ctx.shared& p@64 p z-prep-8 ;
dsp: zi-prep-9 | ctx:Ctx st p |  ctx ctx.shared& p@64 p z-prep-9 ;

dsp: zither-inst-block-prepare | ctx state params |
  ctx state params call: zi-prep-misc
  ctx state params call: zi-prep-0
  ctx state params call: zi-prep-1
  ctx state params call: zi-prep-2
  ctx state params call: zi-prep-3
  ctx state params call: zi-prep-4
  ctx state params call: zi-prep-5
  ctx state params call: zi-prep-6
  ctx state params call: zi-prep-7
  ctx state params call: zi-prep-8
  ctx state params call: zi-prep-9
;

( no coil: only the discs and the plucks drive the strings )
dsp: zi-drive | io ctx s:ZState p:ZParams |
  0.0 -> s.xc
  p.a-on 0.5 f> [ s.da& s.rng& p.a-inc p.a-pull z-disc ] [ 0.0 ] ifte -> s.fa
  p.b-on 0.5 f> [ s.db& s.rng& p.b-inc p.b-pull z-disc ] [ 0.0 ] ifte -> s.fb
;

( the pickup added to the out lanes, as a voice would )
dsp: zi-out | io:Io ctx s:ZState p:ZParams |
  s.tl  s.accl s.tl f- p.tone-k f*  f+ | tl |
  s.tr  s.accr s.tr f- p.tone-k f*  f+ | tr |
  tl -> s.tl  tr -> s.tr
  io.out-l  tl Z-WET-G f* -4.0 4.0 fclamp tanh-fast p.gain f*  f+ -> io.out-l
  io.out-r  tr Z-WET-G f* -4.0 4.0 fclamp tanh-fast p.gain f*  f+ -> io.out-r
  0.0 -> s.accl  0.0 -> s.accr
;

dsp: k-zither-shared | io ctx state params |
  io ctx state params call: zi-drive
  io ctx state params call: z-strings-a
  io ctx state params call: z-strings-b
  io ctx state params call: zi-out
;
