( convo.fy - CONVO's kernel: a convolution reverb.  The host convolves
  the input with the machine's impulse response [the `convolver` asset,
  src/convolver.zig] and hands it over per sample as io.cv-l / io.cv-r,
  256 samples late.  Everything else is here, after
  the convolution, which is linear, so its order doesn't matter:

    cv -> PREDELAY ring -> LO CUT, HI CUT one-poles -> WIDTH [mid/side]
       -> x LEVEL -> wet
    in -> a 256-sample ring, so the dry lines up with the wet -> dry

  The machine reports the 256 samples with latency!, so the host delays
  the other tracks to match.

  One packed buffer, at 96 kHz:
    region  offset    cap
    dry-l        0    256   exactly the convolver's latency
    dry-r      256    256
    pd-l       512  19456   PREDELAY up to 200 ms
    pd-r     19968  19456
    total    39424 -> 0.411 s )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"

:: CV-LAT 256.0 ;
:: PD-CAP 19456.0 ;
:: PD-L 512.0 ;
:: PD-R 19968.0 ;

ustruct: ConvoState
  f64 buf  f64 buf-len
  f64 dry-pos  f64 pd-pos
  f64 lc-l  f64 lc-r  f64 hc-l  f64 hc-r
;

ustruct: ConvoParams
  ( user-facing )
  f64 predelay-ms
  f64 lowcut-hz  f64 highcut-hz
  f64 width
  f64 level-db
  f64 mix
  ( host-injected IR asset )
  f64 ir  f64 ir-len  f64 ir-sr
  ( derived )
  f64 pd  f64 lc-a  f64 hc-a  f64 wet-g  f64 lat
;

dsp: convo-block-prepare
  | ctx:Ctx state params:ConvoParams |
  ctx.sr | sr |
  params.predelay-ms sr f* 0.001 f* floor 0.0 PD-CAP 4.0 f- fclamp -> params.pd
  1.0  -6.2831853 params.lowcut-hz f* sr f/ exp  f- -> params.lc-a
  1.0  -6.2831853 params.highcut-hz f* sr f/ exp  f- -> params.hc-a
  params.level-db db>lin -> params.wet-g
  CV-LAT -> params.lat
;

( p cap -- p' : a ring head's next position. )
dsp: cv-next | p cap -- q |
  p 1.0 f+ | n |
  n cap f>= 0.0 n select
;

dsp: k-convo-tick | io:Io ctx state:ConvoState params:ConvoParams -- |
  state.buf& p@64 | buf |
  ( the dry, CV-LAT samples late like the wet )
  state.dry-pos | dp |
  buf dp f@i | dl |
  buf CV-LAT dp f+ f@i | dr |
  io.in-l  buf dp f!i
  io.in-r  buf CV-LAT dp f+ f!i
  dp CV-LAT cv-next -> state.dry-pos
  ( PREDELAY: write the wet, read it pd samples back )
  state.pd-pos | pp |
  io.cv-l  buf PD-L pp f+ f!i
  io.cv-r  buf PD-R pp f+ f!i
  pp params.pd f- | r0 |
  r0 0.0 f<  r0 PD-CAP f+  r0  select | r |
  buf PD-L r f+ f@i | pl |
  buf PD-R r f+ f@i | pr |
  pp PD-CAP cv-next -> state.pd-pos
  ( LO CUT and HI CUT, one pole each )
  state.lc-l  pl state.lc-l f-  params.lc-a f*  f+ | ll |
  ll -> state.lc-l
  state.lc-r  pr state.lc-r f-  params.lc-a f*  f+ | lr |
  lr -> state.lc-r
  state.hc-l  pl ll f-  state.hc-l f-  params.hc-a f*  f+ | hl |
  hl -> state.hc-l
  state.hc-r  pr lr f-  state.hc-r f-  params.hc-a f*  f+ | hr |
  hr -> state.hc-r
  ( WIDTH and LEVEL, then the mix )
  hl hr f+ 0.5 f* | m |
  hl hr f- 0.5 f* params.width f* | s |
  1.0 params.mix f- | dg |
  params.mix params.wet-g f* | wg |
  dl dg f*  m s f+ wg f*  f+ -> io.out-l
  dr dg f*  m s f- wg f*  f+ -> io.out-r
;
