( concoction.fy - a clean digital wavetable voice, after Serum.

  Two wavetable oscillators [A, B] with a position, octave/semi/fine, a
  fixed start phase and a warp; a sub oscillator; noise; one ladder
  filter with every tap [LP 24/18/12, BP, HP 12/24, notch]; three
  envelopes [AMP, FILTER, MOD]; a pitch envelope and glide; two LFOs; an
  8-slot mod matrix.

  The sound starts where Serum's starts: nothing drifts.  Every note
  starts each oscillator at its PHASE [RAND spreads it], so a bass hits
  the same way every time - the crispness the analog machines don't
  have.  The sub and noise can skip the filter [FILT off], the trick for
  a sub that stays put under a plucked mid.

  Tables [src/wavetable.zig, 01-oscillators/wavetable.fy]: TABLE picks
  one of the bank's built-in tables [assets/bank.wav, WT-BANK-FRAMES
  frames each, tools/wavetables/gen.py] or USER, the oscillator's own
  loaded file - any Serum wavetable.

  Rates.  The voice runs its audio path per sample: the oscillators, the
  sub, noise, the filter, the AMP envelope and the mix.  Everything that
  modulates it runs at the control rate [k-concoction-control, every
  CN-CP samples of the voice, docs/04 control!]: the FILTER and MOD
  envelopes, the pitch envelope, glide, the LFOs and the matrix.  The
  control word computes each modulated value's target and the render
  ramps to it linearly over the period: oscillator increments, table
  positions, warps, levels, the ladder's g and k, the drive, the amp.
  A 0.67 ms ramp keeps a fast pluck smooth and costs a fraction of
  per-sample modulation.

  Warps [per oscillator, WARP + AMT]:
    SYNC  the table read k = 1..8 times a cycle: hard sync
    PWM   the cycle squeezed into the first 1/k of the period, then the
          table's start value
    BEND  the phase bent toward the start [rational, slope 1..16]: phase
          distortion, brighter as it bends
    FM    phase modulation: A by B, B by the sub
  SYNC, PWM and BEND pick their mip level by the steepest slope they
  read at, so they stay band-limited.

  Matrix sources: ENV2 ENV3 LFO1 LFO2 VEL NOTE PRESS SLIDE RAND.  Each
  slot adds AMT x the source to a destination: table position, warp,
  level [+-1], pitch [+-12 semitones], cutoff [+-8 octaves], resonance,
  drive [+-1], AMP [x 1 + amt src: tremolo, the sidechain pump].

  Variants [docs/05 §Branching]: USER on A, B on and USER on B, the
  filter on, the sub on - 24 bodies.  The warp and shape switches are
  selects. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../01-oscillators/primitives/phase.fy"
include "../01-oscillators/primitives/blep.fy"
include "../01-oscillators/wavetable.fy"
include "../03-envelopes/primitives/env_dig.fy"
include "../04-filters/coeffs.fy"
include "../04-filters/ladder.fy"

:: CN-CP 32.0 ;              ( control period, samples: manifest `control!` )
:: WT-BANK-FRAMES 16.0 ;     ( frames per bank table: tools/wavetables/gen.py )
:: CN-USER 9.5 ;             ( TABLE above this is USER )
:: CN-MAKEUP 0.5 ;

