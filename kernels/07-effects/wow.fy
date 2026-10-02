( wow.fy - wow and flutter: a stereo delay read on one modulated head,
  the pitch wobble of a turntable or a tape transport.  Reusable: char2
  runs it after its compressor, tape2 inside its transport.

    t   = centre + wow-spl sin[wow] + fl-spl sin[flutter]
                 + rnd [wow-spl drift + fl-spl jitter]          samples
    yl  = Hermite read t behind the write head [delay.fy dl-read]
    yr  = the same at t + skew                                  azimuth

  A pitch deviation dev at f Hz is a delay swing of dev / [2 pi f]
  seconds, so the depths set deviation, not time: DEPTH 1 is 2.5 % at
  the wow rate [a warped record, a dying belt: 40 cents] and 0.4 % at
  flutter [12x the wow rate - a record's turn and its rumble, a capstan
  and its idler]; FLUTTER adds up to 1.2 % more at the flutter rate on
  its own.  A good deck is around 0.1 % [depth 0.04]: real, and
  inaudible on drums, so the owners' knobs reach well past it.  RND mixes in noise twice
  low-passed [an Ornstein-Uhlenbeck-like drift at the wow rate and a
  jitter at the flutter rate, each normalized to unit deviation], so a
  worn transport wanders instead of ticking like an LFO.  SKEW reads the
  right channel a few samples later: a head out of azimuth, which
  combs the highs when the pair is summed.

  The centre sits just past the deepest swing, so the head never reads
  ahead of itself.  The owner declares the two rings [manifest `buffer`;
  20 ms covers a 33 RPM record at full depth, 50 ms a worn tape with
  randomness and skew] at WowState.bl / bl-len and br / br-len, calls wow-prepare per
  block, wow-seed in its prepare and wow-run per sample.  With every
  depth at 0 the read is skipped [ifte] and the rings are only fed, so
  turning it up never replays stale audio.  At FLUTTER, RND and SKEW 0
  the output is exactly the plain two-sine read. )

include "delay.fy"   ( dl-read, dl-osc, dl-osc-seed )
include "../00-primitives/rand.fy"

ustruct: WowState
  f64 bl       ( host-injected ring pointers and lengths )
  f64 bl-len
  f64 br
  f64 br-len
  f64 wpos     ( shared write head )
  f64 ws       ( wow, magic-circle pair )
  f64 wc
  f64 fs       ( flutter )
  f64 fc
  f64 rng      ( noise generator )
  f64 d1       ( drift: two one-poles )
  f64 d2
  f64 j1       ( jitter: two one-poles )
  f64 j2
;

ustruct: WowParams
  ( user-facing )
  f64 depth    ( 0..1 )
  f64 rate     ( wow rate, Hz )
  f64 flutter  ( 0..1, extra flutter )
  f64 rnd      ( 0..1, randomness )
  f64 skew     ( right channel's extra delay, samples )
  ( derived - wow-prepare )
  f64 on
  f64 wk       ( oscillator steps, 2 pi f / sr )
  f64 fk
  f64 wspl     ( swings, samples )
  f64 fspl
  f64 ctr      ( centre delay, samples )
  f64 da       ( drift and jitter one-pole coefficients )
  f64 ja
  f64 dn       ( ... and the gains that make them unit deviation, x rnd x swing )
  f64 jn
;

:: WOW-DEV 0.025 ;        ( pitch deviation at depth 1: seasick )
:: WOW-FL-DEV 0.004 ;
:: WOW-FL-EXTRA 0.012 ;   ( FLUTTER 1 adds this )
:: WOW-FL-MULT 12.0 ;     ( flutter rate, x the wow rate )

( a -- n : 1 / the deviation of uniform noise [-1, 1] through two
  one-poles with coefficient a: var = a^4 [1 + r^2] / [1 - r^2]^3 / 3,
  r = 1 - a. )
dsp: wow-norm | a -- n |
  1.0 a f- | r |
  r r f* | r2 |
  1.0 r2 f- | q |
  a a f* a a f* f*  1.0 r2 f+ f*  q q f* q f*  3.0 f*  f/ | v |
  1.0  v 1.0e-30 fmax fsqrt  f/
;

( sr wp -- )
dsp: wow-prepare | sr wp:WowParams |
  wp.depth wp.flutter f+ wp.skew f+ | any |
  0.0 any f< 1.0 0.0 select -> wp.on
  wp.rate 0.1 5.0 fclamp | fw |
  fw WOW-FL-MULT f* | ff |
  6.283185307179586 fw f* sr f/ -> wp.wk
  6.283185307179586 ff f* sr f/ -> wp.fk
  wp.depth WOW-DEV f*  6.283185307179586 fw f*  f/  sr f* | aw |
  wp.depth WOW-FL-DEV f*  wp.flutter WOW-FL-EXTRA f*  f+
  6.283185307179586 ff f*  f/  sr f* | af |
  aw -> wp.wspl
  af -> wp.fspl
  ( the random parts: one-poles at the wow and flutter rates )
  1.0  -6.283185307179586 fw f* sr f/ exp  f- | da |
  1.0  -6.283185307179586 ff f* sr f/ exp  f- | ja |
  da -> wp.da
  ja -> wp.ja
  da wow-norm wp.rnd f* aw f* -> wp.dn
  ja wow-norm wp.rnd f* af f* -> wp.jn
  ( the noise peaks near 3 deviations; skew rides on top )
  aw af f+  1.0 wp.rnd 3.0 f* f+  f*  wp.skew f+  5.0 f+ -> wp.ctr
;

( ws -- : start the oscillators at [0, 1]; safe to run every block. )
dsp: wow-seed | ws:WowState |
  ws.ws ws.wc dl-osc-seed -> ws.wc
  ws.fs ws.fc dl-osc-seed -> ws.fc
;

( ws wp xl xr -- yl yr : one stereo sample. )
dsp: wow-run | ws:WowState wp:WowParams xl xr -- yl yr |
  ws.bl& p@64 | bl |
  ws.br& p@64 | br |
  ws.bl-len | len |
  ws.wpos | w |
  xl bl w f!i
  xr br w f!i
  w 1.0 f+ | w1 |
  w1 len  w1  0.0  fsel-lt -> ws.wpos
  wp.on 0.5 f<
  [ xl xr ]
  [ ws.ws ws.wc wp.wk dl-osc | s1 c1 |
    s1 -> ws.ws  c1 -> ws.wc
    ws.fs ws.fc wp.fk dl-osc | s2 c2 |
    s2 -> ws.fs  c2 -> ws.fc
    ws.rng& rand-b | u |
    ws.d1  u ws.d1 f-  wp.da f*  f+ | d1 |
    ws.d2  d1 ws.d2 f-  wp.da f*  f+ | d2 |
    ws.j1  u ws.j1 f-  wp.ja f*  f+ | j1 |
    ws.j2  j1 ws.j2 f-  wp.ja f*  f+ | j2 |
    d1 -> ws.d1  d2 -> ws.d2  j1 -> ws.j1  j2 -> ws.j2
    wp.ctr  s1 wp.wspl f*  f+  s2 wp.fspl f*  f+
    d2 wp.dn f*  j2 wp.jn f*  f+  f+ | t |
    bl len w t dl-read
    br len w  t wp.skew f+  dl-read ]
  ifte
;
