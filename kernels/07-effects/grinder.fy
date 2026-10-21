( grinder.fy - stacked distortion: Grinder [docs/43 §Grinder].

  in -> PHASE -> EMPH pre -> SIZZLE -> DRIVE [x FLUX] -> up4
     -> ALGO x STAGES [BIAS] -> dec4 -> EMPH post -> DC -> TONE
     -> AUTO -> MIX with the dry -> OUT -> CLIP

  ALGO picks the curve, one versioned branch [only its curve runs]:
    OVERDRIVE  tanh: the op-amp drive, rounded
    RAT        hard clip with a narrow knee: the op-amp into diodes
    FUZZ       a biased, over-driven tanh: lopsided, gated by BIAS
    SOFT       the cubic soft clip
    HARD       a straight limit at +-1
    FOLD       the triangle fold [Folder does it anti-aliased and fuller]
    SINE       tanh with a sine ripple on the curve: dense high partials
    CUBE       u^3 into tanh: crushes the quiet parts, crossover grit
    RECT       full-wave rectified: octave-up hash
    DEAD       a dead zone that steps away from zero: brutal crossover
  STAGES runs the curve again on its own output, flipped and pushed
  [x -2], up to four times.  BIAS shifts the operating point, more so
  as the input's envelope rises, so the asymmetry follows the playing.

  EMPH is a pair of bells mirrored around the drive: LO and HI boost a
  band into the curve and cut it back after, so that band distorts
  harder while the balance stays where it was.  SIZZLE adds noise in a
  narrow window around each zero crossing [within 15 % of the
  envelope]: the drive turns it into hash on every crossing while the
  note stays on top.  FLUX drives the curve harder as the low
  band [under 200 Hz] gets louder, so the bass pushes everything above
  it into the clip.  PHASE is self-modulated delay: the signal delayed
  by a lowpassed copy of itself, watery at low settings, sideband hash
  at the top.

  AUTO matches the wet's peak level to the input's, each held with a
  1 s release, and holds through silence: the gain stays put through a
  note, so a sustained note keeps its distorted sustain.  CLIP is the last word:
  OFF, SOFT [a knee into 0 dBFS] or HARD.  4x oversampled; dual mono. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../00-primitives/oversample.fy"
include "../00-primitives/follow.fy"
include "../00-primitives/rand.fy"
include "../04-filters/tone.fy"

ustruct: GrindState
  f64 buf      ( PHASE ring: host-injected base pointer )
  f64 buf-len
  f64 wpos
  f64 ph-lp
  Up4 up
  Dec4 dec
  BellSt lo-pre BellSt hi-pre BellSt lo-post BellSt hi-post
  Follow ein
  Follow elow
  Follow ain
  Follow awet
  f64 low-lp
  f64 seed
  f64 dc-x f64 dc-y
  f64 t1 f64 t2
  f64 auto
  f64 d1 f64 d2 f64 d3 f64 d4 f64 d5
;

ustruct: GrindParams
  ( user-facing )
  f64 algo
  f64 drive-db
  f64 stages   ( 0..3: 1..4 )
  f64 bias
  f64 lo-hz f64 lo-db
  f64 hi-hz f64 hi-db
  f64 sizzle
  f64 flux
  f64 phase
  f64 tone
  f64 auto-on
  f64 clip     ( 0 OFF, 1 SOFT, 2 HARD )
  f64 mix
  f64 out-db
  ( derived )
  f64 drive
  Bell lo-up Bell hi-up Bell lo-dn Bell hi-dn
  f64 low-g
  f64 ph-g
  f64 ph-spl
  f64 tone-g
  f64 dc-r
  f64 atk-c f64 rel-c f64 auto-c f64 lvl-atk f64 lvl-rel
  f64 out
  f64 lat
;

:: GR-FLUSH 1.0e-15 ;
:: GR-STAGE -2.0 ;

dsp: grinder-block-prepare | ctx:Ctx s p:GrindParams -- |
  ctx.sr | sr |
  p.drive-db db>lin -> p.drive
  p.lo-up& p.lo-hz p.lo-db 0.7 sr bell-set
  p.lo-dn& p.lo-hz p.lo-db fneg 0.7 sr bell-set
  p.hi-up& p.hi-hz p.hi-db 0.7 sr bell-set
  p.hi-dn& p.hi-hz p.hi-db fneg 0.7 sr bell-set
  200.0 6.283185307179586 f* sr f/ -> p.low-g
  300.0 6.283185307179586 f* sr f/ -> p.ph-g
  ( PHASE: the swing up to ~25 ms, cubed so the low end of the knob is fine )
  p.phase p.phase f* p.phase f*  0.025 f* sr f* -> p.ph-spl
  p.tone 6.283185307179586 f* sr f/ 0.0 1.0 fclamp -> p.tone-g
  -125.66370614359172 sr f/ exp -> p.dc-r
  0.003 sr follow-coef -> p.atk-c
  0.08 sr follow-coef -> p.rel-c
  0.05 sr follow-coef -> p.auto-c
  0.005 sr follow-coef -> p.lvl-atk
  1.0 sr follow-coef -> p.lvl-rel
  p.out-db db>lin -> p.out
  0.0 p.mix  OS4-LATENCY 0.0  fsel-lt -> p.lat
;

( u -- s : the sign, +1 at 0. )
dsp: gr-sign | u -- s |  u 0.0 f< -1.0 1.0 select ;

( u algo -- y : the curve. )
dsp: gr-curve | u algo -- y |
  algo 4.5 f<
  [ algo 1.5 f<
    [ algo 0.5 f<
      [ u tanh-fast ]
      [ u fabs | a |
        a 0.9 f<  a  a 1.1 f<  a  a 0.9 f- dup f* 2.5 f*  f-  1.0  select  select
        u gr-sign f* ] ifte ]
    [ algo 2.5 f<
      [ u 2.0 f* 0.4 f+ tanh-fast 0.379949 f- ]
      [ algo 3.5 f<
        [ u -1.0 1.0 fclamp | a |  a 1.5 f*  a a f* a f* 0.5 f*  f- ]
        [ u -1.0 1.0 fclamp ] ifte ] ifte ] ifte ]
  [ algo 6.5 f<
    [ algo 5.5 f<
      [ u 1.0 f+ | v |  v  v 0.25 f* floor 4.0 f*  f- | w |  1.0  w 2.0 f- fabs  f- ]
      [ u tanh-fast | v |  v 0.8 f*  v 28.0 f* sin 0.2 f*  f+ ] ifte ]
    [ algo 7.5 f<
      [ u u f* u f* tanh-fast ]
      [ algo 8.5 f<
        [ u fabs tanh-fast 2.0 f* ]
        [ u fabs | a |  a 0.12 f<  0.0  a 0.12 f+  select  u gr-sign f*  tanh-fast ] ifte ] ifte ] ifte ] ifte
;

( p u b -- y : the stages on one substep. )
dsp: gr-stages | p:GrindParams u b -- y |
  p.algo | al |
  u b f+ al gr-curve | y1 |
  y1 GR-STAGE f* b f+ al gr-curve | y2 |
  y2 GR-STAGE f* b f+ al gr-curve | y3 |
  y3 GR-STAGE f* b f+ al gr-curve | y4 |
  p.stages 0.5 y1  p.stages 1.5 y2  p.stages 2.5 y3 y4  fsel-lt fsel-lt fsel-lt
;

( s p x -- y : PHASE, the signal delayed by its own lowpass. )
dsp: gr-phase | s:GrindState p:GrindParams x -- y |
  s.buf& p@64 | buf |
  s.buf-len | len |
  s.ph-lp  x s.ph-lp f-  p.ph-g f*  f+ | m |
  m GR-FLUSH f+ GR-FLUSH f- -> s.ph-lp
  m 4.0 f* tanh-fast 1.0 f+  p.ph-spl f*  1.0  len 4.0 f-  fclamp | d |
  s.wpos | w |
  x buf w f!i
  w d f- | rp0 |
  rp0 0.0  rp0 len f+  rp0 fsel-lt | rp |
  buf rp f@i | s0 |
  rp 1.0 f+ | rp1 |
  rp1 len  rp1  rp1 len f-  fsel-lt | rpw |
  buf rpw f@i | s1 |
  w 1.0 f+ | w1 |
  w1 len  w1  w1 len f-  fsel-lt -> s.wpos
  s0  s1 s0 f-  rp ffrac f*  f+
;

dsp: k-grinder-tick | out:Io ctx s:GrindState p:GrindParams -- |
  out.in-l | dry |
  p.phase 0.0 f=  [ dry ]  [ s p dry gr-phase ] ifte | x0 |
  s.lo-pre& p.lo-up& x0 bell-tick | x1 |
  s.hi-pre& p.hi-up& x1 bell-tick | x2 |
  s.ein& x2 p.atk-c p.rel-c follow-step | e |
  ( SIZZLE: noise in a window around the zero crossings )
  s.seed& rand-b | n |
  1.0  x2 fabs  e 0.15 f* 1.0e-6 f+  f/  f-  0.0 fmax | win |
  win  e f*  p.sizzle f* 0.3 f*  n f* | sz |
  x2 sz f+ | x3 |
  ( FLUX: the low band's level drives the curve harder )
  s.low-lp  x2 s.low-lp f-  p.low-g f*  f+ | lo |
  lo GR-FLUSH f+ GR-FLUSH f- -> s.low-lp
  s.elow& lo p.atk-c p.rel-c follow-step | el |
  1.0  p.flux el f* 8.0 f*  f+  p.drive f* | g |
  x3 g f* | x |
  p.bias  0.15  e 1.5 f*  f+  f* | b |
  s.up& x up4 | a0 a1 a2 a3 |
  s.dec&  p a0 b gr-stages  p a1 b gr-stages  p a2 b gr-stages  p a3 b gr-stages  dec4 | yd |
  s.lo-post& p.lo-dn& yd bell-tick | y1 |
  s.hi-post& p.hi-dn& y1 bell-tick | y2 |
  ( DC: BIAS, FUZZ and RECT leave an offset )
  y2 s.dc-x f-  p.dc-r s.dc-y f*  f+ | dcy |
  y2 -> s.dc-x
  dcy GR-FLUSH f+ GR-FLUSH f- -> s.dc-y
  ( TONE: two one-poles, 12 dB )
  s.t1  dcy s.t1 f-  p.tone-g f*  f+ | t1 |
  t1 GR-FLUSH f+ GR-FLUSH f- -> s.t1
  s.t2  t1 s.t2 f-  p.tone-g f*  f+ | t2 |
  t2 GR-FLUSH f+ GR-FLUSH f- -> s.t2
  ( AUTO: the wet's held peak matched to the input's, held in silence )
  s.ain& x2 p.lvl-atk p.lvl-rel follow-step | li |
  s.awet& t2 p.lvl-atk p.lvl-rel follow-step | lw |
  li  lw 1.0e-6 fmax f/  0.03 4.0 fclamp | r0 |
  s.auto 0.0 f=  1.0 s.auto select | a |
  li 1.0e-4 f<  a r0 select | ratio |
  a  ratio a f-  1.0 p.auto-c f-  f*  f+ | ag |
  ag -> s.auto
  p.auto-on 0.5 f<  1.0 ag select | gain |
  0.0 p.mix  s.d5  dry  fsel-lt | dly |
  s.d4 -> s.d5
  s.d3 -> s.d4
  s.d2 -> s.d3
  s.d1 -> s.d2
  dry -> s.d1
  t2 gain f* p.mix f*  dly 1.0 p.mix f- f*  f+  p.out f* | y |
  ( CLIP: a knee from 0.75 into 1.0, or a hard limit )
  y fabs | ya |
  ya 0.75 f<  ya  ya 1.25 f<  ya  ya 0.75 f- dup f* 1.0 f*  f-  1.0  select  select  y gr-sign f* | soft |
  p.clip 0.5 f<  y  p.clip 1.5 f<  soft  y -1.0 1.0 fclamp  select  select
  out f!64
;
