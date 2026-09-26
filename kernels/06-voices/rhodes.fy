( rhodes.fy — Rhodes-type electric piano voice (modal + nonlinear pickup).

  An FM Rhodes is just a DX patch — the FM-86 machine already covers that.
  A real Rhodes makes its sound a different way, and modelling that mechanism
  is what makes this machine sound organic rather than synthetic:

    * A struck steel TINE is a clamped-free bar.  Such a bar has INHARMONIC
      overtones at 1, 6.267, 17.55, ... of its fundamental.  We render the
      fundamental plus the 6.267x metallic "tine" overtone as two decaying
      sinusoidal modes — the overtone decays faster, giving the bell-like
      attack ping that fades to a warm body.

    * The ELECTROMAGNETIC PICKUP is nonlinear: the tine vibrates in a
      position-dependent magnetic field, so the pickup voltage is an
      ASYMMETRIC, saturating function of tine displacement.  Feeding the
      clean modal sum through this nonlinearity is the heart of the sound:
      it manufactures the harmonic series, and because a waveshaper's
      harmonic content tracks its input amplitude, the tone is bright/barky
      when struck hard and mellows automatically as the note decays.  No FM
      sidebands, no glassy DX character.

    modes -> *velocity -> pickup tanh(drive*(x+bias)) -> warmth LP
          -> DC block -> *VCA(level) -> out

  A real attack+exponential-decay VCA (the modal envelopes) makes the note
  die away while held, like a struck string; key-release switches to a
  faster damper coefficient.  A short hammer-noise chiff and a hair of
  detune between two fundamental modes add the suitcase realism.

  Polyphony contract [src/machines/fy_raw_machine.zig]: the host calls
  k-rhodes-voice once per voice per segment against that voice's state
  region, so ALL note data lives in per-voice STATE — params are shared.
  The warmth stage ACCUMULATES into the host-zeroed out buffer.

  Probe case: rhodes-voice-render. )

include "../04-filters/ms20_svf.fy"     ( svf-dc-coeff )
include "../05-drums/noise.fy"          ( noise-step — hammer chiff )
include "../02-shapers/tanh_table.fy"   ( k-tanh-rational-shape-dsp2 — pickup )
include "../05-drums/sine.fy"           ( sine-shape — modal oscillators )

ustruct: RhodesState
  f64 voice-idx   ( host-injected region/voice index, unused in DSP )
  f64 age         ( seconds since note-on )
  f64 gate-time   ( age at release; huge while held )
  f64 note-hz
  f64 vel
  f64 amp-atk     ( attack one-pole, 0 -> 1 )
  f64 fund-env    ( fundamental decay, 1 -> 0 )
  f64 tine-env    ( tine-overtone decay, 1 -> 0, faster )
  f64 bark-env    ( attack transient: extra pickup drive + chiff, 1 -> 0 )
  f64 phaseA      ( fundamental mode A phase )
  f64 phaseB      ( fundamental mode B phase, detuned )
  f64 tine-phase  ( 6.267x tine overtone phase )
  f64 noise-rng   ( LCG state for the hammer chiff )
  f64 warm-lp     ( warmth one-pole lowpass state )
  f64 dc          ( DC-block highpass state )
  f64 s-fund      ( scratch: fundamental modal output )
  f64 s-tine      ( scratch: tine overtone output )
  f64 s-pre       ( scratch: post-pickup sample )
;

ustruct: RhodesParams
  ( user-facing — knob ids kept stable across the redesign )
  f64 tine-q        ( BELL: tine overtone level + ring length 0..1 )
  f64 bar-q         ( DECAY: note decay time 0..1 -> 0.6..6.6 s )
  f64 bar-detune    ( CHORUS: detune between fundamental modes 0..1 )
  f64 pickup-drive  ( DRIVE: pickup nonlinearity / growl 0..1 )
  f64 bark          ( BARK: attack brightness + hammer chiff 0..1 )
  f64 bark-decay    ( SNAP: attack-transient decay time 0..1 -> 0.02..0.32 s )
  f64 warmth        ( TONE: warmth lowpass 0..1 -> 700..6000 Hz )
  f64 damper        ( RELEASE damping 0..1 )
  f64 level         ( output level 0..1 )
  ( derived — filled by rhodes-block-prepare )
  f64 inv-sr
  f64 sr
  f64 amp-atk-coef
  f64 fund-dec-coef    ( per-sample fundamental decay while held )
  f64 fund-rel-coef    ( per-sample decay after release )
  f64 tine-dec-coef
  f64 bark-dec-coef
  f64 detune-mul       ( 1 + bar-detune*0.006 for fundamental mode B )
  f64 tine-lvl         ( tine overtone mix level )
  f64 pickup-base      ( steady pickup drive )
  f64 bark-drive-amt   ( extra pickup drive that decays with bark-env )
  f64 pickup-bias      ( pickup asymmetry offset )
  f64 chiff-amt        ( hammer-noise level )
  f64 warm-a           ( warmth one-pole coefficient )
  f64 dc-coef          ( DC-block highpass coefficient ~12 Hz )
