( hum.fy - mains hum and a VCR's head-switching buzz, the "brum" under
  cheap gear and old tapes.

    hum   = LVL [0.7 sin + 0.6 [|sin| - 2/pi]]    50 or 60 Hz
    buzz  = SW [q^32 - 1/33] [0.3 + 0.7 sig]      q = 1 - phase at the
                                                  field rate

  A transformer's leakage is the fundamental and odd harmonics; a
  rectifier's ripple is |sin|, a series of even harmonics falling as
  1/n^2 - the 0.6 share makes it a buzz rather than a pure tone.  The
  head switch is a spike each field [59.94 or 50 a second, two heads on
  a drum turning at the frame rate] decaying over about a millisecond,
  louder while the signal is [it rides the audio carrier], DC-free.

  Both are gated by a 0.7 s follower of the level the owner passes, so a
  silent track goes idle: the tape stops when the music does.  Returns
  one mono value to add to both channels. )

include "delay.fy"   ( dl-osc, dl-osc-seed )

ustruct: HumState
  f64 s        ( mains, magic-circle pair )
  f64 c
  f64 ph       ( head-switch phase, 0..1 )
  f64 env      ( gate follower )
;

ustruct: HumParams
  ( set by the owner )
  f64 lvl      ( hum amplitude )
  f64 sw       ( head-switch buzz amplitude )
  f64 mains    ( Hz )
  ( derived - hum-prepare )
  f64 k
  f64 inc      ( head-switch phase step )
  f64 env-c
;

:: HUM-OPEN 16.0 ;   ( the gate is fully open above -24 dBFS )

( sr hp -- )
dsp: hum-prepare | sr hp:HumParams |
  hp.mains 40.0 70.0 fclamp | f |
  6.283185307179586 f f* sr f/ -> hp.k
  ( 60 Hz countries run NTSC at 59.94 fields, 50 Hz PAL at 50 )
  f 55.0 f<  50.0 59.94  select  sr f/ -> hp.inc
  -1.0  0.7 sr f*  f/ exp -> hp.env-c
;

( hs -- )
dsp: hum-seed | hs:HumState |
  hs.s hs.c dl-osc-seed -> hs.c
;

( hs hp lvl -- h : one sample of hum and buzz, gated by lvl. )
dsp: hum-tick | hs:HumState hp:HumParams lvl -- h |
  hs.env | e0 |
  lvl  e0 hp.env-c f*  fmax | e1 |
  e1 1.0e-7 f<  0.0 e1 select -> hs.env
  e0 HUM-OPEN f* 1.0 fmin | gate |
  hs.s hs.c hp.k dl-osc | s c |
  s -> hs.s  c -> hs.c
  s 0.7 f*  s fabs 0.6366197723675814 f- 0.6 f*  f+  hp.lvl f* | hum |
  hs.ph hp.inc f+ | p0 |
  p0 1.0 f>=  p0 1.0 f-  p0  select | ph |
  ph -> hs.ph
  1.0 ph f- | q |
  q q f* | q2 |
  q2 q2 f* | q4 |
  q4 q4 f* | q8 |
  q8 q8 f* | q16 |
  q16 q16 f* 0.030303030303030304 f- | spike |
  lvl 4.0 f* 1.0 fmin 0.7 f* 0.3 f+  spike f*  hp.sw f* | buzz |
  hum buzz f+  gate f*
;
