( wow.fy - wow and flutter: a stereo delay read on one modulated head,
  the pitch wobble of a turntable or a tape transport.  Reusable: char2
  uses it after its compressor, a tape machine would before its lo-fi.

    t   = centre + wow-spl sin[wow] + fl-spl sin[flutter]   samples
    y   = Hermite read t behind the write head [delay.fy dl-read]

  A pitch deviation dev at f Hz is a delay swing of dev / [2 pi f]
  seconds, so DEPTH sets deviation, not time: WOW 1 is 0.8 % at the
  wow rate and 0.15 % at flutter [12x the wow rate - a record's turn and
  its rumble, a capstan and its idler].  The centre sits just past the
  deepest swing, so the head never reads ahead of itself.

  The owner declares the two rings [manifest `buffer`, >= 20 ms covers a
  33 RPM record at full depth] at WowState.bl / bl-len and br / br-len,
  calls wow-prepare per block, wow-seed in its prepare and wow-run per
  sample.  DEPTH 0 skips the read [ifte] and only feeds the rings, so
  turning it up never replays stale audio. )

include "delay.fy"   ( dl-read, dl-osc, dl-osc-seed )

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
;

ustruct: WowParams
  ( user-facing )
  f64 depth    ( 0..1 )
  f64 rate     ( wow rate, Hz )
  ( derived - wow-prepare )
  f64 on
  f64 wk       ( oscillator steps, 2 pi f / sr )
  f64 fk
  f64 wspl     ( swings, samples )
  f64 fspl
  f64 ctr      ( centre delay, samples )
;

:: WOW-DEV 0.008 ;        ( pitch deviation at depth 1 )
:: WOW-FL-DEV 0.0015 ;
:: WOW-FL-MULT 12.0 ;     ( flutter rate, x the wow rate )

( sr wp -- )
dsp: wow-prepare | sr wp:WowParams |
  0.0 wp.depth f< 1.0 0.0 select -> wp.on
  wp.rate 0.1 5.0 fclamp | fw |
  fw WOW-FL-MULT f* | ff |
  6.283185307179586 fw f* sr f/ -> wp.wk
  6.283185307179586 ff f* sr f/ -> wp.fk
  wp.depth WOW-DEV f*  6.283185307179586 fw f*  f/  sr f* | aw |
  wp.depth WOW-FL-DEV f*  6.283185307179586 ff f*  f/  sr f* | af |
  aw -> wp.wspl
  af -> wp.fspl
  aw af f+ 5.0 f+ -> wp.ctr
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
    wp.ctr  s1 wp.wspl f*  f+  s2 wp.fspl f*  f+ | t |
    bl len w t dl-read
    br len w t dl-read ]
  ifte
;
