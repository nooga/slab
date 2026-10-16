( string_body.fy - the instrument around Fretwire's strings: the bridge
  and body every string shares, the pickups' wiring, and the open strings
  that ring in sympathy [docs/41 §Fretwire bodies].

  The voices [string.fy] are strings.  Each one, every sample, pushes on
  the bridge with the wave arriving there and moves with the bridge's
  velocity, and hands its pickup signal to the shared pickup line.  This
  file is the machine's shared word [shared-size!, period 1], which then:

    * rings the open strings no note is on [SYMP]: each a delay loop
      driven by the bridge's motion and pushing back on it, so a held
      chord's partials wake the strings tuned to them;

    * steps the body: BM modes, each a damped oscillator driven by the
      summed bridge force, whose velocities add to the bridge's.  A mode
      takes energy from a string partial near it, so notes there decay
      faster and swell into the body [dead spots on a solid body, the
      wood of a hollow one].  The first 8 are the body's low modes [the
      air cavity, the top's and back's first plate modes]; above them
      the body is modally dense, so the rest are spread evenly to a few
      kHz with overlapping bandwidths.  A dozen peaks alone make the
      honky, boxy colour the Hammerwork Grand's board taught us to avoid;

    * runs the pickup line through the wiring: the coil's inductance and
      resistance against the cable's capacitance and the pots' load, a
      resonant lowpass [RESO, PEAK], and the tone pot's capacitor, which
      as TONE comes down pulls that resonance down into the mids; the
      volume pot then loses treble into the cable as it turns down;

    * mixes the pickups with the body's radiated sound [AIR: its modes'
      acceleration, plus the flat radiation above them] and an
      under-saddle piezo [PIEZO: the bridge force itself].

  Physics, all textbook: the bridge as a moving string termination
  [Gough 1981; Woodhouse 2004], modal body mobility [Cremer, The Physics
  of the Violin], and a passive pickup circuit [Lemme, Electric Guitar
  Sound Secrets].  Coupling is explicit: a voice uses the bridge velocity
  the last sample left, which is stable at any coupling these bodies
  reach because each mode's drive per sample is small. )

include "string.fy"
include "../10-physical/modal.fy"

( The bodies.  0-3 a guitar's: SOLID, SEMI [a centre block], HOLLOW [an
  archtop] and ACOUSTIC [a flat-top]; 4-6 a bass's: SOLID, HOLLOW,
  ACOUSTIC.  Per body, 8 low modes: Hz, Q, peak coupling to the low
  string [x 1e-4: the share of the string's wave the bridge passes on at
  resonance], radiation weight [x 0.01, signed: a back plate moves
  against the top].  Then the dense modes: from, to [Hz], Q, coupling,
  radiation.  The low modes follow published guitar mobility and
  radiation measurements in shape, not any one instrument. )
table: fw-bf 56  f>i [
  148 232 330 410 520 640 790 960
  118 190 255 330 420 520 640 780
  108 175 228 296 380 470 575 700
   98 196 228 285 380 455 540 660
   98 176 262 345 430 560 720 900
   88 140 205 275 360 450 560 690
   72 128 178 240 310 400 500 620  620 ] swap qnth i>f ;
table: fw-bq 56  f>i [
  60 70 80 80 90 90 100 100
  30 35 40 40 45 45 50 50
  25 28 32 35 38 40 42 45
  18 22 30 30 35 35 40 40
  60 70 80 80 90 90 100 100
  25 28 32 35 38 40 42 45
  16 20 26 30 32 35 38 40  40 ] swap qnth i>f ;
table: fw-bb 56  f>i [
   30  50  20  25  15  15  10  10
   60 110  80  70  60  50  40  35
  100 180 120 100  90  70  60  50
  220 400 160 140 130 110  90  80
   40  30  20  20  15  12  10  10
  120 200 120 100  80  70  60  50
  250 400 180 150 130 110  90  80  80 ] swap qnth i>f ;
