( tone.fy - the small filters for tone shaping around a nonlinearity:
  a TPT one-pole low-pass, one-pole shelves whose cut and boost cancel
  exactly, and Simper's SVF bell.  sat2 wraps its shaper in them [the
  pre/de-emphasis that is most of each mode's sound]; tape2 builds its
  record/playback EQ and head bump from them.  Coefficients per block
  [*-set, pole-G], one state struct per filter per channel. )

include "../00-primitives/math.fy"

ustruct: Pole  f64 s ;
ustruct: BellSt  f64 ic1  f64 ic2 ;
ustruct: Bell  f64 a1  f64 a2  f64 a3  f64 m1 ;
( a one-pole shelf: x + k LP[x] [low] or x + k [x - LP[x]] [high], its
  pole placed so a shelf and its negative in dB cancel exactly )
ustruct: Shelf  f64 G  f64 k ;

( f sr -- G : a TPT one-pole's gain. )
dsp: pole-G | f sr -- G |
  f 3.141592653589793 f* sr f/ tan | g |
  g 1.0 g f+ f/
;

( p G x -- y : TPT one-pole lowpass. )
dsp: pole-lp | p:Pole G x -- y |
  x p.s f- G f* | v |
  v p.s f+ | y |
  y v f+ -> p.s
  y
;

( b f db q sr -- : an SVF bell [Simper]; 0 dB is an exact pass. )
dsp: bell-set | b:Bell f db q sr -- |
  db 0.025 f* 3.321928094887362 f* exp2 | A |
  f 3.141592653589793 f* sr f/ tan | g |
  1.0 q A f* f/ | k |
  1.0  1.0 g g k f+ f* f+  f/ | a1 |
  a1 -> b.a1
  g a1 f* | a2 |
  a2 -> b.a2
  g a2 f* -> b.a3
  k A A f* 1.0 f- f* -> b.m1
;

( st b x -- y )
dsp: bell-tick | st:BellSt b:Bell x -- y |
  x st.ic2 f- | v3 |
  b.a1 st.ic1 f*  b.a2 v3 f*  f+ | v1 |
  st.ic2  b.a2 st.ic1 f* f+  b.a3 v3 f* f+ | v2 |
  v1 2.0 f* st.ic1 f- -> st.ic1
  v2 2.0 f* st.ic2 f- -> st.ic2
  x  b.m1 v1 f*  f+
;

( sh f db hi sr -- : a shelf of db at corner f, high if hi = 1.  The
  pole sits at f / sqrt G [low] or f sqrt G [high]: the zero then lands
  at the mirror point, and -db is the exact inverse. )
dsp: shelf-set | sh:Shelf f db hi sr -- |
  db db>lin | G |
  G 1.0 f- -> sh.k
  db 0.5 f* db>lin | r |
  hi 0.5  f r f/  f r f*  fsel-lt  0.45 sr f* fmin  sr pole-G -> sh.G
;

( sh x p -- y : a low shelf with its state p. )
dsp: shelf-lo | sh:Shelf x p -- y |  x  p sh.G x pole-lp sh.k f*  f+ ;

( sh x p -- y : a high shelf. )
dsp: shelf-hi | sh:Shelf x p -- y |  x  x p sh.G x pole-lp f-  sh.k f*  f+ ;

