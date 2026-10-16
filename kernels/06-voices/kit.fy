( kit.fy - a modal physical-model drum kit voice [docs/41].

  Every hit is a body - a drumhead or a cymbal - rung by a striker.  A
  voice holds one hit: note-on picks the piece from the note [GM drum
  map] and builds its 40 modes; the render runs the same code for all of
  them.

  HEADS [kick, snare, toms] are ideal circular membranes
  [10-physical/bessel.fy]: modes at the Bessel ratios j_mn/j_01, a little
  compressed as air loading does to a real drum, struck at a radius whose
  shape value J_m[j_mn r] sets how hard each mode is driven - a center
  hit is round, toward the rim the overtones come in.  Loss rises with
  frequency, sigma = s0 + s1 f^2, fitted through two T60s.  Hard hits
  stretch the head and raise its tension: the modes run sharp in
  proportion to the head's strain energy and glide down as it decays
  [tension modulation; Berger's approximation, Bilbao 2009 ch. 13].  The
  gain follows from the head's elastic stiffness against its tension.

  CYMBALS AND HATS are plates: 40 inharmonic modes, loss rising with f,
  and a quadratic coupling between them through one shared coordinate
  [the lowest-order von Karman term], which pumps energy from the struck
  low modes into the upper ones - the crash's bloom and wash.

  STRIKERS are point masses meeting the body through the implicit
  power-law contact of 10-physical/modal.fy: hickory sticks as a Hertz
  contact [p = 1.5, K = 4/3 E* sqrt R], the kick's felt beater softer and
  more nonlinear.  The stick's impact itself clicks.

  SNARE WIRES are a lumped mass on a spring just under the head's center.
  When the head swings into them they collide [the same contact solve],
  fly off and fall back, rattling; each collision rings a bank of short
  high modes - the wires' buzz - and pushes back on the head.

  A closed or pedal hat chokes any open hat still ringing [through
  params.hat-clock].

  Clean-room: written from the literature cited here; the piece sizes,
  tensions and decays are estimates of typical kits, set by ear. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../04-filters/coeffs.fy"
include "../10-physical/modal.fy"
include "../10-physical/bessel.fy"
include "../00-primitives/rand.fy"

:: DN 40 ;   ( modes per hit )
:: WN 8 ;    ( wire buzz modes )

( plate mode ratios: [[i + 1.2]/1.2]^1.17 with a fixed jitter, so no two partials line up, x 1e6 )
table: cym-ratio 40
  f>i [ 965000 2018090 3216673 4239736 5598953 7069540 8079406 9672488 10611168 12315146
        14121229 14973928 16882702 17632060 19639425 21747761 22379859 24583770 25094722 27392224
        29791304 30165907 32657308 32898658 35481277 38166614 38258096 41034146 40983250 43849348
        46819477 46608319 49668379 49307532 52457109 55712068 55182535 58527107 57841783 61275707
        61275707 ] swap qnth i>f 0.000001 f* ;
( a fixed weight per plate mode at the strike, x 1e6 )
table: cym-w 40
  f>i [ 517000 949624 682248 414871 847495 580119 312743 745367 477990 910614
        643238 375862 808486 541109 973733 706357 438981 871605 604228 336852
        769476 502100 934724 667347 399971 832595 565219 997843 730466 463090
        895714 628338 360962 793585 526209 958833 691457 424081 856704 589328
        589328 ] swap qnth i>f 0.000001 f* ;
( a fixed sign per plate mode: the coupling vector, x 1e6 )
table: cym-s 40
  f>i [ 1000000 -1000000 -1000000 1000000 1000000 -1000000 -1000000 1000000 1000000 -1000000
        -1000000 1000000 1000000 -1000000 -1000000 1000000 1000000 1000000 -1000000 -1000000
        1000000 1000000 -1000000 -1000000 1000000 1000000 -1000000 -1000000 1000000 1000000
        -1000000 -1000000 1000000 1000000 -1000000 -1000000 1000000 1000000 -1000000 -1000000
        -1000000 ] swap qnth i>f 0.000001 f* ;
( plate radiation to the left microphone, x 1e6 )
table: cym-l 40
  f>i [ -140000 999680 139360 -720960 418720 -441600 698080 -162240 977440 117120
        -743200 396480 -463840 675840 -184480 955200 94880 -765440 374240 -486080
        653600 -206720 932960 72640 -787680 352000 -508320 631360 -228960 910720
        50400 -809920 329760 -530560 609120 -251200 888480 28160 -832160 307520
        307520 ] swap qnth i>f 0.000001 f* ;
( plate radiation to the right microphone, x 1e6 )
table: cym-r 40
  f>i [ -780000 884906 549812 214718 -120376 -455470 -790564 874342 539248 204154
        -130940 -466034 -801128 863778 528684 193590 -141504 -476598 -811692 853214
        518120 183026 -152068 -487162 -822256 842650 507556 172462 -162632 -497726
        -832820 832086 496992 161898 -173196 -508290 -843384 821522 486428 151334
        151334 ] swap qnth i>f 0.000001 f* ;
( snare wire buzz modes, Hz, x 1e6 )
table: wire-hz 8
  f>i [ 2100000000 4065750000 6606480000 9422190000 13112880000 17078550000 21919200000 27334830000 27334830000 ] swap qnth i>f 0.000001 f* ;

ustruct: KitState
  f64 q 40   f64 v 40
  f64 c 40   f64 sw 40   f64 ws 40   f64 rho 40
  f64 b1 40  f64 b2 40              ( exact-step force gains )
  f64 phi 40                        ( shape at the strike point )
  f64 gs 40                         ( striker force -> modal acceleration )
  f64 pc 40                         ( shape at the center / the plate's coupling vector )
  f64 w2 40                         ( w^2: tension modulation )
  f64 wl 40  f64 wr 40              ( radiation to each microphone )
  f64 wq 8  f64 wv 8                ( wire buzz modes )
  f64 wc 8  f64 wsw 8  f64 wws 8  f64 wrho 8  f64 wb2 8
  ( the hit )
  f64 piece                         ( 0 kick .. 11 ride bell )
  f64 plate                         ( 1 for cymbals and hats )
  f64 wires                         ( wire coupling 0..1 )
  f64 y  f64 en                     ( center coordinate, strain energy last sample )
  f64 glide                         ( tension modulation gain )
  f64 bloom                         ( plate coupling gain, 1/[m^2 s^2] )
  f64 kcap                          ( the coupling's stiffness cap, 1/s^2 )
  f64 inv-m                         ( 1 / modal mass )
  f64 su  f64 sv  f64 se            ( striker position, velocity, compression )
  f64 sm  f64 sk  f64 sp  f64 sal   ( striker mass, stiffness, exponent, hysteresis )
  f64 scomp                         ( striker + body compliance at the strike point )
  f64 stick-on
  f64 click-lp  f64 click-g
  f64 wu  f64 wuv  f64 we           ( wire mass position, velocity, compression )
  f64 wcomp  f64 wgap  f64 wbuzz
  f64 gain                          ( piece level x velocity scaling )
  f64 t0                            ( clock at note-on, for the hat choke )
  f64 choke                         ( 1 once choked )
  f64 rng-l  f64 rng-r              ( noise streams )
  f64 ed                            ( diffuse-field energy: the dense modes above the 40 )
  f64 dr  f64 kap  f64 dgain        ( its decay per sample, coupling, radiation gain )
  f64 hpa  f64 lpa                  ( its band: one-pole coefficients )
  f64 hl  f64 ll  f64 hr  f64 lr    ( its filter states )
  f64 ll2  f64 lr2
  ( the hit, for the mode stages )
  f64 k-f0  f64 k-s0  f64 k-s1  f64 k-sq  f64 k-r  f64 k-h  f64 k-fny
;

ustruct: KitParams
  ( user-facing: per piece tune [semitones], decay [x], level )
  f64 kick-tune   f64 kick-decay   f64 kick-level
  f64 snare-tune  f64 snare-decay  f64 snare-level
  f64 tom-tune    f64 tom-decay    f64 tom-level
  f64 hat-tune    f64 hat-decay    f64 hat-level
  f64 crash-tune  f64 crash-decay  f64 crash-level
  f64 ride-tune   f64 ride-decay   f64 ride-level
  f64 stick       ( striker hardness -1..1 )
  f64 wires       ( snare wire amount 0..1 )
  f64 glide       ( tension modulation 0..2 )
  f64 bloom       ( cymbal coupling 0..2 )
  f64 width       ( stereo width 0..1 )
  f64 level
  ( derived )
  f64 sr  f64 inv-sr
  f64 hat-clock   ( the clock of the last closed or pedal hat )
;

( p a0 .. a11 -- y : the value for piece p )
dsp: sel12 | p a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 -- y |
  a0
  p 0.5 f> a1 rot select  p 1.5 f> a2 rot select  p 2.5 f> a3 rot select
  p 3.5 f> a4 rot select  p 4.5 f> a5 rot select  p 5.5 f> a6 rot select
  p 6.5 f> a7 rot select  p 7.5 f> a8 rot select  p 8.5 f> a9 rot select
  p 9.5 f> a10 rot select  p 10.5 f> a11 rot select
;

dsp: kit-block-prepare | ctx:Ctx state params:KitParams -- |
  ctx.sr -> params.sr
  1.0 ctx.sr f/ -> params.inv-sr
;

( pitch -- piece : the GM drum map; notes outside 35..59 fold into it )
dsp: kit-piece | pitch -- p notelow |
  pitch 34.5 f<  pitch 59.5 f> or | out |
  out  pitch 12.0 f/ ffrac 12.0 f* 0.5 f+ floor 36.0 f+  pitch  select | n |
  n 36.5 f< 0.0
  n 37.5 f< 2.0
  n 38.5 f< 1.0
  n 39.5 f< 2.0
  n 40.5 f< 1.0
  n 41.5 f< 3.0
  n 42.5 f< 6.0
  n 43.5 f< 3.0
  n 44.5 f< 7.0
  n 45.5 f< 4.0
  n 46.5 f< 8.0
  n 47.5 f< 4.0
  n 48.5 f< 5.0
  n 49.5 f< 9.0
  n 50.5 f< 5.0
  n 51.5 f< 10.0
  n 52.5 f< 9.0
  n 53.5 f< 11.0
  n 56.5 f< 9.0
  n 57.5 f< 9.0
  10.0  select select select select select select select select select select
        select select select select select select select select select select
  ( the lower note of each tom pair, and the second kick, sit lower )
  n 35.5 f<  n 41.5 f< n 40.5 f> and or  n 45.5 f< n 44.5 f> and or  n 48.5 f< n 47.5 f> and or
    mask>f
;

( ctx state params -- : note-on part 1, the piece's physical constants )
dsp: kit-key | ctx:Ctx state:KitState params:KitParams -- |
  ctx.hz kit-piece | p low |
  p -> state.piece
  p 5.5 f> | plm |
  plm mask>f -> state.plate
  params.inv-sr | h |
  h -> state.k-h
  params.sr 0.45 f* -> state.k-fny
  ctx.clock -> state.t0
  0.0 -> state.choke
  ( a closed or pedal hat chokes the open ones )
  p 5.5 f> p 7.5 f< and  ctx.clock params.hat-clock select -> params.hat-clock
  ( tuning: the piece's own pitch, its knob, and the lower note of a pair )
  p params.kick-tune params.snare-tune params.snare-tune params.tom-tune params.tom-tune
    params.tom-tune params.hat-tune params.hat-tune params.hat-tune params.crash-tune
    params.ride-tune params.ride-tune sel12 0.08333333333333333 f* exp2 | tune |
  p 52.0 185.0 185.0 82.0 118.0 165.0 420.0 420.0 420.0 190.0 240.0 560.0 sel12
    tune f*  low 0.5 f> 0.86 1.0 select f* | f0 |
  f0 -> state.k-f0
  ( decay: T60 at f0 and at 3 kHz, times the piece's knob )
  p params.kick-decay params.snare-decay params.snare-decay params.tom-decay params.tom-decay
    params.tom-decay params.hat-decay params.hat-decay params.hat-decay params.crash-decay
    params.ride-decay params.ride-decay sel12 | dk |
  p 0.5 0.6 0.15 1.4 1.0 0.8 0.18 0.06 1.8 5.0 7.0 5.0 sel12 dk f* t60>sigma | sa |
  p 0.06 0.25 0.07 0.18 0.18 0.18 0.12 0.04 1.0 1.6 2.2 2.5 sel12 dk f* t60>sigma | sb |
  ( membranes lose as f^2, plates as f )
  plm 1.0 2.0 select | sq |
  sq -> state.k-sq
  3000.0 sq pow  f0 sq pow  f- 1.0 fmax | span |
  sb sa f- 0.0 fmax span f/ | s1 |
  s1 -> state.k-s1
  sa s1 f0 sq pow f* f- 0.0 fmax -> state.k-s0
  ( body: radius, mass, strike radius )
  p 0.229 0.17 0.17 0.2 0.165 0.15 0.18 0.18 0.18 0.23 0.255 0.255 sel12 | a |
  p 0.08 0.032 0.032 0.057 0.038 0.032 0.8 0.8 0.8 1.5 2.2 2.2 sel12 0.25 f* | mm |
  1.0 mm f/ -> state.inv-m
  p 0.1 0.35 0.92 0.4 0.4 0.4 0.6 0.6 0.6 0.85 0.6 0.12 sel12 -> state.k-r
  ( tension modulation: G = 150 / c^2, c = 2 pi f0 a / j01, two-ply heads stiffer )
  6.283185307179586 f0 f* a f* 2.4048 f/ dup f* | c2 |
  p 300.0 150.0 150.0 300.0 150.0 150.0 0.0 0.0 0.0 0.0 0.0 0.0 sel12 c2 f/
    params.glide f* -> state.glide
  ( bloom: the coupling matches the linear stiffness at about 0.3 mm )
  6.283185307179586 f0 f* dup f* | w02 |
  p 0.0 0.0 0.0 0.0 0.0 0.0 0.6 0.6 0.6 1.0 0.25 0.1 sel12 params.bloom f*
    w02 f* 3.0e6 f* -> state.bloom
  w02 0.5 f* -> state.kcap
  ( wires: the snare, and a little under a side stick )
  p 0.0 1.0 0.3 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 sel12 params.wires f* | wi |
  wi -> state.wires
  ( striker: mass, stiffness, exponent, hysteresis, speed )
  p 0.035 0.012 0.02 0.012 0.012 0.012 0.012 0.008 0.012 0.012 0.012 0.012 sel12 | sm |
  sm -> state.sm
  p 7.3 8.64 8.3 8.64 8.64 8.64 9.08 8.8 9.08 9.08 9.08 9.2 sel12
    params.stick 0.7 f* f+ 3.321928094887362 f* exp2 -> state.sk
  p 2.3 1.5 1.5 1.5 1.5 1.5 1.5 1.5 1.5 1.5 1.5 1.5 sel12 -> state.sp
  p 0.3 0.05 0.1 0.05 0.05 0.05 0.05 0.2 0.05 0.05 0.05 0.05 sel12 -> state.sal
  ctx.vel 0.0 1.0 fclamp | vel |
  p 0.6 0.8 0.5 0.8 0.8 0.8 0.6 0.25 0.6 0.8 0.6 0.6 sel12  vel 1.2 pow
  p 4.0 9.0 4.0 9.0 9.0 9.0 6.0 1.5 6.0 8.0 6.0 6.0 sel12 f* f+ -> state.sv
  -0.00002 -> state.su  -0.00002 -> state.se
  1.0 -> state.stick-on
  h h f* 0.5 f* state.sm f/ -> state.scomp
  0.0 -> state.click-lp
  p 0.25 0.12 0.5 0.08 0.08 0.08 0.15 0.3 0.15 0.08 0.1 0.1 sel12 -> state.click-g
  ( wires: rest a hair under the head, closer with more WIRES )
  0.0 -> state.wu  0.0 -> state.wuv  -0.00001 -> state.we
  1.0 wi f- 0.00006 f* 0.000005 f+ -> state.wgap
  h h f* 0.5 f* 0.004 f/ -> state.wcomp
  0.0 -> state.y  0.0 -> state.en
  ( level: the piece's knob, a gentle velocity curve, and a per-piece trim
    that puts each near the same loudness )
  p params.kick-level params.snare-level params.snare-level params.tom-level params.tom-level
    params.tom-level params.hat-level params.hat-level params.hat-level params.crash-level
    params.ride-level params.ride-level sel12
  p 0.5 0.019 0.054 0.03 0.025 0.024 0.05 0.32 0.045 0.055 0.1 0.1 sel12 f*
    params.level f* params.sr f* 0.002 f* -> state.gain
  ( the wire buzz bank )
  0.0 WN [ | j |
    wire-hz j f@i 6.283185307179586 f* | w |
    w h zoh-coefs | c sw ws b1 b2 |
    c state.wc& j f!i  sw state.wsw& j f!i  ws state.wws& j f!i  b2 state.wb2& j f!i
    0.016 j 0.001 f* f- t60>sigma h f* fneg exp state.wrho& j f!i
    0.0 state.wq& j f!i  0.0 state.wv& j f!i
    j 1.0 f+ ] times drop
  0.0 -> state.wbuzz
  ( the diffuse field: the plates' dense upper modes as one energy store
    fed by the discrete modes [statistical energy analysis, Lyon 1975],
    decaying at the piece's high-frequency rate, radiating band noise )
  0.0 -> state.ed  0.0 -> state.hl  0.0 -> state.ll  0.0 -> state.hr  0.0 -> state.lr
  0.0 -> state.ll2  0.0 -> state.lr2
  sb h f* fneg exp -> state.dr
  p 0.0 0.0 0.0 0.0 0.0 0.0 1.0 1.0 1.0 1.0 0.5 0.2 sel12 params.bloom f* 160.0 f* -> state.kap
  p 0.0 0.0 0.0 0.0 0.0 0.0 1.0 1.0 1.0 1.0 1.0 1.0 sel12 -> state.dgain
  params.sr  p 0.0 0.0 0.0 0.0 0.0 0.0 4000.0 4000.0 3500.0 1800.0 2200.0 2500.0 sel12 1000.0 fmax
    svf-dc-coeff -> state.hpa
  params.sr 6500.0 svf-dc-coeff -> state.lpa
  ( every hit starts its noise from the same place, like a sample, but
    the two channels differ )
  0.1234567 -> state.rng-l  0.7654321 -> state.rng-r
;

( state i -- comp : build mode i of the hit and return its compliance at
  the strike point [i a literal in each stage] )
dsp: kit-mode | state:KitState params:KitParams i -- comp |
  state.k-h | h |  state.plate 0.5 f> | pl |
  ( frequency: membranes at the air-loaded Bessel ratios, plates on theirs )
  pl  cym-ratio i f@i  memb-ratio i f@i log2 0.94 f* exp2  select state.k-f0 f* | fr |
  fr state.k-fny f< mask>f | live |
  fr state.k-fny fmin 6.283185307179586 f* | w |
  w h zoh-coefs | c sw ws b1 b2 |
  c state.c& i f!i  sw state.sw& i f!i  ws state.ws& i f!i
  b1 state.b1& i f!i  b2 state.b2& i f!i
  w w f* state.w2& i f!i
  ( the plates' upper modes also lose to the diffuse field, which takes
    their energy over as wash )
  state.kap 0.0015 f* fr 2500.0 f- 0.0 fmax f* state.plate f* | sdf |
  state.k-s0  state.k-s1 fr state.k-sq pow f* f+  sdf f+  h f* fneg exp state.rho& i f!i
  memb-m i f@i | m |
  ( shape at the strike point; plates use their fixed weights )
  pl  cym-w i f@i cym-s i f@i f*  cym-ratio i f@i log2 -0.7 f* exp2 f*
      i state.k-r memb-shape-at  select live f* | ph |
  ph state.phi& i f!i
  ph state.inv-m f* state.gs& i f!i
  ( center coordinate: only the m = 0 modes move there; plates couple
    through a fixed signed vector )
  pl  cym-s i f@i 0.5 f*  m 0.5 f< mask>f i 0.0 memb-shape-at f*  select live f* state.pc& i f!i
  ( radiation: the m = 0 modes are monopoles, higher m radiate less; the
    microphones sit at r = 0.6 on two angles )
  1.0 m 1.0 f+ f/ | rad |
  i 0.6 memb-shape-at rad f* | mic |
  pl  cym-l i f@i  mic m 0.5 f* cos f* select live f* | wl0 |
  pl  cym-r i f@i  mic m 0.5 1.2 params.width f* f+ f* cos f* select live f* | wr0 |
  wl0 wr0 f+ 0.5 f* | mid |
  wl0 mid f- params.width f* mid f+ state.wl& i f!i
  wr0 mid f- params.width f* mid f+ state.wr& i f!i
  0.0 state.q& i f!i  0.0 state.v& i f!i
  ph state.inv-m f* b1 f* ph f*
;

dsp: kit-modes-0 | ctx state:KitState params -- |
  0.0 state.scomp 16 [ | i cp |  i 1.0 f+  cp state params i kit-mode f+ ] times nip -> state.scomp
;
dsp: kit-modes-1 | ctx state:KitState params -- |
  16.0 state.scomp 16 [ | i cp |  i 1.0 f+  cp state params i kit-mode f+ ] times nip -> state.scomp
;
dsp: kit-modes-2 | ctx state:KitState params -- |
  32.0 state.scomp 8 [ | i cp |  i 1.0 f+  cp state params i kit-mode f+ ] times nip -> state.scomp
;
( the wires' compliance: their mass plus the head at its center )
dsp: kit-wire-comp | ctx state:KitState params -- |
  0.0 state.wcomp DN [ | i cp |  i 1.0 f+  cp  state.pc& i f@i dup f* state.inv-m f* state.b1& i f@i f* f+ ] times nip
    -> state.wcomp
;

( ctx state params -- : strike this voice. )
dsp: kit-note-on | ctx state params |
  ctx state params call: kit-key
  ctx state params call: kit-modes-0
  ctx state params call: kit-modes-1
  ctx state params call: kit-modes-2
  ctx state params call: kit-wire-comp
;

( ctx state params -- : every 32 samples - retire the striker once it has
  bounced clear, and choke an open hat when a closed one is played. )
dsp: kit-control | ctx state:KitState params:KitParams -- |
  state.sv 0.0 f<  state.se -0.001 f< and  0.0 state.stick-on select -> state.stick-on
  state.piece 7.5 f> state.piece 8.5 f< and  params.hat-clock state.t0 f> and | ch |
  ch state.choke 0.5 f< and | now |
  ( a choke multiplies every decay factor down to a 40 ms T60 )
  0.0 DN [ | i |
    state.rho& i f@i  now 0.9965 1.0 select f*  state.rho& i f!i
    i 1.0 f+ ] times drop
  ch 1.0 state.choke select -> state.choke
;

( state f -- f : the striker; returns its force on the body )
dsp: kit-stick | state:KitState params:KitParams fc -- f |
  state.glide state.en f* 0.25 fmin | dl |
  params.inv-sr | h |
  0.0 0.0 DN [ | i acc |
    i 1.0 f+  acc
    state.c& i f@i | c |  state.sw& i f@i | sw |  state.ws& i f@i | ws |
    c ws h f* dl f* f-  state.q& i f@i f*
      sw  c h f* sw f- dl f* f+  state.v& i f@i f* f+
      state.rho& i f@i f*
      state.pc& i f@i fc f*  state.b1& i f@i f* f+
      state.phi& i f@i f* f+ ] times nip | ypred |
  params.inv-sr | h |
  state.su state.sv h f* f+ | ufree |
  ufree ypred f-  state.se  state.scomp  state.sk state.sp state.sal params.sr
    contact-solve | e f |
  e -> state.se
  f state.sm f/ | a |
  ufree 0.5 h f* h f* a f* f- -> state.su
  state.sv h a f* f- -> state.sv
  f
;

( state -- fw : the snare wires against the head's center )
dsp: kit-wires | state:KitState params:KitParams -- fw |
  params.inv-sr | h |
  ( the wires: 100 Hz spring, heavily damped, 4 g )
  state.wuv -394784.176 state.wu f* -251.0 state.wuv f* f+ h f* f+ | vfree |
  state.wu vfree h f* f+ | ufree |
  ( the head's center moves into the wires: compression = y - u - gap )
  state.y ufree f- state.wgap f-  state.we  state.wcomp  5000000.0 1.5 0.2 params.sr
    contact-solve | e f |
  e -> state.we
  vfree f 0.004 f/ h f* f+ -> state.wuv
  ufree 0.5 h f* h f* f 0.004 f/ f* f+ -> state.wu
  ( the collision rings the wire buzz modes.  Twenty strands land at
    scattered moments, so the force reaching them is the collision force
    times noise )
  state.rng-l& rand-b f 45.0 f* f* | fz |
  0.0 0.0 WN [ | j acc |
    state.wq& j f@i | q |  state.wv& j f@i | v |
    state.wc& j f@i | c |  state.wrho& j f@i | r |
    c q f* state.wsw& j f@i v f* f+ r f* | qn |
    state.wws& j f@i q f* fneg c v f* f+ r f*  state.wb2& j f@i fz f* f+ | vn |
    qn state.wq& j f!i  vn state.wv& j f!i
    j 1.0 f+  acc vn v f- f+ ] times nip  state.wires f* -> state.wbuzz
  f
;

( io state params f fc -- : advance the modes under the striker force f
  and the center force fc, and radiate )
dsp: kit-body | io:Io state:KitState params:KitParams f fc -- |
  ( tension modulation: every mode's frequency rises by dl, its share of
    the head's strain energy; the step's rotation is bent to first order,
    which keeps it a rotation and so stable at any mode frequency )
  state.glide state.en f* 0.25 fmin | dl |
  params.inv-sr | h |
  0.0 0.0 0.0 0.0 0.0 DN [ | i y en ol or |
    state.q& i f@i | q |  state.v& i f@i | v |
    state.c& i f@i | c0 |  state.sw& i f@i | sw0 |  state.ws& i f@i | ws0 |
    state.rho& i f@i | r |
    state.w2& i f@i | w2 |
    c0 ws0 h f* dl f* f- | c |
    sw0  c0 h f* sw0 f- dl f* f+ | sw |
    ws0  ws0 w2 h f* c0 f* f+ dl f* f+ | ws |
    state.gs& i f@i f f*  state.pc& i f@i fc f* f+ | fi |
    c q f*  sw v f* f+  r f*  state.b1& i f@i fi f* f+ | qn |
    ws q f* fneg  c v f* f+  r f*  state.b2& i f@i fi f* f+ | vn |
    qn state.q& i f!i  vn state.v& i f!i
    vn v f- | dv |
    i 1.0 f+
    y state.pc& i f@i qn f* f+
    en w2 qn f* qn f* f+
    ol state.wl& i f@i dv f* f+
    or state.wr& i f@i dv f* f+ ] times | i y en ol or |
  y -> state.y  en -> state.en
  ( the striker's click: its force, high-passed by a 1 kHz one-pole )
  state.click-lp | cl |
  f cl f- 0.12 f* cl f+ | cln |
  cln -> state.click-lp
  f cln f- state.click-g f* state.inv-m f* params.inv-sr f* | ck |
  ( the diffuse field: fed by the modes' strain energy, radiated as noise
    in the plate's upper band, its amplitude the field's rms velocity )
  state.ed state.dr f*  state.kap en f* params.inv-sr f* f+ | ed |
  ed 1.0e-16 f> mask>f ed f* | ed |
  ed -> state.ed
  ed fsqrt state.dgain f* 7000.0 f* | da |
  state.rng-l& rand-b da f* | nl |  state.rng-r& rand-b da f* | nr |
  state.hl nl state.hl f- state.hpa f* f+ | hl |  hl -> state.hl
  state.ll nl hl f- state.ll f- state.lpa f* f+ | ll1 |  ll1 -> state.ll
  state.ll2 ll1 state.ll2 f- state.lpa f* f+ | ll |  ll -> state.ll2
  state.hr nr state.hr f- state.hpa f* f+ | hr |  hr -> state.hr
  state.lr nr hr f- state.lr f- state.lpa f* f+ | lr1 |  lr1 -> state.lr
  state.lr2 lr1 state.lr2 f- state.lpa f* f+ | lr |  lr -> state.lr2
  io.out-l  ol ck f+ state.wbuzz f+ ll params.inv-sr f* f+ state.gain f* f+ -> io.out-l
  io.out-r  or ck f+ state.wbuzz f+ lr params.inv-sr f* f+ state.gain f* f+ -> io.out-r
;

( io ctx state params -- : one hit, one sample.  Output ACCUMULATES. )
dsp: k-kit-voice | io:Io ctx state:KitState params:KitParams -- |
  ( the plate coupling: a cubic restoring force through the shared
    coordinate - a quartic potential, so it only moves energy between
    modes - with its stiffness capped so the explicit step stays stable )
  state.y | y |
  state.bloom y f* y f* | gy |
  gy y f* fneg  1.0 gy state.kcap f/ f+  f/ state.plate f* | fnl |
  state.wires 0.0 f> [ state params kit-wires ] [ 0.0 ] ifte | fw |
  fnl fw state.inv-m f* f- | fc |
  state.stick-on 0.5 f> [ state params fc kit-stick ] [ 0.0 ] ifte | f |
  io state params f fc kit-body
;