ustruct: ConcoctionParams
  ( OSC A )
  f64 a-table  f64 a-pos  f64 a-oct  f64 a-semi  f64 a-fine  f64 a-level
  f64 a-warp   f64 a-wamt  f64 a-phase  f64 a-rand  f64 a-filt
  ( OSC B )
  f64 b-on
  f64 b-table  f64 b-pos  f64 b-oct  f64 b-semi  f64 b-fine  f64 b-level
  f64 b-warp   f64 b-wamt  f64 b-phase  f64 b-rand  f64 b-filt
  ( SUB: shape 0 sine 1 triangle 2 saw 3 square )
  f64 sub-on  f64 sub-shape  f64 sub-oct  f64 sub-level  f64 sub-filt
  ( NOISE )
  f64 n-level  f64 n-color  f64 n-filt
  ( FILTER: mode 0 off 1 LP24 2 LP18 3 LP12 4 BP 5 HP12 6 HP24 7 notch )
  f64 f-mode  f64 f-cut  f64 f-res  f64 f-drive  f64 f-key  f64 f-env
  ( envelopes )
  f64 e1-a  f64 e1-h  f64 e1-d  f64 e1-s  f64 e1-r
  f64 e2-a  f64 e2-d  f64 e2-s  f64 e2-r
  f64 e3-a  f64 e3-d  f64 e3-s  f64 e3-r
  ( pitch envelope [semitones, seconds, 0 all / 1 A+B], glide [s, 0 always / 1 legato] )
  f64 p-amt  f64 p-time  f64 p-dest
  f64 glide  f64 g-mode
  ( LFOs: shape 0 sine 1 tri 2 saw up 3 saw down 4 square 5 S&H;
    sync 0 = RATE in Hz, else beats a cycle; mode 0 free 1 retrig 2 env )
  f64 l1-shape  f64 l1-rate  f64 l1-sync  f64 l1-mode  f64 l1-uni
  f64 l2-shape  f64 l2-rate  f64 l2-sync  f64 l2-mode  f64 l2-uni
  ( matrix )
  f64 m-src 8
  f64 m-dst 8
  f64 m-amt 8
  ( out )
  f64 vel  f64 level
  ( tables, injected by the host [manifest `wavetable`] )
  f64 bank  f64 bank-frames
  f64 wt-a  f64 wt-a-frames
  f64 wt-b  f64 wt-b-frames
  ( derived - concoction-block-prepare )
  f64 inv-sr
  f64 mip-k
  f64 a-fb  f64 a-fn  f64 b-fb  f64 b-fn   ( first frame, frames )
  f64 fc0  f64 fc1  f64 fc2  f64 fc3  f64 fc4  ( filter tap mix )
  f64 f-comp   ( resonance gain compensation, LP modes )
  f64 p-coef  f64 g-coef               ( per control step )
  f64 l1-inc  f64 l2-inc               ( cycles per control step )
  f64 n-a                              ( noise color one-pole )
  f64 dc-a                             ( the output's 5 Hz DC blocker )
  EnvDCoefs e1c
  EnvDCoefs e2c
  EnvDCoefs e3c
;

ustruct: ConcoctionState
  f64 a-ph  f64 b-ph  f64 s-ph
  f64 rng   f64 nlp
  LadderState lad
  EnvD e1  EnvD e2  EnvD e3
  ( the note )
  f64 base-inc  ( note f / sr )
  f64 kt        ( octaves from middle C )
  f64 note      ( NOTE source, -1..1 over C2..C6 )
  f64 velo  f64 press  f64 slide  f64 rnd  f64 seed
  ( control-rate modulators )
  f64 pe        ( pitch envelope, 1 -> 0 )
  f64 gl        ( glide offset, octaves -> 0 )
  f64 l1-ph  f64 l1-sh  f64 l2-ph  f64 l2-sh
  f64 first     ( 1 until the first control step snaps the ramps )
  f64 macc 16   ( matrix sums by destination )
  ( ramps: the value, its step per sample )
  f64 a-inc  f64 a-inc-d   f64 b-inc  f64 b-inc-d   f64 s-inc  f64 s-inc-d
  f64 a-pos  f64 a-pos-d   f64 b-pos  f64 b-pos-d
  f64 a-w    f64 a-w-d     f64 b-w    f64 b-w-d
  f64 a-lv   f64 a-lv-d    f64 b-lv   f64 b-lv-d
  f64 s-lv   f64 s-lv-d    f64 n-lv   f64 n-lv-d
  f64 g      f64 g-d       f64 k      f64 k-d
  f64 dg     f64 dg-d      f64 dp     f64 dp-d
  f64 amp    f64 amp-d
  f64 dc-x   f64 dc-y      ( the output's DC blocker )
  ( for the panel [docs/15 §Modulation]: the LFOs' values, and what the
    filter, drive and amp are modulated to, in their controls' units )
  f64 l1-v  f64 l2-v
  f64 cut-hz  f64 res-v  f64 drv-v  f64 amp-v
;

( --- block rate ----------------------------------------------------- )

( mode -- c0 c1 c2 c3 c4 : the ladder tap mix for a FILTER mode. )
dsp: cn-taps | m -- c0 c1 c2 c3 c4 |
  m 1.5 f< m 2.5 f< m 3.5 f< m 4.5 f< m 5.5 f< m 6.5 f< | t1 t2 t3 t4 t5 t6 |
  t1 0.0  t2 0.0  t3 0.0  t4 0.0  t5 1.0  t6 1.0  1.0  select select select select select select
  t1 0.0  t2 0.0  t3 0.0  t4 2.0  t5 -2.0  t6 -4.0  -2.0  select select select select select select
  t1 0.0  t2 0.0  t3 1.0  t4 -2.0  t5 1.0  t6 6.0  2.0  select select select select select select
  t1 0.0  t2 1.0  t3 0.0  t4 0.0  t5 0.0  t6 -4.0  0.0  select select select select select select
  t1 1.0  t2 0.0  t3 0.0  t4 0.0  t5 0.0  t6 1.0  0.0  select select select select select select
;

( sync rate -- inc : an LFO's cycles per control step: RATE in Hz, or
  one cycle per `sync` beats at the host tempo. )
dsp: cn-lfo-inc | ctx:Ctx sync rate -- inc |
  sync 0.5 f<  rate  ctx.tempo 60.0 f/  sync 0.0625 fmax f/  select
  CN-CP f* ctx.inv-sr f*
;

dsp: concoction-block-prepare | ctx:Ctx state params:ConcoctionParams |
  ctx.inv-sr | inv |
  inv -> params.inv-sr
  ctx.sr wt-mip-k -> params.mip-k
  ( tables: a bank table's frames, or the whole USER file )
  params.a-table CN-USER f>  0.0  params.a-table WT-BANK-FRAMES f*  select -> params.a-fb
  params.a-table CN-USER f>  params.wt-a-frames 1.0 fmax  WT-BANK-FRAMES  select -> params.a-fn
  params.b-table CN-USER f>  0.0  params.b-table WT-BANK-FRAMES f*  select -> params.b-fb
  params.b-table CN-USER f>  params.wt-b-frames 1.0 fmax  WT-BANK-FRAMES  select -> params.b-fn
  params.f-mode cn-taps | c0 c1 c2 c3 c4 |
  c0 -> params.fc0  c1 -> params.fc1  c2 -> params.fc2  c3 -> params.fc3  c4 -> params.fc4
  params.f-mode 4.5 f<  0.5 0.0 select -> params.f-comp
  inv CN-CP f* | cdt |
  params.e1c&  params.e1-a params.e1-h params.e1-d params.e1-s params.e1-r  inv env-d-coefs
  params.e2c&  params.e2-a 0.0 params.e2-d params.e2-s params.e2-r  cdt env-d-coefs
  params.e3c&  params.e3-a 0.0 params.e3-d params.e3-s params.e3-r  cdt env-d-coefs
  ( pitch envelope and glide: 99% of the way in their times )
  -4.605170185988091 cdt f*  params.p-time 0.0005 fmax f/ exp -> params.p-coef
  -4.605170185988091 cdt f*  params.glide 0.0005 fmax f/ exp -> params.g-coef
  ctx params.l1-sync params.l1-rate cn-lfo-inc -> params.l1-inc
  ctx params.l2-sync params.l2-rate cn-lfo-inc -> params.l2-inc
  ( noise color: a 1.2 kHz one-pole to lean on either side of white )
  1.0  -7539.822368615503 inv f* exp  f- -> params.n-a
  1.0  1.0  31.41592653589793 inv f*  f+  f/ -> params.dc-a
;

( --- notes ---------------------------------------------------------- )

( state -- r : the voice's next pseudo-random number, 0..1. )
dsp: cn-rand | state:ConcoctionState -- r |
  state.seed 0.7548776662466927 f* 0.5698402909980532 f+ 7.0 f* ffrac | r |
  r -> state.seed
  r
;

( ph phase rand r -- ph : an oscillator's start phase. )
dsp: cn-start | phase rand r -- ph |
  phase rand r f* f+ ffrac
;

dsp: concoction-note-on | ctx:Ctx state:ConcoctionState params:ConcoctionParams |
  ctx.legato | legato |
  legato 0.5 f< | fresh |
  ctx.hz params.inv-sr f* | inc |
  ( glide: from where this voice is, when GLIDE is up and the mode allows )
  state.base-inc 0.0 f>  params.glide 0.0005 f> and
    legato 0.5 f>  params.g-mode 0.5 f<  or  and | glides |
  glides  state.base-inc inc f/ log2 state.gl f+  0.0  select -> state.gl
  inc -> state.base-inc
  ctx.hz 261.6255653005986 f/ log2 -> state.kt
  ctx.pitch 60.0 f- 24.0 f/ -1.0 1.0 fclamp -> state.note
  ctx.pressure -> state.press
  ctx.slide -> state.slide
  ( a unison voice's place stirs its random numbers apart )
  state.seed  ctx.chan 0.6180339887 f* f+  ctx.phase f+  ctx.pitch 0.0137 f* f+  ffrac -> state.seed
  state cn-rand | r1 |
  state cn-rand | r2 |
  state cn-rand | r3 |
  fresh  r3 2.0 f* 1.0 f-  state.rnd  select -> state.rnd
  fresh ctx.vel state.velo select -> state.velo
  ( a fresh note starts every oscillator at its phase; legato runs on )
  fresh  params.a-phase params.a-rand r1 cn-start  state.a-ph  select -> state.a-ph
  fresh  params.b-phase params.b-rand r2 cn-start  state.b-ph  select -> state.b-ph
  fresh  0.5  state.s-ph  select -> state.s-ph
  fresh  1.0  state.pe  select -> state.pe
  ( LFOs: RETRIG and ENV restart; FREE in sync locks to the bar )
  params.l1-mode 0.5 f>  0.0
    params.l1-sync 0.5 f>  ctx.beat params.l1-sync f/ ffrac  state.l1-ph  select  select | p1 |
  params.l2-mode 0.5 f>  0.0
    params.l2-sync 0.5 f>  ctx.beat params.l2-sync f/ ffrac  state.l2-ph  select  select | p2 |
  fresh p1 state.l1-ph select -> state.l1-ph
  fresh p2 state.l2-ph select -> state.l2-ph
  state.e1& params.e1c& legato env-d-trigger
  state.e2& params.e2c& legato env-d-trigger
  state.e3& params.e3c& legato env-d-trigger
  1.0 -> state.first
;

dsp: concoction-note-expr | ctx:Ctx state:ConcoctionState params:ConcoctionParams |
  ctx.hz params.inv-sr f* -> state.base-inc
  ctx.pressure -> state.press
  ctx.slide -> state.slide
;

dsp: concoction-note-off | ctx state:ConcoctionState params |
  state.e1& env-d-release
  state.e2& env-d-release
  state.e3& env-d-release
;

( --- control rate --------------------------------------------------- )

( ph inc mode -- ph' wrapped : advance an LFO phase; ENV mode stops at 1. )
dsp: cn-lfo-adv | ph inc mode -- ph2 wrapped |
  ph inc f+ | n |
  mode 1.5 f>  n 1.0 fmin  n ffrac  select
  n 1.0 f>=  mode 1.5 f< and  mask>f
;

( ph sh shape uni -- v : an LFO's value. )
dsp: cn-lfo-val | ph sh shape uni -- v |
  ph sin2pi | sn |
  ph 0.25 f+ ffrac 0.5 f- fabs 4.0 f* 1.0 f- fneg | tr |
  ph 2.0 f* 1.0 f- | up |
  shape 0.5 f< sn
   shape 1.5 f< tr
    shape 2.5 f< up
     shape 3.5 f< up fneg
      shape 4.5 f<  ph 0.5 f< 1.0 -1.0 select  sh
  select select select select select | v |
  uni 0.5 f>  v 1.0 f+ 0.5 f*  v  select
;

( s -- v : one matrix source by its index. )
dsp: cn-src | state:ConcoctionState s e2 e3 l1 l2 -- v |
  s 0.5 f< 0.0
   s 1.5 f< e2
    s 2.5 f< e3
     s 3.5 f< l1
      s 4.5 f< l2
       s 5.5 f< state.velo
        s 6.5 f< state.note
         s 7.5 f< state.press
          s 8.5 f< state.slide
           state.rnd
  select select select select select select select select select
;

( cur target first -- : set a ramp toward target over the period. )
dsp: cn-ramp | r target first -- |
  r f@64 | cur |
  first 0.5 f>  target  cur  select | from |
  from r f!64
  first 0.5 f>  0.0  target from f- CN-CP f/  select  r 8 ptr+ f!64
;

dsp: k-concoction-control | ctx:Ctx state:ConcoctionState params:ConcoctionParams |
  state.e2& params.e2c& env-d-step | e2 |
  state.e3& params.e3c& env-d-step | e3 |
  ( LFOs; S&H takes a new value on each wrap )
  state.l1-ph params.l1-inc params.l1-mode cn-lfo-adv | p1 w1 |
  p1 -> state.l1-ph
  state cn-rand | r1 |
  w1 0.5 f>  r1 2.0 f* 1.0 f-  state.l1-sh  select -> state.l1-sh
  state.l2-ph params.l2-inc params.l2-mode cn-lfo-adv | p2 w2 |
  p2 -> state.l2-ph
  state cn-rand | r2 |
  w2 0.5 f>  r2 2.0 f* 1.0 f-  state.l2-sh  select -> state.l2-sh
  p1 state.l1-sh params.l1-shape params.l1-uni cn-lfo-val | l1 |
  p2 state.l2-sh params.l2-shape params.l2-uni cn-lfo-val | l2 |
  l1 -> state.l1-v
  l2 -> state.l2-v
  ( pitch envelope, glide )
  state.pe params.p-coef f* | pe |
  pe -> state.pe
  state.gl params.g-coef f* | gl |
  gl -> state.gl
  ( the matrix: each slot's AMT x source, summed by destination )
  0.0 16 [ | j |  0.0 state.macc& j f!i  j 1.0 f+ ] times drop
  0.0 8 [ | i |
    state  params.m-src& i f@i  e2 e3 l1 l2  cn-src  params.m-amt& i f@i f* | mv |
    params.m-dst& i f@i | dst |
    1.0 15 [ | j |
      state.macc& j f@i  dst j f= mv 0.0 select  f+  state.macc& j f!i
      j 1.0 f+ ] times drop
    i 1.0 f+ ] times drop
  state.macc& 1.0 f@i  state.macc& 2.0 f@i  state.macc& 3.0 f@i  state.macc& 4.0 f@i
  | dapos dbpos daw dbw |
  state.macc& 5.0 f@i  state.macc& 6.0 f@i  state.macc& 7.0 f@i
  | dapit dbpit dpit |
  state.macc& 8.0 f@i  state.macc& 9.0 f@i  state.macc& 10.0 f@i  state.macc& 11.0 f@i
  | dalv dblv dslv dnlv |
  state.macc& 12.0 f@i  state.macc& 13.0 f@i  state.macc& 14.0 f@i  state.macc& 15.0 f@i
  | dcut dres ddrv damp |
  state.first | first |
  ( pitch, in octaves: the oscillator's tuning, the matrix, the pitch
    envelope, glide )
  pe params.p-amt f* 12.0 f/ | po |
  dpit 12.0 f* 12.0 f/  gl f+ | glob |
  state.base-inc | bi |
  params.a-oct  params.a-semi 12.0 f/ f+  params.a-fine 1200.0 f/ f+  dapit f+  po f+ glob f+ exp2 bi f*
    state.a-inc& swap first cn-ramp
  params.b-oct  params.b-semi 12.0 f/ f+  params.b-fine 1200.0 f/ f+  dbpit f+  po f+ glob f+ exp2 bi f*
    state.b-inc& swap first cn-ramp
  params.sub-oct  params.p-dest 0.5 f< po 0.0 select f+  glob f+ exp2 bi f*
    state.s-inc& swap first cn-ramp
  state.a-pos& params.a-pos dapos f+ 0.0 1.0 fclamp first cn-ramp
  state.b-pos& params.b-pos dbpos f+ 0.0 1.0 fclamp first cn-ramp
  state.a-w& params.a-wamt daw f+ 0.0 1.0 fclamp first cn-ramp
  state.b-w& params.b-wamt dbw f+ 0.0 1.0 fclamp first cn-ramp
  state.a-lv& params.a-level dalv f+ 0.0 1.0 fclamp first cn-ramp
  state.b-lv& params.b-level dblv f+ 0.0 1.0 fclamp first cn-ramp
  state.s-lv& params.sub-level dslv f+ 0.0 1.0 fclamp first cn-ramp
  state.n-lv& params.n-level dnlv f+ 0.0 1.0 fclamp first cn-ramp
  ( the filter: cutoff in octaves from FILTER ENV, the matrix, KEY )
  e2 params.f-env f* 8.0 f*  dcut 8.0 f* f+  state.kt params.f-key f* f+
    exp2 params.f-cut f* | fc |
  fc -> state.cut-hz
  fc ctx.sr svf-g | g |
  state.g& g first cn-ramp
  params.f-res dres f+ 0.0 1.0 fclamp | rv |
  rv -> state.res-v
  rv 4.0 f* | k |
  state.k& k first cn-ramp
  ( drive: up to +24 dB into the ladder, about half of it taken back )
  params.f-drive ddrv f+ 0.0 1.0 fclamp | dr |
  dr -> state.drv-v
  dr dr f* 15.0 f* 1.0 f+ | dg |
  state.dg& dg first cn-ramp
  dg log2 -0.5 f* exp2  1.0 k params.f-comp f* f+ f* | dp |
  state.dp& dp first cn-ramp
  ( the amp: velocity, LEVEL, the matrix's AMP )
  1.0 params.vel f-  params.vel state.velo f* f+ | vg |
  1.0 damp f+ 0.0 fmax  params.level f* | lv |
  lv 1.0 fmin -> state.amp-v
  lv vg f* CN-MAKEUP f* | amp |
  state.amp& amp first cn-ramp
  0.0 -> state.first
;

( --- sample rate ---------------------------------------------------- )

( r -- v : step a ramp one sample. )
dsp: cn-step | r -- v |
  r f@64  r 8 ptr+ f@64  f+ | v |
  v r f!64
  v
;

( p mode w fm -- q scale : an oscillator's warp: the phase to read the
  table at, and how much faster than the phase it moves at its
  steepest [the mip level follows it]. )
dsp: cn-warp | p mode w fm -- q scale |
  1.0 w 7.0 f* f+ | ks |
  1.0  1.0 w 0.97 f* f-  f/ | kp |
  1.0 w 15.0 f* f+ | c |
  p ks f* ffrac | qs |
  p kp f* | pp |
  pp 1.0 f<  pp  0.0  select | qp |
  p c f*  1.0  c 1.0 f- p f*  f+  f/ | qb |
  p w 3.0 f* fm f* f+ ffrac | qf |
  mode 0.5 f< | m0 |  mode 1.5 f< | m1 |  mode 2.5 f< | m2 |  mode 3.5 f< | m3 |
  m0 p  m1 qs  m2 qp  m3 qb  qf  select select select select
  m0 1.0  m1 ks  m2 kp  m3 c  1.0  select select select select
;

( ph inc -- y : the sub oscillator, by SUB SHAPE. )
dsp: cn-sub | params:ConcoctionParams ph inc -- y |
  params.sub-shape | sh |
  sh 0.5 f<  ph sin2pi
   sh 1.5 f<  ph 0.25 f+ ffrac tri-raw
    sh 2.5 f<  ph inc saw-falling-polyblep
     ph inc 0.5 pulse-polyblep
  select select select
;

dsp: k-concoction-voice | io:Io ctx state:ConcoctionState params:ConcoctionParams -- |
  state.a-inc& cn-step | ai |
  state.b-inc& cn-step | bi |
  state.s-inc& cn-step | si |
  state.a-pos& cn-step | apos |
  state.b-pos& cn-step | bpos |
  state.a-w& cn-step | aw |
  state.b-w& cn-step | bw |
  state.a-lv& cn-step | alv |
  state.b-lv& cn-step | blv |
  state.s-lv& cn-step | slv |
  state.n-lv& cn-step | nlv |
  state.g& cn-step | g |
  state.k& cn-step | k |
  state.dg& cn-step | dg |
  state.dp& cn-step | dp |
  state.amp& cn-step | amp |
  ( sub )
  params.sub-on 0.5 f<
    [ 0.0 ]
    [ state.s-ph si phase-advance01 | sp |
      sp -> state.s-ph
      params sp si cn-sub ]
  ifte | sub |
  ( B, FM'd by the sub )
  params.b-on 0.5 f<
    [ 0.0 ]
    [ state.b-ph bi phase-advance01 | bp |
      bp -> state.b-ph
      bp params.b-warp bw sub cn-warp | bq bk |
      bi params.mip-k f* bk f* | bx |
      params.b-table CN-USER f>
        [ params.wt-b& p@64  params.b-fb params.b-fn bpos bq bx  wt-read ]
        [ params.bank& p@64  params.b-fb params.b-fn bpos bq bx  wt-read ]
      ifte ]
  ifte | osb |
  ( A, FM'd by B )
  state.a-ph ai phase-advance01 | ap |
  ap -> state.a-ph
  ap params.a-warp aw osb cn-warp | aq ak |
  ai params.mip-k f* ak f* | ax |
  params.a-table CN-USER f>
    [ params.wt-a& p@64  params.a-fb params.a-fn apos aq ax  wt-read ]
    [ params.bank& p@64  params.a-fb params.a-fn apos aq ax  wt-read ]
  ifte | osa |
  ( noise: a float LCG, leaned dark or bright off one one-pole )
  state.rng 1103515245.0 f* 0.31337 f+ ffrac | rng |
  rng -> state.rng
  rng 2.0 f* 1.0 f- | wn |
  state.nlp  wn state.nlp f- params.n-a f*  f+ | nl |
  nl -> state.nlp
  params.n-color | col |
  col 0.0 f<  wn nl wn f- col fneg f* f+   wn nl col f* f-  select | ns |
  ( the mix, split between the filter and the direct path )
  osa alv f* | a |
  osb blv f* | b |
  sub slv f* | s |
  ns nlv f* | n |
  a params.a-filt f*  b params.b-filt f* f+  s params.sub-filt f* f+  n params.n-filt f* f+ | fin |
  a b f+ s f+ n f+ fin f- | dir |
  params.f-mode 0.5 f<
    [ fin ]
    [ state.lad& fin dg f* g k 0.15 ladder4-taps | x0 y1 y2 y3 y4 |
      x0 params.fc0 f*  y1 params.fc1 f* f+  y2 params.fc2 f* f+  y3 params.fc3 f* f+  y4 params.fc4 f* f+
      dp f* ]
  ifte | fout |
  state.e1& params.e1c& env-d-step | env |
  fout dir f+ env f* amp f* | v |
  ( a warp or a sync leaves DC in the cycle; 5 Hz takes it out )
  state.dc-y v f+ state.dc-x f-  params.dc-a f* | o |
  v -> state.dc-x
  o -> state.dc-y
  io.out-l o f+ -> io.out-l
;
