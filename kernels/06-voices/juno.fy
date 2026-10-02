( juno.fy - Juno-style polyphonic voice: DCO [polyBLEP saw + PWM pulse
  + sub square one octave down + noise], one 4-pole lowpass, one HPF,
  one ADSR shared by VCF and VCA, one triangle LFO for vibrato and PWM.

  Polyphony contract [src/machines/fy_raw_machine.zig]: the host calls
  k-juno-voice once per voice per segment against that voice's state
  region, so ALL note data lives in per-voice STATE - params are shared.
  The VCA stage ACCUMULATES into the host-zeroed out buffer.  Voices are
  never freed; a fully released envelope renders silence.

  ctx.chan is the voice index [kernel ABI, ctx.fy]; DETUNE
  spreads voices a few cents apart off a per-voice golden-ratio offset -
  the analog-drift knob the real DCOs were too stable to need.

  Against the Juno-60/106 panels: the ENV, LFO and KYBD move the cutoff
  in octaves, like control voltage [ENV +-8 oct, LFO +-3 oct, KYBD 1
  oct/oct at full]; the envelope is RC [env_rc.fy], so a retrigger or a
  voice steal attacks from the current level; ENV times reach the real
  12 s; the LFO has the 60's DELAY [0-2 s fade-in from each note-on];
  PWM takes MAN, LFO or ENV; the HPF is the 106's four-step slider -
  0 bass boost, 1 flat, 2 225 Hz, 3 720 Hz.  The boost's size is not
  published; ours is a +3.5 dB shelf under ~90 Hz.

  Probe case: juno-voice-render. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../01-oscillators/primitives/phase.fy"
include "../01-oscillators/primitives/blep.fy"
include "../03-envelopes/primitives/env_rc.fy"
include "../04-filters/coeffs.fy"   ( svf-g, svf-damping, svf-dc-coeff )
include "../04-filters/ladder.fy"     ( ZDF 4-pole ladder, saturating input pair )
include "../08-analog/analog.fy"      ( AGE: drift + per-voice spread )

ustruct: JunoState
  f64 phase       ( DCO phase, free-running )
  f64 sub-phase   ( sub oscillator phase, half rate )
  f64 lfo-phase
  f64 noise-rng
  f64 age         ( seconds since note-on: the LFO delay )
  f64 note-hz
  f64 vel
  f64 ic1         ( ladder integrator states - MUST stay contiguous, )
  f64 ic2         ( ladder4-core indexes &ic1 as a 4-cell LadderState )
  f64 ic3
  f64 ic4
  f64 hpf-lp      ( HPF one-pole lowpass state )
  EnvRc env
  Drift drift     ( this voice's slow pitch wander )
  f64 t-spread    ( this voice's envelope-time multiplier, from AGE )
  f64 cut-spread  ( this voice's cutoff multiplier, from AGE )
  f64 oc-x        ( the output coupling cap: last input, last output )
  f64 oc-y
;

ustruct: JunoParams
  ( user-facing )
  f64 lfo-rate    ( Hz )
  f64 vibrato     ( LFO -> pitch, 0..1 )
  f64 range       ( DCO octave: 0.5 16' / 1 8' / 2 4' - switch value )
  f64 saw-on      ( switch 0/1 )
  f64 pulse-on    ( switch 0/1 )
  f64 pwm         ( pulse width amount, 0..1 )
  f64 pwm-mode    ( 0 manual / 1 LFO / 2 ENV - switch )
  f64 sub-level
  f64 noise-level
  f64 detune      ( per-voice spread, 0..1 )
  f64 hpf-pos     ( 0 boost / 1 flat / 2 225 Hz / 3 720 Hz - switch )
  f64 cutoff-hz
  f64 resonance   ( 0..1 )
  f64 env-amount  ( VCF envelope, bipolar -1..1: +-8 octaves )
  f64 lfo-vcf     ( LFO -> cutoff, 0..1: +-3 octaves )
  f64 kybd        ( keyboard tracking, 0..1 )
  f64 atk-s
  f64 dec-s
  f64 sus
  f64 rel-s
  f64 vca-mode    ( 0 env / 1 gate - switch )
  f64 level
  f64 age-amt     ( AGE 0..1: drift + per-voice component spread )
  f64 lfo-delay   ( seconds: the LFO fades in after each note-on )
  ( derived - filled by juno-block-prepare )
  f64 inv-sr
  f64 lfo-inc
  f64 hpf-a
  f64 hpf-on      ( 1 in positions 2 and 3: subtract the lowpass )
  f64 boost       ( position 0: add half the lowpass back, a low shelf )
  f64 env-oct     ( env-amount * 8 )
  f64 lfo-oct     ( lfo-vcf * 3 )
  f64 vib-frac    ( vibrato * 0.03 - peak pitch deviation ratio )
  f64 drift-c
  f64 oc-a        ( the output coupling cap's one-pole coefficient, 10 Hz )
  EnvRcCoefs co
;

( ctx state params -- : derived fills, all idempotent. )
dsp: juno-block-prepare
  | ctx:Ctx state params:JunoParams |
  ctx.sr | sr |
  1.0 sr f/ | inv |
  inv -> params.inv-sr
  params.lfo-rate inv f* -> params.lfo-inc
  ( HPF: the slider's four steps; position 0's shelf lives at 90 Hz )
  params.hpf-pos | hp |
  hp 0.5  90.0  hp 1.5 90.0  hp 2.5 225.0 720.0 fsel-lt  fsel-lt  fsel-lt
    6.2831853 f* inv f* 0.0 1.0 fclamp -> params.hpf-a
  hp 1.5  0.0 1.0  fsel-lt -> params.hpf-on
  hp 0.5  0.5 0.0  fsel-lt -> params.boost
  params.env-amount 8.0 f* -> params.env-oct
  params.lfo-vcf 3.0 f* -> params.lfo-oct
  params.co&  params.atk-s params.dec-s params.sus params.rel-s  0.0 0.0  inv env-rc-coefs
  params.vibrato 0.03 f* -> params.vib-frac
  0.3 inv drift-coef -> params.drift-c
  1.0  1.0  6.283185307179586 10.0 f* inv f*  f+  f/ -> params.oc-a
;

( ctx state params -- : start this voice.  DCO phases free-run -
  the digitally-controlled oscillators never reset, the envelope does
  the de-clicking, exactly like the hardware. )
dsp: juno-note-on
  | ctx:Ctx state:JunoState params:JunoParams |
  ctx.hz ctx.vel | hz velocity |
  hz -> state.note-hz
  velocity -> state.vel
  0.0 -> state.age
  state.env& params.co& 0.0 env-rc-trigger
  state.drift& ctx.chan 1.0 f+ drift-seed-once
  state.noise-rng& ctx.chan 37.0 f+ rand-seed-once
  ( unison: a fresh voice's DCO starts at the host's phase, not 0 )
  state.phase 0.0 f=  ctx.phase  state.phase  select -> state.phase
  state.sub-phase 0.0 f=  ctx.phase 0.5 f*  state.sub-phase  select -> state.sub-phase
  ( AGE: each voice's parts are a little off, the same way every time )
  1.0  ctx.chan 7.0 spread params.age-amt f* 0.08 f*  f+ -> state.t-spread
  ctx.chan 5.0 spread params.age-amt f* 0.14 f* exp2 -> state.cut-spread
;

( ctx state params -- : per-note expression [docs/22]: retune the
  sounding voice to ctx.hz. )
dsp: juno-note-expr | ctx:Ctx state:JunoState params |
  ctx.hz -> state.note-hz
;

( ctx state params -- : release this voice from its current level. )
dsp: juno-note-off
  | ctx state:JunoState params:JunoParams |
  state.env& params.co& env-rc-release
;

( Advance age + LFO; the bipolar triangle LFO, faded in over DELAY
  from the note-on, and the shared VCF/VCA envelope. )
dsp: jn-mod | state:JunoState params:JunoParams -- lfo env |
  state.age params.inv-sr f+ | age |
  age -> state.age
  state.lfo-phase params.lfo-inc f+ ffrac | ph |
  ph -> state.lfo-phase
  ph 0.5 f- | u |
  u fabs 4.0 f* 1.0 f-
  age  params.lfo-delay 0.001 fmax  f/  1.0 fmin  f*
  state.env& params.co& env-rc-step
;

( DCO: saw + PWM pulse + sub + noise. )
dsp: jn-dco | ctx:Ctx state:JunoState params:JunoParams lfo env -- osc |
  ( per-voice golden-ratio detune around center, +-0.4% at full knob )
  state.note-hz params.range f*
  1.0
    ctx.chan 0.618034 f* ffrac 0.5 f-
    params.detune f* 0.008 f*
  f+ f*
  1.0  lfo params.vib-frac f*  f+ f*
  ( AGE drift, ~4 cents RMS at full )
  1.0  state.drift& params.drift-c drift-step  params.age-amt 0.0023 f* f*  f+ f*
  params.inv-sr f* | dt |
  state.phase dt phase-advance01 | phs |
  phs -> state.phase
  ( pulse width: MAN narrows from square; LFO sweeps it; ENV follows
    the envelope )
  params.pwm-mode 0.5
    0.5  params.pwm 0.45 f*  f-
    params.pwm-mode 1.5
      0.5  params.pwm 0.225 f* 1.0 lfo f+ f*  f-
      0.5  params.pwm 0.45 f* env f*  f-
    fsel-lt
  fsel-lt | width |
  ( a wave switched off or a SUB at 0 isn't computed; the sub's phase
    runs on either way )
  phs dt saw-falling-polyblep params.saw-on f*
  params.pulse-on 0.0 f=  [ 0.0 ]  [ phs dt width pulse-polyblep params.pulse-on f* ]  ifte f+
  ( sub: blep square at half rate )
  state.sub-phase dt 0.5 f* phase-advance01 | sph |
  sph -> state.sub-phase
  params.sub-level 0.0 f=  [ 0.0 ]  [ sph  dt 0.5 f*  0.5 pulse-polyblep params.sub-level f* ]  ifte f+
  ( noise )
  state.noise-rng& rand-b  params.noise-level f* f+
  0.32 f*
;

( Envelope/LFO/keyboard-modulated cutoff -> ladder g [via svf-g, at the
  base rate], and resonance -> feedback k.  The three sum in octaves,
  like the CVs they are; KYBD tracks from middle C.  svf-g clamps the
  result into [20, 20160]. )
dsp: jn-cutoff | state:JunoState params:JunoParams lfo env -- g k |
  env params.env-oct f*
  lfo params.lfo-oct f* f+
  state.note-hz 261.6 f/ log2  params.kybd f*  f+
  exp2 params.cutoff-hz f*
  state.cut-spread f*
  1.0 params.inv-sr f/ svf-g
  ( resonance -> feedback; past 4 the saturating input keeps the
    self-oscillation bounded )
  params.resonance 4.4 f*
;

( The ZDF 4-pole ladder with its input pair saturating [ladder4-sat].
  Mild input gain compensation [1 + 0.2*k] keeps the low end from
  thinning as resonance rises, the way the Juno's IR3109 stays full. )
dsp: jn-ladder | state:JunoState x g k -- y |
  state.ic1&  x 1.0 k 0.2 f* f+ f*  g k  1.6 ladder4-sat
;

( The HPF slider on the ladder output, one one-pole lowpass: positions
  2 and 3 subtract it [hp = x - lp], position 0 adds half of it back
  [+3.5 dB below its corner], position 1 passes. )
dsp: jn-hpf | state:JunoState params:JunoParams x -- y |
  state.hpf-lp | lp0 |
  lp0  x lp0 f-  params.hpf-a f*  f+ | lp |
  lp -> state.hpf-lp
  x  lp params.hpf-on f* f-  lp params.boost f* f+
;

( VCA - env or gate mode - then the output's 10 Hz coupling cap, which
  takes out the pulse's DC [a narrow PWM sits far off centre] and the
  thump it leaves at the attack; ACCUMULATE into out. )
dsp: jn-vca | out state:JunoState params:JunoParams env y -- |
  params.vca-mode 0.5
    env
    state.env& env-rc-gate
  fsel-lt | amp |
  y amp f*  state.vel f* params.level f* 3.5 f* | v |  ( +11 dB makeup )
  state.oc-y v f+ state.oc-x f-  params.oc-a f* | o |
  v -> state.oc-x
  o -> state.oc-y
  out f@64 o f+ out f!64
;

( io ctx state params -- : one polyphonic voice tick. )
dsp: k-juno-voice | io ctx state params -- |
  state params jn-mod | lfo env |
  state  ctx state params lfo env jn-dco
  state params lfo env jn-cutoff  jn-ladder
  state params rot jn-hpf | y |
  io state params env y jn-vca
;
