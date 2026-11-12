( rhodes.fy — Rhodes-type electric piano voice: modal tine + magnetic pickup.

  A Rhodes gets its sound from where the steel tine sits against its
  electromagnetic pickup, not from the tine's spectrum alone:

    * The struck TINE [plus its tonebar] rings as a few modes: two close
      fundamentals that can beat [CHORUS; a real tine doesn't], and the
      tine's second mode at 7.35x - a faint metallic ping on the attack
      [BELL, SNAP].  Decay follows pitch: bass notes ring, top notes die
      sooner.

    * The PICKUP sees flux Phi = 1/[1 + [x - off]^2] of the tine displacement
      x, and its coil outputs dPhi/dt.  Soft strikes keep x small, so the
      output is a fundamental proportional to the offset plus a clean 2nd
      harmonic - mellow.  Hard strikes [displacement ~ vel^1.4, DRIVE] swing
      past the axis and back, two pulses a cycle: the 2nd harmonic passes
      the fundamental and the series runs to the 9th - bark.  This flux
      law fits a sampled 1977 Mark I's first eight harmonics within about
      2 dB at every velocity layer [docs/41], with a swing of 2.3 pickup
      widths at D3 full velocity, 4 or more in the bass and 0.4 at E5.  VOICING
      moves the tine off the pickup axis: toward the axis is bell-like [even
      harmonics], away from it round and fundamental-heavy.  A derivative has
      no DC, so there is no DC blocker and no thump.

    modes * vel-amp -> Phi -> d/dt * sr/[2 pi f0] -> + hammer chiff
          -> warmth LP [TONE] -> * level -> out

  Key release switches the decay to the damper [RELEASE].  Suitcase
  tremolo / stereo pan are not modeled - chain chorus2 for motion.

  Polyphony contract [src/machines/fy_raw_machine.zig]: the host calls
  k-rhodes-voice once per voice per segment against that voice's state
  region, so ALL note data lives in per-voice STATE — params are shared.
  The warmth stage ACCUMULATES into the host-zeroed out buffer. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../04-filters/coeffs.fy"   ( svf-g, svf-damping, svf-dc-coeff )
include "../05-drums/noise.fy"          ( noise-step — hammer chiff )
include "../02-shapers/rational.fy"   ( tanh-rational )
include "../00-primitives/math.fy"      ( dsp-std: sin2pi, exp2, log2 )

:: RH-REF-HZ 146.83 ;     ( D3: where DRIVE's swing is stated )
:: RH-SWING-TRACK 1.15 ;  ( swing ~ [D3/f]^this )
:: RH-SWING-MAX 2.0 ;
:: RH-SCATTER 0.25 ;      ( key-to-key spread of the tine offset, pickup widths )
:: RH-TOP-HZ 1700.0 ;     ( above this the decay shortens as f^4 )
:: RH-TINE-RATIO 7.35 ;   ( the tine's second mode, measured: the tuning spring raises a bare bar's 6.27 )
:: RH-OUT 0.45 ;          ( output trim: a full-velocity note near -6 dBFS at LEVEL 0.8 )

ustruct: RhodesState
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
  f64 tine-phase  ( tine overtone phase )
  f64 noise-rng   ( noise state for the hammer chiff [rand.fy] )
  f64 warm-lp     ( warmth one-pole lowpass state )
  f64 phi-prev    ( pickup flux last sample - the output is its derivative )
  f64 vel-amp     ( tine displacement scale for this strike: vel^1.4 * drive )
  f64 emf-norm    ( sr / [2 pi f0]: derivative gain that keeps level pitch-flat )
  f64 fund-dec-v  ( this note's decay multiplier - lower notes ring longer )
  f64 off         ( this tine's offset from its pickup's axis: VOICING and the key's own )
  f64 pf          ( this key's swing, x the swing at D3: long bass tines move further )
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
  f64 voicing       ( VOICING: tine offset from the pickup axis 0..1 )
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
  f64 drive-amt        ( tine displacement at full velocity )
  f64 bark-drive-amt   ( extra displacement that decays with bark-env )
  f64 pickup-off       ( voicing -> tine offset in pickup units )
  f64 chiff-amt        ( hammer-noise level )
  f64 warm-a           ( warmth one-pole coefficient )
  f64 fund-tau         ( fundamental decay time at C3, s )
;

( ctx state params -- : derived fills, all idempotent. No libm: svf-dc-coeff is the
  1-exp(-2pi*f/sr) polynomial; decay multipliers are its complement.
  1/(2pi) = 0.15915494309189535 maps a time constant tau to its corner f. )
dsp: rhodes-block-prepare
  | ctx:Ctx state params:RhodesParams |
  ctx.sr | sr |
  1.0 sr f/ -> params.inv-sr
  sr -> params.sr
  ( attack one-pole rise: tau ~ 2 ms -> corner 79.577 Hz, coef direct )
  sr 79.57747154594767 svf-dc-coeff -> params.amp-atk-coef
  ( fundamental decay: tau = 0.6 + bar-q*6.0 s )
  sr 0.15915494309189535 0.6 params.bar-q 6.0 f* f+ f/ svf-dc-coeff
  1.0 swap f- -> params.fund-dec-coef
  ( release: tau = 0.02 + (1-damper)*0.3 s - dampers stop a tine fast )
  sr 0.15915494309189535 0.02 1.0 params.damper f- 0.3 f* f+ f/ svf-dc-coeff
  1.0 swap f- -> params.fund-rel-coef
  ( tine ping decay: tau = 0.03 + tine-q*0.25 s - a bright attack, not a drone )
  sr 0.15915494309189535 0.03 params.tine-q 0.25 f* f+ f/ svf-dc-coeff
  1.0 swap f- -> params.tine-dec-coef
  ( bark transient decay: tau = 0.02 + bark-decay*0.3 s )
  sr 0.15915494309189535 0.02 params.bark-decay 0.3 f* f+ f/ svf-dc-coeff
  1.0 swap f- -> params.bark-dec-coef
  ( detune multiplier: 1 + bar-detune*0.006 (up to ~0.6%) )
  1.0 params.bar-detune 0.006 f* f+ -> params.detune-mul
  ( tine ping level in DISPLACEMENT.  The measured piano's is 38 dB under
    the fundamental at the output [BELL 0.36]; the pickup's derivative
    lifts it by its ratio, 7.35.  BELL 1 is 12 dB under: a caricature. )
  params.tine-q dup dup f* f* 0.035 f* -> params.tine-lvl
  ( pickup: displacement at full velocity, attack-extra, voicing offset, chiff )
  ( swing at D3, full velocity, in pickup widths: the measured piano is 2.3 )
  0.6 params.pickup-drive 3.6 f* f+ -> params.drive-amt
  params.bark 0.6 f* -> params.bark-drive-amt
  ( offset 0.15..0.75: a centered tine [0] gives no fundamental at all )
  params.voicing 0.6 f* 0.15 f+ -> params.pickup-off
  params.bark 0.02 f* -> params.chiff-amt
  ( fundamental decay at C3; note-on scales it by pitch )
  0.6 params.bar-q 6.0 f* f+ -> params.fund-tau
  ( warmth one-pole: corner 700 + warmth*5300 Hz )
  sr 700.0 params.warmth 5300.0 f* f+ svf-dc-coeff -> params.warm-a
;

( ctx state params -- : strike this voice.  Phases reset to 0 so sample 0
  is silent; envelopes seed for a fresh strike.

  Displacement grows faster than velocity [vel^1.4]: hard hits reach the
  pickup's curved region and bark, soft ones stay near-linear and mellow.
  dPhi/dt scales with frequency; emf-norm divides it back out so level is
  pitch-flat.  Decay tau ~ fund-tau * [C3/f]^0.5: bass notes ring, top
  notes die sooner, as tines shorten. )
dsp: rhodes-note-on | ctx:Ctx state:RhodesState params:RhodesParams -- |
  ctx.hz -> state.note-hz
  ctx.vel -> state.vel
  0.0 -> state.age
  1000000000.0 -> state.gate-time
  0.0 -> state.amp-atk
  1.0 -> state.fund-env
  1.0 -> state.tine-env
  1.0 -> state.bark-env
  0.0 -> state.phaseA
  0.0 -> state.phaseB
  0.0 -> state.tine-phase
  2.8742942959070206e-06 -> state.noise-rng   ( 12345 * 2^-32: rand.fy states are fractions )
  0.0 -> state.warm-lp
  ( a strike from rest: flux starts at the tine's rest position )
  ctx.hz 20.0 20000.0 fclamp | hz |
  ( each tine sits a little differently against its pickup )
  ctx.pitch 0.6180339887 f* ffrac 0.5 f- RH-SCATTER f*  params.pickup-off f+  0.1 fmax | off |
  off -> state.off
  1.0  1.0 off off f* f+  f/  -> state.phi-prev
  ( the swing: bass tines are long and move further, as [D3/f]^1.15 up to
    twice D3's; the output is divided by the same so the keys stay level )
  RH-REF-HZ hz f/ log2 RH-SWING-TRACK f* exp2 RH-SWING-MAX fmin | pf |
  pf -> state.pf
  ctx.vel 0.0001 1.0 fclamp log2 1.4 f* exp2 params.drive-amt f* pf f*
    -> state.vel-amp
  params.sr 6.283185307179586 hz f* f/  pf f/ RH-OUT f*  -> state.emf-norm
  ( decay: as [C3/f]^0.5, and the short top tines faster still )
  130.81 hz f/ log2 0.5 f* exp2
    hz RH-TOP-HZ f/ dup f* dup f* 1.0 f+ f/
    params.fund-tau f* | tau |
  params.sr 0.15915494309189535 tau f/ svf-dc-coeff 1.0 swap f-
    -> state.fund-dec-v
;

( ctx state params -- : per-note expression [docs/22]: retune the
  sounding voice to ctx.hz. )
dsp: rhodes-note-expr | ctx:Ctx state:RhodesState params:RhodesParams -- |
  ctx.hz -> state.note-hz
  params.sr 6.283185307179586 ctx.hz 20.0 20000.0 fclamp f* f/  state.pf f/ RH-OUT f*  -> state.emf-norm
;

( ctx state params -- : release this voice — the damper engages. )
dsp: rhodes-note-off
  | ctx state:RhodesState params |
  state.age -> state.gate-time
;

( state params -- : advance age and all envelopes. The decay multipliers
  switch to the faster release coefficient once age >= gate-time. )
dsp: rhodes-env
  | state:RhodesState params:RhodesParams |
  ( age += 1/sr )
  state.age params.inv-sr f+ -> state.age
  ( attack: a += (1-a)*atk-coef )
  state.amp-atk | a |
  1.0 a f- params.amp-atk-coef f* a f+ -> state.amp-atk
  ( fundamental: held -> fund-dec, released -> fund-rel )
  state.fund-env
  state.age state.gate-time
    state.fund-dec-v params.fund-rel-coef fsel-lt
  f* -> state.fund-env
  ( tine: held -> tine-dec, released -> fund-rel (damper cuts the ring) )
  state.tine-env
  state.age state.gate-time
    params.tine-dec-coef params.fund-rel-coef fsel-lt
  f* -> state.tine-env
  ( bark transient always decays fast )
  state.bark-env params.bark-dec-coef f* -> state.bark-env
;

( Two fundamental modes (detuned), summed unequally so the pair never
  fully cancels, scaled by the decay and attack envelopes. )
dsp: rhodes-fund | state:RhodesState params:RhodesParams -- y |
  state.phaseA sin2pi 0.55 f*
  state.phaseB sin2pi 0.45 f* f+
  state.fund-env f* state.amp-atk f*
  ( advance phases: A at note-hz, B detuned )
  state.phaseA state.note-hz params.inv-sr f* f+ ffrac -> state.phaseA
  state.phaseB
    state.note-hz params.inv-sr f* params.detune-mul f* f+ ffrac
    -> state.phaseB
;

( The tine's second mode at RH-TINE-RATIO — the metallic ping — with its
  own faster decay. )
dsp: rhodes-tine | state:RhodesState params:RhodesParams -- y |
  state.tine-phase sin2pi
  state.tine-env f* params.tine-lvl f* state.amp-atk f*
  ( advance: note-hz * RH-TINE-RATIO )
  state.tine-phase
    state.note-hz params.inv-sr f* RH-TINE-RATIO f* f+ ffrac
    -> state.tine-phase
;

( state params -- : the electromagnetic pickup.  x is the tine's
  displacement at the pickup [velocity-scaled modes plus a bark boost on
  the attack]; the flux through the coil falls off with distance from the
  pickup axis, Phi = 1 / [1 + [x - off]^2]; the coil voltage is dPhi/dt.
  Small x: Phi ~ 1 - [x-off]^2, so a fundamental proportional to the
  voicing offset plus a clean 2nd harmonic - mellow.  Large x reaches the
  curved part of Phi and the harmonics bloom - bark.  A derivative has no
  DC, so no DC blocker [the old tanh pickup needed one, and thumped]. )
dsp: rhodes-pickup | state:RhodesState params:RhodesParams fund tine -- y |
  fund tine f+
    state.vel-amp  params.bark-drive-amt state.bark-env f* 1.0 f+  f*
  f* | x |
  x state.off f- | d |
  1.0  1.0 d d f* f+  f/ | phi |
  phi state.phi-prev f- state.emf-norm f*
  state.noise-rng& noise-step
    params.chiff-amt f* state.bark-env f* state.vel f* f+
  phi -> state.phi-prev
;

( Warmth one-pole lowpass [the amp], then accumulate into out. )
dsp: rhodes-warmth | out state:RhodesState params:RhodesParams x -- |
  state.warm-lp | lp0 |
  lp0  x lp0 f-  params.warm-a f*  f+ | lp |
  lp -> state.warm-lp
  out f@64  lp params.level f* f+  out f!64
;

( io ctx state params -- : one voice tick. Output ACCUMULATES into out. )
dsp: k-rhodes-voice | io ctx state params -- |
  state params rhodes-env
  state params rhodes-fund  state params rhodes-tine | fund tine |
  state params fund tine rhodes-pickup | x |
  io state params x rhodes-warmth
;
