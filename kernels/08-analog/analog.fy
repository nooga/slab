( analog.fy - the analog layer: drift and component spread.

  drift-step   a slow random walk: white noise through two one-pole
               lowpasses at `rate` Hz, scaled so its RMS is about 1
               whatever the rate.  Scale by cents or octaves at the use.
  spread       a fixed per-voice offset in -1..1 from the voice index and
               a salt, so each voice [and each part of a voice] keeps its
               own slightly-off component values, reproducibly.

  One AGE knob per machine scales all of it: 0 is a factory-fresh unit
  still warming up, 1 a well-used one. )

ustruct: Drift
  f64 rng
  f64 a
  f64 b
;

( s c -- d : one sample of drift; c = 2 pi rate / sr from drift-coef.
  Two one-poles cascaded pass white noise of variance 1/3 with variance
  ~ c/8 ... the sqrt[3/c] normalizes it. )
dsp: drift-step | s:Drift c -- d |
  s.rng 1103515245.0 f* 0.31337 f+ ffrac | r |
  r -> s.rng
  r 2.0 f* 1.0 f- | n |
  s.a  n s.a f- c f*  f+ | a |
  s.b  a s.b f- c f*  f+ | b |
  a -> s.a
  b -> s.b
  b  3.0 c f/ fsqrt  f*  2.0 f*
;

( rate inv-sr -- c )
dsp: drift-coef  f* 6.283185307179586 f* ;

( voice salt -- -1..1 : golden-ratio sequences in two directions, so
  neighbouring voices and neighbouring salts land far apart. )
dsp: spread | v salt -- x |
  v 0.6180339887498949 f*  salt 0.7548776662466927 f*  f+  0.5 f+ ffrac
  2.0 f* 1.0 f-
;

( s seed -- : seed a drift generator that has never run [rng still 0],
  so parts of a voice, and voices, wander independently. )
dsp: drift-seed-once | s:Drift seed -- |
  s.rng 0.0 f=
    seed 0.6180339887498949 f* 0.1234567 f+ ffrac
    s.rng
  select -> s.rng
;
