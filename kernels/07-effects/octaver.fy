( octaver.fy - an analog-style octave divider: Octaver [docs/43 §Octaver].

  The OC-2 recipe, as a model of what the circuit does rather than of its
  parts:

    in -> LP at TRACK -> comparator with hysteresis -> square at f
                                     |
                         flip-flop 1: toggles each rising edge -> f/2
                         flip-flop 2: toggles on flip-flop 1's -> f/4

  MODE picks the sub voice:
    SQUARE  the flip-flops themselves, scaled by the input's envelope -
            the buzzy synth sub
    FLIP    the tracking-filtered input, its polarity flipped by the
            flip-flops: x ff1 is an octave down [the components at f/2 and
            3f/2 - the round OC-2 sub], x ff1 ff2 two octaves down
  Each sub then runs through its own resonant lowpass [CUT, RES], as in
  Guitar Rig's Oktaver.

  GLITCH is the pedal pushed: the hysteresis narrows [relative to the
  envelope] and the tracking filter opens, so harmonics, chords and fret
  noise chatter the comparator and the sub jumps.  At 0 a single note
  tracks cleanly.  THRESH gates the subs: below it the divider would
  only follow noise.

  UP is the Octavia: the input full-wave rectified [doubling its
  frequency], DC-blocked, then FUZZ squares it; at FUZZ 0 it's the clean
  rectifier.  Ring-mod-like on chords and low notes, like the pedal.

  Dual mono: the host runs one pass per channel against its own state. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../00-primitives/follow.fy"
include "../04-filters/coeffs.fy"

ustruct: OcSvf f64 s1 f64 s2 ;

ustruct: OctState
  OcSvf track
  OcSvf track2
  OcSvf sub1
  OcSvf sub2
  Follow env
  f64 sq       ( comparator output, -1 / +1 )
  f64 ff1
  f64 ff2
  f64 gate     ( smoothed gate )
  f64 dc-x
  f64 dc-y
  f64 up-lp
;

ustruct: OctParams
  ( user-facing )
  f64 track-hz
  f64 glitch
  f64 mode     ( 0 SQUARE, 1 FLIP )
  f64 thresh-db
  f64 direct
  f64 oct1
  f64 oct2
  f64 up
  f64 fuzz
  f64 cut1
  f64 res1
  f64 cut2
  f64 res2
  f64 out-db
  ( derived )
  f64 g-track
  f64 hyst
  f64 thresh
  f64 g1 f64 k1
  f64 g2 f64 k2
  f64 atk-c f64 rel-c f64 gate-c
  f64 fuzz-gain f64 fuzz-norm
  f64 up-g
  f64 dc-r
  f64 out
;

:: OC-FLUSH 1.0e-12 ;
:: OC-SQ-GAIN 1.4 ;

dsp: octaver-block-prepare | ctx:Ctx s p:OctParams -- |
  ctx.sr | sr |
  p.track-hz  1.0 p.glitch 3.0 f* f+  f*  sr svf-g -> p.g-track
  ( hysteresis as a share of the envelope: 0.35 clean, 0 at full GLITCH )
  1.0 p.glitch f-  0.35 f* -> p.hyst
  p.thresh-db db>lin -> p.thresh
  p.cut1 sr svf-g -> p.g1
  1.4142135623730951  1.0 p.res1 0.9 f* f-  f* -> p.k1
  p.cut2 sr svf-g -> p.g2
  1.4142135623730951  1.0 p.res2 0.9 f* f-  f* -> p.k2
  0.002 sr follow-coef -> p.atk-c
  0.06 sr follow-coef -> p.rel-c
  0.005 sr follow-coef -> p.gate-c
  p.fuzz 30.0 f* db>lin -> p.fuzz-gain
  1.0  p.fuzz-gain tanh  f/ -> p.fuzz-norm
  7000.0 6.283185307179586 f* sr f/ 0.0 1.0 fclamp -> p.up-g
  -125.66370614359172 sr f/ exp -> p.dc-r
  p.out-db db>lin -> p.out
;

( s x g k -- lp bp : one TPT SVF step. )
dsp: oc-svf | s:OcSvf x g k -- lp bp |
  s.s1 | s1 |
  s.s2 | s2 |
  x  k g f+ s1 f*  f-  s2 f-   1.0 k g f* f+  g g f* f+  f/ | hp |
  g hp f* | ghp |
  ghp s1 f+ | bp |
  g bp f* | gbp |
  gbp s2 f+ | lp |
  ghp bp f+  OC-FLUSH f+ OC-FLUSH f- -> s.s1
  gbp lp f+  OC-FLUSH f+ OC-FLUSH f- -> s.s2
  lp bp
;

dsp: k-octaver-tick | out:Io ctx s:OctState p:OctParams -- |
  out.in-l | x |
  s.env& x p.atk-c p.rel-c follow-step | e |
  ( the tracking filter: two poles twice, a 4-pole Butterworth-ish LP )
  s.track& x p.g-track 1.4142135623730951 oc-svf drop | t1 |
  s.track2& t1 p.g-track 1.4142135623730951 oc-svf drop | t |
  ( comparator with hysteresis relative to the envelope )
  e p.hyst f* | h |
  s.sq | sq0 |
  sq0 0.0 f>  t 0.0 h f- f<  and | down |
  sq0 0.0 f<=  t h f>  and | upx |
  down -1.0  upx 1.0 sq0 select  select | sq |
  sq -> s.sq
  ( rising edges clock the flip-flops )
  sq0 0.0 f<=  sq 0.0 f>  and | rise1 |
  s.ff1 | f10 |
  f10 0.0 f= 1.0 f10 select | f10 |
  rise1  f10 fneg  f10  select | f1 |
  f1 -> s.ff1
  rise1  f10 0.0 f<  and  f1 0.0 f>  and | rise2 |
  s.ff2 | f20 |
  f20 0.0 f= 1.0 f20 select | f20 |
  rise2  f20 fneg  f20  select | f2 |
  f2 -> s.ff2
  ( the gate: open above THRESH, glided )
  e p.thresh f>  1.0 0.0 select | gt |
  s.gate  gt s.gate f-  1.0 p.gate-c f-  f*  f+ | gate |
  gate 1.0e-6 f< 0.0 gate select | gate |
  gate -> s.gate
  p.mode 0.5 f<
  [ f1 e f* OC-SQ-GAIN f*   f2 e f* OC-SQ-GAIN f* ]
  [ t f1 f*   t f1 f* f2 f* ] ifte | r1 r2 |
  s.sub1& r1 p.g1 p.k1 oc-svf drop gate f* | sub1 |
  s.sub2& r2 p.g2 p.k2 oc-svf drop gate f* | sub2 |
  ( UP: rectify, block the DC it makes, fuzz, smooth the top )
  p.up 0.0 f=
  [ 0.0 ]
  [ x fabs | r |
    r s.dc-x f-  p.dc-r s.dc-y f*  f+ | d |
    r -> s.dc-x  d -> s.dc-y
    p.fuzz 0.0 f=  d 2.0 f*  d p.fuzz-gain f* tanh p.fuzz-norm f* 0.5 f*  select | fz |
    s.up-lp  fz s.up-lp f-  p.up-g f*  f+ | u |
    u OC-FLUSH f+ OC-FLUSH f- -> s.up-lp
    u ] ifte | upv |
  x p.direct f*  sub1 p.oct1 f* f+  sub2 p.oct2 f* f+  upv p.up f* f+  p.out f*
  out f!64
;