table: fw-br 56  f>i [
    5   4  -3   3  -2   2  -2   2
   40  60 -35  30 -25  20 -18  15
   70  90 -50  45 -40  30 -25  20
  100 100 -40  50 -45  35 -30  25
    5   4  -3   3  -2   2  -2   2
   70  90 -50  45 -40  30 -25  20
  100 100 -50  50 -40  35 -30  25  25 ] swap qnth i>f ;
table: fw-bd 35  f>i [
  1100 5000 60  6  1
   950 5000 35 25  5
   850 5000 28 40  7
   800 6000 20 60 10
  1000 4000 60  5  1
   850 4500 28 40  7
   750 5000 20 60 10  10 ] swap qnth i>f ;
( AIR and PIEZO at 1 sit near the pickups at LEVEL's level on an
  acoustic body: the scale from the body's units to the pickups'. )
:: AIR-K 2500.0 ;
:: PZ-K 1.1 ;
:: SYM-A 0.2 ;   ( an open string's loss lowpass: y += [1 - a] [x - y] )

( ctx state params -- : the wiring.  A coil of inductance L and
  resistance R into a shunt of the cable's capacitance C, the pots' and
  amp's load G, and the tone branch Rt + Ct:

    H[s] = 1 / [1 + [R + sL] [sC + G + sCt / [1 + s Rt Ct]]]

  With the tone pot open the branch is gone and H is the resonant lowpass
  RESO and PEAK describe, so C and G are solved from them [for L and R
  of the selected coils]; RESO is a single coil's, and a humbucker or two
  coils in parallel move it by the square root of their inductance.  The
  tone pot's 3rd-order H goes to z by the bilinear transform prewarped at
  the resonance.  The volume pot is its taper's attenuation and the
  lowpass of its wiper's resistance into the cable. )
dsp: fw-prep-wiring | ctx:Ctx state params:StringParams |
  ctx.shared& p@64 | body:FwBody |
  ctx.sr | sr |
  params.tone params.l-eff fsqrt f/ 20.0 20000.0 fclamp | f0 |
  f0 sr svf-g | g |
  g -> body.eg
  params.pk-d -> body.ed
  6.283185307179586 f0 f* | w0 |
  params.l-coil params.l-eff f* | l |
  params.r-coil params.l-eff f* | r |
  2.0 params.pk-d f* w0 f/ | a |
  1.0 w0 w0 f* f/ | b |
  a r b f* l f/ f-   l r r f* b f* l f/ f+ a r f* f-  f/ 0.0 fmax | gl |
  b 1.0 r gl f* f+ f* l f/ | c |
  params.c-tone | ct |
  params.tpot dup f* 250000.0 f* 1000.0 fmax ct f* | tau |
  1.0 r gl f* f+ | a0 |
  tau  c gl tau f* f+ ct f+ r f* f+  l gl f* f+ | a1 |
  r c f* tau f*  c gl tau f* f+ ct f+ l f* f+ | a2 |
  l c f* tau f* | a3 |
  w0 g f/ | k |
  k k f* | k2 |  k2 k f* | k3 |
  a1 k f* | p1 |  a2 k2 f* | p2 |  a3 k3 f* | p3 |
  a0 p1 f+ p2 f+ p3 f+ | d0 |
  1.0 d0 f/ | id |
  3.0 a0 f* p1 f+ p2 f- 3.0 p3 f* f- id f* -> body.ea1
  3.0 a0 f* p1 f- p2 f- 3.0 p3 f* f+ id f* -> body.ea2
  a0 p1 f- p2 f+ p3 f- id f* -> body.ea3
  a0 tau f* k f* | q1 |
  a0 q1 f+ id f* -> body.eb0
  3.0 a0 f* q1 f+ id f* -> body.eb1
  3.0 a0 f* q1 f- id f* -> body.eb2
  a0 q1 f- id f* -> body.eb3
  ( the volume pot: an audio taper, and its wiper's resistance into the cable )
  params.vol 0.0 1.0 fclamp | v |
  v v f* v f* | ga |
  ga -> body.vg
  250000.0 ga f* 1.0 ga f- f* 1.0 fmax | rs |
  1.0  6.283185307179586 rs f* 0.7 c f* f* f/  0.45 sr f* fmin | fc |
  sr fc svf-dc-coeff -> body.va
  sr 40.0 svf-dc-coeff -> body.pz-a
  ( above the dense modes the body radiates like a resistance: the
    bridge force times the dense modes' own coupling and radiation )
  params.body-base params.body f+ 5.0 f* | di |
  sr  fw-bd di 1.0 f+ f@i  svf-dc-coeff -> body.rf-a
  fw-bd di 3.0 f+ f@i 0.0001 f*  fw-bd di 4.0 f+ f@i 0.01 f* f* -> body.rflat
  params.level params.out-g f* | lv |
  lv -> body.mag-g
  ( the radiated pressure is the radiating velocity's rate of change,
    stated per sample and scaled to a 1 kHz velocity; a body an octave
    lower radiates its notes an octave lower, so the register's low
    string [ref-hz, against a guitar's E] keeps AIR at the pickups' level )
  lv params.air f* AIR-K f* sr f* 0.00015915494309189535 f*
    params.ref-hz 82.41 f/ f* -> body.air-g
  lv params.piezo f* PZ-K f* -> body.pz-g
;

( body params bi h sr j -- : body mode j's step coefficients.  j < 8 is a
  low mode from the tables; above, the dense modes run evenly from the
  dense band's bottom to its top, each placed a little off its slot
  [a golden-ratio sequence, so no two bodies' spacings line up], with a
  coupling that falls as the plate's mobility does and a radiation sign
  and size of its own. )
dsp: fw-prep-mode | body:FwBody params:StringParams bi h sr j -- |
  bi 8.0 f* j 7.0 fmin f+ | ti |
  bi 5.0 f* | di |
  fw-bd di f@i | fd0 |
  j 8.0 f- 0.0 fmax | kk |
  kk 0.6180339887498949 f* ffrac 0.5 f- 0.8 f* kk f+ 0.5 f+ 0.025 f* | fr |
  fw-bd di 1.0 f+ f@i fd0 f- fr f* fd0 f+ | fdn |
  j 8.0 f< | low |
  low  fw-bf ti f@i  fdn  select | fq |
  low  fw-bq ti f@i  fw-bd di 2.0 f+ f@i  select | q |
  low  fw-bb ti f@i  fw-bd di 3.0 f+ f@i  fd0 fq f/ fsqrt f*  select 0.0001 f* | beta |
  kk 0.7548776662466927 f* ffrac 0.5 f> 1.0 -1.0 select
    kk 0.5698402909980532 f* ffrac 0.5 f+ f*  fw-bd di 4.0 f+ f@i f* | rd |
  low  fw-br ti f@i  rd  select 0.01 f* | rad |
  fq 0.45 sr f* f< | ok |
  fq 0.45 sr f* fmin 6.283185307179586 f* | w |
  w h zoh-coefs | c sw ws b1 b2 |
  w 2.0 q f* f/ | sig |
  c body.mc& j f!i  sw body.msw& j f!i  ws body.mws& j f!i
  b1 body.mb1& j f!i  b2 body.mb2& j f!i
  sig h f* fneg exp body.mrho& j f!i
  ok  2.0 sig f* beta f* params.couple f*  0.0 select body.mal& j f!i
  ok rad 0.0 select body.mr& j f!i
;

dsp: fw-prep-modes-0 | ctx:Ctx state params:StringParams |
  ctx.shared& p@64 | body |  ctx.sr | sr |  1.0 sr f/ | h |
  params.body-base params.body f+ | bi |
  0.0 16 [ | j |  body params bi h sr j fw-prep-mode  j 1.0 f+ ] times drop
;
dsp: fw-prep-modes-1 | ctx:Ctx state params:StringParams |
  ctx.shared& p@64 | body |  ctx.sr | sr |  1.0 sr f/ | h |
  params.body-base params.body f+ | bi |
  16.0 16 [ | j |  body params bi h sr j fw-prep-mode  j 1.0 f+ ] times drop
;
dsp: fw-prep-modes-2 | ctx:Ctx state params:StringParams |
  ctx.shared& p@64 | body |  ctx.sr | sr |  1.0 sr f/ | h |
  params.body-base params.body f+ | bi |
  32.0 16 [ | j |  body params bi h sr j fw-prep-mode  j 1.0 f+ ] times drop
;

( ctx state params -- : the open strings: each tuned to its open pitch,
  losing DECAY's share a period, heard at the pickups' points.  SYMP
  scales how hard the bridge drives them and they push back. )
dsp: fw-prep-sym | ctx:Ctx state params:StringParams |
  ctx.shared& p@64 | body:FwBody |
  ctx.sr | sr |
  0.0 SYM-N [ | s |
    params.o1& s f@i | fo |
    fo 100000000.0 f<  s params.n-str f<  and | on |
    on fo 1000.0 select | fo |
    sr fo f/ | n |
    6.283185307179586 fo f* sr f/ 3.0 fmin | w |
    SYM-A w sin f*  1.0 SYM-A w cos f* f-  f/ st-atan w f/ | pd |
    n pd f- 2.0 SYM-RLF 4.0 f- fclamp body.sd& s f!i
    on  -6.907755278982137 params.decay fo f* f/ exp  0.0 select body.sg& s f!i
    on  params.ref-hz fo f/ params.symp f*  0.0 select body.sz& s f!i
    params.pickup n f* 0.5 n f* fmin 1.0 fmax body.spn& s f!i
    params.pickup-b n f* 0.5 n f* fmin 1.0 fmax body.spb& s f!i
    s 1.0 f+ ] times drop
;

( ctx state params -- : every block.  The string coefficients and the
  pickups, the wiring, the body's modes, the open strings. )
dsp: string-block-prepare | ctx state params |
  ctx state params call: st-prep-core
  ctx state params call: fw-prep-wiring
  ctx state params call: fw-prep-modes-0
  ctx state params call: fw-prep-modes-1
  ctx state params call: fw-prep-modes-2
  ctx state params call: fw-prep-sym
;

( rings base pos -- y : an open string's ring read at pos [cells from its
  start, wrapped], linear. )
dsp: fw-ring-read | rings base pos -- y |
  pos 0.0 f< SYM-RLF 0.0 select pos f+ | p |
  p SYM-RLF f>= SYM-RLF 0.0 select p swap f- | p |
  p floor | i |  p i f- | fr |
  i 1.0 f+ dup SYM-RLF f>= SYM-RLF 0.0 select f- | i1 |
  rings base i f+ f@i | y0 |
  rings base i1 f+ f@i | y1 |
  y1 y0 f- fr f* y0 f+
;

( io ctx body params -- : the open strings, one sample. )
dsp: fw-sym | io ctx body:FwBody params:StringParams |
  params.symp 0.0 f>
  [ body.vb params.symp f* | vin |
    body FwBody.size ptr+ | rings |
    0.0 0.0 0.0 SYM-N [ | s fs ps |
      s SYM-RLF f* | base |
      body.sw& s f@i | w |
      rings base  w body.sd& s f@i f-  fw-ring-read | r |
      body.slp& s f@i | l0 |
      r l0 f- 1.0 SYM-A f- f* l0 f+ | l |
      l body.slp& s f!i
      body.mute& s f@i 0.5 f> 0.5 1.0 select  body.sg& s f@i f*  l f* | y |
      y vin f+ | nw |
      nw  rings base w f+  f!i
      w 1.0 f+ dup SYM-RLF f>= 0.0 rot select body.sw& s f!i
      0.0 body.mute& s f!i
      nw  rings base w body.spn& s f@i f- fw-ring-read f- | yn |
      nw  rings base w body.spb& s f@i f- fw-ring-read f- | yb |
      s 1.0 f+
      fs  y 2.0 f* body.sz& s f@i f* f-
      ps  yn params.wn f* yb params.wb f* f+ f+
    ] times
    | s fs ps |
    body.f fs f+ -> body.f
    body.pu ps f+ -> body.pu
    0.0 ]
  [ 0.0 ]
  ifte drop
;

( body F vba rada j -- vba' rada' : body mode j, one sample, driven by
  the bridge force F: its velocity joins the bridge's, its acceleration
  the radiating velocity. )
dsp: fw-mode | body:FwBody fb vba rada j -- vba rada |
  body.q& j f@i | q |  body.v& j f@i | v |
  body.mal& j f@i fb f* | fm |
  q v  body.mc& j f@i body.msw& j f@i body.mws& j f@i body.mrho& j f@i
    fm body.mb1& j f@i body.mb2& j f@i  modal-step | qn vn |
  qn body.q& j f!i  vn body.v& j f!i
  vba vn f+
  rada  vn body.mr& j f@i f* f+
;

dsp: fw-modes-0 | io ctx body:FwBody params |
  body.f | fb |
  body.vba body.rada 0.0 16 [ | vba rada j |  body fb vba rada j fw-mode  j 1.0 f+ ] times drop
  | vba rada |  vba -> body.vba  rada -> body.rada
;
dsp: fw-modes-1 | io ctx body:FwBody params |
  body.f | fb |
  body.vba body.rada 16.0 16 [ | vba rada j |  body fb vba rada j fw-mode  j 1.0 f+ ] times drop
  | vba rada |  vba -> body.vba  rada -> body.rada
;
dsp: fw-modes-2 | io ctx body:FwBody params |
  body.f | fb |
  body.vba body.rada 32.0 16 [ | vba rada j |  body fb vba rada j fw-mode  j 1.0 f+ ] times drop
  | vba rada |  vba -> body.vba  rada -> body.rada
;

( io ctx body params -- : the wiring and the outputs; clears the step's sums. )
dsp: fw-out | io:Io ctx body:FwBody params:StringParams |
  body.vba -> body.vb
  body.pu | pu |
  params.tpot 0.999 f<
    [ body.eb0 pu f* body.e1 f+ | y |
      body.eb1 pu f* body.ea1 y f* f- body.e2 f+ -> body.e1
      body.eb2 pu f* body.ea2 y f* f- body.e3 f+ -> body.e2
      body.eb3 pu f* body.ea3 y f* f- -> body.e3
      y ]
    [ body.s1& body.s2& pu body.eg body.ed tpt-svf-lp-step ]
  ifte | el |
  params.vol 0.999 f<
    [ body.vl  el body.vl f- body.va f* f+ | vl |  vl -> body.vl  vl body.vg f* ]
    [ el ]
  ifte | el |
  body.f | fb |
  body.pz-lp  fb body.pz-lp f- body.pz-a f* f+ | pl |
  pl -> body.pz-lp
  body.rf-lp  fb body.rf-lp f- body.rf-a f* f+ | rl |
  rl -> body.rf-lp
  fb rl f- body.rflat f* body.rada f+ | rv |
  rv body.rv f- | rad |
  rv -> body.rv
  el body.mag-g f*  rad body.air-g f* f+  fb pl f- body.pz-g f* f+ | o |
  ( the wiring rings down far below hearing in the body's last block
    before it sleeps: flush it rather than hand on denormals )
  io.out-l  o fabs 1.0e-25 f< 0.0 o select  f+ -> io.out-l
  0.0 -> body.f  0.0 -> body.pu  0.0 -> body.vba  0.0 -> body.rada
;

( io ctx body params -- : the shared word, once a sample after the strings. )
dsp: fw-body-render | io ctx body params |
  io ctx body params call: fw-sym
  io ctx body params call: fw-modes-0
  io ctx body params call: fw-modes-1
  io ctx body params call: fw-modes-2
  io ctx body params call: fw-out
;