;

( params sr -- : derived fills, all idempotent. No libm: svf-dc-coeff is the
  1-exp(-2pi*f/sr) polynomial; decay multipliers are its complement.
  1/(2pi) = 0.15915494309189535 maps a time constant tau to its corner f. )
dsp: rhodes-block-prepare
  | params sr |
  1.0 sr f/ params RhodesParams.inv-sr-p f!64
  sr params RhodesParams.sr-p f!64
  ( attack one-pole rise: tau ~ 2 ms -> corner 79.577 Hz, coef direct )
  sr 79.57747154594767 svf-dc-coeff params RhodesParams.amp-atk-coef-p f!64
  ( fundamental decay: tau = 0.6 + bar-q*6.0 s )
  sr 0.15915494309189535 0.6 params RhodesParams.bar-q@ 6.0 f* f+ f/ svf-dc-coeff
  1.0 swap f- params RhodesParams.fund-dec-coef-p f!64
  ( release: tau = 0.06 + (1-damper)*0.9 s )
  sr 0.15915494309189535 0.06 1.0 params RhodesParams.damper@ f- 0.9 f* f+ f/ svf-dc-coeff
  1.0 swap f- params RhodesParams.fund-rel-coef-p f!64
  ( tine overtone decay: tau = 0.2 + tine-q*0.8 s )
  sr 0.15915494309189535 0.2 params RhodesParams.tine-q@ 0.8 f* f+ f/ svf-dc-coeff
  1.0 swap f- params RhodesParams.tine-dec-coef-p f!64
  ( bark transient decay: tau = 0.02 + bark-decay*0.3 s )
  sr 0.15915494309189535 0.02 params RhodesParams.bark-decay@ 0.3 f* f+ f/ svf-dc-coeff
  1.0 swap f- params RhodesParams.bark-dec-coef-p f!64
  ( detune multiplier: 1 + bar-detune*0.006 (up to ~0.6%) )
  1.0 params RhodesParams.bar-detune@ 0.006 f* f+ params RhodesParams.detune-mul-p f!64
  ( tine overtone level )
  params RhodesParams.tine-q@ 0.5 f* params RhodesParams.tine-lvl-p f!64
  ( pickup: steady drive, attack-extra drive, asymmetry bias, chiff level )
  0.8 params RhodesParams.pickup-drive@ 1.6 f* f+ params RhodesParams.pickup-base-p f!64
  params RhodesParams.bark@ 2.5 f* params RhodesParams.bark-drive-amt-p f!64
  0.3 params RhodesParams.pickup-bias-p f!64
  params RhodesParams.bark@ 0.12 f* params RhodesParams.chiff-amt-p f!64
  ( warmth one-pole: corner 700 + warmth*5300 Hz )
  sr 700.0 params RhodesParams.warmth@ 5300.0 f* f+ svf-dc-coeff params RhodesParams.warm-a-p f!64
  ( DC-block highpass corner ~12 Hz )
  sr 12.0 svf-dc-coeff params RhodesParams.dc-coef-p f!64
  drop2
;

( state params hz velocity -- : strike this voice. Phases reset to 0 so
  sample 0 is silent (no click); envelopes seed for a fresh strike. )
dsp: rhodes-note-on
  | state params hz velocity |
  hz state RhodesState.note-hz-p f!64
  velocity state RhodesState.vel-p f!64
  0.0 state RhodesState.age-p f!64
  1000000000.0 state RhodesState.gate-time-p f!64
  0.0 state RhodesState.amp-atk-p f!64
  1.0 state RhodesState.fund-env-p f!64
  1.0 state RhodesState.tine-env-p f!64
  1.0 state RhodesState.bark-env-p f!64
  0.0 state RhodesState.phaseA-p f!64
  0.0 state RhodesState.phaseB-p f!64
  0.0 state RhodesState.tine-phase-p f!64
  12345.0 state RhodesState.noise-rng-p f!64
  0.0 state RhodesState.warm-lp-p f!64
  0.0 state RhodesState.dc-p f!64
  drop2 drop2
;

( state params -- : release this voice — the damper engages. )
dsp: rhodes-note-off
  | state params |
  state RhodesState.age@ state RhodesState.gate-time-p f!64
  drop2
;

( state params -- : advance age and all envelopes. The decay multipliers
  switch to the faster release coefficient once age >= gate-time. )
