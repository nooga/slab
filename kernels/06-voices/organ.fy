( organ.fy - a tonewheel organ: 91 wheels that never stop, nine drawbars,
  key contacts, percussion, a scanner vibrato and a valve preamp.

  The wheels are the machine's, not the note's.  Each is a sine a
  semitone above the last, C1 [32.7 Hz] to F#7 [5.9 kHz], turning from
  the moment the machine loads, so two keys that reach the same wheel
  get the same phase and a chord is one waveform, not a sum of voices.
  They live in the shared region [docs/04 Shared state] and run once a
  sample however many keys are down.

  A key is nine contacts, one per drawbar: 16', 5 1/3', 8', 4', 2 2/3',
  2', 1 3/5', 1 1/3', 1', which is the sub-octave, its fifth, and
  harmonics 1 2 3 4 5 6 8 of the key.  A contact that asks for a wheel
  above the top or below the bottom gets the one an octave in [fold-
  back].  The contacts close one after another as the key goes down,
  faster the harder it is struck, each at whatever point its wheel has
  reached: that is the key click, and CLICK sets how abruptly a contact
  makes.

  PERC is one decaying note of the key's 2nd or 3rd harmonic.  It fires
  only when a key goes down with none held, and every key held shares
  the one decay, so legato lines have it on the first note alone.

  The scanner vibrato is a short delay line read at a point that sweeps
  6.9 times a second: V1-V3 are three depths, C1-C3 the same mixed with
  the straight signal.  LEAK is the wheels heard through the wiring
  while a key is down.  DRIVE is the preamp.

  Stages through state [docs/18 Composition]: seven groups of 13 wheels,
  the mix, the scanner, the preamp. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../07-effects/delay.fy"     ( dl-read, dl-osc, dl-osc-seed )

:: OR-G 0.06 ;        ( one contact at drawbar 8 )
:: OR-VIB-HZ 6.87 ;
:: OR-RING 512.0 ;    ( the scanner's line, samples )

ustruct: OrState
  f64 ws 91  f64 wc 91     ( the wheels: magic-circle oscillators )
  f64 wk 91                ( their rates )
  f64 wt 91                ( the taper: the top wheels are quieter )
  f64 wl 91                ( how much of each leaks )
  f64 wo 91                ( what a contact picks up this sample )
  f64 lk                   ( the leak, summed over the wheels )
  f64 bus f64 pbus         ( the keys' sum, the percussion's; cleared each sample )
  f64 held f64 held-z      ( keys down this sample, and the one before )
  f64 kenv                 ( a key is down, smoothed )
  f64 ptrig f64 pe         ( percussion: fire, and its decay )
  f64 x f64 y              ( between the stages )
  f64 vb 512  f64 vw       ( the scanner's line and its write head )
  f64 vs f64 vc            ( the scanner's sweep )
;

( a key: its nine wheels, the two the percussion can take, its travel )
ustruct: OrVoice
  f64 w 9
  f64 wp2 f64 wp3
  f64 age f64 rel f64 off  ( samples since down, since up; 1 once up )
  f64 stag                 ( samples between one contact and the next )
  f64 lvl                  ( the loudest contact, for idle skipping )
;

ustruct: OrParams
  f64 d16 f64 d513 f64 d8 f64 d4 f64 d223 f64 d2 f64 d135 f64 d113 f64 d1
  f64 perc f64 pharm f64 pfast f64 psoft
  f64 vib f64 click f64 leak f64 drive f64 volume
  ( derived )
  f64 dg 9
  f64 ramp-inv
  f64 perc-g f64 perc-dec
  f64 vib-on f64 vib-k f64 vib-base f64 vib-d f64 vib-dry f64 vib-wet
  f64 drv-g f64 drv-ig f64 vol
  f64 leak-g f64 kenv-a
;

( i -- w : the wheel a contact gets, folded in by octaves to 0..90. )
dsp: or-fold | i -- w |
  i 90.0 f- 12.0 f/ fneg floor fneg 0.0 fmax | hi |
  i fneg 12.0 f/ fneg floor fneg 0.0 fmax | lo |
  i  hi 12.0 f* f-  lo 12.0 f* f+
;

( a decayed state is nothing: no denormals, and the machine can sleep )
dsp: or-flush | x -- y |  x fabs 1.0e-7 f<  0.0 x select ;

( --- block rate ------------------------------------------------------- )

( ctx state i0 -- : 13 wheels from i0: rate, taper, leak, and a start
  phase on fresh state, each wheel somewhere else on its turn. )
dsp: or-prep-w | ctx:Ctx s:OrState i0 -- |
  i0 13 [ | i |
    i 12.0 f/ exp2 32.70319566257483 f* | f |
    f ctx.inv-sr f* 0.49 fmin sinpi 2.0 f* s.wk& i f!i
    1.0  i 66.0 f- 0.0 fmax 0.0167 f*  f- s.wt& i f!i
    i 0.6180339887498949 f* ffrac | h |
    h s.wl& i f!i
    s.ws& i f@i fabs  s.wc& i f@i fabs  f+ 1.0e-9 f< | fresh |
    fresh  h 7.0 f* sin2pi  s.ws& i f@i  select s.ws& i f!i
    fresh  h 7.0 f* 0.25 f+ sin2pi  s.wc& i f@i  select s.wc& i f!i
    i 1.0 f+ ] times drop
;

dsp: or-prep-0 | ctx:Ctx st p |  ctx ctx.shared& p@64 0.0 or-prep-w ;
dsp: or-prep-1 | ctx:Ctx st p |  ctx ctx.shared& p@64 13.0 or-prep-w ;
dsp: or-prep-2 | ctx:Ctx st p |  ctx ctx.shared& p@64 26.0 or-prep-w ;
dsp: or-prep-3 | ctx:Ctx st p |  ctx ctx.shared& p@64 39.0 or-prep-w ;
dsp: or-prep-4 | ctx:Ctx st p |  ctx ctx.shared& p@64 52.0 or-prep-w ;
dsp: or-prep-5 | ctx:Ctx st p |  ctx ctx.shared& p@64 65.0 or-prep-w ;
dsp: or-prep-6 | ctx:Ctx st p |  ctx ctx.shared& p@64 78.0 or-prep-w ;

( a drawbar step is 3 dB; the last half step fades to nothing )
dsp: or-prep-misc | ctx:Ctx st p:OrParams |
  ctx.shared& p@64 | s:OrState |
  ctx.sr | sr |
  0.0 9 [ | j |
    p.d16& j f@i | d |
    d 8.0 f- 3.0 f* db>lin  d 2.0 f* 0.0 1.0 fclamp f*  OR-G f* p.dg& j f!i
    j 1.0 f+ ] times drop
  ( a contact makes in 4 ms at CLICK 0, 0.16 ms at 1 )
  1.0  p.click -4.64 f* exp2 0.004 f* sr f* 1.0 fmax  f/ -> p.ramp-inv
  p.perc 0.5 f> mask>f  p.psoft 0.5 f> 0.5 1.0 select f*  OR-G f* 2.0 f* -> p.perc-g
  -1.0  p.pfast 0.5 f> 0.2 0.7 select sr f*  f/ exp -> p.perc-dec
  ( the scanner: half the sweep is 0.15, 0.3 or 0.5 ms )
  p.vib 0.5 f+ floor | m |
  m 0.5 f> mask>f -> p.vib-on
  m 4.5 f> 0.0005  m 2.5 f> 0.0003 0.00015 select  select sr f* | d |
  d -> p.vib-d
  d 6.0 f+ -> p.vib-base
  OR-VIB-HZ ctx.inv-sr f* sinpi 2.0 f* -> p.vib-k
  ( the even settings are the chorus )
  m 0.5 f* dup floor f- 0.25 f< | chorus |
  chorus 0.6 0.0 select -> p.vib-dry
  chorus 0.6 1.0 select -> p.vib-wet
  p.drive dup f* 15.0 f* 1.0 f+ | g |
  g -> p.drv-g
  1.0 g fsqrt f/ -> p.drv-ig
  p.volume db>lin -> p.vol
  p.leak dup f* 0.004 f* -> p.leak-g
  1.0  -1.0 0.01 sr f* f/ exp  f- -> p.kenv-a
  s.vs s.vc dl-osc-seed -> s.vc
;

dsp: organ-block-prepare | ctx state params |
  ctx state params call: or-prep-misc
  ctx state params call: or-prep-0
  ctx state params call: or-prep-1
  ctx state params call: or-prep-2
  ctx state params call: or-prep-3
  ctx state params call: or-prep-4
  ctx state params call: or-prep-5
  ctx state params call: or-prep-6
;

( --- a key ------------------------------------------------------------- )

dsp: organ-note-on | ctx:Ctx v:OrVoice p:OrParams |
  ctx.shared& p@64 | s:OrState |
  ctx.pitch 0.5 f+ floor 24.0 f- | w0 |
  w0 -12.0 f+ or-fold v.w& 0.0 f!i
  w0 7.0 f+ or-fold v.w& 1.0 f!i
  w0 or-fold v.w& 2.0 f!i
  w0 12.0 f+ or-fold v.w& 3.0 f!i
  w0 19.0 f+ or-fold v.w& 4.0 f!i
  w0 24.0 f+ or-fold v.w& 5.0 f!i
  w0 28.0 f+ or-fold v.w& 6.0 f!i
  w0 31.0 f+ or-fold v.w& 7.0 f!i
  w0 36.0 f+ or-fold v.w& 8.0 f!i
  w0 12.0 f+ or-fold -> v.wp2
  w0 19.0 f+ or-fold -> v.wp3
  0.0 -> v.age  0.0 -> v.rel  0.0 -> v.off
  ( the nine contacts take 10 ms at a soft touch, 1 ms at a hard one )
  1.0 ctx.vel f- 0.0011 f* 0.0001 f+ ctx.sr f* -> v.stag
  s.held-z 0.5 f<  1.0 s.ptrig  select -> s.ptrig
;

dsp: organ-note-off | ctx v:OrVoice p |  1.0 -> v.off ;

( the contacts pick their wheels up into the bus )
dsp: k-organ-voice | io ctx:Ctx v:OrVoice p:OrParams |
  ctx.shared& p@64 | s:OrState |
  v.age v.rel v.off v.stag | age rel off stag |
  0.0 0.0 0.0 9 [ | sum lv j |
    j stag f* | dly |
    age dly f- p.ramp-inv f* 0.0 1.0 fclamp
    1.0  rel dly f- p.ramp-inv f* 0.0 1.0 fclamp off f*  f-
    f* | g |
    s.wo&  v.w& j f@i  f@i  g f*  p.dg& j f@i f*  sum f+
    lv g fmax
    j 1.0 f+ ] times drop | sum lv |
  s.bus sum f+ -> s.bus
  s.pbus  s.wo&  p.pharm 0.5 f> v.wp3 v.wp2 select  f@i  lv f*  f+ -> s.pbus
  s.held 1.0 off f- f+ -> s.held
  lv -> v.lvl
  age 1.0 f+ -> v.age
  rel off f+ -> v.rel
;

( --- the machine, once a sample ----------------------------------------- )

( state lk i0 -- lk' : turn 13 wheels from i0, adding their leak to lk. )
dsp: or-wheels | s:OrState lk i0 -- lk2 |
  lk i0 13 [ | lk i |
    s.ws& i f@i | sn |
    s.wc& i f@i | cs |
    s.wk& i f@i | k |
    sn k cs f* f+ | s1 |
    cs k s1 f* f- | c1 |
    s1 s.ws& i f!i
    c1 s.wc& i f!i
    s1 s.wt& i f@i f* | o |
    o s.wo& i f!i
    lk  o s.wl& i f@i f*  f+
    i 1.0 f+ ] times drop
;

dsp: or-w0 | io ctx s:OrState p |  s 0.0 0.0 or-wheels -> s.lk ;
dsp: or-w1 | io ctx s:OrState p |  s s.lk 13.0 or-wheels -> s.lk ;
dsp: or-w2 | io ctx s:OrState p |  s s.lk 26.0 or-wheels -> s.lk ;
dsp: or-w3 | io ctx s:OrState p |  s s.lk 39.0 or-wheels -> s.lk ;
dsp: or-w4 | io ctx s:OrState p |  s s.lk 52.0 or-wheels -> s.lk ;
dsp: or-w5 | io ctx s:OrState p |  s s.lk 65.0 or-wheels -> s.lk ;
dsp: or-w6 | io ctx s:OrState p |  s s.lk 78.0 or-wheels -> s.lk ;

( the keys, the percussion and the leak; clears the sample's sums. )
dsp: or-mix | io ctx s:OrState p:OrParams |
  s.held | held |
  held -> s.held-z
  s.kenv  held 1.0 fmin s.kenv f- p.kenv-a f*  f+ or-flush | ke |
  ke -> s.kenv
  s.ptrig 0.5 f>  1.0  s.pe p.perc-dec f*  select or-flush | pe |
  pe -> s.pe
  0.0 -> s.ptrig
  s.bus  s.pbus pe f* p.perc-g f*  f+  s.lk p.leak-g f* ke f*  f+ -> s.x
  0.0 -> s.bus  0.0 -> s.pbus  0.0 -> s.held
;

dsp: or-vib | io ctx s:OrState p:OrParams |
  s.x | x |
  s.vw | w |
  x s.vb& w f!i
  w 1.0 f+ | w1 |
  w1 OR-RING  w1  0.0  fsel-lt -> s.vw
  p.vib-on 0.5 f>
  [ s.vs s.vc p.vib-k dl-osc | vs vc |
    vs -> s.vs  vc -> s.vc
    s.vb& OR-RING w  p.vib-base vs p.vib-d f* f+  dl-read | v |
    x p.vib-dry f*  v p.vib-wet f*  f+ ]
  [ x ]
  ifte -> s.y
;

( the preamp, added to the out lane as a voice would )
dsp: or-out | io:Io ctx s:OrState p:OrParams |
  p.drive 0.0 f>
  [ s.y p.drv-g f* -4.0 4.0 fclamp tanh-fast p.drv-ig f* ]
  [ s.y ]
  ifte p.vol f* | o |
  io.out-l o f+ -> io.out-l
;

dsp: k-organ-shared | io ctx state params |
  io ctx state params call: or-w0
  io ctx state params call: or-w1
  io ctx state params call: or-w2
  io ctx state params call: or-w3
  io ctx state params call: or-w4
  io ctx state params call: or-w5
  io ctx state params call: or-w6
  io ctx state params call: or-mix
  io ctx state params call: or-vib
  io ctx state params call: or-out
;
