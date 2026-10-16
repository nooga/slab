( piano.fy - a struck-string piano voice built from modes [docs/41].

  One voice is one key: up to three unison strings, a felt hammer that
  strikes them, and a small soundboard the strings drive through the
  bridge.  Everything is a physical quantity - metres, newtons,
  kilograms - so the hammer's tone comes from the felt law and the
  strings' masses, not from a filter.

  STRINGS.  Each string is a bank of transverse modes with the stiff-
  string partials f_n = n f0 sqrt[1 + B n^2] / sqrt[1 + B] [Fletcher
  1964], decaying at sigma_n = b1 + b3 w_n^2 [frequency-dependent loss,
  Chaigne and Askenfelt 1994].  Mode n has the shape sin[n pi x/L] and
  modal mass mu L/2.  The main string carries 56 modes, the two unison
  partners 16 each: their low partials beat against the main string's
  [UNISON detune], and above the 16th partial the main string's modes
  stand for all of a key's strings at once.  Bass keys run the main
  string's upper modes on every 2nd..4th partial, weighted by the square
  root of the stride, so a low A still reaches 7 kHz.

  HAMMER.  A point mass of felt [mass, stiffness K, exponent p from the
  key; Hall 1986, Stulov 1995] launched at the strings at a speed set by
  velocity, pressing them with F = K e^p [1 + alpha de/dt] while the felt
  is compressed.  contact-solve [10-physical/modal.fy] solves the force
  implicitly each sample, so soft hits are short dull pushes and hard
  hits a sharper, brighter knock - the felt stiffens as it compresses.
  Once the hammer has rebounded clear [checked at control rate] the
  render skips the contact solve.

  BRIDGE AND SOUNDBOARD.  The strings end on a bridge that moves.  The
  string force on it, F_b = sum [-1]^[n+1] n pi T/L q_n, drives 12
  soundboard plate modes; the board's acceleration pushes back on each
  string mode as -c_n b'' [c_n = 2 [-1]^[n+1]/[n pi]], the inertia of a
  string whose end is shaken.  That shared bridge couples the unison
  strings: their in-phase motion drains into the board quickly and the
  out-of-phase part lingers - the piano's two-stage decay [Weinreich
  1977].  Where on the board the key's bridge point sits sets how
  strongly each board mode hears it.

  OUTPUT is the board's acceleration seen from two microphone points:
  low notes and board resonances spread across the stereo field, and
  above the board modes the bridge force passes through flat.

  DAMPERS.  A released key drops its damper, adding decay to each mode
  by how far the damper point moves in it; PEDAL lifts the dampers.
  The top 20 keys have no dampers, as on a grand.  The decay factors are
  re-blended at control rate, so the pedal is live on held notes.

  Clean-room: written from the literature cited here and fitted by ear
  and on the bench; no code or data from other piano models. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../10-physical/modal.fy"
include "../04-filters/coeffs.fy"      ( svf-dc-coeff )

:: PN 88 ;     ( string modes per voice: 56 main + 16 + 16 )
:: PN-A 56 ;
:: PN-SEP 16 ; ( partials the unison strings carry separately )
:: PN-LIN 32 ; ( main-string modes before bass keys start striding )
:: BN 12 ;     ( soundboard modes )
:: WR 0.12 ;
:: PN-AF 56.0 ;  :: PN-SEPF 16.0 ;  :: PN-LINF 32.0 ;

