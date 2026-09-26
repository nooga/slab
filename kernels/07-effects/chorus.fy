( chorus.fy - Juno-style BBD chorus: one modulated delay tap per
  channel, triangle LFO, right channel running the inverted LFO - the
  half-period phase shift IS the Juno stereo trick - and a one-pole
  lowpass on the wet path standing in for the BBD's darkness.

  The MODE switch selects the measured Juno-106 voicings as base
  values; RATE and DEPTH are multipliers around them, so noon = the
  canned warm sound and the extremes are new territory:

    mode I     LFO 0.513 Hz   center 3.35 ms   depth +-1.80 ms
    mode II    LFO 0.863 Hz   center 3.35 ms   depth +-1.80 ms
    mode I+II  LFO 9.75 Hz    center 3.20 ms   depth +-0.20 ms

  SPREAD scales the right channel's LFO inversion: 1 = full Juno wide,
  0 = mono chorus.  Probe case: chorus-render - impulse train, the wet
  tap's delay trace is recovered per impulse and ratcheted against
  center/depth/rate. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
ustruct: ChorusState
  f64 buf        ( host-injected ring base pointer )
  f64 buf-len    ( host-injected element count )
  f64 wpos
  f64 lfo-phase
  f64 lpf-z      ( BBD tone filter state )
;

ustruct: ChorusParams
  ( user-facing )
  f64 mode       ( 0 I, 1 II, 2 I+II )
  f64 rate-mul
  f64 depth-mul
  f64 tone-hz
  f64 spread
  f64 mix
  ( derived - filled by chorus-block-prepare )
  f64 lfo-inc
  f64 center-spl
  f64 depth-spl
  f64 tone-a
;

( ctx state params -- : mode voicing times the musical multipliers. )
dsp: chorus-block-prepare
  | ctx state params |
  ctx Ctx.sr@ | sr |
  params ChorusParams.mode@ | mode |
  mode 0.5  0.513  mode 1.5  0.863  9.75  fsel-lt  fsel-lt
  params ChorusParams.rate-mul@ f* sr f/
  params ChorusParams.lfo-inc-p f!64
  mode 1.5  3.35  3.20  fsel-lt  0.001 f* sr f*
  params ChorusParams.center-spl-p f!64
  mode 1.5  1.80  0.20  fsel-lt  0.001 f* sr f*
  params ChorusParams.depth-mul@ f*
  params ChorusParams.depth-spl-p f!64
  params ChorusParams.tone-hz@ 6.2831853 f* sr f/ 0.0 1.0 fclamp
  params ChorusParams.tone-a-p f!64
;

( io ctx state params -- : one BBD tick.  The triangle argument gets a
  chan * spread/2 offset - a half-period shift inverts a triangle, so
  spread 1 is the Juno's mirrored L/R modulation. )
dsp: k-chorus-tick
  | out ctx state params |
  state ChorusState.buf-p p@64 | buf |
  state ChorusState.buf-len@ | len |
  state ChorusState.lfo-phase@ params ChorusParams.lfo-inc@ f+ ffrac | ph |
  ph state ChorusState.lfo-phase-p f!64
  ph  ctx Ctx.chan@ 0.5 f* params ChorusParams.spread@ f*  f+ ffrac
  0.5 f- | u |
  u 0.0  0.0 u f-  u  fsel-lt 4.0 f* 1.0 f- | tri |
  params ChorusParams.center-spl@  params ChorusParams.depth-spl@ tri f*  f+
  1.0  len 4.0 f-  fclamp | d |
  out Io.in-l@ | x |
  state ChorusState.wpos@ | w |
  x buf w f!i
  w d f- | rp0 |
  rp0 0.0  rp0 len f+  rp0 fsel-lt | rp |
  buf rp f@i | s0 |
  rp 1.0 f+ | rp1 |
  rp1 len  rp1  rp1 len f-  fsel-lt | rpw |
  buf rpw f@i | s1 |
  s0  s1 s0 f-  rp ffrac f*  f+ | v |
  state ChorusState.lpf-z@ | z |
  z  v z f-  params ChorusParams.tone-a@ f*  f+ | zn |
  zn state ChorusState.lpf-z-p f!64
  w 1.0 f+ | w1 |
  w1 len  w1  w1 len f-  fsel-lt
  state ChorusState.wpos-p f!64
  x  1.0 params ChorusParams.mix@ f-  f*
  zn params ChorusParams.mix@ f*  f+
  out f!64
;
