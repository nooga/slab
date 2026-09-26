( saturator.fy - gentle multi-mode coloring saturator.

  A warming box, not a fuzz: drive into a soft rational waveshaper, mode
  picks the curve's character, a DC blocker cleans the asymmetric modes,
  a one-pole tone control tames brightness, and MIX blends back to dry
  for parallel "glue" saturation.  The DAW and rig share this kernel.

  The shaper is the rational soft-clip  y = s*(a + s^2)/(a + b*s^2),
  clamped to [-1,1] (same family as the mixer/drum rational-tanh).  a and
  b set the knee; a small pre-bias makes the curve asymmetric, which adds
  even harmonics (the "tube"/"transformer" warmth).  All four constants
  are derived per block from the MODE switch + DRIVE, so the per-sample
  path is branch-free:

    Tube        a=27 b=9  bias=0.18   asymmetric, even harmonics, round
    Tape        a=40 b=6  bias=0.0    very soft symmetric, subtle
    Transformer a=27 b=9  bias=0.10   mild asymmetry, fuller lows
    Transistor  a=18 b=14 bias=0.0    harder symmetric, more bite

  Per sample:
    s     = clamp(in*drive + bias, -4, 4)
    shf   = clamp(s*(a+s^2)/(a+b*s^2), -1, 1) - biasComp   (biasComp removes rest DC)
    dc    = shf - x1 + R*y1   (one-pole DC blocker, R=0.9995)
    tone  = lp + g*(dc - lp)  (one-pole lowpass; g from TONE)
    out   = tone*outGain*mix + dry*(1-mix)

  Probe case: sat-render - drive sweep, finite + monotonic-ish THD. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/pow2.fy"

ustruct: SatState
  f64 dc-x1   ( DC blocker previous input )
  f64 dc-y1   ( DC blocker previous output )
  f64 lp      ( tone lowpass state )
;

ustruct: SatParams
  ( user-facing )
  f64 drive-db   ( 0..36 )
  f64 mode       ( 0..3 switch )
  f64 tone-hz    ( tone lowpass cutoff )
  f64 mix        ( 0..1 )
  f64 out-db     ( -24..24 makeup )
  ( derived - filled by sat-block-prepare )
  f64 drive-lin
  f64 out-lin
  f64 tone-g
  f64 a
  f64 b
  f64 bias
  f64 bias-comp
;

( ctx state params -- : derive drive/out gains, tone coefficient, and the
  mode-dependent shaper constants.  a/b/bias are kept as locals so bias-comp
  can use them (a freshly stored param reads back stale within the word). )
dsp: sat-block-prepare
  | ctx:Ctx state params:SatParams |
  ctx.sr | sr |
  params.drive-db 0.16609640474436813 f* exp2-approx
  -> params.drive-lin
  params.out-db 0.16609640474436813 f* exp2-approx
  -> params.out-lin
  params.tone-hz 6.283185307179586 f* sr f/ 0.0 1.0 fclamp
  -> params.tone-g
  params.mode | mode |
  mode 0.5 27.0  mode 1.5 40.0  mode 2.5 27.0 18.0  fsel-lt fsel-lt fsel-lt | a |
  mode 0.5 9.0   mode 1.5 6.0   mode 2.5 9.0  14.0  fsel-lt fsel-lt fsel-lt | b |
  mode 0.5 0.18  mode 1.5 0.0   mode 2.5 0.10 0.0   fsel-lt fsel-lt fsel-lt | bias |
  a    -> params.a
  b    -> params.b
  bias -> params.bias
  bias bias f* | bb |
  bias a bb f+ f*  a b bb f* f+  f/
  -> params.bias-comp
  ( locals: params sr mode a b bias bb = 7 )
;

( io ctx state params -- : one saturator sample. )
dsp: k-sat-tick
  | out:Io ctx state:SatState params:SatParams |
  out.in-l | dry |
  dry params.drive-lin f*  params.bias f+  -4.0 4.0 fclamp | s |
  s s f* | s2 |
  s  params.a s2 f+  f*
  params.a  params.b s2 f* f+  f/
  -1.0 1.0 fclamp
  params.bias-comp f- | sh |
  ( DC blocker: dcy = sh - x1 + R*y1 )
  sh state.dc-x1 f-  0.9995 state.dc-y1 f* f+ | dcy |
  sh  -> state.dc-x1
  dcy -> state.dc-y1
  ( tone one-pole lowpass: lp += g*(dcy - lp) )
  state.lp  dcy state.lp f-  params.tone-g f*  f+ | toned |
  toned -> state.lp
  ( wet*mix + dry*(1-mix) )
  toned params.out-lin f*  params.mix f*
  dry  1.0 params.mix f-  f*  f+
  out f!64
  ( locals: out state params in dry s s2 sh dcy toned = 10 )
;