dsp: rhodes-env
  | state params |
  ( age += 1/sr )
  state RhodesState.age@ params RhodesParams.inv-sr@ f+ state RhodesState.age-p f!64
  ( attack: a += (1-a)*atk-coef )
  state RhodesState.amp-atk@ | a |
  1.0 a f- params RhodesParams.amp-atk-coef@ f* a f+ state RhodesState.amp-atk-p f!64
  ( fundamental: held -> fund-dec, released -> fund-rel )
  state RhodesState.fund-env@
  state RhodesState.age@ state RhodesState.gate-time@
    params RhodesParams.fund-dec-coef@ params RhodesParams.fund-rel-coef@ fsel-lt
  f* state RhodesState.fund-env-p f!64
  ( tine: held -> tine-dec, released -> fund-rel (damper cuts the ring) )
  state RhodesState.tine-env@
  state RhodesState.age@ state RhodesState.gate-time@
    params RhodesParams.tine-dec-coef@ params RhodesParams.fund-rel-coef@ fsel-lt
  f* state RhodesState.tine-env-p f!64
  ( bark transient always decays fast )
  state RhodesState.bark-env@ params RhodesParams.bark-dec-coef@ f* state RhodesState.bark-env-p f!64
  drop2 drop
;

( state params -- : two fundamental modes (detuned), summed unequally so the
  pair never fully cancels, scaled by the decay and attack envelopes. )
dsp: rhodes-fund
  | state params |
  state RhodesState.phaseA@ sine-shape 0.55 f*
  state RhodesState.phaseB@ sine-shape 0.45 f* f+
  state RhodesState.fund-env@ f* state RhodesState.amp-atk@ f*
  state RhodesState.s-fund-p f!64
  ( advance phases: A at note-hz, B detuned )
  state RhodesState.phaseA@ state RhodesState.note-hz@ params RhodesParams.inv-sr@ f* f+ ffrac
    state RhodesState.phaseA-p f!64
  state RhodesState.phaseB@
    state RhodesState.note-hz@ params RhodesParams.inv-sr@ f* params RhodesParams.detune-mul@ f* f+ ffrac
    state RhodesState.phaseB-p f!64
  drop2
;

( state params -- : the 6.267x clamped-free-bar tine overtone — the metallic
  ping — with its own faster decay. )
dsp: rhodes-tine
  | state params |
  state RhodesState.tine-phase@ sine-shape
  state RhodesState.tine-env@ f* params RhodesParams.tine-lvl@ f* state RhodesState.amp-atk@ f*
  state RhodesState.s-tine-p f!64
  ( advance: note-hz * 6.267 )
  state RhodesState.tine-phase@
    state RhodesState.note-hz@ params RhodesParams.inv-sr@ f* 6.267 f* f+ ffrac
    state RhodesState.tine-phase-p f!64
  drop2
;

( state params -- : the nonlinear pickup. x = (fund + tine)*vel + hammer
  chiff; drive rises during the attack (bark-env); y = tanh(drive*(x+bias)).
  The asymmetric bias + amplitude-tracking saturation is the Rhodes growl. )
dsp: rhodes-pickup
  | state params |
  state RhodesState.s-fund@ state RhodesState.s-tine@ f+ state RhodesState.vel@ f*
  state RhodesState.noise-rng-p noise-step
    params RhodesParams.chiff-amt@ f* state RhodesState.bark-env@ f* state RhodesState.vel@ f* f+
  | x |
  params RhodesParams.pickup-base@
    params RhodesParams.bark-drive-amt@ state RhodesState.bark-env@ f* f+
  | drv |
  x params RhodesParams.pickup-bias@ f+ drv f*
  k-tanh-rational-shape-dsp2
  state RhodesState.s-pre-p f!64
  drop2 drop2
;

( out state params -- : warmth one-pole lowpass + DC-block highpass, then
  accumulate.  The asymmetric pickup leaves a DC term the leaky-integrator
  highpass (dc += k*(lp-dc); hp = lp-dc) removes. )
dsp: rhodes-warmth
  | out state params |
  ( one-pole lowpass: lp += a * (pre - lp) )
  state RhodesState.s-pre@ state RhodesState.warm-lp@ f-
  params RhodesParams.warm-a@ f*
  state RhodesState.warm-lp@ f+
  state RhodesState.warm-lp-p f!64
  ( DC block: dc += k*(lp - dc) ; hp = lp - dc )
  state RhodesState.warm-lp@ state RhodesState.dc@ f-
  params RhodesParams.dc-coef@ f*
  state RhodesState.dc@ f+
  state RhodesState.dc-p f!64
  ( accumulate: out += (lp - dc) * level )
  out f@64
  state RhodesState.warm-lp@ state RhodesState.dc@ f- params RhodesParams.level@ f* f+
  out f!64
  drop2 drop
;

( out state params -- : one voice tick, staged. Output ACCUMULATES into out.
  Each call: boundary is a fresh register budget. )
dsp: k-rhodes-voice
  | out state params |
  state params      call: rhodes-env
  state params      call: rhodes-fund
  state params      call: rhodes-tine
  state params      call: rhodes-pickup
  out state params  call: rhodes-warmth
;
