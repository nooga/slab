( fm86_voice.fy - the FM-86 voice: a DX7, following Dexed's msfa engine
  [github asb2m10/dexed Source/msfa, Apache-2.0] closely enough that a
  patch's parameters mean what they meant on the instrument.

  Units follow msfa's, as floats:
    level   an operator envelope's position in log2 units [msfa level_ /
            2^24]; the operator's gain is 2^(level - 14), so the top of
            the range [OL 99, L 99] is gain 2
    phase   cycles; a modulator's output adds to its carrier's phase, so
            a full-level modulator swings it by 2 cycles
    pitch   octaves [msfa logfreq / 2^24]

  At note-on [dx-op-on] each operator gets its frequency [ratio: coarse,
  fine, detune scaled by the note; fixed: 10^(coarse + fine/100) Hz],
  its output level [Env::scaleoutlevel + keyboard level scaling +
  velocity], and the four stage targets, per-sample increments and hold
  counts of its envelope [rate scaling folded in].  Per sample: the LFO
  [six waves, delay], the pitch EG, then each operator's envelope
  [dx-env: msfa's Env::getsample - the attack jumps to 1716/256 and
  climbs by [17 - level] x rate, decays fall linearly in log2, flat
  segments hold for the measured `statics` time], amplitude modulation
  [AMS], and the algorithm matrix [fm-op-step, OP6 first].

  msfa runs the envelopes and LFO once per 64 samples and ramps the gain
  between; here they run every sample.  Envelope rates carry msfa's
  44.1 kHz scaling. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../01-oscillators/fm_operator.fy"
include "dx7_tables.fy"

