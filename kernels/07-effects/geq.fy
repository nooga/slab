( geq.fy - 8-band EQ in the shape of Ableton's EQ Eight: eight bands in
  series, each with an on switch, a filter type, a frequency, a Q and a
  gain.

  Types [the band's `t` value], the same set on every band:
    0 LC48   low cut, 48 dB per octave
    1 LC12   low cut, 12 dB per octave
    2 LSHLF  RBJ low shelf; Q 0.71 is the plain S=1 shelf, higher bumps
    3 BELL   RBJ peaking, Q sets the width
    4 NOTCH  RBJ notch, Q sets the width
    5 HSHLF  RBJ high shelf
    6 HC12   high cut, 12 dB per octave
    7 HC48   high cut, 48 dB per octave
  Gain applies to the shelves and the bell only.  A 12 dB cut is one
  biquad at the band's Q; a 48 dB cut is four cascaded at the Butterworth
  Qs, with the band's Q scaling the last [highest-Q] stage, so Q 0.71 is
  flat Butterworth and higher resonates at the corner.  ADAPT [adaptive
  Q] narrows a bell as its gain grows: Q x [1 + |gain| / 12].

  Each band owns four biquad stages; the ones its type doesn't use, and
  every stage of a band that is off, are passthrough [b0 = 1, the rest
  0], which leaves the signal bit-exact.  geq-block-prepare records
  whether any band is a 48 dB cut, and the render word branches on it
  with `ifte`, so a patch without one runs one stage per band.

  The render word also writes its output into a host buffer ring that
  the panel reads for the spectrum analyser; nothing on the audio path
  reads it back. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/math.fy"

:: GEQ-BANDS 8 ;

ustruct: GeqState
  f64 z 64      ( 8 bands x 4 stages x two z cells )
  f64 ring      ( host-injected analyser ring base pointer )
  f64 ring-len  ( host-injected element count )
  f64 wpos      ( analyser write head, 0..ring-len )
;

ustruct: GeqParams
  ( user-facing, in banks of eight so band i is element i of each )
  f64 g1 f64 g2 f64 g3 f64 g4 f64 g5 f64 g6 f64 g7 f64 g8           ( gain dB )
  f64 q1 f64 q2 f64 q3 f64 q4 f64 q5 f64 q6 f64 q7 f64 q8           ( Q )
  f64 t1 f64 t2 f64 t3 f64 t4 f64 t5 f64 t6 f64 t7 f64 t8           ( type )
  f64 f1 f64 f2 f64 f3 f64 f4 f64 f5 f64 f6 f64 f7 f64 f8           ( Hz )
  f64 on1 f64 on2 f64 on3 f64 on4 f64 on5 f64 on6 f64 on7 f64 on8   ( 0 / 1 )
  f64 adapt     ( adaptive Q, 0 / 1 )
  f64 out-db
  ( derived: per band, per stage b0 b1 b2 a1 a2, a0 normalized to 1 )
  f64 co 160
  f64 out-lin
  f64 stages    ( 4 when any band is a 48 dB cut, else 1 )
;

( ---- coefficients ---------------------------------------------------- )

( mask k co b0 b1 b2 a1 a2 -- : where mask, overwrite the five
  coefficients at element k of co; elsewhere keep them. )
dsp: geq-put | m k co b0 b1 b2 a1 a2 -- |
  m b0  co k f@i         select  co k f!i
  m b1  co k 1.0 f+ f@i  select  co k 1.0 f+ f!i
  m b2  co k 2.0 f+ f@i  select  co k 2.0 f+ f!i
  m a1  co k 3.0 f+ f@i  select  co k 3.0 f+ f!i
  m a2  co k 4.0 f+ f@i  select  co k 4.0 f+ f!i
;

( a alpha cw -- b0 b1 b2 a1 a2 : RBJ peaking EQ. )
dsp: geq-bell | a alpha cw -- b0 b1 b2 a1 a2 |
  1.0  1.0 alpha a f/ f+  f/ | inv |
  -2.0 cw f* inv f* | k |
  1.0 alpha a f* f+ inv f*  k  1.0 alpha a f* f- inv f*  k  1.0 alpha a f/ f- inv f*
;

( a alpha cw -- b0 b1 b2 a1 a2 : RBJ low shelf, beta = 2 sqrt[A] alpha. )
dsp: geq-lshelf | a alpha cw -- b0 b1 b2 a1 a2 |
  a fsqrt 2.0 f* alpha f* | beta |
  a 1.0 f+ | ap1 |
  a 1.0 f- | am1 |
  1.0  ap1 am1 cw f* f+ beta f+  f/ | inv |
  a  ap1 am1 cw f* f- beta f+  f* inv f*
  2.0 a f*  am1 ap1 cw f* f-  f* inv f*
  a  ap1 am1 cw f* f- beta f-  f* inv f*
  -2.0  am1 ap1 cw f* f+  f* inv f*
  ap1 am1 cw f* f+ beta f-  inv f*
;

( a alpha cw -- b0 b1 b2 a1 a2 : RBJ high shelf. )
dsp: geq-hshelf | a alpha cw -- b0 b1 b2 a1 a2 |
  a fsqrt 2.0 f* alpha f* | beta |
  a 1.0 f+ | ap1 |
  a 1.0 f- | am1 |
  1.0  ap1 am1 cw f* f- beta f+  f/ | inv |
  a  ap1 am1 cw f* f+ beta f+  f* inv f*
  -2.0 a f*  am1 ap1 cw f* f+  f* inv f*
  a  ap1 am1 cw f* f+ beta f-  f* inv f*
  2.0  am1 ap1 cw f* f-  f* inv f*
  ap1 am1 cw f* f- beta f-  inv f*
;

( alpha cw -- b0 b1 b2 a1 a2 : RBJ high-pass [a low-cut stage]. )
dsp: geq-hpf | alpha cw -- b0 b1 b2 a1 a2 |
  1.0  1.0 alpha f+  f/ | inv |
  1.0 cw f+ | opc |
  opc 0.5 f* inv f* | h |
  h  0.0 opc f- inv f*  h  -2.0 cw f* inv f*  1.0 alpha f- inv f*
;

( alpha cw -- b0 b1 b2 a1 a2 : RBJ low-pass [a high-cut stage]. )
dsp: geq-lpf | alpha cw -- b0 b1 b2 a1 a2 |
  1.0  1.0 alpha f+  f/ | inv |
  1.0 cw f- | omc |
  omc 0.5 f* inv f* | h |
  h  omc inv f*  h  -2.0 cw f* inv f*  1.0 alpha f- inv f*
;

( alpha cw -- b0 b1 b2 a1 a2 : RBJ notch. )
dsp: geq-notch | alpha cw -- b0 b1 b2 a1 a2 |
  1.0  1.0 alpha f+  f/ | inv |
  -2.0 cw f* inv f* | k |
  inv  k  inv  k  1.0 alpha f- inv f*
;

( co k sw cw q m-lo m-hi -- : a cut stage at element k with Q q: the
  high-pass where m-lo, the low-pass where m-hi. )
dsp: geq-cut-stage | co k sw cw q mlo mhi -- |
  sw q 2.0 f* f/ | alpha |
  mlo  k co  alpha cw geq-hpf  geq-put
  mhi  k co  alpha cw geq-lpf  geq-put
;

( ctx state params -- : every band's stages, the output gain, and the
  stage count the render word branches on. )
dsp: geq-block-prepare | ctx:Ctx state params:GeqParams -- |
  ctx.sr | sr |
  params.co& | co |
  params.adapt 0.5 f> | adapt |
  1.0  0.0 GEQ-BANDS [ | most i |
    params i f@i        | g |
    params i 8.0 f+ f@i 0.1 18.0 fclamp | q |
    params i 16.0 f+ f@i | t |
    params i 24.0 f+ f@i 10.0 22000.0 fclamp | fc |
    params i 32.0 f+ f@i 0.5 f> | on |
    fc 6.283185307179586 f* sr f/ 0.0 3.0 fclamp | w |
    w cos | cw |
    w sin | sw |
    g 0.08304820237218405 f* exp2 | a |   ( 10^[g/40] )
    sw q 2.0 f* f/ | alpha |
    adapt  q  g fabs 0.08333333333333333 f* 1.0 f+ f*  q  select | qb |
    i 20.0 f* | k0 |                      ( the band's first stage )
    ( every stage starts as passthrough )
    k0 4 [ | k | 1.0 co k f!i  0.0 co k 1.0 f+ f!i  0.0 co k 2.0 f+ f!i
          0.0 co k 3.0 f+ f!i  0.0 co k 4.0 f+ f!i  k 5.0 f+ ] times
    drop
    ( one-stage types )
    on t 2.0 f= and  k0 co  a alpha cw geq-lshelf  geq-put
    on t 3.0 f= and  k0 co  a  sw qb 2.0 f* f/  cw geq-bell  geq-put
    on t 4.0 f= and  k0 co  alpha cw geq-notch  geq-put
    on t 5.0 f= and  k0 co  a alpha cw geq-hshelf  geq-put
    ( 12 dB cuts: one stage at the band's Q )
    co k0 sw cw q  on t 1.0 f= and  on t 6.0 f= and  geq-cut-stage
    ( 48 dB cuts: Butterworth 0.5098, 0.6013, 0.9000, 2.5629 )
    on t 0.0 f= and | m48lo |
    on t 7.0 f= and | m48hi |
    co k0         sw cw 0.5097955791041592 m48lo m48hi geq-cut-stage
    co k0 5.0 f+  sw cw 0.6013448869350453 m48lo m48hi geq-cut-stage
    co k0 10.0 f+ sw cw 0.8999762231364156 m48lo m48hi geq-cut-stage
    co k0 15.0 f+ sw cw 2.5629154477415055 q 1.4142135623730951 f* f*
      m48lo m48hi geq-cut-stage
    m48lo m48hi or  4.0  most  select  i 1.0 f+ ] times
  drop -> params.stages
  params.out-db db>lin -> params.out-lin
;

( ---- per sample ------------------------------------------------------ )

( co z k x -- y : biquad stage k [coefficients at 5k, state at 2k],
  transposed Direct Form II. )
dsp: geq-stage | co z k x -- y |
  co k 5.0 f* f@i x f*  z k 2.0 f* f@i f+ | y |
  co k 5.0 f* 1.0 f+ f@i x f*  co k 5.0 f* 3.0 f+ f@i y f* f-
    z k 2.0 f* 1.0 f+ f@i f+
  z k 2.0 f* f!i
  co k 5.0 f* 2.0 f+ f@i x f*  co k 5.0 f* 4.0 f+ f@i y f* f-
  z k 2.0 f* 1.0 f+ f!i
  y
;

( co z x -- y : every band, its first stage only. )
dsp: geq-run1 | co z x -- y |
  x 0.0 GEQ-BANDS [ | x b | co z b 4.0 f* x geq-stage  b 1.0 f+ ] times
  drop
;

( co z x -- y : every band, all four stages. )
dsp: geq-run4 | co z x -- y |
  x 0.0 GEQ-BANDS [ | x b |
    co z b 4.0 f* x geq-stage | x |
    co z b 4.0 f* 1.0 f+ x geq-stage | x |
    co z b 4.0 f* 2.0 f+ x geq-stage | x |
    co z b 4.0 f* 3.0 f+ x geq-stage  b 1.0 f+ ] times
  drop
;

( io ctx state params -- : one sample through the eight bands. )
dsp: k-geq-tick | io:Io ctx state:GeqState params:GeqParams -- |
  params.co& | co |
  state.z& | z |
  io.in-l | x |
  params.stages 2.5 f<
  [ co z x geq-run1 ]
  [ co z x geq-run4 ]
  ifte
  params.out-lin f* | y |
  y io f!64
  ( the analyser tap )
  state.ring& p@64 | ring |
  state.wpos | w |
  y ring w f!i
  w 1.0 f+ | w1 |
  w1 state.ring-len  w1  0.0  fsel-lt -> state.wpos
;
