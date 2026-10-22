( acid_voice.fy - a TB-303-style mono bassline voice around the HOT/WET
  lowpass [ms20_lpf.fy].

  That filter was the SM-24 Mono's first LPF and sounded like a 303, not
  an MS-20 [docs/14]: its clipped lowpass is subtracted at a hot input,
  so PEAK thins the bass 16-25 dB, and the peak rides 1.5-2 octaves over
  CUT and moves with the level.  Here it gets the voice it was asking
  for.  The kernel is used as is.

    VCO [saw, or the square shaped from it] -> LPF [4x] -> VCA -> DC block

  The 303's voicing:
  - one VCO, SAW or SQR.  The square keeps a little of the saw's ramp on
    its tops, like the transistor shaper that makes it, and sits at the
    saw's loudness.
  - the MEG is decay only [sustain 0], from a 3 ms attack, and keeps
    falling after the key is up.  ENV MOD scales it onto the cutoff.
  - an accented note [velocity over 0.8, the `!` of a slabkit seq] runs a
    second MEG with the decay at its 200 ms minimum, and sends the
    envelope through the accent RC into the cutoff and the VCA.  The RC
    is slower with RES up, so accents in a row stack the sweep higher:
    the 'wow'.
  - a note that overlaps the last one slides to its pitch [ctx.legato]
    on an RC, without retriggering anything.
  - the VCA decays over 3 s while held and closes in 8 ms on key-up. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/math.fy"
include "../00-primitives/oversample.fy"
include "../01-oscillators/primitives/phase.fy"
include "../01-oscillators/primitives/blep.fy"
include "../01-oscillators/primitives/vco.fy"
include "../02-shapers/rational.fy"   ( tanh-rational )
include "../03-envelopes/primitives/env_rc.fy"
include "../04-filters/coeffs.fy"   ( svf-g )
include "../04-filters/ms20_lpf.fy"

ustruct: AcidState
  f64 phase
  f64 oct          ( current pitch, log2 Hz: slides toward target-oct )
  f64 target-oct
  f64 acc          ( this note's accent, 0..ACCENT )
  f64 accf         ( 1 when the note was triggered accented )
  f64 acc-cv       ( the accent RC )
  f64 dc-prev-x
  f64 dc-prev-y
  EnvRc meg  EnvRc mega  EnvRc vca
  Ms20Lpf lpf
  Up4 up
  Dec4 dec
;

ustruct: AcidParams
  f64 tune         ( semitones )
  f64 wave         ( 0 SAW 1 SQR - switch )
  f64 cutoff       ( base cutoff Hz )
  f64 resonance    ( RES 0..1 )
  f64 env-mod      ( ENV MOD 0..1 )
  f64 decay        ( MEG decay, seconds )
  f64 accent       ( ACCENT 0..1 )
  f64 slide        ( slide time, seconds )
  f64 drive        ( LPF input drive, x the mode's own )
  f64 mode         ( 0 HOT 1 WET - switch )
  f64 level
  ( derived per block by acid-block-prepare )
  f64 inv-sample-rate
  f64 osr
  EnvRcCoefs meg-co
  EnvRcCoefs mega-co
  EnvRcCoefs vca-co
  Ms20LpfProfile lpf-pr
  f64 slide-c      ( slide one-pole, per sample )
  f64 tune-ratio
  f64 env-oct      ( ENV MOD in octaves )
  f64 acc-c        ( accent RC, per sample )
;

( ctx state params -- : a note.  An overlapping note slides and keeps
  the envelopes; any other jumps to its pitch and retriggers them. )
dsp: acid-note-on | ctx:Ctx state:AcidState params:AcidParams |
  ctx.hz 1.0 fmax log2 | o |
  o -> state.target-oct
  ctx.legato 0.5  o state.oct  fsel-lt -> state.oct
  ctx.vel 0.8 f- 6.666666666666667 f* 0.0 1.0 fclamp | av |
  av params.accent f* -> state.acc
  ctx.legato 0.5  0.0 av 1.0 0.0 fsel-lt  state.accf  fsel-lt -> state.accf
  state.meg& params.meg-co& ctx.legato env-rc-trigger
  state.mega& params.mega-co& ctx.legato env-rc-trigger
  state.vca& params.vca-co& ctx.legato env-rc-trigger
;

( ctx state params -- : per-note expression [docs/22]: a bend moves the
  pitch directly. )
dsp: acid-note-expr | ctx:Ctx state:AcidState params:AcidParams |
  ctx.hz 1.0 fmax log2 | o |
  o -> state.target-oct
  o -> state.oct
;

( ctx state params -- : key up.  The MEGs release at their decay rate,
  so they fall on as if still held; the VCA closes. )
dsp: acid-note-off | ctx state:AcidState params:AcidParams |
  state.meg& params.meg-co& env-rc-release
  state.mega& params.mega-co& env-rc-release
  state.vca& params.vca-co& env-rc-release
;

( One LPF substep. )
dsp: acid-lpf-sub | state:AcidState params:AcidParams x g -- y |
  state.lpf&  params.lpf-pr&  x g  ms20-lpf-step
;

( io ctx state params -- : one sample. )
dsp: k-acid-voice-sample | io ctx state:AcidState params:AcidParams -- |
  state.oct  state.target-oct state.oct f-  params.slide-c f*  f+ | oct |
  oct -> state.oct
  oct exp2  params.tune-ratio f*  params.inv-sample-rate f* | dt |
  state.phase | ph |
  ph dt phase-advance01 -> state.phase
  ph dt 0.1 vco-saw fneg | saw |
  params.wave 0.5 f<
  [ saw ]
  [ ph dt 0.5 pulse-polyblep  saw 0.15 f*  f+  0.72 f* ]  ifte  0.62 f* | x |
  ( the MEG: the accented one for an accented note )
  state.meg& params.meg-co& env-rc-step | fn |
  state.mega& params.mega-co& env-rc-step | fa |
  fa fn f-  state.accf f*  fn f+ | fenv |
  state.acc-cv  fa state.acc f*  state.acc-cv f-  params.acc-c f*  f+ | acv |
  acv -> state.acc-cv
  state.vca& params.vca-co& env-rc-step | aenv |
  fenv params.env-oct f*  acv 4.0 f*  f+  exp2  params.cutoff f* | hz |
  hz params.osr svf-g | g |
  state.up& x up4 | x0 x1 x2 x3 |
  state.dec&
    state params x0 g acid-lpf-sub
    state params x1 g acid-lpf-sub
    state params x2 g acid-lpf-sub
    state params x3 g acid-lpf-sub
  dec4 | y |
  ( VCA: the envelope, the accent's push, the level; a ~20 Hz DC block )
  1.0  fa state.acc f* 1.2 f*  f+ | ag |
  y aenv f*  ag f*  params.level f*  1.78 f* | v |
  v state.dc-prev-x f-  state.dc-prev-y 0.9974 f*  f+ | o |
  v -> state.dc-prev-x
  o -> state.dc-prev-y
  o io f!64
;
