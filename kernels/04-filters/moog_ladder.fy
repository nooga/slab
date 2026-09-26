( moog_ladder.fy - the transistor ladder with a tanh in every stage.

  Huovilainen's improved model [DAFx 2004]: four one-pole stages, each
  driven through the differential pair's tanh,

    s[n] += g [tanh[in[n]] - tanh[s[n]]]

  with the feedback taken as the half-sample average of the last stage.
  Explicit, so it wants oversampling: run one moog-step per 4x substep.
  The tuning and resonance corrections are Huovilainen's polynomial fits,
  evaluated at the equivalent 2x rate, so the filter self-oscillates at
  the cutoff frequency.

  Signals are volts around +-1; THERMAL = 1 / [2 Vt] with Vt = 0.312 sets
  where the pairs bend.  Driving the input harder is the Minimoog's
  overdriven mixer.  Resonance k = 4 is the edge of oscillation; the
  corrected loop gain lets res 1.0 sustain a clean sine.  Bass drops as
  resonance rises, as on the hardware. )

include "../00-primitives/math.fy"

ustruct: MoogLadder
  f64 s0  f64 s1  f64 s2  f64 s3     ( stage outputs )
  f64 t0  f64 t1  f64 t2  f64 t3     ( tanh of each, cached for the next stage )
  f64 y-prev                         ( last s3, for the half-sample feedback )
  f64 fb                             ( averaged feedback )
;

:: MOOG-THERMAL 1.6025641025641026 ;

( cutoff osr res -- g k : per-sample coefficients for moog-step at rate
  osr [4x]. cutoff is clamped to 20 Hz .. osr/8.8 [21.8 kHz at 192 kHz]. )
dsp: moog-coeffs | cutoff osr res -- g k |
  ( 1.0116 = +20 cents: the fits assume 2x; at 4x they run that flat )
  cutoff 1.0116 f*  20.0  osr 0.11363636363636363 f*  fclamp  2.0 f* osr f/ | fc |
  fc fc f* | fc2 |
  1.8730 fc2 f* fc f*  0.4955 fc2 f* f+  -0.6490 fc f* f+  0.9988 f+ | fcr |
  -3.9364 fc2 f*  1.8409 fc f* f+  0.9968 f+ | acr |
  1.0  -3.141592653589793 fc f* fcr f* exp  f-  MOOG-THERMAL f/
  4.0 res f* acr f*
;

( m x g k -- y : one substep. )
dsp: moog-step | m:MoogLadder x g k -- y |
  x k m.fb f* f-  MOOG-THERMAL f* tanh-fast | u |
  m.s0  u m.t0 f- g f* f+ | s0 |
  s0 MOOG-THERMAL f* tanh-fast | t0 |
  m.s1  t0 m.t1 f- g f* f+ | s1 |
  s1 MOOG-THERMAL f* tanh-fast | t1 |
  m.s2  t1 m.t2 f- g f* f+ | s2 |
  s2 MOOG-THERMAL f* tanh-fast | t2 |
  m.s3  t2 m.t3 f- g f* f+ | s3 |
  s3 MOOG-THERMAL f* tanh-fast | t3 |
  s0 -> m.s0  s1 -> m.s1  s2 -> m.s2  s3 -> m.s3
  t0 -> m.t0  t1 -> m.t1  t2 -> m.t2  t3 -> m.t3
  s3 m.y-prev f+ 0.5 f* -> m.fb
  s3 -> m.y-prev
  s3
;