ustruct: PianoState
  ( the modes: amplitude [m], velocity [m/s], the exact step [cos, sin/w,
    w sin], the decay factor now / damper up / damper down, hammer force
    -> mode, bridge acceleration -> mode, mode shape at the strike point
    over the strings, mode -> bridge force [N/m] )
  f64 q 88    f64 v 88
  f64 c 88    f64 sw 88     f64 ws 88
  f64 rho 88  f64 ron 88    f64 rfull 88
  f64 gb1 88  f64 gb2 88    f64 cb1 88  f64 cb2 88
  f64 phi 88  f64 kb 88
  f64 bp 12   f64 bv 12     ( board mode displacement, velocity )
  f64 g 12                  ( board mode shape at this key's bridge point )
  f64 fb-lp                 ( bridge force, lowpassed: the resistive part sees the rest )
  f64 vr  f64 br            ( resistive bridge velocity and displacement )
  f64 wrl  f64 wrr          ( this key's resistive radiation to each microphone )
  f64 bacc                  ( bridge acceleration last sample )
  f64 bdisp                 ( bridge displacement last sample )
  f64 tl                    ( strings * T/L: the strings' stiffness on the bridge )
  f64 hu  f64 hv            ( hammer position, velocity [toward the strings] )
  f64 he                    ( felt compression this sample )
  f64 hcomp                 ( D: hammer + string compliance at the strike )
  f64 hk  f64 hp  f64 halpha  f64 hmass
  f64 nstr                  ( strings on this key: 1, 2 or 3 )
  f64 ham-on                ( 1 while the hammer may touch; control clears it )
  f64 gate                  ( 1 held, 0 released )
  f64 damped                ( 1 if the key has a damper )
  f64 pitch
  ( the key, set at note-on for the mode stages )
  f64 k-f0  f64 k-h  f64 k-fny  f64 k-len  f64 k-tens  f64 k-mmode
  f64 k-bb  f64 k-bnorm  f64 k-xs  f64 k-xd  f64 k-s1  f64 k-b3  f64 k-sd
  f64 k-stride  f64 k-detb  f64 k-detc
;

ustruct: PianoParams
  ( user-facing )
  f64 hard      ( felt hardness, -1..1: K and p around the key's own )
  f64 felt      ( felt hysteresis 0..1 )
  f64 strike    ( strike point shift, -1..1 )
  f64 decay     ( decay time scale )
  f64 hf-decay  ( s: T60 of the partials near 4 kHz, at middle C )
  f64 stiff     ( inharmonicity scale )
  f64 unison    ( cents between unison strings )
  f64 board     ( bridge coupling 0..1 )
  f64 release   ( s: damper T60 of the fundamental )
  f64 pedal     ( 0 dampers down .. 1 lifted )
  f64 width     ( stereo width 0..1 )
  f64 level
  ( derived )
  f64 sr  f64 inv-sr
  f64 ped-k                     ( [1 - pedal]^2 )
  f64 bc 12  f64 bsw 12  f64 bws 12  f64 brho 12  f64 bb1 12  f64 bb2 12
  f64 bwl 12  f64 bwr 12        ( mic weights per board mode )
  f64 out-g
  f64 yr                        ( bridge mobility of the board's dense modes, s/kg )
  f64 yr-a                      ( one-pole coefficient: the mobility's high-pass corner )
;

( board mode j: plate indices [a, b] of a rectangular board's first
  modes in rising order, the mode frequency in Hz and its damping ratio. )
( 13 cells: table: also fills index len )
table: board-hz 12
  f>i [ 58 101 142 187 236 291 357 433 522 641 790 985 985 ] swap qnth i>f ;
table: board-a 12  f>i [ 1 2 1 3 2 1 4 3 2 5 4 1 1 ] swap qnth i>f ;
table: board-b 12  f>i [ 1 1 2 1 2 3 1 2 3 1 2 4 4 ] swap qnth i>f ;

( ctx state params -- : shared board coefficients and knob scalings. )
dsp: piano-block-prepare | ctx:Ctx state params:PianoParams -- |
  ctx.sr | sr |
  sr -> params.sr
  1.0 sr f/ | h |
  h -> params.inv-sr
  1.0 params.pedal f- dup f* -> params.ped-k
  ( board: exact steps; zeta rises gently with the mode number )
  0.0 BN [ | j |
    board-hz j f@i 6.283185307179586 f* | w |
    w h zoh-coefs | c sw ws b1 b2 |
    c params.bc& j f!i  sw params.bsw& j f!i  ws params.bws& j f!i
    b1 params.bb1& j f!i  b2 params.bb2& j f!i
    0.016 j 0.0016 f* f+ w f* h f* fneg exp params.brho& j f!i
    ( mic weights: a mode's net volume [odd-odd modes radiate as a
      monopole] plus its shape at two points either side of centre )
    board-a j f@i | a |  board-b j f@i | b |
    1.0 a cospi f-  1.0 b cospi f- f*  a b f* 9.869604401089358 f* f/ | vol |
    a 0.28 f* sinpi b 0.45 f* sinpi f* | ml |
    a 0.72 f* sinpi b 0.45 f* sinpi f* | mr |
    ml mr f+ 0.5 f* | mm |
    ml mm f- params.width f* mm f+ | ml |
    mr mm f- params.width f* mm f+ | mr |
    vol 0.6 f* ml 0.4 f* f+ params.bwl& j f!i
    vol 0.6 f* mr 0.4 f* f+ params.bwr& j f!i
    j 1.0 f+ ] times drop
  ( the board radiates in proportion to its coupling, so it is divided
    out: COUPLE changes tone and decay, not level )
  params.level 0.05 f* sr f* params.board 0.05 fmax f/ -> params.out-g
  ( above its first modes the board is modally dense and acts like a
    resistance at the bridge [an infinite plate's mobility 1/[8 sqrt[D m]],
    Cremer], high-passed so the board stays stiff below its first modes )
  params.board 0.0002 f* -> params.yr
  sr 220.0 svf-dc-coeff -> params.yr-a
;

( key m -- string length L [m]: a grand's scale, shortened in the bass. )
dsp: pn-length | m -- l |  108.0 m f- 0.0767 f* exp2 0.05 f* 0.05 1.95 fclamp ;

( ctx state params -- : strike this voice.  Builds every mode's
  coefficients for the key and launches the hammer. )
( ctx state params -- : note-on, part 1 - the key's scale, loss, hammer
  and board point.  The mode banks are filled by the stages below; the
  host runs them in order as the composition piano-note-on. )
dsp: piano-key | ctx:Ctx state:PianoState params:PianoParams -- |
  ctx.pitch 21.0 108.0 fclamp | m |
  m -> state.pitch
  m 21.0 f- 87.0 f/ | k |
  ctx.hz | f0 |
  params.inv-sr | h |
  params.sr 0.45 f* | fny |
  ( strings: 1 below B0, 2 below G#2, else 3 )
  m 30.0 f< 1.0  m 44.0 f< 2.0 3.0 select  select | ns |
  ns -> state.nstr
  ( the scale: length, tension, mass )
  m pn-length | len |
  48.0 m f- 0.0 fmax 30.0 f* 700.0 f+ | tens |
  2.0 len f* f0 f* | twolf |
  tens twolf twolf f* f/ | mu |
  mu len f* 0.5 f* | mmode |
  ( inharmonicity: lowest near C3, rising steeply into the treble )
  m 48.0 f- | dm |
  dm 0.0 f>  dm 0.029 f*  dm fneg 0.012 f*  select -4.0 f+ 3.321928094887362 f* exp2
    params.stiff f* | bb |
  1.0 bb f+ fsqrt | bnorm |
  ( strike point: 1/8 of the string in the bass to 1/12.5 at the top )
  0.125 0.045 k f* f- params.strike 0.025 f* f+ 0.04 0.3 fclamp | xs |
  ( loss: fundamental T60 and the T60 near 4 kHz set b1 and b3 )
  m 21.0 f- -0.03846 f* exp2 30.0 f* params.decay f* t60>sigma | s1 |
  m 60.0 f- -0.04 f* exp2 params.hf-decay f* params.decay f* t60>sigma | shf |
  shf s1 f- 0.0 fmax 25132.741228718345 dup f* f/ | b3 |
  ( damper: a release T60 for the fundamental, felt at x = xs + 0.03 )
  params.release t60>sigma s1 f- 0.0 fmax | sd |
  m 88.0 f<= mask>f | dmp |
  dmp -> state.damped
  xs 0.03 f+ | xd |
  ( bass stride for the main string's upper modes )
  160.0 f0 f/ floor 1.0 4.0 fclamp | stride |
  ( unison detune, a different spread on each key )
  m 0.6180339887 f* ffrac 0.6 f* 0.7 f+ params.unison f* | dc |
  dc fneg 0.0008333333333333334 f* exp2 | detb |   ( 2^[-dc/1200] )
  dc 0.6 f* 0.0008333333333333334 f* exp2 | detc |
  f0 -> state.k-f0  h -> state.k-h  fny -> state.k-fny  len -> state.k-len
  tens -> state.k-tens  mmode -> state.k-mmode  bb -> state.k-bb
  bnorm -> state.k-bnorm  xs -> state.k-xs  xd -> state.k-xd  s1 -> state.k-s1
  b3 -> state.k-b3  sd -> state.k-sd  stride -> state.k-stride
  detb -> state.k-detb  detc -> state.k-detc
  ns tens f* len f/ -> state.tl
  ( the board point of this key's bridge, on a diagonal across the board )
  0.2 0.6 k f* f+ | bx |
  0.72 0.4 k f* f- | by |
  0.0 BN [ | j |
    board-a j f@i bx f* sinpi  board-b j f@i by f* sinpi f* 0.35 f* params.board f*
      state.g& j f!i
    0.0 state.bp& j f!i  0.0 state.bv& j f!i
    j 1.0 f+ ] times drop
  0.0 -> state.bacc  0.0 -> state.bdisp
  0.0 -> state.fb-lp  0.0 -> state.vr  0.0 -> state.br
  ( the dense modes radiate from around the bridge point: bass keys lean
    left, treble keys right, as heard from the player's side )
  k 0.5 f- params.width f* | pan |
  0.5 pan f- WR f* -> state.wrl
  0.5 pan f+ WR f* -> state.wrr
  ( hammer: lighter, harder and more nonlinear toward the treble.  The
    effective masses, stiffnesses and exponents interpolate the values
    Chaigne and Askenfelt [1994] fitted at C2, C4 and C7 )
  m 36.0 f- 60.0 f/ -1.155 f* exp2 0.0049 f* | hm |   ( 4.9 g at C2, 2.2 g at C7 )
  hm -> state.hmass
  m 60.0 f< | lo |
  lo  m 36.0 f- 0.008333 f* 2.3 f+  m 60.0 f- 0.013889 f* 2.5 f+  select 1.8 3.6 fclamp
    -> state.hp
  lo  m 36.0 f- 0.0272 f* 9.0 f+  m 60.0 f- 0.0374 f* 9.653 f+  select
    params.hard f+ 3.321928094887362 f* exp2 -> state.hk
  params.felt 0.6 f* -> state.halpha
  ( hammer speed: 0.25 m/s pianissimo to 6 m/s fortissimo )
  ctx.vel 0.0 1.0 fclamp 4.584962500721156 f* exp2 0.25 f* -> state.hv
  -0.0001 -> state.hu
  -0.0001 -> state.he
  ( compliance: the hammer's own; the mode stages add the strings' )
  ns h f* h f* 0.5 f* hm f/ -> state.hcomp
  1.0 -> state.ham-on
  1.0 -> state.gate
;
( state i -- comp : fill mode i [a literal in each stage, so every
  array access is a fixed field] and return its strike-point compliance. )
dsp: pn-mode | state:PianoState i -- comp |
  state.k-f0 | f0 |  state.k-h | h |  state.k-fny | fny |  state.nstr | ns |
  state.k-len | len |  state.k-tens | tens |  state.k-mmode | mmode |
  state.k-bb | bb |  state.k-bnorm | bnorm |  state.k-xs | xs |  state.k-xd | xd |
  state.k-s1 | s1 |  state.k-b3 | b3 |  state.k-sd | sd |  state.damped | dmp |
  state.k-stride | stride |  state.k-detb | detb |  state.k-detc | detc |
  ( which string and partial this mode is )
  i PN-AF 0.5 f- f< | on-a |
  i PN-AF PN-SEPF f+ 0.5 f- f< | on-b0 |
  on-a  i PN-LINF 0.5 f- f<  and | lin |
  lin  i 1.0 f+  i PN-LINF f- 1.0 f+ stride f* PN-LINF f+  select | na |
  on-b0  i PN-AF f- 1.0 f+  i PN-AF f- PN-SEPF f- 1.0 f+  select | nbc |
  on-a na nbc select | n |
  on-a 1.0  on-b0 detb detc select  select | det |
  ( present: B needs 2 strings, C needs 3 )
  on-a 1.0  on-b0 ns 1.5 f> mask>f  ns 2.5 f> mask>f select  select | here |
  ( merged: main-string modes above the separate partials carry every string )
  on-a  n PN-SEPF 0.5 f+ f>  and | merged |
  merged ns 1.0 select | um |
  on-a lin not and  stride fsqrt 1.0 select | wst |
  n n f* bb f* 1.0 f+ fsqrt bnorm f/ n f* f0 f* det f* | fn |
  fn fny f< mask>f here f* | live |
  fn fny fmin 6.283185307179586 f* | w |
  w h zoh-coefs | c sw ws b1 b2 |
  c state.c& i f!i  sw state.sw& i f!i  ws state.ws& i f!i
  ( the unison strings meet the hammer a few percent apart along their
    lengths, which fills the strike-point notches; merged modes average
    all three )
  n xs f* sinpi | sa |
  n xs f* 1.03 f* sinpi | sb |
  n xs f* 0.97 f* sinpi | sc |
  on-a  merged  sa sb f+ sc f+ 0.3333333333333333 f*  sa  select  on-b0 sb sc select  select | shp |
  shp mmode f/ wst f* um f* live f* | gh |
  gh b1 f* | gb1 |
  gb1 state.gb1& i f!i  gh b2 f* state.gb2& i f!i
  n 1.0 f+ turn-sign | sgn |   ( [-1]^[n+1] )
  sgn 2.0 f* n 3.141592653589793 f* f/ um f* live f* | cn |
  cn b1 f* state.cb1& i f!i  cn b2 f* state.cb2& i f!i
  shp ns f/ live f* | ph |
  ph state.phi& i f!i
  sgn n f* 3.141592653589793 f* tens f* len f/ live f* state.kb& i f!i
  s1 b3 w f* w f* f+ | sig |
  sig h f* fneg exp | ron |
  n xd f* sinpi dup f* 0.6 f* 0.4 f+ sd f* dmp f* | sdn |
  ron state.ron& i f!i
  sig sdn f+ h f* fneg exp state.rfull& i f!i
  ron state.rho& i f!i
  0.0 state.q& i f!i  0.0 state.v& i f!i
  ph gb1 f*
;

dsp: pn-modes-0 | ctx state:PianoState params -- |
  0.0 state.hcomp 16 [ | i comp |  i 1.0 f+  comp state i pn-mode f+ ] times nip
    -> state.hcomp
;
dsp: pn-modes-1 | ctx state:PianoState params -- |
  16.0 state.hcomp 16 [ | i comp |  i 1.0 f+  comp state i pn-mode f+ ] times nip
    -> state.hcomp
;
dsp: pn-modes-2 | ctx state:PianoState params -- |
  32.0 state.hcomp 16 [ | i comp |  i 1.0 f+  comp state i pn-mode f+ ] times nip
    -> state.hcomp
;
dsp: pn-modes-3 | ctx state:PianoState params -- |
  48.0 state.hcomp 16 [ | i comp |  i 1.0 f+  comp state i pn-mode f+ ] times nip
    -> state.hcomp
;
dsp: pn-modes-4 | ctx state:PianoState params -- |
  64.0 state.hcomp 16 [ | i comp |  i 1.0 f+  comp state i pn-mode f+ ] times nip
    -> state.hcomp
;
dsp: pn-modes-5 | ctx state:PianoState params -- |
  80.0 state.hcomp 8 [ | i comp |  i 1.0 f+  comp state i pn-mode f+ ] times nip
    -> state.hcomp
;

( ctx state params -- : strike this voice.  Each stage writes at most
  16 modes, which keeps a word's pending stores inside the compiler's
  frame. )
dsp: piano-note-on | ctx state params |
  ctx state params call: piano-key
  ctx state params call: pn-modes-0
  ctx state params call: pn-modes-1
  ctx state params call: pn-modes-2
  ctx state params call: pn-modes-3
  ctx state params call: pn-modes-4
  ctx state params call: pn-modes-5
;


( ctx state params -- : key up - the damper falls [control blends it in]. )
dsp: piano-note-off | ctx state:PianoState params -- |
  0.0 -> state.gate
;

( ctx state params -- : every 32 samples.  Blend each mode's decay
  between damper up and damper down by the key and the pedal, and retire
  the hammer once it has rebounded clear of the strings. )
dsp: piano-control | ctx state:PianoState params:PianoParams -- |
  1.0 state.gate f- params.ped-k f* state.damped f* | kd |
  0.0 PN [ | i |
    state.ron& i f@i | ron |
    ron  ron state.rfull& i f@i f- kd f*  f- state.rho& i f!i
    i 1.0 f+ ] times drop
  state.hv 0.0 f<  state.he -0.002 f< and | gone |
  gone 0.0 state.ham-on select -> state.ham-on
;

( state params ba -- F : the hammer.  Predict the strings' mean
  displacement at the strike point without a new force, then solve the
  felt contact for this sample's force on each string. )
dsp: piano-hammer | state:PianoState params:PianoParams ba -- f |
  0.0 0.0 PN [ | i acc |
    i 1.0 f+  acc
    state.c& i f@i state.q& i f@i f*  state.sw& i f@i state.v& i f@i f* f+
      state.rho& i f@i f*  state.cb1& i f@i ba f* f-
      state.phi& i f@i f* f+ ] times nip | ypred |
  params.inv-sr | h |
  state.hu state.hv h f* f+ | ufree |
  ufree ypred f-  state.he  state.hcomp  state.hk state.hp state.halpha params.sr
    contact-solve | e f |
  e -> state.he
  state.nstr f state.hmass f/ f* | a |
  ufree 0.5 h f* h f* a f* f- -> state.hu
  state.hv h a f* f- -> state.hv
  f
;

( state params f ba -- fb : advance every string mode under the hammer
  force f and the bridge acceleration ba; return the net force on the
  bridge. )
dsp: piano-strings | state:PianoState params f ba -- fb |
  0.0 0.0 PN [ | i acc |
    state.q& i f@i | q |  state.v& i f@i | v |
    state.c& i f@i | c |  state.rho& i f@i | r |
    c q f*  state.sw& i f@i v f* f+  r f*
      state.gb1& i f@i f f* f+  state.cb1& i f@i ba f* f- | qn |
    state.ws& i f@i q f* fneg  c v f* f+  r f*
      state.gb2& i f@i f f* f+  state.cb2& i f@i ba f* f- | vn |
    qn state.q& i f!i  vn state.v& i f!i
    i 1.0 f+  acc state.kb& i f@i qn f* f+ ] times nip
  state.tl state.bdisp f* f-
;

( io state params fb -- : the soundboard, driven by the bridge force;
  its acceleration goes back to the strings and out to the microphones. )
dsp: piano-board | io:Io state:PianoState params:PianoParams fb -- |
  0.0 0.0 0.0 0.0 0.0 BN [ | j ba bd ol or |
    state.g& j f@i | g |
    state.bp& j f@i | p |  state.bv& j f@i | v |
    params.bc& j f@i | c |  params.brho& j f@i | r |
    g fb f* | fj |
    c p f*  params.bsw& j f@i v f* f+  r f*  params.bb1& j f@i fj f* f+ | pn |
    params.bws& j f@i p f* fneg  c v f* f+  r f*  params.bb2& j f@i fj f* f+ | vn |
    pn state.bp& j f!i  vn state.bv& j f!i
    vn v f- | dv |
    j 1.0 f+
    ba g dv f* f+
    bd g pn f* f+
    ol params.bwl& j f@i dv f* f+
    or params.bwr& j f@i dv f* f+ ] times | j ba bd ol or |
  ( the resistive part: velocity = mobility x the high-passed force )
  state.fb-lp | lp0 |
  fb lp0 f- params.yr-a f* lp0 f+ | lp |
  lp -> state.fb-lp
  fb lp f- params.yr f* | vrn |
  vrn state.vr f- | dvr |
  vrn -> state.vr
  state.br 0.9995 f* vrn params.inv-sr f* f+ | brn |   ( leaky: no drift )
  brn -> state.br
  ba dvr f+ params.sr f* -> state.bacc
  bd brn f+ -> state.bdisp
  io.out-l ol state.wrl dvr f* f+ params.out-g f* f+ -> io.out-l
  io.out-r or state.wrr dvr f* f+ params.out-g f* f+ -> io.out-r
;

( io ctx state params -- : one voice sample.  Output ACCUMULATES. )
dsp: k-piano-voice | io:Io ctx state:PianoState params -- |
  state.bacc | ba |
  state.ham-on 0.5 f> [ state params ba piano-hammer ] [ 0.0 ] ifte | f |
  state params f ba piano-strings | fb |
  io state params fb piano-board
;
