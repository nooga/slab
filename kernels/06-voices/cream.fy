( cream.fy - Cream Mono: a Prodigy / Messenger style mono voice.

  Two VCOs and a third that is either a locked SUB or a free OSC, a mixer
  the player drives hot into a transistor ladder, filter and loudness
  contours, glide.  Oscillators, mixer and ladder run at 4x; dec4 brings
  the result down; envelopes, glide, drift and coefficients run once per
  sample.

    OSC 1 ------------------------------.
    OSC 2 [hard sync to OSC 1] ----------+-> mix + noise -> DRIVE
    OSC 3: SUB [square, 1 or 2 octaves   |     -> moog-step x4 -> dec4
           under OSC 1, phase-locked]    |     -> VCA -> DC block -> out
        or OSC [range, wave, detune] ----'

  AGE [0..1] is the analog layer: each oscillator wanders on its own slow
  drift [~6 cents RMS at 1], the cutoff wanders, and OSC 2/3 sit a few
  cents off their dials.  SYNC reset has no BLEP; at 4x the edge's
  aliases mostly land above the band dec4 removes.

  Legato: a note that arrives while one is held [ctx.legato] glides
  without restarting the contours, the way a single-trigger mono plays. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../00-primitives/oversample.fy"
include "../01-oscillators/primitives/phase.fy"
include "../01-oscillators/primitives/blep.fy"
include "../01-oscillators/primitives/shapes.fy"
include "../03-envelopes/primitives/segments.fy"
include "../04-filters/moog_ladder.fy"
include "../08-analog/analog.fy"

ustruct: CreamState
  f64 ph1  f64 ph2  f64 ph3
  f64 sub-count    ( OSC 1 cycles counted for the SUB, 0 .. 1/sub-oct - 1 )
  f64 age
  f64 gate-time
  f64 vel
  f64 oct          ( current pitch, log2 Hz - glides toward target-oct )
  f64 target-oct
  f64 noise-rng
  f64 dc-x  f64 dc-y
  MoogLadder lad
  Dec4 dec
  Drift dr1  Drift dr2  Drift dr3  Drift drc
;

ustruct: CreamParams
  ( oscillators )
  f64 range1  f64 range2  f64 range3      ( octave multiplier 0.25 .. 4 - switches )
  f64 wave1   f64 wave2   f64 wave3       ( 0 tri 1 saw 2 square 3 wide 4 narrow )
  f64 detune2 f64 detune3                 ( semitones, -7 .. 7 )
  f64 sync2                               ( OSC 2 hard sync to OSC 1 - switch 0/1 )
  f64 env-osc2                            ( filter contour -> OSC 2 pitch, semitones: the sync sweep )
  f64 osc3-mode                           ( 0 SUB 1 OSC - switch )
  f64 sub-oct                             ( SUB frequency: 0.5 or 0.25 of OSC 1 )
  ( mixer )
  f64 lvl1 f64 lvl2 f64 lvl3 f64 noise
  f64 drive                               ( 0..1: into the ladder, 0.5x .. 8x )
  ( filter )
  f64 cutoff                              ( Hz )
  f64 emphasis                            ( 0..1.1; 1 sustains a sine )
  f64 contour                             ( filter EG, octaves )
  f64 kbd                                 ( keyboard tracking 0..1 )
  f64 f-atk f64 f-dec f64 f-sus f64 f-rel
  ( loudness )
  f64 a-atk f64 a-dec f64 a-sus f64 a-rel
  f64 glide                               ( seconds to cover most of an interval )
  f64 age-amt                             ( AGE 0..1 )
  f64 level
  ( derived by cream-block-prepare )
  f64 inv-sr
  f64 inv-osr
  f64 osr
  f64 glide-c
  f64 ratio2 f64 ratio3                   ( detune + AGE spread, as ratios )
  f64 drive-g
  f64 drift-c
  f64 cut-drift-c
;

( ctx state params -- )
dsp: cream-block-prepare | ctx:Ctx state params:CreamParams -- |
  ctx.inv-sr -> params.inv-sr
  ctx.sr 4.0 f* | osr |
  osr -> params.osr
  1.0 osr f/ -> params.inv-osr
  ( one-pole in the pitch domain: ~3 time constants over GLIDE )
  params.glide 0.001  1.0
    1.0  -3.0  params.glide ctx.sr f* f/  exp  f-
  fsel-lt -> params.glide-c
  ( AGE puts osc 2 and 3 a few cents off: spread is fixed per part )
  params.detune2  0.0 2.0 spread params.age-amt f* 0.04 f*  f+  0.08333333333333333 f* exp2
    -> params.ratio2
  params.detune3  0.0 3.0 spread params.age-amt f* 0.04 f*  f+  0.08333333333333333 f* exp2
    -> params.ratio3
  ( DRIVE 0..1 -> 0.5x .. 8x, equal steps in dB )
  params.drive 4.0 f* 1.0 f- exp2 -> params.drive-g
  0.35 ctx.inv-sr drift-coef -> params.drift-c
  0.15 ctx.inv-sr drift-coef -> params.cut-drift-c
;

( ctx state params -- : legato notes only move the pitch target.  The
  very first note starts on pitch instead of gliding up from nothing. )
dsp: cream-note-on | ctx:Ctx state:CreamState params -- |
  ctx.hz 1.0 fmax log2 | o |
  o -> state.target-oct
  state.oct 1.0  o  state.oct  fsel-lt -> state.oct
  ( a fresh voice seeds its drift generators apart from each other )
  state.dr1& 1.0 drift-seed-once
  state.dr2& 2.0 drift-seed-once
  state.dr3& 3.0 drift-seed-once
  state.drc& 4.0 drift-seed-once
  ctx.legato 0.5  0.0 state.age  fsel-lt -> state.age
  ctx.legato 0.5  ctx.vel state.vel  fsel-lt -> state.vel
  1000000000.0 -> state.gate-time
;

( ctx state params -- )
dsp: cream-note-off | ctx state:CreamState params -- |
  state.age -> state.gate-time
;

( wave phase dt -- y : 0 tri 1 saw 2 square 3 wide 4 narrow pulse. )
dsp: cr-wave | w ph dt -- y |
  w 2.5  0.5  w 3.5  0.7  0.88  fsel-lt  fsel-lt | width |
  w 0.5
    ph tri-raw
    w 1.5  ph dt saw-polyblep  ph dt width pulse-polyblep  fsel-lt
  fsel-lt
;

( one 4x substep: OSC 1 leads; OSC 2 restarts when OSC 1 wraps if SYNC
  is on; OSC 3 as SUB restarts on every 1/sub-oct-th wrap of OSC 1, i.e.
  it follows OSC 1's phase exactly. )
dsp: cr-sub | state:CreamState params:CreamParams dt1 dt2 dt3 nz g k -- y |
  state.ph1 dt1 f+ | q1 |
  q1 wrap01 | p1 |
  p1 -> state.ph1
  1.0 q1 f<= | wrapped |
  ( OSC 2: free, or restarted at OSC 1's wrap, carried by the overshoot )
  state.ph2 dt2 phase-advance01 | p2free |
  params.sync2 0.5 f>  wrapped and
    p1 dt2 f* dt1 f/ ffrac  p2free  select | p2 |
  p2 -> state.ph2
  ( OSC 3: SUB counts OSC 1's cycles modulo 1/sub-oct and reads its
    phase off that count, so it can never drift from OSC 1; OSC free-runs )
  1.0 params.sub-oct f/ | n |
  state.sub-count | c |
  c 1.0 f+ | cn |
  wrapped  cn n f>= 0.0 cn select  c  select | c2 |
  c2 -> state.sub-count
  state.ph3 dt3 phase-advance01 | p3free |
  params.osc3-mode 0.5 f<  c2 p1 f+ params.sub-oct f*  p3free  select | p3 |
  p3 -> state.ph3
  params.wave1 p1 dt1 cr-wave params.lvl1 f*
  params.wave2 p2 dt2 cr-wave params.lvl2 f* f+
  params.osc3-mode 0.5  p3 dt3 0.5 pulse-polyblep  params.wave3 p3 dt3 cr-wave  fsel-lt
    params.lvl3 f* f+
  nz params.noise f* f+
  0.5 f* params.drive-g f* | x |
  state.lad& x g k moog-step
;

( io ctx state params -- : one output sample. )
dsp: k-cream-voice | io ctx state:CreamState params:CreamParams -- |
  state.age params.inv-sr f+ | age |
  age -> state.age
  ( glide in octaves )
  state.oct  state.target-oct state.oct f-  params.glide-c f*  f+ | oct |
  oct -> state.oct
  oct exp2 | hz |
  ( drift: cents -> ratio, small enough for 1 + x ln2 )
  params.age-amt 0.0035 f* | dscale |
  state.dr1& params.drift-c drift-step dscale f* 1.0 f+ | d1 |
  state.dr2& params.drift-c drift-step dscale f* 1.0 f+ | d2 |
  state.dr3& params.drift-c drift-step dscale f* 1.0 f+ | d3 |
  ( contours )
  age params.f-atk params.f-dec params.f-sus state.gate-time params.f-rel adsr-cap | fenv |
  age params.a-atk params.a-dec params.a-sus state.gate-time params.a-rel adsr-cap | aenv |
  hz params.inv-osr f* | base |
  base params.range1 f* d1 f* | dt1 |
  base params.range2 f* params.ratio2 f* d2 f*
    fenv params.env-osc2 f* 0.08333333333333333 f* exp2 f* | dt2 |
  params.osc3-mode 0.5  dt1 params.sub-oct f*  base params.range3 f* params.ratio3 f* d3 f*  fsel-lt | dt3 |
  ( cutoff in octaves: contour, keyboard from middle C, drift )
  fenv params.contour f*
  oct 8.031359713524661 f-  params.kbd f*  f+
  state.drc& params.cut-drift-c drift-step  params.age-amt 0.07 f* f*  f+
  exp2 params.cutoff f*
  params.osr params.emphasis moog-coeffs | g k |
  ( one noise sample, held across the substeps )
  state.noise-rng 1103515245.0 f* 0.31337 f+ ffrac | r |
  r -> state.noise-rng
  r 2.0 f* 1.0 f- | nz |
  state.dec&
    state params dt1 dt2 dt3 nz g k cr-sub
    state params dt1 dt2 dt3 nz g k cr-sub
    state params dt1 dt2 dt3 nz g k cr-sub
    state params dt1 dt2 dt3 nz g k cr-sub
  dec4 | y |
  ( VCA, velocity a gentle 6 dB, then a ~10 Hz DC block )
  y aenv f*  0.5 state.vel 0.5 f* f+ f*  params.level f*  2.0 f* | x |
  x state.dc-x f-  state.dc-y 0.9987 f*  f+ | o |
  x -> state.dc-x
  o -> state.dc-y
  io f@64 o f+ io f!64
;
