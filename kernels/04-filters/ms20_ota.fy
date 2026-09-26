( ms20_ota.fy - MS-20 [OTA] lowpass, written in fy.

  Topology, as on the MS-20 mk2 board: OTA -> op-amp -> OTA -> op-amp, with
  the resonance returned through an op-amp whose feedback holds a diode
  clipper.  Behaviourally, per substep:

    e   = drive*x + fb                     input + resonance return
    y1 += g * tanh[e - y1]                 OTA1 integrator, op-amp buffer
    y2 += g * tanh[y1 - y2]                OTA2 integrator, op-amp buffer
    fb  = k * diode[y1 - y2]               resonance op-amp, diode-clipped

  Linear check: each stage is G = 1/[1 + s/wc] and the loop gain is
  k*G*[1-G].  At w = wc, G*[1-G] = 1/2 exactly, so the resonant peak sits
  ON the cutoff and self-oscillation starts at k = 2; at DC G*[1-G] = 0, so
  resonance costs no bass.  The diodes clip the resonance signal, not the
  audio path - the aggressive, screaming character - and hold the
  self-oscillation at a stable level.

  Explicit [Euler] OTA integrators want oversampling: the voice runs this
  step 4x per sample and averages. g = 1 - e^[-2 pi fc/fs_os]
  [ms20-ota-g].  Output is y2.  State is caller-owned [Ms20OtaState]. )

include "../02-shapers/tanh_table.fy"   ( k-tanh-rational-shape-dsp2 )
include "../00-primitives/pow2.fy"       ( exp2-approx )

ustruct: Ms20OtaState
  f64 y1   ( OTA1 / op-amp 1 output )
  f64 y2   ( OTA2 / op-amp 2 output = lowpass out )
  f64 fb   ( resonance return, one substep behind )
;

( v -- diode[v] : antiparallel diode pair as a soft clip, unity slope at 0,
  bounded at +-1/1.6. )
dsp: ms20-diode | v -- d |
  v 1.6 f* k-tanh-rational-shape-dsp2 0.625 f*
;

( fc os-inv -- g : explicit one-pole coefficient 1 - e^[-2 pi fc / fs_os],
  os-inv = 1/fs_os.  2 pi / ln 2 = 9.0647202. )
dsp: ms20-ota-g | fc os-inv -- g |
  1.0  fc 20.0 20000.0 fclamp os-inv f* -9.0647202 f* exp2-approx  f-
;

( fs x g k drive -- y : one substep; fs points at an Ms20OtaState. )
dsp: ms20-ota-step | fs:Ms20OtaState x g k drive -- y |
  x drive f*  fs.fb f+ | e |
  fs.y1 | y1 |
  e y1 f- k-tanh-rational-shape-dsp2 g f*  y1 f+ | y1n |
  fs.y2 | y2 |
  y1n y2 f- k-tanh-rational-shape-dsp2 g f*  y2 f+ | y2n |
  y1n y2n f- ms20-diode k f*  -> fs.fb
  y1n -> fs.y1
  y2n -> fs.y2
  y2n
;
