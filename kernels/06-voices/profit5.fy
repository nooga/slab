( profit5.fy - Consequential Circuits Profit-5: a Prophet-5 style
  2-VCO poly voice, with an Oberheim SEM filter behind a switch.

    OSC B [saw tri pulse, LO FREQ, KBD] --+----------------.
      |  POLY-MOD: filter env + OSC B     |                 |
      v  -> FREQ A, PW A, FILTER          |                 |
    OSC A [saw pulse, SYNC to B] ---------+-> mix + noise -> droop HP
                                                -> P5 4-pole | OB 12 dB
    VCA out -> FEEDBACK -> back into the mix        -> hb9 -> VCA -> out

  Rates: the oscillators run at 4x [hb4 down to 2x], the filter at 2x
  [hb9 down to 1x], the envelopes, LFO, glide and coefficients once per
  sample.  POLY-MOD reaches OSC A's frequency and width at 4x, so B -> A
  is true audio-rate FM; its cutoff leg reads B once per sample.

  POLY-MOD is the Prophet's idea: two sources, the filter envelope and
  OSC B, each with its own amount, summed and sent to any of FREQ A, PW A
  and FILTER.  Env -> FREQ A with SYNC on is the sync sweep; B -> FREQ A
  is FM, bells and clang.  WHEEL-MOD is the performance LFO: SAW, TRI or
  SQR, crossfaded into noise by MIX, to FREQ A, FREQ B, PW A, PW B,
  FILTER; the Prophet's wheel is our AMOUNT knob.

  Past the Prophet [an ex-Korg tube designer's tips]:
  - the P5 filter's resonance loop goes through a lopsided tanh and a
    7 Hz coupling cap [ota_cascade.fy];
  - HEAT: |filter out| through an asymmetric 3 Hz / 1 Hz follower heats
    the voice: the filter input biases off-centre [even harmonics], drives
    harder and the cutoff sags a little.  Bass notes squeeze;
  - FEEDBACK: the VCA output fed back into the mix, as players patched
    a Minimoog's output into its own input.  Past about 0.8 the loop has
    gain in the band and the voice growls and sputters;
  - AGE also bleeds the filter envelope into the audio, the thump real
    envelope CV leaves in the signal path.

  The oscillators are analog-ish [vco.fy]: AGE bows each voice's saws
  toward the capacitor ramp by a different amount, spreads their pulse
  widths, pitches and cutoffs, and the droop highpass sags low pulse
  tops.  SYNC resets have no BLEP; at 4x most of the edge's aliases land
  where hb4 removes them. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../00-primitives/oversample.fy"
include "../01-oscillators/primitives/phase.fy"
include "../01-oscillators/primitives/blep.fy"
include "../01-oscillators/primitives/vco.fy"
include "../03-envelopes/primitives/env_rc.fy"
include "../04-filters/ota_cascade.fy"
include "../04-filters/sem_svf.fy"
include "../08-analog/analog.fy"

ustruct: P5State
  f64 pha  f64 phb
  f64 vel
  f64 oct  f64 target-oct
  f64 noise-rng
  f64 lfo-ph
  f64 bsum           ( OSC B's last output: the filter leg of POLY-MOD )
  f64 heat
  f64 y-prev         ( VCA output, for FEEDBACK )
  f64 dro-x  f64 dro-y
  f64 dc-x  f64 dc-y
  f64 curve-a  f64 curve-b      ( per-voice saw bow, from AGE )
  f64 pw-spread
  f64 cut-spread
  f64 pitch-spread              ( ratio )
  EnvRc f-env
  EnvRc a-env
  OtaCascade ota
  SemSvf sem
  Hb4 h4
  Hb9 h9
  Drift dra  Drift drb  Drift drc
;

ustruct: P5Params
  ( POLY-MOD )
  f64 pm-fenv  f64 pm-oscb           ( source amounts 0..1 )
  f64 pm-dfa  f64 pm-dpw  f64 pm-dfl ( destinations, switches 0/1 )
  ( OSC A )
  f64 freq-a                         ( semitones, int )
  f64 saw-a  f64 pul-a  f64 pw-a  f64 sync
  ( OSC B )
  f64 freq-b  f64 fine-b             ( semitones int, fine semitones )
  f64 saw-b  f64 tri-b  f64 pul-b  f64 pw-b
  f64 lo-b  f64 kbd-b
  ( WHEEL-MOD )
  f64 lfo-rate  f64 lfo-wave  f64 wm-mix  f64 wm-amt
  f64 wm-dfa  f64 wm-dfb  f64 wm-dpa  f64 wm-dpb  f64 wm-dfl
  ( MIXER )
  f64 lvl-a  f64 lvl-b  f64 lvl-n
  ( FILTER )
  f64 ftype                          ( 0 P5, 1 OB, 2 OB BP )
  f64 cutoff  f64 res  f64 env-amt  f64 kbd  f64 drive  f64 mode
  f64 f-atk f64 f-dec f64 f-sus f64 f-rel
  f64 a-atk f64 a-dec f64 a-sus f64 a-rel
  ( OUT )
  f64 glide  f64 vel-amt  f64 heat-amt  f64 fbk  f64 age-amt  f64 level
  ( derived by p5-block-prepare )
  f64 inv-osr4
  f64 osr2
  f64 glide-c
  f64 ratio-a  f64 ratio-b
  f64 b-kbd  f64 b-fixed             ( OSC B pitch: kbd-b * note + b-fixed )
  f64 pm-freq  f64 pm-pw  f64 pm-filt
  f64 wm-fa  f64 wm-fb  f64 wm-pa  f64 wm-pb  f64 wm-filt
  f64 lfo-inc
  f64 env-oct
  f64 lad-in  f64 lad-out
  f64 hp-a  f64 dro-a  f64 dc-a
  f64 heat-up  f64 heat-dn
  f64 lpw  f64 hpw  f64 bpw  f64 is-ob
  f64 drift-c  f64 cut-drift-c
  f64 bleed
  f64 fb-g
  f64 pm-norm                        ( 1 / OSC A's mean speed-up under B's FM )
  f64 ob-comp                        ( OB output trim: the SVF's resonant peak )
  EnvRcCoefs f-co
  EnvRcCoefs a-co
;

( ctx state params -- )
dsp: p5-block-prepare | ctx:Ctx state params:P5Params -- |
  ctx.sr | sr |
  ctx.inv-sr | inv |
  1.0 sr 4.0 f* f/ -> params.inv-osr4
  sr 2.0 f* | osr2 |
  osr2 -> params.osr2
  params.glide 0.001  1.0
    1.0  -3.0  params.glide sr f* f/  exp  f-
  fsel-lt -> params.glide-c
  params.freq-a 0.08333333333333333 f* exp2 -> params.ratio-a
  params.freq-b params.fine-b f+ 0.08333333333333333 f* exp2
    params.lo-b 0.5  1.0 0.0078125  fsel-lt  f* | rb |
  rb -> params.ratio-b
  ( KBD off: B holds the pitch its knob sets from middle C )
  params.kbd-b 0.5  0.0 1.0  fsel-lt | kb |
  kb -> params.b-kbd
  1.0 kb f-  261.6255653 f*  rb f* -> params.b-fixed
  params.pm-dfa 4.0 f* -> params.pm-freq
  params.pm-dpw 0.45 f* -> params.pm-pw
  params.pm-dfl 4.0 f* -> params.pm-filt
  ( Exponential FM speeds A up more than it slows it down: over one B
    cycle A runs sharp by the mean of 2^[d b], and its partials land
    between the harmonics.  Divide that mean out so A keeps its pitch and
    B -> A stays tonal at whole ratios.  A saw or triangle spends equal
    time at every level: mean = [2^d - 2^-d] / [2 d ln2].  A lone pulse
    sits at +1 for PW and -1 for the rest: PW 2^d + [1 - PW] 2^-d.  A
    mix of waves spans wider; treat it as uniform over its sum. )
  params.saw-b params.tri-b f+ | st |
  st params.pul-b f+ | nw |
  params.pm-oscb params.pm-freq f*  nw 1.0 fmax f*  0.000001 fmax | d |
  d exp2 | up |
  1.0 up f/ | dn |
  up dn f-  d 1.3862943611198906 f* f/ | mu-u |
  params.pm-oscb params.pm-freq f* exp2 | pu |
  params.pw-b pu f*  1.0 params.pw-b f-  1.0 pu f/ f*  f+ | mu-p |
  st 0.5  params.pul-b 0.5  1.0 mu-p fsel-lt  mu-u  fsel-lt | mu |
  1.0 mu f/ -> params.pm-norm
  params.wm-amt | wa |
  params.wm-dfa wa f* -> params.wm-fa
  params.wm-dfb wa f* -> params.wm-fb
  params.wm-dpa wa f* 0.4 f* -> params.wm-pa
  params.wm-dpb wa f* 0.4 f* -> params.wm-pb
  params.wm-dfl wa f* 3.0 f* -> params.wm-filt
  params.lfo-rate inv f* -> params.lfo-inc
  params.env-amt 7.0 f* -> params.env-oct
  ( DRIVE 0..1 -> 0.25x .. 16x into the filter; the makeup undoes the
    filter's large-signal gain, as in Cream )
  params.drive 6.0 f* 2.0 f- exp2 0.125 f* | a |
  a -> params.lad-in
  0.5  a 0.125 fmax 1.6129032258064515 f* tanh 0.62 f*  f/ -> params.lad-out
  3.0 osr2 ota-hp-coef -> params.hp-a
  25.0 osr2 ota-hp-coef -> params.dro-a
  10.0 sr ota-hp-coef -> params.dc-a
  18.84955592 inv f* -> params.heat-up     ( 3 Hz )
  6.283185307 inv f* -> params.heat-dn     ( 1 Hz )
  params.ftype | ft |
  ft 0.5  0.0 1.0  fsel-lt -> params.is-ob
  ft 1.5  1.0 params.mode f-  0.0  fsel-lt -> params.lpw
  ft 1.5  params.mode  0.0  fsel-lt -> params.hpw
  ft 1.5  0.0 1.0  fsel-lt -> params.bpw
  0.35 inv drift-coef -> params.drift-c
  0.15 inv drift-coef -> params.cut-drift-c
  params.age-amt 0.06 f* -> params.bleed
  params.fbk 2.5 f* -> params.fb-g
  ( the SVF peaks by Q = 1/[2d] where the P5 thins: trim the OB by
    sqrt[Q0 / Q], Q0 = 0.707 )
  params.res -6.0 f* exp2 1.4142135623730951 f* 1.0 fmin fsqrt -> params.ob-comp
  params.f-co&  params.f-atk params.f-dec params.f-sus params.f-rel  0.0 0.0  inv env-rc-coefs
  params.a-co&  params.a-atk params.a-dec params.a-sus params.a-rel  0.0 0.0  inv env-rc-coefs
;

( ctx state params -- : a voice glides from wherever it last played; a
  fresh one starts on pitch.  Oscillators free-run. )
dsp: p5-note-on | ctx:Ctx state:P5State params:P5Params -- |
  ctx.hz 1.0 fmax log2 | o |
  o -> state.target-oct
  state.oct 1.0  o  state.oct  fsel-lt -> state.oct
  ctx.chan | v |
  state.dra& v 1.0 f+ drift-seed-once
  state.drb& v 11.0 f+ drift-seed-once
  state.drc& v 23.0 f+ drift-seed-once
  ( AGE: this voice's parts, the same way every time )
  params.age-amt | ag |
  v 1.0 spread 0.5 f* 0.5 f+  ag f* 0.35 f* -> state.curve-a
  v 2.0 spread 0.5 f* 0.5 f+  ag f* 0.35 f* -> state.curve-b
  v 3.0 spread ag f* 0.03 f* -> state.pw-spread
  v 4.0 spread ag f* 0.15 f* exp2 -> state.cut-spread
  v 5.0 spread ag f* 0.0025 f* exp2 -> state.pitch-spread
  state.f-env& params.f-co& ctx.legato env-rc-trigger
  state.a-env& params.a-co& ctx.legato env-rc-trigger
  ctx.vel -> state.vel
;

( ctx state params -- : note expression retunes the voice. )
dsp: p5-note-expr | ctx:Ctx state:P5State params:P5Params -- |
  ctx.hz 1.0 fmax log2 | o |
  o -> state.target-oct
  o -> state.oct
;

( ctx state params -- )
dsp: p5-note-off | ctx state:P5State params:P5Params -- |
  state.f-env& params.f-co& env-rc-release
  state.a-env& params.a-co& env-rc-release
;

( one 4x substep: OSC B leads [it is the sync master and the POLY-MOD
  source], then OSC A, modulated and synced by it. )
dsp: p5-osc | state:P5State params:P5Params dta dtb fterm pwa pwb nz -- x |
  state.phb dtb f+ | qb |
  qb wrap01 | pb |
  pb -> state.phb
  1.0 qb f<= | wrapped |
  ( the switches are 0 or 1: a wave switched off isn't computed )
  pb dtb state.curve-b vco-saw params.saw-b f*
  params.tri-b 0.0 f=  [ 0.0 ]  [ pb tri-raw params.tri-b f* ]  ifte f+
  params.pul-b 0.0 f=  [ 0.0 ]  [ pb dtb pwb pulse-polyblep params.pul-b f* ]  ifte f+ | b |
  b -> state.bsum
  fterm  b params.pm-oscb f*  f+ | pm |
  dta  pm params.pm-freq f* exp2  f*  params.pm-norm f* | da |
  state.pha da phase-advance01 | pfree |
  params.sync 0.5 f>  wrapped and
    pb da f* dtb f/ ffrac  pfree  select | pa |
  pa -> state.pha
  pwa  pm params.pm-pw f*  f+  0.02 0.98 fclamp | wa |
  pa da state.curve-a vco-saw params.saw-a f*
  params.pul-a 0.0 f=  [ 0.0 ]  [ pa da wa pulse-polyblep params.pul-a f* ]  ifte f+
  params.lvl-a f*
  b params.lvl-b f* f+
  nz params.lvl-n f* f+
;

( one 2x filter step: the coupling cap, the extra drive, then the P5
  cascade or the SEM, whichever FILTER picks. )
dsp: p5-filt | state:P5State params:P5Params x extra dmul g k sg sd -- y |
  x state.dro-x state.dro-y params.dro-a droop-hp | xd |
  x -> state.dro-x
  xd -> state.dro-y
  xd extra f+  params.lad-in dmul f* f* | xin |
  ( FILTER is a mode: only its filter runs; the other holds its state )
  params.is-ob 0.5 f<
  [ state.ota& xin g k params.hp-a ota-step ]
  [ state.sem& xin sg sd params.lpw params.hpw params.bpw sem-step params.ob-comp f* ]  ifte
;

( io ctx state params -- : one output sample. )
dsp: k-p5-voice | io ctx state:P5State params:P5Params -- |
  ( WHEEL-MOD: SAW TRI SQR, crossfaded into noise )
  state.lfo-ph params.lfo-inc f+ ffrac | lp |
  lp -> state.lfo-ph
  state.noise-rng 1103515245.0 f* 0.31337 f+ ffrac | r |
  r -> state.noise-rng
  r 2.0 f* 1.0 f- | nz |
  params.lfo-wave 0.5
    lp 2.0 f* 1.0 f-
    params.lfo-wave 1.5
      lp 0.5 f- fabs 4.0 f* 1.0 f-
      lp 0.5  1.0 -1.0  fsel-lt
    fsel-lt
  fsel-lt | lfo |
  lfo  nz lfo f- params.wm-mix f*  f+ | wm |
  ( glide in octaves )
  state.oct  state.target-oct state.oct f-  params.glide-c f*  f+ | oct |
  oct -> state.oct
  oct exp2 state.pitch-spread f* | hz |
  params.age-amt 0.0035 f* | dscale |
  state.dra& params.drift-c drift-step dscale f* 1.0 f+ | d1 |
  state.drb& params.drift-c drift-step dscale f* 1.0 f+ | d2 |
  state.f-env& params.f-co& env-rc-step | fenv |
  state.a-env& params.a-co& env-rc-step | aenv |
  1.0  params.vel-amt  1.0 state.vel f-  f*  f- | vg |
  fenv vg f* | fe |
  ( oscillator increments at 4x )
  hz params.ratio-a f* d1 f*  wm params.wm-fa f* exp2 f*  params.inv-osr4 f* | dta |
  hz params.b-kbd f* params.ratio-b f*  params.b-fixed f+  d2 f*
    wm params.wm-fb f* exp2 f*  params.inv-osr4 f* | dtb |
  fe params.pm-fenv f* | fterm |
  params.pw-a  wm params.wm-pa f*  f+  state.pw-spread f+  0.02 0.98 fclamp | pwa |
  params.pw-b  wm params.wm-pb f*  f+  state.pw-spread f-  0.02 0.98 fclamp | pwb |
  ( HEAT: 0..1 from the follower, scaled by the knob )
  state.heat 4.0 f* tanh-fast params.heat-amt f* | hv |
  ( cutoff, in octaves )
  fe params.env-oct f*
  oct 8.031359713524661 f-  params.kbd f*  f+
  state.drc& params.cut-drift-c drift-step  params.age-amt 0.07 f* f*  f+
  wm params.wm-filt f*  f+
  fterm  state.bsum params.pm-oscb f*  f+  params.pm-filt f*  f+
  hv -0.7 f*  f+
  exp2 params.cutoff f* state.cut-spread f* | fc |
  ( x1.08: RES 1 oscillates at every cutoff, like a Prophet at full )
  params.is-ob 0.5 f<
  [ fc params.osr2 params.res 1.08 f* ota-coeffs  0.0 0.0 ]
  [ 0.0 0.0  fc params.osr2 params.res sem-coeffs ]  ifte | g k sg sd |
  ( into the filter: FEEDBACK from the last output, the heat's bias and
    the envelope's bleed )
  state.y-prev params.fb-g f* | fbx |
  ( and a noise floor, -86 dB: what starts a self-oscillation )
  hv 0.6 f*  fenv params.bleed f*  f+  nz 0.0001 f* f+ | extra |
  1.0 hv 2.0 f* f+ | dmul |
  state.h9&
    state.h4&
      state params dta dtb fterm pwa pwb nz p5-osc fbx f+
      state params dta dtb fterm pwa pwb nz p5-osc fbx f+
    hb4-dec | x0 |
    state params x0 extra dmul g k sg sd p5-filt
    state.h4&
      state params dta dtb fterm pwa pwb nz p5-osc fbx f+
      state params dta dtb fterm pwa pwb nz p5-osc fbx f+
    hb4-dec | x1 |
    state params x1 extra dmul g k sg sd p5-filt
  hb9-dec  params.lad-out f* | y |
  ( the heat follows the filter's output: up in ~50 ms, down in ~150 )
  y fabs | ya |
  state.heat | h |
  h  ya h f-  h ya  params.heat-up params.heat-dn  fsel-lt  f*  f+ -> state.heat
  y aenv f* | yv |
  yv -> state.y-prev
  yv vg f* params.level f* 2.0 f* | x |
  x state.dc-x state.dc-y params.dc-a droop-hp | o |
  x -> state.dc-x
  o -> state.dc-y
  io f@64 o f+ io f!64
;