ustruct: DxOpS
  ( FmOpState prefix: fm-op-step reads these )
  f64 phase f64 fb1 f64 fb2
  ( envelope )
  f64 lvl      ( log2 units )
  f64 ix       ( stage 0..3, 4 = done )
  f64 st       ( flat-segment hold left, samples )
  f64 rise     ( 1 while the stage climbs )
  f64 t0 f64 t1 f64 t2 f64 t3   ( stage targets )
  f64 i0 f64 i1 f64 i2 f64 i3   ( per-sample increments )
  f64 s0 f64 s1 f64 s2 f64 s3   ( hold counts of flat stages )
  ( note )
  f64 binc     ( phase increment at the note's pitch, cycles / sample )
  f64 fixed    ( 1: fixed frequency - no pitch EG, no LFO )
  f64 ams      ( amplitude-modulation sensitivity, 0..1 )
;

ustruct: Fm86State
  DxOpS op1 DxOpS op2 DxOpS op3 DxOpS op4 DxOpS op5 DxOpS op6
  f64 down     ( 1 while the key is held )
  f64 hz0      ( the note's Hz at note-on, for pitch expression )
  f64 bend     ( octaves, from note expression )
  ( pitch EG, octaves )
  f64 pl f64 pix f64 prise
  f64 pt0 f64 pt1 f64 pt2 f64 pt3
  f64 pi0 f64 pi1 f64 pi2 f64 pi3
  ( LFO )
  f64 lph      ( phase, cycles )
  f64 ldl      ( delay counter, 0..1 [msfa delaystate_ / 2^32] )
  f64 lrnd     ( S&H generator )
;

ustruct: DxOpP
  f64 r1 f64 r2 f64 r3 f64 r4 f64 l1 f64 l2 f64 l3 f64 l4   ( 0..99 )
  f64 bp       ( break point 0..99 )
  f64 ld f64 rd  ( left / right depth 0..99 )
  f64 lc f64 rc  ( curves: 0 -LIN 1 -EXP 2 +EXP 3 +LIN )
  f64 rs       ( rate scaling 0..7 )
  f64 ams      ( 0..3 )
  f64 kvs      ( key velocity sensitivity 0..7 )
  f64 ol       ( output level 0..99 )
  f64 mode     ( 0 ratio, 1 fixed )
  f64 coarse   ( 0..31 )
  f64 fine     ( 0..99 )
  f64 det      ( -7..7 )
;

ustruct: Fm86Params
  ( --- routing, filled by fm86-derive [fm86_algo.fy] --- )
  f64 fb0  f64 fb1  f64 fb2  f64 fb3  f64 fb4  f64 fb5    ( per-op feedback )
  f64 w01 f64 w02 f64 w03 f64 w04 f64 w05
  f64 w12 f64 w13 f64 w14 f64 w15
  f64 w23 f64 w24 f64 w25
  f64 w34 f64 w35
  f64 w45
  f64 c0 f64 c1 f64 c2 f64 c3 f64 c4 f64 c5
  ( --- the patch --- )
  DxOpP op1 DxOpP op2 DxOpP op3 DxOpP op4 DxOpP op5 DxOpP op6
  f64 algo      ( 1..32 )
  f64 feedback  ( 0..7 )
  f64 oks       ( oscillator key sync 0 / 1 )
  f64 transpose ( semitones -24..24 )
  f64 pr1 f64 pr2 f64 pr3 f64 pr4 f64 pl1 f64 pl2 f64 pl3 f64 pl4   ( pitch EG )
  f64 lfo-speed f64 lfo-delay f64 lfo-pmd f64 lfo-amd   ( 0..99 )
  f64 lfo-sync  ( 0 / 1 )
  f64 lfo-wave  ( 0 TRI 1 SAW DOWN 2 SAW UP 3 SQUARE 4 SINE 5 S&H )
  f64 pms       ( 0..7 )
  f64 volume    ( output gain, 1 = Dexed's level )
  ( --- derived each block by fm86-derive --- )
  f64 lfo-inc f64 dl-inc1 f64 dl-inc2
  f64 pmd f64 pmsv f64 amd
;

:: DX-JUMP 6.703125 ;               ( the attack's floor, 1716 / 256 )
:: DX-THRESH 0.0000667572021484375 ; ( gain under 1120 / 2^24 is silence )
:: DX-INC 9.313225746154785e-10 ;   ( 1 / 2^30: a block's Q24 increment -> per sample )
:: DX-NOTE0 3.0313597917556763 ;    ( log2 440 - 69/12: MIDI note 0 )
:: DX-LOG10 0.033219280948873623 ;  ( log2 10 / 100 )
:: DX-Q24 5.9604644775390625e-08 ;  ( 1 / 2^24 )

( ix a b c d -- x : the value for stage ix. )
dsp: dx-pick4 | ix a b c d -- x |
  ix 0.5 a  ix 1.5 b  ix 2.5 c d  fsel-lt fsel-lt fsel-lt
;

( ── note-on: the patch at this note and velocity ─────────────────────── )

( p note -- s : keyboard level scaling [msfa ScaleLevel / ScaleCurve],
  in scaleoutlevel units. )
dsp: dx-kls | p:DxOpP note -- s |
  note p.bp f- 17.0 f- | off |
  off 0.0 f>= | right |
  right  off 1.0 f+ 3.0 f/ floor  1.0 off f- 3.0 f/ floor  select | grp |
  right p.rd p.ld select | dep |
  right p.rc p.lc select | cv |
  grp dep f* 329.0 f* 4096.0 f/ floor | lin |
  dx-expcurve  grp 32.0 fmin  f@i  dep f* 329.0 f* 32768.0 f/ floor | ex |
  cv 0.5 f<  cv 2.5 f>  or  lin ex select | sc |
  cv 1.5 f<  0.0 sc f-  sc  select
;

( vel kvs -- s : velocity scaling [msfa ScaleVelocity], vel 0..127. )
dsp: dx-velscale | vel kvs -- s |
  dx-vel  vel 2.0 f/ floor  f@i  239.0 f- | vv |
  kvs vv f* 7.0 f+ 8.0 f/ floor 16.0 f*
;

( L outl -- t : a stage target [Env::advance], log2 units. )
dsp: dx-target | l outl -- t |
  dx-sol l f@i 2.0 f/ floor 64.0 f*  outl f+  4256.0 f-  16.0 fmax  0.00390625 f*
;

( r rsc srm -- inc : a stage's per-sample increment [Env::advance]. )
dsp: dx-rinc | r rsc srm -- inc |
  r 41.0 f* 64.0 f/ floor rsc f+ 63.0 fmin | q |
  q 4.0 f/ floor | qh |
  4.0  q qh 4.0 f* f-  f+  8.0 qh f+ fexp2i f*  srm f* floor  DX-INC f*
;

( r rsc srm attack -- n : a flat stage's hold, samples [ACCURATE_ENVELOPE
  statics; an attack to L1 = 0 holds a twentieth of it]. )
dsp: dx-hold | r rsc srm attack -- n |
  r rsc f+ 99.0 fmin | sr |
  sr 77.0 f<  dx-statics sr f@i  99.0 sr f- 20.0 f*  select | c |
  attack 0.5 f>  sr 77.0 f<  and  c 20.0 f/ floor  c  select  srm f* floor
;

( o p note vel srm isr oks -- : one operator at note-on. )
dsp: dx-op-on | o:DxOpS p:DxOpP note vel srm isr oks -- |
  dx-sol p.ol f@i  p note dx-kls f+  127.0 fmin  32.0 f*
    vel p.kvs dx-velscale f+  0.0 fmax | outl |
  note 3.0 f/ floor 7.0 f- 0.0 31.0 fclamp  p.rs f* 8.0 f/ floor | rsc |
  p.l1 outl dx-target -> o.t0
  p.l2 outl dx-target -> o.t1
  p.l3 outl dx-target -> o.t2
  p.l4 outl dx-target -> o.t3
  p.r1 rsc srm dx-rinc -> o.i0
  p.r2 rsc srm dx-rinc -> o.i1
  p.r3 rsc srm dx-rinc -> o.i2
  p.r4 rsc srm dx-rinc -> o.i3
  p.l1 0.5 f< mask>f | l1z |
  p.r1 rsc srm l1z dx-hold | h0 |
  h0 -> o.s0
  p.r2 rsc srm 0.0 dx-hold -> o.s1
  p.r3 rsc srm 0.0 dx-hold -> o.s2
  p.r4 rsc srm 0.0 dx-hold -> o.s3
  ( pitch: ratio [detune scaled by the note, coarse, fine] or fixed )
  DX-NOTE0 note 12.0 f/ f+ | lf0 |
  0.0209  -0.396 lf0 f* exp f*  7.0 f/ | dr |
  lf0  dr lf0 f* p.det f* f+
    p.coarse 0.5 f<  -1.0  p.coarse 1.0 fmax log2  select f+
    1.0 p.fine 0.01 f* f+ log2 f+ | lfr |
  p.coarse 4.0 f/ floor 4.0 f* | c4 |
  p.coarse c4 f- 100.0 f* p.fine f+ DX-LOG10 f*
    p.det 0.0 f>  p.det 13457.0 f* DX-Q24 f*  0.0  select f+ | lfx |
  p.mode 0.5 f>  lfx lfr select exp2 isr f* -> o.binc
  p.mode -> o.fixed
  p.ams 0.5 f< 0.0  p.ams 1.5 f< 0.25881969928741455  p.ams 2.5 f< 0.42744630575180054 1.0  select select select -> o.ams
  ( the envelope starts from silence at stage 0 [Env::init] )
  0.0 -> o.lvl
  0.0 -> o.ix
  1.0 -> o.rise
  l1z 0.5 f>  h0 0.0 select -> o.st
  ( key sync restarts the oscillator )
  oks 0.5 f>  0.0 o.phase select -> o.phase
  oks 0.5 f>  0.0 o.fb1 select -> o.fb1
  oks 0.5 f>  0.0 o.fb2 select -> o.fb2
;

( o -- : one operator's key-up: to the release stage [Env::keydown]. )
dsp: dx-op-off | o:DxOpS |
  3.0 -> o.ix
  o.t3 o.lvl f> mask>f -> o.rise
  o.t3 o.lvl f=  o.s3 0.0 select -> o.st
;

( ── per sample ───────────────────────────────────────────────────────── )

( o down -- level : one operator envelope sample [Env::getsample]. )
dsp: dx-env | o:DxOpS down -- l |
  o.lvl | l0 |
  o.ix | ix |
  o.st | st |
  ix o.t0 o.t1 o.t2 o.t3 dx-pick4 | tg |
  ix o.i0 o.i1 o.i2 o.i3 dx-pick4 | inc |
  ix 3.0 f<  ix 4.0 f<  down 0.5 f<  and  or | act |
  st 0.5 f> | hold |
  st 1.0 f- 0.0 fmax | st1 |
  hold st1 0.5 f< and | hdone |
  l0 DX-JUMP fmax | lj |
  lj  17.0 lj f- floor inc f*  f+ | lr |
  l0 inc f- | lf |
  o.rise 0.5 f> | rising |
  rising lr lf select | c |
  rising c tg f>= and  rising not c tg f<= and  or | past |
  act hold not and | mv |
  mv past and | reach |
  mv  reach tg c select  l0  select | l1 |
  reach hdone or | adv |
  adv  ix 1.0 f+  ix  select | ix1 |
  ix1 o.t0 o.t1 o.t2 o.t3 dx-pick4 | tn |
  ix1 o.s0 o.s1 o.s2 o.s3 dx-pick4 | sn |
  adv  tn l1 f> mask>f  o.rise  select -> o.rise
  adv  tn l1 f= sn 0.0 select  hold st1 st select  select -> o.st
  ix1 -> o.ix
  l1 -> o.lvl
  l1
;

( o down amod -- gain : envelope, amplitude modulation [the AMS
  attenuation in Dx7Note::compute], gain. )
dsp: dx-gain | o:DxOpS down amod -- g |
  o down dx-env | l |
  amod o.ams f* 4.48 f* 12.2 f+ exp DX-Q24 f* | pt |
  o.ams 0.0 f>  l l pt f* f-  l  select 14.0 f- exp2 | g |
  g DX-THRESH f<  0.0 g select
;

( o pr pf -- inc : this sample's phase increment; fixed operators get
  only the bend. )
dsp: dx-inc | o:DxOpS pr pf -- inc |
  o.fixed 0.5 f> pf pr select o.binc f*
;

( s p -- v delay : the LFO [msfa Lfo::getsample / getdelay], v 0..1. )
dsp: dx-lfo-step | s:Fm86State p:Fm86Params -- v d |
  s.lph p.lfo-inc f+ | ph |
  ph ffrac | u |
  u -> s.lph
  ph 1.0 f>= | wrap |
  s.lrnd 179.0 f* 17.0 f+ | rn |
  rn  rn 0.00390625 f* floor 256.0 f*  f- | rn8 |
  wrap rn8 s.lrnd select | r |
  r -> s.lrnd
  r 128.0 f<  r 128.0 f+  r 128.0 f-  select 1.0 f+ 0.00390625 f* | sh |
  u 0.5 f<  u 2.0 f*  2.0 u 2.0 f* f-  select | tri |
  1.5 u f- ffrac | sdn |
  u 0.5 f+ ffrac | sup |
  u 0.5 f<  1.0 0.0 select | sq |
  u sin2pi 0.5 f* 0.5 f+ | sn |
  p.lfo-wave | w |
  w 0.5 tri  w 1.5 sdn  w 2.5 sup  w 3.5 sq  w 4.5 sn sh  fsel-lt fsel-lt fsel-lt fsel-lt fsel-lt | v |
  s.ldl | d0 |
  d0 0.5 f<  p.dl-inc1 p.dl-inc2 select | dd |
  d0 dd f+ | d1 |
  d1 1.0 f>  d0 d1 select -> s.ldl
  d1 1.0 f>  1.0  d1 0.5 f<  0.0  d1 0.5 f- 2.0 f*  select  select | dly |
  v dly
;

( s down -- pitch : the pitch EG [msfa PitchEnv::getsample], octaves. )
dsp: dx-penv | s:Fm86State down -- pl |
  s.pl | l0 |
  s.pix | ix |
  ix s.pt0 s.pt1 s.pt2 s.pt3 dx-pick4 | tg |
  ix s.pi0 s.pi1 s.pi2 s.pi3 dx-pick4 | inc |
  ix 3.0 f<  ix 4.0 f<  down 0.5 f<  and  or | act |
  s.prise 0.5 f> | rising |
  rising  l0 inc f+  l0 inc f-  select | c |
  rising c tg f>= and  rising not c tg f<= and  or  act and | reach |
  act  reach tg c select  l0  select | l1 |
  reach  ix 1.0 f+  ix  select | ix1 |
  ix1 s.pt0 s.pt1 s.pt2 s.pt3 dx-pick4 | tn |
  reach  tn l1 f> mask>f  s.prise  select -> s.prise
  ix1 -> s.pix
  l1 -> s.pl
  l1
;

( s p -- out : one voice sample. )
dsp: fm86-voice-step | s:Fm86State p:Fm86Params -- out |
  s.down | down |
  s p dx-lfo-step | v dly |
  s down dx-penv | pe |
  ( pitch: EG + LFO [PMD x PMS x delay], and the note's bend )
  pe  p.pmd p.pmsv f* dly f* v 0.5 f- f* 0.000030517578125 f*  f+  s.bend f+ exp2 | pr |
  s.bend exp2 | pf |
  ( amplitude modulation depth: AMD x delay x the inverted LFO )
  p.amd dly f* 1.0 v f- f* 0.00390625 f* | am |
  s.op6& down am dx-gain | g5 |
  s.op5& down am dx-gain | g4 |
  s.op4& down am dx-gain | g3 |
  s.op3& down am dx-gain | g2 |
  s.op2& down am dx-gain | g1 |
  s.op1& down am dx-gain | g0 |
  ( the algorithm matrix, OP6 first )
  s.op6&  s.op6& pr pf dx-inc  0.0  g5 p.fb5 fm-op-step | out5 |
  s.op5&  s.op5& pr pf dx-inc
    p.w45 out5 f*
    g4 p.fb4 fm-op-step | out4 |
  s.op4&  s.op4& pr pf dx-inc
    p.w34 out4 f* p.w35 out5 f* f+
    g3 p.fb3 fm-op-step | out3 |
  s.op3&  s.op3& pr pf dx-inc
    p.w23 out3 f* p.w24 out4 f* f+ p.w25 out5 f* f+
    g2 p.fb2 fm-op-step | out2 |
  s.op2&  s.op2& pr pf dx-inc
    p.w12 out2 f* p.w13 out3 f* f+ p.w14 out4 f* f+ p.w15 out5 f* f+
    g1 p.fb1 fm-op-step | out1 |
  s.op1&  s.op1& pr pf dx-inc
    p.w01 out1 f* p.w02 out2 f* f+ p.w03 out3 f* f+ p.w04 out4 f* f+ p.w05 out5 f* f+
    g0 p.fb0 fm-op-step | out0 |
  p.c0 out0 f*
  p.c1 out1 f* f+
  p.c2 out2 f* f+
  p.c3 out3 f* f+
  p.c4 out4 f* f+
  p.c5 out5 f* f+
;

( io ctx state params -- : one FM-86 voice sample, ACCUMULATED into out.
  The host renders every voice into the same zeroed buffer. )
dsp: k-fm86-voice-sample | io ctx state params -- |
  io f@64  state params fm86-voice-step  f+  io f!64
;

( ── machine wiring: note-on / note-off / expression ────────────────── )

( ctx state params -- : start a note [Dx7Note::init]: MIDI note with the
  patch's transpose, velocity 0..127, every operator, the pitch EG from
  L4, the LFO's key sync and delay. )
dsp: fm86-note-on | ctx:Ctx state:Fm86State params:Fm86Params |
  ctx.pitch params.transpose f+ 0.0 127.0 fclamp | note |
  ctx.vel 127.0 f* 0.5 f+ floor 0.0 127.0 fclamp | vel |
  44100.0 ctx.sr f/ | srm |
  1.0 ctx.sr f/ | isr |
  params.oks | oks |
  state.op1& params.op1& note vel srm isr oks dx-op-on
  state.op2& params.op2& note vel srm isr oks dx-op-on
  state.op3& params.op3& note vel srm isr oks dx-op-on
  state.op4& params.op4& note vel srm isr oks dx-op-on
  state.op5& params.op5& note vel srm isr oks dx-op-on
  state.op6& params.op6& note vel srm isr oks dx-op-on
  ( pitch EG, 1/32 octave per table step; rate x 1/(21.3 sr) per sample )
  dx-plevel params.pl4 f@i 0.03125 f* | pl |
  pl -> state.pl
  0.0 -> state.pix
  dx-plevel params.pl1 f@i 0.03125 f* | p0 |
  p0 -> state.pt0
  dx-plevel params.pl2 f@i 0.03125 f* -> state.pt1
  dx-plevel params.pl3 f@i 0.03125 f* -> state.pt2
  pl -> state.pt3
  isr 0.046948356807511735 f* | pu |
  dx-prate params.pr1 f@i pu f* -> state.pi0
  dx-prate params.pr2 f@i pu f* -> state.pi1
  dx-prate params.pr3 f@i pu f* -> state.pi2
  dx-prate params.pr4 f@i pu f* -> state.pi3
  p0 pl f> mask>f -> state.prise
  ( LFO: key sync restarts it half way [Lfo::keydown]; the delay restarts )
  params.lfo-sync 0.5 f>  0.49999999976716936  state.lph  select -> state.lph
  0.0 -> state.ldl
  1.0 -> state.down
  ctx.hz -> state.hz0
  0.0 -> state.bend
;

( ctx state params -- : per-note expression [docs/22]: bend by the
  retuned pitch. )
dsp: fm86-note-expr | ctx:Ctx state:Fm86State params |
  ctx.hz  state.hz0 0.001 fmax  f/ log2 -> state.bend
;

( ctx state params -- : key-up [Dx7Note::keyup]. )
dsp: fm86-note-off | ctx state:Fm86State params |
  0.0 -> state.down
  state.op1& dx-op-off
  state.op2& dx-op-off
  state.op3& dx-op-off
  state.op4& dx-op-off
  state.op5& dx-op-off
  state.op6& dx-op-off
  3.0 -> state.pix
  state.pt3 state.pl f> mask>f -> state.prise
;
