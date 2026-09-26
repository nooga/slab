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
include "../02-shapers/tanh_table.fy"

ustruct: FunkState
  f64 env        ( envelope follower )
  f64 ic1        ( lpf4 integrator states )
  f64 ic2
  f64 gate-gain  ( smoothed gate )
  f64 wet        ( stage scratch )
  f64 fg         ( stage scratch: filter g for this sample's substeps )
  f64 fx         ( stage scratch: driven filter input, held over the substeps )
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
  derived value is bound or written once; reads use the live funk knob,
  never a just-stored derived param [deferred stores flush at word end]. )
dsp: funk-block-prepare
  | ctx state params |
  ctx Ctx.sr@ | sr |
  4.0 sr f* params FunkParams.osr-p f!64
  params FunkParams.freq@ params FunkParams.base-hz-p f!64
  params FunkParams.funk@ | f |
  f 5000.0 f* params FunkParams.sweep-hz-p f!64
  1.2  f 1.08 f* f-  0.1 2.0 fclamp params FunkParams.damp-p f!64
  1.0  f dup f* 9.0 f*  f+ params FunkParams.drive-p f!64
  1.0  f 0.55 f* f-  params FunkParams.wet-gain-p f!64
  f 0.6 f-  2.5 f*  0.0 1.0 fclamp | gz |
  gz 0.22 f* params FunkParams.gate-thresh-p f!64
  0.002 sr decay-exp-coeff params FunkParams.atk-c-p f!64
  0.002 sr decay-exp-coeff params FunkParams.gate-c-p f!64
  params FunkParams.speed@  1.0 gz 0.75 f* f-  f*  0.005 2.0 fclamp  sr decay-exp-coeff
  params FunkParams.rel-c-p f!64
  drop2 drop2 drop2
;

( state params in -- : envelope follower on the rectified input. )
dsp: fo-env
  | state params in |
  in Io.in-l@ | x |
  x 0.0  0.0 x f-  x  fsel-lt | tgt |
  state FunkState.env@ | e |
  e tgt  params FunkParams.atk-c@  params FunkParams.rel-c@  fsel-lt | c |
  tgt  e tgt f-  c f*  f+
  state FunkState.env-p f!64
  drop2 drop2 drop2 drop
;

( state params in -- : drive + envelope-swept cutoff for this sample; the
  lowpass itself runs in the four fo-sub substeps [4x oversampled]. )
dsp: fo-filt
  | state params in |
  state FunkState.env@ params FunkParams.sweep-hz@ f*
  params FunkParams.base-hz@ f+ | cutoff |
  cutoff params FunkParams.osr@ svf-g state FunkState.fg-p f!64
  ( drive into tanh, then the filter's own unity input clip )
  in Io.in-l@ params FunkParams.drive@ f* k-tanh-rational-shape-dsp2 k-tanh-rational-shape-dsp2
  state FunkState.fx-p f!64
  drop2 drop2
;

( state params -- : one of four saturating lowpass substeps per sample
  [input held]; the last one leaves its output in wet. )
dsp: fo-sub ( state params -- )
  | state params |
  state FunkState.ic1-p state FunkState.ic2-p
  state FunkState.fx@ state FunkState.fg@ params FunkParams.damp@
  tpt-svf-lp-sat-step
  state FunkState.wet-p f!64
  drop2
;

( state params -- : output clip after the substeps, tanh[1.8*lp]. )
dsp: fo-sat ( state params -- )
  | state params |
  state FunkState.wet@ 1.8 f* k-tanh-rational-shape-dsp2 state FunkState.wet-p f!64
  drop2
;

( out state params in -- : envelope gate on the wet path, dry/wet mix. )
dsp: fo-out
  | out state params in |
  state FunkState.env@ | e |
  params FunkParams.gate-thresh@ e  1.0 0.0  fsel-lt | gt |
  state FunkState.gate-gain@ | gg0 |
  gt  gg0 gt f-  params FunkParams.gate-c@ f*  f+ | gg |
  gg state FunkState.gate-gain-p f!64
  state FunkState.wet@ gg f* params FunkParams.wet-gain@ f* | wet |
  in Io.in-l@ | x |
  x  1.0 params FunkParams.mix@ f-  f*
  wet params FunkParams.mix@ f*  f+
  out f!64
  drop2 drop2 drop2 drop2 drop2
;

( io ctx state params -- : one FUNK OVERLOAD tick, staged. )
dsp: k-funk-tick
  | io ctx state params |
  state params io call: fo-env
  state params io call: fo-filt
  state params call: fo-sub
  state params call: fo-sub
  state params call: fo-sub
  state params call: fo-sub
  state params call: fo-sat
  io state params io call: fo-out
;
