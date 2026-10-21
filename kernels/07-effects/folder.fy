( folder.fy - a wavefolder: Folder [docs/43 §Folder].

  in -> TIGHT HP -> gain FOLD [x DYN] + SYMM -> up4 -> fold x STAGES -> dec4
     -> DC -> TONE -> AUTO -> MIX with the dry [delayed to meet the wet]

  The fold reflects the waveform back each time it passes +-1, so drive
  adds folds instead of flattening the top.  SHAPE runs from the
  triangle fold [straight segments, the Serge's buzz] to the sine fold
  [rounded, the Buchla's ring]:

    tri   T[x] = 1 - |u - 2|,  u = [x + 1] mod 4
    sine  S[x] = sin[pi x / 2]

  Each stage folds its input times 2 again, so STAGES doubles the fold
  count per stage.  Folding aliases hard, so it runs at 4x and each fold
  is first-order antiderivative anti-aliased [ADAA]: the output is the
  mean of the curve over the step from the last input to this one,
  [F[x] - F[x']] / [x - x'], with the antiderivatives

    tri   G[u] = u^2/2 - u           u <= 2
               = 3u - u^2/2 - 4      u > 2     [periodic, 0 at u = 0, 4]
    sine  -2/pi cos[pi x / 2]

  falling back to the curve at the midpoint when the step is tiny.

  SYMM offsets the input: the folds go lopsided and even harmonics come
  in.  DYN lets the input's envelope move FOLD: harder on loud notes and
  unfolding as they decay [negative: quiet notes fold harder].  AUTO
  matches the peak level to the input's as FOLD climbs [each held with
  a 1 s release, and held through silence], so it never reshapes a
  note's decay.  Dual mono. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../00-primitives/oversample.fy"
include "../00-primitives/follow.fy"

ustruct: FoldCell f64 px f64 fp ;

ustruct: FoldState
  Up4 up
  Dec4 dec
  FoldCell c1
  FoldCell c2
  FoldCell c3
  FoldCell c4
  Follow ein
  Follow ain
  Follow awet
  f64 hp-x f64 hp-y
  f64 dc-x f64 dc-y
  f64 lp
  f64 auto
  f64 d1 f64 d2 f64 d3 f64 d4 f64 d5
;

ustruct: FoldParams
  ( user-facing )
  f64 fold-db
  f64 symm
  f64 stages   ( 0..3: 1..4 stages )
  f64 shape    ( 0 tri .. 1 sine )
  f64 dyn
  f64 tight
  f64 tone
  f64 auto-on
  f64 mix
  f64 out-db
  ( derived )
  f64 g
  f64 hp-r
  f64 tone-g
  f64 dc-r
  f64 atk-c f64 rel-c f64 auto-c f64 lvl-atk f64 lvl-rel
  f64 out
  f64 lat
;

:: FD-FLUSH 1.0e-15 ;
:: FD-HALF-PI 1.5707963267948966 ;
:: FD-2-PI 0.6366197723675814 ;   ( 2 / pi )
:: FD-REF 4.0 ;                    ( DYN's reference: an envelope of 0.25 )

dsp: folder-block-prepare | ctx:Ctx s p:FoldParams -- |
  ctx.sr | sr |
  p.fold-db db>lin -> p.g
  -6.283185307179586 p.tight f* sr f/ exp -> p.hp-r
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

( x shape -- y : the curve. )
dsp: fd-curve | x shape -- y |
  x 1.0 f+ | v |
  v  v 0.25 f* floor 4.0 f*  f- | u |
  1.0  u 2.0 f- fabs  f- | tri |
  x FD-HALF-PI f* sin | sn |
  tri  sn tri f-  shape f*  f+
;

( x shape -- F : its antiderivative. )
dsp: fd-anti | x shape -- F |
  x 1.0 f+ | v |
  v  v 0.25 f* floor 4.0 f*  f- | u |
  u u f* 0.5 f* | h |
  u 2.0  h u f-  3.0 u f* h f- 4.0 f-  fsel-lt | gt |
  x FD-HALF-PI f* cos FD-2-PI f* fneg | gs |
  gt  gs gt f-  shape f*  f+
;

( c x shape -- y : one ADAA fold. )
dsp: fd-fold | c:FoldCell x shape -- y |
  x shape fd-anti | fx |
  x c.px f- | dx |
  dx fabs 1.0e-6 f<
    x c.px f+ 0.5 f* shape fd-curve
    fx c.fp f-  dx f/
  select | y |
  x -> c.px
  fx -> c.fp
  y
;

( s p x -- y : one 4x substep through the stages. )
dsp: fd-sub | s:FoldState p:FoldParams x -- y |
  p.shape | sh |
  s.c1& x sh fd-fold | y |
  p.stages 0.5 f<
  [ y ]
  [ s.c2& y 2.0 f* sh fd-fold | y |
    p.stages 1.5 f<
    [ y ]
    [ s.c3& y 2.0 f* sh fd-fold | y |
      p.stages 2.5 f<
      [ y ]
      [ s.c4& y 2.0 f* sh fd-fold ] ifte ] ifte ] ifte
;

dsp: k-folder-tick | out:Io ctx s:FoldState p:FoldParams -- |
  out.in-l | dry |
  ( TIGHT: a one-pole highpass before the folder )
  dry s.hp-x f-  p.hp-r s.hp-y f*  f+ | hp |
  dry -> s.hp-x
  hp FD-FLUSH f+ FD-FLUSH f- -> s.hp-y
  s.ein& dry p.atk-c p.rel-c follow-step | e |
  p.dyn 0.0 f=
  [ p.g ]
  [ e FD-REF f* 0.001 fmax log2 p.dyn f*  -3.3 3.3 fclamp exp2  p.g f* ] ifte | g |
  hp g f*  p.symm f+ | x |
  s.up& x up4 | a b c d |
  s.dec&  s p a fd-sub  s p b fd-sub  s p c fd-sub  s p d fd-sub  dec4 | yd |
  ( DC blocker: SYMM and the uneven folds leave an offset )
  yd s.dc-x f-  p.dc-r s.dc-y f*  f+ | dcy |
  yd -> s.dc-x
  dcy FD-FLUSH f+ FD-FLUSH f- -> s.dc-y
  s.lp  dcy s.lp f-  p.tone-g f*  f+ | toned |
  toned FD-FLUSH f+ FD-FLUSH f- -> s.lp
  ( AUTO: the wet's held peak matched to the input's, held in silence )
  s.ain& dry p.lvl-atk p.lvl-rel follow-step | li |
  s.awet& toned p.lvl-atk p.lvl-rel follow-step | lw |
  li  lw 1.0e-6 fmax f/  0.05 4.0 fclamp | r0 |
  s.auto 0.0 f=  1.0 s.auto select | a0 |
  li 1.0e-4 f<  a0 r0 select | ratio |
  a0  ratio a0 f-  1.0 p.auto-c f-  f*  f+ | ag |
  ag -> s.auto
  p.auto-on 0.5 f<  1.0 ag select | gain |
  ( the dry waits for the halfbands while any wet is mixed in )
  0.0 p.mix  s.d5  dry  fsel-lt | dly |
  s.d4 -> s.d5
  s.d3 -> s.d4
  s.d2 -> s.d3
  s.d1 -> s.d2
  dry -> s.d1
  toned gain f* p.mix f*  dly 1.0 p.mix f- f*  f+  p.out f*
  out f!64
;
