( wobble.fy - a moving filter: Wobble [docs/43 §Wobble].

  One modulation value m in 0..1 per channel moves the filter's cutoff
  by DEPTH octaves, f = CUTOFF x 2^[DEPTH m], and AMP takes the level
  down to 1 - AMP at m = 0 [tremolo and gate from the same source].

  SOURCE picks m:
    LFO    lfo.fy's shapes at RATE, or synced to the transport at DIV;
           PHASE offsets it, SPREAD offsets the right channel, RETRIG
           restarts a free LFO when a note comes in
    STEP   sixteen step values, one per DIV [or 1/RATE s], LENGTH long
    ENV    the input's level [linked], SENS into a follower at ATK/REL:
           the auto-wah and envelope filter
    PEDAL  POS: a rocking pedal for automation or a rack macro
  GLIDE smooths m [and takes the click off a square or a step]; 1 ms at
  0, a quarter second at 1.

  TYPE picks the filter:
    SVF    a TPT state-variable filter, LP -> BP -> HP by MORPH, 12 or
           24 dB, RES up to self-oscillation [its first integrator
           saturates, so the ring holds near 0 dBFS instead of growing]
    WAH    the inductor wah's voicing: a peaking bandpass, Q 2..12 by
           RES, with its volume boost and a little of the lowpass under
           it for the body; CUTOFF is the heel, DEPTH ~2.6 octaves the
           toe [350 Hz to 2.2 kHz for guitar]
  DRIVE pushes the input into a tanh before the filter, unity gain at
  0 dB. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../00-primitives/lfo.fy"
include "../00-primitives/follow.fy"
include "../04-filters/coeffs.fy"

ustruct: WbSvf f64 s1 f64 s2 ;
ustruct: WbChan WbSvf a WbSvf b ;

ustruct: WobbleState
  WbChan l
  WbChan r
  Lfo lfo-l
  Lfo lfo-r
  Follow env
  f64 beat     ( transport position, quarter notes )
  f64 free     ( free-running position, cycles or steps )
  f64 m-l      ( glided modulation )
  f64 m-r
  f64 armed    ( RETRIG: 1 once the level fell back, ready for a note )
;

ustruct: WobbleParams
  ( user-facing )
  f64 type     ( 0 SVF, 1 WAH )
  f64 cutoff
  f64 res      ( 0..1 )
  f64 morph    ( 0 LP .. 0.5 BP .. 1 HP )
  f64 slope    ( 0 12 dB, 1 24 dB )
  f64 drive-db
  f64 source   ( 0 LFO, 1 STEP, 2 ENV, 3 PEDAL )
  f64 shape
  f64 rate
  f64 sync
  f64 div      ( quarter notes per cycle or step )
  f64 phase0
  f64 retrig
  f64 steps 16
  f64 length
  f64 glide
  f64 atk
  f64 rel
  f64 sens-db
  f64 pos
  f64 depth    ( octaves )
  f64 amp
  f64 spread   ( degrees )
  f64 mix
  f64 out-db
  ( derived )
  f64 cut-l2
  f64 k        ( SVF damping term 2R )
  f64 drive
  f64 idrive
  f64 beat-inc
  f64 free-inc
  f64 atk-c
  f64 rel-c
  f64 sens
  f64 glide-c
  f64 out
  f64 wl f64 wb f64 wh
  f64 wah-k
  f64 off-r    ( right channel's phase offset, cycles )
  f64 step-off ( PHASE in steps )
  f64 inv-sr
  f64 sr
  f64 kn       ( k for normalizing the bandpass, kept positive )
;

:: WB-FLUSH 1.0e-18 ;
:: WB-WAH-GAIN 2.2 ;
:: WB-WAH-BODY 0.3 ;
:: WB-SAT 4.0 ;
:: WB-ISAT 0.25 ;

dsp: wobble-block-prepare | ctx:Ctx s:WobbleState p:WobbleParams -- |
  ctx.sr | sr |
  p.cutoff log2 -> p.cut-l2
  ( RES 0 is Butterworth, 1 just past self-oscillation )
  1.4142135623730951  1.0 p.res f- 1.5 pow  f*  0.02 f- -> p.k
  p.drive-db db>lin -> p.drive
  1.0 p.drive f/ -> p.idrive
  ctx.tempo 20.0 999.0 fclamp 60.0 f/ sr f/ -> p.beat-inc
  ctx.beat -> s.beat
  p.rate sr f/ -> p.free-inc
  p.atk sr follow-coef -> p.atk-c
  p.rel sr follow-coef -> p.rel-c
  p.sens-db db>lin -> p.sens
  0.001  p.glide p.glide f* 0.25 f*  f+  sr follow-coef -> p.glide-c
  p.out-db db>lin -> p.out
  ( MORPH: LP to BP over the first half, BP to HP over the second; the
    bandpass normalized to unity at its peak )
  p.morph 2.0 f* 0.0 1.0 fclamp | a |
  p.morph 2.0 f* 1.0 f- 0.0 1.0 fclamp | b |
  1.0 a f- -> p.wl
  a b f- -> p.wb
  b -> p.wh
  1.0  2.0 p.res 10.0 f* f+  f/ -> p.wah-k
  p.spread 360.0 f/ -> p.off-r
  p.phase0 p.length 1.0 fmax f* -> p.step-off
  ctx.inv-sr -> p.inv-sr
  sr -> p.sr
  p.k 0.02 fmax -> p.kn
;

( s x g k -- lp bp hp : one TPT SVF step; the first integrator saturates. )
dsp: wb-svf | s:WbSvf x g k -- lp bp hp |
  s.s1 | s1 |
  s.s2 | s2 |
  x  k g f+ s1 f*  f-  s2 f-   1.0 k g f* f+  g g f* f+  f/ | hp |
  g hp f* | ghp |
  ghp s1 f+ | bp |
  g bp f* | gbp |
  gbp s2 f+ | lp |
  ghp bp f+ WB-ISAT f* tanh-fast WB-SAT f*  WB-FLUSH f+ WB-FLUSH f- -> s.s1
  gbp lp f+  WB-FLUSH f+ WB-FLUSH f- -> s.s2
  lp bp hp
;

( c p x m -- y : one channel's filter at modulation m. )
dsp: wb-filter | c:WbChan p:WobbleParams x m -- y |
  p.drive 1.00001 f<  x  x p.drive f* tanh-fast p.idrive f*  select | xd |
  p.cut-l2  p.depth m f*  f+  exp2 | f |
  p.type 0.5 f<
  [ f p.sr svf-g | g |
    c.a& xd g p.k wb-svf | lp bp hp |
    lp p.wl f*  bp p.kn f* p.wb f* f+  hp p.wh f* f+ | y1 |
    p.slope 0.5 f<
    [ y1 ]
    [ c.b& y1 g 1.4142135623730951 wb-svf | lp2 bp2 hp2 |
      lp2 p.wl f*  bp2 1.4142135623730951 f* p.wb f* f+  hp2 p.wh f* f+ ] ifte ]
  [ f 150.0 4000.0 fclamp p.sr svf-g | g |
    c.a& xd g p.wah-k wb-svf | lp bp hp |
    bp p.wah-k f* WB-WAH-GAIN f*  lp WB-WAH-BODY f*  f+ ] ifte
;

( s p det -- ml mr : the two channels' raw modulation. )
dsp: wb-source | s:WobbleState p:WobbleParams det -- ml mr |
  s.env& det p.sens f*  p.atk-c p.rel-c follow-step | e |
  ( RETRIG: a note arriving after the level fell back restarts FREE )
  e 0.1 f>  s.armed 0.5 f>  and  p.retrig 0.5 f>  and | hit |
  e 0.03 f<  1.0  hit 0.0 s.armed select  select -> s.armed
  hit  0.0  s.free  select | free |
  free p.free-inc f+ -> s.free
  p.sync 0.5 f<  free  s.beat p.div 0.0001 fmax f/  select | pos |
  p.source 1.5 f<
  [ p.source 0.5 f<
    [ s.lfo-l& pos p.phase0 f+ p.shape lfo-at
      s.lfo-r& pos p.phase0 f+ p.off-r f+ p.shape lfo-at ]
    [ p.length 1.0 16.0 fclamp floor | len |
      pos p.step-off f+ | sp |
      sp  sp len f/ floor len f*  f- floor | il |
      sp p.off-r f+ | spr |
      spr  spr len f/ floor len f*  f- floor | ir |
      p.steps& il f@i  p.steps& ir f@i ] ifte ]
  [ p.source 2.5 f<
    [ e 0.0 1.0 fclamp dup ]
    [ p.pos p.pos ] ifte ] ifte
;

dsp: k-wobble-tick | io:Io ctx s:WobbleState p:WobbleParams -- |
  s p io.det wb-source | ml mr |
  s.m-l  ml s.m-l f-  1.0 p.glide-c f-  f*  f+ | gl |
  gl -> s.m-l
  s.m-r  mr s.m-r f-  1.0 p.glide-c f-  f*  f+ | gr |
  gr -> s.m-r
  s.beat p.beat-inc f+ -> s.beat
  1.0  p.amp 1.0 gl f- f*  f- | al |
  1.0  p.amp 1.0 gr f- f*  f- | ar |
  io.in-l | xl |
  io.in-r | xr |
  s.l& p xl gl wb-filter al f* | yl |
  s.r& p xr gr wb-filter ar f* | yr |
  xl 1.0 p.mix f- f*  yl p.mix f*  f+  p.out f* -> io.out-l
  xr 1.0 p.mix f- f*  yr p.mix f*  f+  p.out f* -> io.out-r
;
