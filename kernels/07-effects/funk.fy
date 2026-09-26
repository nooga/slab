( funk.fy - FUNK OVERLOAD: a touch-responsive envelope auto-wah with a
  stutter gate, all driven by one macro knob.

  One envelope follower on the input drives everything.  The macro maps
  in block-prepare to a staged progression:

    funk 0.0  clean resonant lowpass parked at FREQ
    funk 0.3  auto-wah - the envelope opens the filter on each transient
    funk 0.6  + pre-filter drive saturates into the wah
    funk 0.9  + the envelope hard-gates -> rhythmic stutter
    funk 1.0  fast envelope, gate slamming between every hit

  The stutter is gated by the SAME envelope that drives the wah, and the
  envelope's release shortens as the macro climbs - so the gate snaps
  shut in the gaps between transients and the chop follows the player's
  dynamics, not a clock.  Dig in -> it opens; lay back -> it stutters.

  Per-channel effect [src/machines/fy_raw_machine.zig runs L and R
  through separate state regions].  Probe case: funk-render. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../05-drums/decay.fy"
include "../04-filters/coeffs.fy"   ( svf-g, svf-damping, svf-dc-coeff )
include "../04-filters/tpt_svf.fy"
include "../02-shapers/rational.fy"   ( tanh-rational )

ustruct: FunkState
  f64 env        ( envelope follower )
  f64 ic1        ( lpf4 integrator states )
  f64 ic2
  f64 gate-gain  ( smoothed gate )
;

ustruct: FunkParams
  ( user-facing )
  f64 funk       ( the macro, 0..1 )
  f64 freq       ( base filter cutoff Hz )
  f64 speed      ( envelope response time, s )
  f64 mix        ( dry/wet )
  ( derived - filled by funk-block-prepare )
  f64 osr        ( 4 * sample-rate, for svf-g )
  f64 base-hz
  f64 sweep-hz   ( env -> cutoff depth )
  f64 damp       ( filter damping, lower = more resonant )
  f64 drive      ( pre-filter gain )
  f64 wet-gain   ( drive loudness compensation )
  f64 gate-thresh
  f64 atk-c      ( env attack retention coeff )
  f64 rel-c      ( env release retention coeff )
  f64 gate-c     ( gate smoothing retention coeff )
;

( ctx state params -- : map the macro to the whole effect.  Every
  derived value is bound or written once and reads use the live funk
  knob. )
dsp: funk-block-prepare
  | ctx:Ctx state params:FunkParams |
  ctx.sr | sr |
  4.0 sr f* -> params.osr
  params.freq -> params.base-hz
  params.funk | f |
  f 5000.0 f* -> params.sweep-hz
  1.2  f 1.08 f* f-  0.1 2.0 fclamp -> params.damp
  1.0  f dup f* 9.0 f*  f+ -> params.drive
  1.0  f 0.55 f* f-  -> params.wet-gain
  f 0.6 f-  2.5 f*  0.0 1.0 fclamp | gz |
  gz 0.22 f* -> params.gate-thresh
  0.002 sr decay-exp-coeff -> params.atk-c
  0.002 sr decay-exp-coeff -> params.gate-c
  params.speed  1.0 gz 0.75 f* f-  f*  0.005 2.0 fclamp  sr decay-exp-coeff
  -> params.rel-c
;

( Envelope follower on the rectified input. )
dsp: fo-env | state:FunkState params:FunkParams x -- e |
  x fabs | tgt |
  state.env | e0 |
  e0 tgt  params.atk-c  params.rel-c  fsel-lt | c |
  tgt  e0 tgt f-  c f*  f+ | e |
  e -> state.env
  e
;

( Envelope-swept cutoff -> filter g at the oversampled rate, and the
  driven filter input: drive into tanh, then the filter's own unity input
  clip.  The lowpass itself runs in four fo-sub substeps [4x oversampled]. )
dsp: fo-filt | params:FunkParams e x -- g fx |
  e params.sweep-hz f*
  params.base-hz f+
  params.osr svf-g
  x params.drive f* tanh-rational tanh-rational
;

( One of four saturating lowpass substeps per sample [input held]. )
dsp: fo-sub | state:FunkState params:FunkParams x g -- y |
  state.ic1& state.ic2&  x g params.damp  tpt-svf-lp-sat-step
;

( Envelope gate on the wet path, dry/wet mix. )
dsp: fo-out | out state:FunkState params:FunkParams x e wet -- |
  params.gate-thresh e  1.0 0.0  fsel-lt | gt |
  state.gate-gain | gg0 |
  gt  gg0 gt f-  params.gate-c f*  f+ | gg |
  gg -> state.gate-gain
  wet gg f* params.wet-gain f* | w |
  x  1.0 params.mix f-  f*
  w params.mix f*  f+
  out f!64
;

( io ctx state params -- : one FUNK OVERLOAD tick.  The last substep's
  output goes through the output clip, tanh[1.8*lp]. )
dsp: k-funk-tick | io:Io ctx state params -- |
  io.in-l | x |
  state params x fo-env | e |
  params e x fo-filt | g fx |
  state params fx g fo-sub drop
  state params fx g fo-sub drop
  state params fx g fo-sub drop
  state params fx g fo-sub  1.8 f* tanh-rational | wet |
  io state params x e wet fo-out
;
