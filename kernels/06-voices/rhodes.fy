( rhodes.fy — Rhodes-type electric piano voice: modal tine + magnetic pickup.

  A Rhodes gets its sound from where the steel tine sits against its
  electromagnetic pickup, not from the tine's spectrum alone:

    * The struck TINE [plus its tonebar] rings as a few modes: two close
      fundamentals that beat slightly [CHORUS], and the clamped-free bar's
      inharmonic 6.267x partial - a short metallic ping on the attack [BELL,
      SNAP].  Decay follows pitch: bass notes ring, top notes die sooner.

    * The PICKUP sees flux Phi = 1/[1 + [x - off]^2] of the tine displacement
      x, and its coil outputs dPhi/dt.  Soft strikes keep x small, so the
      output is a fundamental proportional to the offset plus a clean 2nd
      harmonic - mellow.  Hard strikes [displacement ~ vel^1.4, DRIVE] swing
      into the curved part of Phi and the harmonics bloom - bark.  VOICING
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
  The warmth stage ACCUMULATES into the host-zeroed out buffer.

  Note-on is staged [rn-*] only because the pow2 ladders overflow one
  register budget [docs/17 A3 removes that]. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../04-filters/coeffs.fy"   ( svf-g, svf-damping, svf-dc-coeff )
include "../05-drums/noise.fy"          ( noise-step — hammer chiff )
include "../02-shapers/tanh_table.fy"   ( k-tanh-rational-shape-dsp2 — pickup )
include "../05-drums/sine.fy"           ( sine-shape — modal oscillators )
include "../00-primitives/pow2.fy"      ( exp2/log2 — pitch-dependent decay )

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
  f64 tine-phase  ( 6.267x tine overtone phase )
  f64 noise-rng   ( LCG state for the hammer chiff )
  f64 warm-lp     ( warmth one-pole lowpass state )
  f64 phi-prev    ( pickup flux last sample - the output is its derivative )
  f64 vel-amp     ( tine displacement scale for this strike: vel^1.4 * drive )
  f64 emf-norm    ( sr / [2 pi f0]: derivative gain that keeps level pitch-flat )
  f64 fund-dec-v  ( this note's decay multiplier - lower notes ring longer )
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
  | ctx state params |
  ctx Ctx.sr@ | sr |
  1.0 sr f/ params RhodesParams.inv-sr-p f!64
  sr params RhodesParams.sr-p f!64
  ( attack one-pole rise: tau ~ 2 ms -> corner 79.577 Hz, coef direct )
  sr 79.57747154594767 svf-dc-coeff params RhodesParams.amp-atk-coef-p f!64
  ( fundamental decay: tau = 0.6 + bar-q*6.0 s )
  sr 0.15915494309189535 0.6 params RhodesParams.bar-q@ 6.0 f* f+ f/ svf-dc-coeff
  1.0 swap f- params RhodesParams.fund-dec-coef-p f!64
  ( release: tau = 0.02 + (1-damper)*0.3 s - dampers stop a tine fast )
  sr 0.15915494309189535 0.02 1.0 params RhodesParams.damper@ f- 0.3 f* f+ f/ svf-dc-coeff
  1.0 swap f- params RhodesParams.fund-rel-coef-p f!64
  ( tine ping decay: tau = 0.03 + tine-q*0.25 s - a bright attack, not a drone )
  sr 0.15915494309189535 0.03 params RhodesParams.tine-q@ 0.25 f* f+ f/ svf-dc-coeff
  1.0 swap f- params RhodesParams.tine-dec-coef-p f!64
  ( bark transient decay: tau = 0.02 + bark-decay*0.3 s )
  sr 0.15915494309189535 0.02 params RhodesParams.bark-decay@ 0.3 f* f+ f/ svf-dc-coeff
  1.0 swap f- params RhodesParams.bark-dec-coef-p f!64
  ( detune multiplier: 1 + bar-detune*0.006 (up to ~0.6%) )
  1.0 params RhodesParams.bar-detune@ 0.006 f* f+ params RhodesParams.detune-mul-p f!64
  ( tine ping level in DISPLACEMENT: the pickup's derivative lifts a partial
    at 6.267 f0 by 6.267, so 1/6.267 keeps BELL 1.0 at about the fundamental )
  params RhodesParams.tine-q@ 0.16 f* params RhodesParams.tine-lvl-p f!64
  ( pickup: displacement at full velocity, attack-extra, voicing offset, chiff )
  0.35 params RhodesParams.pickup-drive@ 1.25 f* f+ params RhodesParams.drive-amt-p f!64
  params RhodesParams.bark@ 0.6 f* params RhodesParams.bark-drive-amt-p f!64
  ( offset 0.15..0.75: a centered tine [0] gives no fundamental at all )
  params RhodesParams.voicing@ 0.6 f* 0.15 f+ params RhodesParams.pickup-off-p f!64
  params RhodesParams.bark@ 0.02 f* params RhodesParams.chiff-amt-p f!64
  ( fundamental decay at C3; note-on scales it by pitch )
  0.6 params RhodesParams.bar-q@ 6.0 f* f+ params RhodesParams.fund-tau-p f!64
  ( warmth one-pole: corner 700 + warmth*5300 Hz )
  sr 700.0 params RhodesParams.warmth@ 5300.0 f* f+ svf-dc-coeff params RhodesParams.warm-a-p f!64
  drop2 drop2
;

( ctx state params -- : reset this voice's strike state.  Phases reset
  to 0 so sample 0 is silent; envelopes seed for a fresh strike. )
dsp: rn-reset ( ctx state params -- )
  | ctx state params |
  ctx Ctx.hz@ state RhodesState.note-hz-p f!64
  ctx Ctx.vel@ state RhodesState.vel-p f!64
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
  ( a strike from rest: flux starts at the tine's rest position )
  1.0  1.0 params RhodesParams.pickup-off@ dup f* f+  f/  state RhodesState.phi-prev-p f!64
  drop2 drop
;

( ctx state params -- : log halves of the strike's two pow terms, one
  pow2 ladder per stage [each needs its own register budget]. )
dsp: rn-log-vel ( ctx state params -- )
  | ctx state params |
  ctx Ctx.vel@ 0.0001 1.0 fclamp log2-approx 1.4 f*  state RhodesState.s-fund-p f!64
  drop2 drop
;
dsp: rn-ratio ( ctx state params -- )
  | ctx state params |
  130.81 ctx Ctx.hz@ 20.0 20000.0 fclamp f/  state RhodesState.s-tine-p f!64
  drop2 drop
;
dsp: rn-log-pitch ( ctx state params -- )
  | ctx state params |
  state RhodesState.s-tine@ log2-approx 0.5 f*  state RhodesState.s-tine-p f!64
  drop2 drop
;

( ctx state params -- : displacement scale and pickup gain.  Displacement
  grows faster than velocity [vel^1.4]: hard hits reach the pickup's curved
  region and bark, soft ones stay near-linear and mellow.  dPhi/dt scales
  with frequency; emf-norm divides it back out so level is pitch-flat. )
dsp: rn-velamp ( ctx state params -- )
  | ctx state params |
  state RhodesState.s-fund@ exp2-approx params RhodesParams.drive-amt@ f*
    state RhodesState.vel-amp-p f!64
  params RhodesParams.sr@ 6.283185307179586 ctx Ctx.hz@ f* f/  state RhodesState.emf-norm-p f!64
  drop2 drop
;

( ctx state params -- : this note's decay.  tau ~ fund-tau * [C3/f]^0.5:
  bass notes ring, top notes die sooner, as tines shorten. )
dsp: rn-tau ( ctx state params -- )
  | ctx state params |
  state RhodesState.s-tine@ exp2-approx params RhodesParams.fund-tau@ f*
    state RhodesState.s-tine-p f!64
  drop2 drop
;
dsp: rn-decay ( ctx state params -- )
  | ctx state params |
  params RhodesParams.sr@ 0.15915494309189535 state RhodesState.s-tine@ f/ svf-dc-coeff 1.0 swap f-
    state RhodesState.fund-dec-v-p f!64
  drop2 drop
;

( ctx state params -- : strike this voice. )
dsp: rhodes-note-on ( ctx state params -- )
  | ctx state params |
  ctx state params call: rn-reset
  ctx state params call: rn-log-vel
  ctx state params call: rn-ratio
  ctx state params call: rn-log-pitch
  ctx state params call: rn-velamp
  ctx state params call: rn-tau
  ctx state params call: rn-decay
;

( ctx state params -- : release this voice — the damper engages. )
dsp: rhodes-note-off
  | ctx state params |
  state RhodesState.age@ state RhodesState.gate-time-p f!64
  drop2 drop
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
    state RhodesState.fund-dec-v@ params RhodesParams.fund-rel-coef@ fsel-lt
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

( state params -- : the electromagnetic pickup.  x is the tine's
  displacement at the pickup [velocity-scaled modes plus a bark boost on
  the attack]; the flux through the coil falls off with distance from the
  pickup axis, Phi = 1 / [1 + [x - off]^2]; the coil voltage is dPhi/dt.
  Small x: Phi ~ 1 - [x-off]^2, so a fundamental proportional to the
  voicing offset plus a clean 2nd harmonic - mellow.  Large x reaches the
  curved part of Phi and the harmonics bloom - bark.  A derivative has no
  DC, so no DC blocker [the old tanh pickup needed one, and thumped]. )
dsp: rhodes-pickup
  | state params |
  state RhodesState.s-fund@ state RhodesState.s-tine@ f+
    state RhodesState.vel-amp@
    params RhodesParams.bark-drive-amt@ state RhodesState.bark-env@ f* state RhodesState.vel@ f* f+
  f* | x |
  x params RhodesParams.pickup-off@ f- | d |
  1.0  1.0 d d f* f+  f/ | phi |
  phi state RhodesState.phi-prev@ f- state RhodesState.emf-norm@ f*
  state RhodesState.noise-rng-p noise-step
    params RhodesParams.chiff-amt@ f* state RhodesState.bark-env@ f* state RhodesState.vel@ f* f+
  state RhodesState.s-pre-p f!64
  phi state RhodesState.phi-prev-p f!64
  drop2 drop2 drop
;

( out state params -- : warmth one-pole lowpass [the amp], then
  accumulate.  Reads its own new value from a local: stores land at the
  end of the word. )
dsp: rhodes-warmth
  | out state params |
  state RhodesState.warm-lp@ | lp0 |
  lp0  state RhodesState.s-pre@ lp0 f-  params RhodesParams.warm-a@ f*  f+ | lp |
  lp state RhodesState.warm-lp-p f!64
  out f@64  lp params RhodesParams.level@ f* f+  out f!64
  drop2 drop2 drop
;

( io ctx state params -- : one voice tick, staged. Output ACCUMULATES into out.
  Each call: boundary is a fresh register budget. )
dsp: k-rhodes-voice
  | io ctx state params |
  state params call: rhodes-env
  state params call: rhodes-fund
  state params call: rhodes-tine
  state params call: rhodes-pickup
  io state params call: rhodes-warmth
;
