( rotary.fy - a rotating speaker cabinet: a valve amp, a crossover at
  800 Hz, a treble horn and a bass drum that turn, and two microphones.

  What turns is the direction the sound leaves in.  As a rotor swings
  toward a microphone its path shortens, so the pitch rises [Doppler:
  a delay line read at a moving point]; facing it, it is loudest and
  brightest; facing away it is quiet and dull, and what is heard is
  mostly the cabinet wall behind it, late and bending the other way.
  The two microphones sit SPREAD apart round the cabinet, so they hear
  the same turn at different moments: that is the stereo.

  The rotors have mass, and not the same mass.  SPEED asks for STOP,
  SLOW or FAST; the horn gets there in about a second, the drum takes
  four or five, and they turn opposite ways at slightly different
  rates, so the change of speed is a few seconds of the two halves of
  the sound going out of step.  INERTIA scales both times.

  MIC is how far the microphones are: close is deep tremolo, far is
  more wall and less swing.  DEPTH is the size of the Doppler bend.
  The cabinet is mono in: the input's two sides are summed.

  Stages through state [docs/18 Composition]: the amp, crossover and
  motors; the horn; the drum and the output. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "delay.fy"     ( dl-read )

:: RO-XO-HZ 800.0 ;
:: RO-HORN-R 0.00055 ;   ( the horn's reach as a delay, seconds, at DEPTH 1 )
:: RO-DRUM-R 0.00022 ;
:: RO-WALL 0.0013 ;      ( the extra path off the back wall )

ustruct: RoState
  f64 hb f64 hb-len  f64 db f64 db-len    ( host-injected rings: treble, bass )
  f64 wpos
  f64 x1 f64 x2            ( the crossover )
  f64 init
  f64 hsp f64 drs         ( the rotors' speeds now, turns a sample )
  f64 hph f64 dph          ( where they point, 0..1 )
  f64 hl f64 hr f64 dl f64 dr   ( each microphone's tone )
  f64 yhl f64 yhr          ( the horn at each microphone )
;

ustruct: RoParams
  f64 speed f64 slow f64 fast f64 inertia
  f64 drive f64 balance f64 mic f64 spread f64 depth
  f64 mix f64 out
  ( derived - rotary-block-prepare )
  f64 h-tgt f64 d-tgt
  f64 h-up f64 h-dn f64 d-up f64 d-dn
  f64 xo-a
  f64 h-base f64 h-dev f64 h-wall f64 h-am f64 refl
  f64 d-base f64 d-dev f64 d-am
  f64 h-lp-lo f64 h-lp-span f64 d-lp-lo f64 d-lp-span
  f64 spr
  f64 hg f64 dg
  f64 drv-g f64 drv-ig
  f64 dry f64 wet
;

( sr hz -- a : a one-pole's coefficient )
dsp: ro-pole | sr hz -- a |  1.0  hz -6.283185307179586 f* sr f/ exp  f- ;

( sr seconds -- a : the share of the way a motor gets each sample )
dsp: ro-lag | sr t -- a |  1.0  -1.0 t sr f* f/ exp  f- ;

dsp: rotary-block-prepare | ctx:Ctx state p:RoParams |
  ctx.sr | sr |
  p.speed 0.5 f+ floor | m |
  m 1.5 f> p.fast  m 0.5 f> p.slow 0.0 select  select | hz |
  hz ctx.inv-sr f* -> p.h-tgt
  ( the drum is belted a little slower )
  hz 0.87 f* ctx.inv-sr f* -> p.d-tgt
  sr 0.9 p.inertia f* ro-lag -> p.h-up
  sr 1.2 p.inertia f* ro-lag -> p.h-dn
  sr 4.5 p.inertia f* ro-lag -> p.d-up
  sr 5.5 p.inertia f* ro-lag -> p.d-dn
  sr RO-XO-HZ ro-pole -> p.xo-a
  p.depth RO-HORN-R f* sr f* | hd |
  hd -> p.h-dev
  hd 6.0 f+ -> p.h-base
  RO-WALL sr f* -> p.h-wall
  p.depth RO-DRUM-R f* sr f* | dd |
  dd -> p.d-dev
  dd 6.0 f+ -> p.d-base
  ( close microphones hear the swing, far ones the wall )
  0.9 p.mic 0.6 f* f- -> p.h-am
  0.15 p.mic 0.4 f* f+ -> p.refl
  0.55 p.mic 0.3 f* f- -> p.d-am
  sr 2500.0 ro-pole | hlo |
  hlo -> p.h-lp-lo
  sr 12000.0 ro-pole hlo f- -> p.h-lp-span
  sr 500.0 ro-pole | dlo |
  dlo -> p.d-lp-lo
  sr 2500.0 ro-pole dlo f- -> p.d-lp-span
  p.spread 0.5 f* -> p.spr
  p.balance 0.5 f* sinpi 1.4142135623730951 f* -> p.hg
  p.balance 0.5 f* cospi 1.4142135623730951 f* -> p.dg
  p.drive dup f* 20.0 f* 1.0 f+ | g |
  g -> p.drv-g
  1.0 g fsqrt f/ -> p.drv-ig
  p.out db>lin | gain |
  1.0 p.mix f- gain f* -> p.dry
  p.mix gain f* -> p.wet
;

dsp: ro-flush | x -- y |  x fabs 1.0e-18 f<  0.0 x select ;

( now target up dn -- now' : a motor, one sample )
dsp: ro-motor | now tgt up dn -- n |
  now  tgt now f-  tgt now f> up dn select  f*  f+
;

( the amp, the crossover, the write, the motors. )
dsp: ro-front | io:Io ctx s:RoState p:RoParams |
  io.in-l io.in-r f+ 0.5 f* | x0 |
  p.drive 0.0 f>
  [ x0 p.drv-g f* -4.0 4.0 fclamp tanh-fast p.drv-ig f* ]
  [ x0 ]
  ifte | x |
  s.x1  x s.x1 f- p.xo-a f*  f+ ro-flush | l1 |
  s.x2  l1 s.x2 f- p.xo-a f*  f+ ro-flush | lo |
  l1 -> s.x1  lo -> s.x2
  s.wpos | w |
  x lo f- s.hb& p@64 w f!i
  lo s.db& p@64 w f!i
  w 1.0 f+ | w1 |
  w1 s.hb-len  w1  0.0  fsel-lt -> s.wpos
  ( fresh state starts at speed )
  s.init 0.5 f< | fresh |
  fresh p.h-tgt s.hsp select  p.h-tgt p.h-up p.h-dn ro-motor | hs |
  fresh p.d-tgt s.drs select  p.d-tgt p.d-up p.d-dn ro-motor | ds |
  hs -> s.hsp  ds -> s.drs
  1.0 -> s.init
  s.hph hs f+ ffrac -> s.hph
  s.dph 1.0 f+ ds f- ffrac -> s.dph
;

( state params th lp -- y : the horn at a microphone th turns round from
  where the horn points; lp is that microphone's tone state. )
dsp: ro-horn-mic | s:RoState p:RoParams th lp -- y |
  th 0.25 f+ sin2pi | c |
  s.hb& p@64 s.hb-len s.wpos  p.h-base c p.h-dev f* f-  dl-read | a |
  s.hb& p@64 s.hb-len s.wpos  p.h-base c p.h-dev f* f+ p.h-wall f+  dl-read | b |
  1.0  1.0 c f- 0.5 f* p.h-am f*  f- | g |
  1.0  1.0 c f+ 0.5 f* p.h-am f*  f- | g2 |
  a g f*  b g2 f* p.refl f*  f+ | v |
  p.h-lp-lo  c 1.0 f+ 0.5 f* p.h-lp-span f*  f+ | k |
  lp f@64  v lp f@64 f- k f*  f+ ro-flush | y |
  y lp f!64
  y
;

dsp: ro-drum-mic | s:RoState p:RoParams th lp -- y |
  th 0.25 f+ sin2pi | c |
  s.db& p@64 s.db-len s.wpos  p.d-base c p.d-dev f* f-  dl-read | a |
  1.0  1.0 c f- 0.5 f* p.d-am f*  f- | g |
  p.d-lp-lo  c 1.0 f+ 0.5 f* p.d-lp-span f*  f+ | k |
  lp f@64  a g f* lp f@64 f- k f*  f+ ro-flush | y |
  y lp f!64
  y
;

dsp: ro-horn | io ctx s:RoState p:RoParams |
  s p  s.hph 1.0 f+ p.spr f+  s.hl& ro-horn-mic -> s.yhl
  s p  s.hph 1.0 f+ p.spr f-  s.hr& ro-horn-mic -> s.yhr
;

dsp: ro-out | io:Io ctx s:RoState p:RoParams |
  s p  s.dph 1.0 f+ p.spr f+  s.dl& ro-drum-mic | dl |
  s p  s.dph 1.0 f+ p.spr f-  s.dr& ro-drum-mic | dr |
  io.in-l p.dry f*  s.yhl p.hg f* dl p.dg f* f+ p.wet f*  f+ -> io.out-l
  io.in-r p.dry f*  s.yhr p.hg f* dr p.dg f* f+ p.wet f*  f+ -> io.out-r
;

dsp: k-rotary-tick | io ctx state params |
  io ctx state params call: ro-front
  io ctx state params call: ro-horn
  io ctx state params call: ro-out
;
