( ota_cascade.fy - the Prophet-5's 4-pole: an OTA cascade [SSM2040 in
  revs 1-2, CEM3320 in rev 3] with a tube designer's resonance loop.

  Four one-pole stages, each through its pair's tanh, as in Huovilainen's
  ladder model [moog_ladder.fy], run at 2x: that is the rate his tuning
  and resonance fits were made for, so they apply without correction.

  The feedback path is where the character lives [the tips in
  reference: an ex-Korg tube designer's notes]:

    fb -> tanh[fb + OFFS] - tanh[OFFS] -> coupling highpass -> x k

  The offset makes the saturation lopsided, so a screaming resonance
  grows even harmonics and sizzles instead of clipping flat; the tanh is
  scaled back to unit slope, so small-signal tuning and the oscillation
  threshold stay where the fits put them.  The highpass is the coupling
  capacitor in vintage feedback paths: it removes the offset's DC and
  lets the loop's bass through a little less.  The tip says ~7 Hz; its
  phase lead there stops the loop sustaining below ~150 Hz, so the voice
  sets 3 Hz, which still oscillates at 100 Hz. )

include "../00-primitives/math.fy"

ustruct: OtaCascade
  f64 s0  f64 s1  f64 s2  f64 s3     ( stage outputs )
  f64 t0  f64 t1  f64 t2  f64 t3     ( tanh of each, cached for the next stage )
  f64 y-prev                         ( last s3, for the half-sample feedback )
  f64 fb                             ( averaged feedback )
  f64 hp-x  f64 hp-y                 ( coupling highpass state )
;

:: OTA-THERMAL 1.6025641025641026 ;
:: OTA-OFFS 0.3 ;
:: OTA-TOFFS 0.2913126124515909 ;    ( tanh 0.3 )
:: OTA-SLOPE 1.0927316152938014 ;    ( 1 / [1 - tanh^2 0.3] )

( cutoff osr res -- g k : coefficients at the 2x rate osr.  cutoff is
  clamped to 20 Hz .. 0.21 osr. )
dsp: ota-coeffs | cutoff osr res -- g k |
  cutoff  20.0  osr 0.21 f*  fclamp  2.0 f* osr f/ | fc |
  fc fc f* | fc2 |
  1.8730 fc2 f* fc f*  0.4955 fc2 f* f+  -0.6490 fc f* f+  0.9988 f+ | fcr |
  -3.9364 fc2 f*  1.8409 fc f* f+  0.9968 f+ | acr |
  1.0  -3.141592653589793 fc f* fcr f* exp  f-  OTA-THERMAL f/
  4.0 res f* acr f*
;

( hz osr -- a : the coupling highpass coefficient. )
dsp: ota-hp-coef | hz osr -- a |
  1.0  1.0  6.283185307179586 hz f* osr f/  f+  f/
;

( m x g k hpa -- y : one 2x step. )
dsp: ota-step | m:OtaCascade x g k hpa -- y |
  m.fb OTA-OFFS f+ tanh-fast OTA-TOFFS f-  OTA-SLOPE f* | fs |
  m.hp-y fs f+ m.hp-x f- hpa f* | fh |
  fs -> m.hp-x
  fh -> m.hp-y
  x k fh f* f- | v |
  v OTA-THERMAL f* tanh-fast | u |
  m.s0  u m.t0 f- g f* f+ | s0 |
  s0 OTA-THERMAL f* tanh-fast | t0 |
  m.s1  t0 m.t1 f- g f* f+ | s1 |
  s1 OTA-THERMAL f* tanh-fast | t1 |
  m.s2  t1 m.t2 f- g f* f+ | s2 |
  s2 OTA-THERMAL f* tanh-fast | t2 |
  m.s3  t2 m.t3 f- g f* f+ | s3 |
  s3 OTA-THERMAL f* tanh-fast | t3 |
  s0 -> m.s0  s1 -> m.s1  s2 -> m.s2  s3 -> m.s3
  t0 -> m.t0  t1 -> m.t1  t2 -> m.t2  t3 -> m.t3
  s3 m.y-prev f+ 0.5 f* -> m.fb
  s3 -> m.y-prev
  s3
;
