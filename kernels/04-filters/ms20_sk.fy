( ms20_sk.fy - the MS-20's own filters: K35 and OTA, low-pass and high-pass.

  Stinchcombe's study of the MS-10/MS-20 filters [timstinchcombe.co.uk/
  synth/MS20_study.pdf] gives both generations the same linear response,

    LP = 1 / [s^2 + [a - k] s + 1]      HP = s^2 / [same]

  with a = 2 1/3 for the Korg35 Sallen-Key [early units] and a = 2 for the
  later LM13600 OTA pair, k the resonance loop gain.  The DC gain stays 1
  whatever the resonance and the poles stay on the unit circle: PEAK
  sharpens the corner without moving it or thinning the bass.  That is the
  difference from the HOT/WET pair [ms20_lpf.fy], whose ladder-style
  negative feedback gives the 303 squelch.

  Here: a TPT state-variable core with base damping a, and the resonance
  as positive band-pass feedback k bp into the input, one zero-delay step
  per substep.  The feedback is predicted linearly, then clipped:

    v      = x - [a + g] s1 - s2
    bp-lin = [g h v + s1] / [1 - g h k]        h = 1 / [1 + a g + g^2]
    fb     = vd tanh[k bp-lin / vd]            the feedback diodes
    u      = vf [tanh[[drive x + fb] / vf + fo] - tanh[fo]]
    hp     = [u - [a + g] s1 - s2] h ...       then bp, lp as usual

  Where the two generations differ [Stinchcombe §4, §5]:
  - K35: the diodes sit in the forward amplifier [x58 gain, one diode
    drop], so a loud signal distorts at every frequency, and the signal
    tilts the Korg35's transistor currents, making the resonance stronger
    on one half-wave.  Small vf, a fo offset.
  - OTA: three diodes per side in the feedback amplifier [x4], so only the
    corner distorts and the response is symmetric.  vf large [the OTA
    input pair, soft], fo 0, and the feedback diodes vd set the peak.

  k past a self-oscillates; vd bounds it.  Run at 4x [the voice's
  up4/dec4].  Coefficients come once per block from ms20-sk-set; g per
  sample from the cutoff. )

include "../00-primitives/math.fy"   ( tanh-fast )

ustruct: Ms20Sk
  f64 s1
  f64 s2
;

ustruct: Ms20SkProfile
  f64 a        ( base damping: 2 OTA, 7/3 K35 )
  f64 k-lp     ( LPF loop gain, from PEAK )
  f64 k-hp     ( HPF loop gain, from its PEAK )
  f64 drive    ( input gain )
  f64 vf       ( forward clip level )
  f64 fo       ( forward clip offset: K35 asymmetry )
  f64 fto      ( tanh[fo], subtracted so 0 in is 0 out )
  f64 vd       ( feedback diode level )
  f64 g-hp     ( HPF g at the 4x rate )
  f64 out-g    ( output gain, to the HOT mode's level )
;

( p a -- k : PEAK [0..1 of its travel] to loop gain.  A linear pot would
  give k = a p / 0.9: Q = 1 / [a - k] stays near 1 until the last third,
  the 'resonance invisible until the top' of the September OTA probe.  The
  taper here is a design choice, not a measured pot: k = a [1 - u^2] with
  u = 1 - p / 0.9, so the peak is +6 dB by noon and climbs steadily; past
  90%, where u < 0, k = a [1 - u] keeps rising linearly into
  self-oscillation, to 1.11 a at the end. )
dsp: ms20-sk-k | p a -- k |
  1.0  p 0.0 1.0 fclamp 0.9 f/  f- | u |
  1.0  u  u 0.0 1.0 u fsel-lt  f*  f-  a f*
;

( pr drive res hres mode hpf-hz osr -- : one block's constants.  mode 2
  K35, 3 OTA; res and hres are the PEAK knobs, 0..2. )
dsp: ms20-sk-set | pr:Ms20SkProfile drive res hres mode hz osr -- |
  mode 2.5  2.3333333333333335 2.0  fsel-lt | a |
  a -> pr.a
  res 0.5 f*  a ms20-sk-k -> pr.k-lp
  hres 0.5 f*  a ms20-sk-k -> pr.k-hp
  mode 2.5  0.9 0.6  fsel-lt  drive f* -> pr.drive
  mode 2.5  0.55 1.6  fsel-lt -> pr.vf
  mode 2.5  0.12 0.0  fsel-lt | fo |
  fo -> pr.fo
  fo tanh-fast -> pr.fto
  mode 2.5  0.45 0.5  fsel-lt -> pr.vd
  hz 20.0 15000.0 fclamp 3.141592653589793 f* osr f/ tan-warp -> pr.g-hp
  mode 2.5  1.7 1.75  fsel-lt -> pr.out-g
;

( f pr x g k dr -- lp hp : one zero-delay substep of the core; dr is the
  input gain [DRIVE for the first filter of the pair, 1 for the second]. )
dsp: ms20-sk-core | f:Ms20Sk pr:Ms20SkProfile x g k dr -- lp hp |
  x dr f* | xd |
  f.s1 | s1 |
  f.s2 | s2 |
  pr.a | a |
  1.0  1.0 a g f* f+ g g f* f+  f/ | h |
  a g f+ s1 f* s2 f+ | lin |
  g h f* | gh |
  gh  xd lin f-  f*  s1 f+   1.0 gh k f* f-  f/ | bpl |
  k bpl f*  pr.vd f/  tanh-fast  pr.vd f* | fb |
  xd fb f+  pr.vf f/  pr.fo f+  tanh-fast  pr.fto f-  pr.vf f* | u |
  u lin f-  h f* | hp |
  g hp f* | ghp |
  ghp s1 f+ | bp |
  g bp f* | gbp |
  gbp s2 f+ | lp |
  ghp bp f+ -> f.s1
  gbp lp f+ -> f.s2
  lp hp
;

( hf lf pr x g -- y : one 4x substep of the MS-20's series pair, HPF into
  LPF; g is the LPF's. )
dsp: ms20-sk-step | hf:Ms20Sk lf:Ms20Sk pr:Ms20SkProfile x g -- y |
  hf pr x pr.g-hp pr.k-hp pr.drive ms20-sk-core | hlp hhp |
  lf pr hhp g pr.k-lp 1.0 ms20-sk-core | llp lhp |
  llp pr.out-g f*
;
