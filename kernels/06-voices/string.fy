( string.fy — plucked-string voice: a digital waveguide [Karplus-Strong as
  Jaffe and Smith extended it], tuned for electric bass.

  One delay loop per voice holds the traveling velocity wave.  Each sample:

    ring read at w - D [Lagrange, 4 taps]
      -> loss shelf [decay per partial]
      -> 16 dispersion allpasses [stiffness: upper partials run sharp]
      -> + excitation  -> the frets [a one-sided stop]  -> ring write at w

    loop signal - itself pickup-pos periods ago [pickup comb]
      -> pickup resonance [2-pole LP] -> out

  What makes it sound like a string rather than a pluck-and-fade toy.
  Each was fitted against a sampled roundwound bass [Karoryfer
  fashionbass, neck pickup, DI] with tools/fit/string_fit.py:

    * DECAY sets the T60 of the low partials, HF DEC the T60 of those
      above KNEE [a harmonic number].  See string-tune.
    * STIFF is the inharmonicity B at D1 [x 1e-4], key-tracked as
      1/sqrt f; the measured bass is about 3.6 at D1 and 2.2 at D3.  The
      tuning subtracts the loss shelf's and the allpasses' phase delay at
      f0, so notes measure within a few cents.
    * HAND picks the string a note is played on [st-fret], which moves the
      pluck and pickup points along the vibrating length.
    * The excitation is a smooth velocity pulse, the finger's push and
      release, minus itself one pluck delay later.  Measured finger plucks
      [neck pickup, DI] look like this: a smooth bump a few ms wide, and an
      attack spectrum near flat to the 12th harmonic with notches at
      multiples of 1/POS.  SOFT is the pulse width.  SHAPE crossfades to a
      smoothed velocity STEP instead [a rectangle as long as the pluck
      point's share of the period, the ideal plucked string, 1/n]: a
      pick's or a pop's harder, rounder push.
    * The pickup sees the wave at its own point: a second comb [PICKUP
      POS], which also removes the loop's DC.
    * THUMP: tension modulation.  The loop shortens with displacement
      squared [the velocity follower over f], so a hard pluck starts sharp
      and settles as it decays.  At 0.5 it matches the measured bass: a
      hard low D starts ~50 cents sharp, a D3 ~7.
    * BUZZ: the frets.  The string's displacement over the last fret
      cannot pass it; the wave that would carry it past is reflected, so
      a string that swings wide rattles, each period, until it has lost
      enough.  BUZZ is how close the frets sit.  SLAP is a thumb's weight
      behind the pulse: it drives the string onto the fret and is stopped
      there, which is the click.  A pluck [SHAPE 1] from the far side
      meets the frets half a period later: a pop.  With SLAP up, notes
      on the upper half of the strings are popped and the rest thumbed.

  A note-on mutes the old note's content: for one loop length the
  feedback is masked, so the ring refills with the new excitation, while
  the old read fades out on the output over 64 samples.

  Polyphony: the ring is a host buffer per voice [manifest `buffer`], so
  every voice owns its own string.  Voices ACCUMULATE into io.out-l. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../00-primitives/rand.fy"
include "../04-filters/coeffs.fy"
include "../04-filters/tpt_svf.fy"

ustruct: StringState
  f64 buf       ( host ring base pointer )
  f64 buf-len   ( host ring cells )
  f64 w         ( write index )
  f64 dl        ( loop delay in samples, gliding to dl-tgt )
  f64 dl-tgt
  f64 hz
  f64 vel
  f64 age       ( samples since note-on )
  f64 et        ( samples since the excitation began: note-on or a legato note )
  f64 gate      ( 1 held, 0 released )
  f64 clear-n   ( feedback masked while age < clear-n )
  f64 g-hi      ( loss shelf: per-period gain above the knee )
  f64 g-dif     ( gain below the knee minus g-hi )
  f64 g-rel     ( flat per-period gain once released )
  f64 la        ( loss shelf one-pole coefficient )
  f64 lp1
  f64 apc       ( dispersion allpass coefficient )
  f64 apx 16    ( dispersion allpass states )
  f64 apy 16
  f64 amp       ( excitation level from velocity )
  f64 inv-w     ( 1 / excitation width in samples )
  f64 pu-g      ( pulse level: narrow pulses carry less energy )
  f64 pd        ( pluck comb delay, samples )
  f64 pk        ( pickup comb delay, samples )
  f64 nz-env
  f64 nz-k
  f64 rng
  f64 tens      ( amplitude follower for THUMP )
  f64 th-k      ( THUMP: delay shortening per tens^2, this note )
  f64 s1  f64 s2  ( pickup resonance )
  f64 p0        ( MIDI pitch at note-on: where bends and slides start )
  f64 slid      ( 1 once this note's pitch motion is a slide [AUTO latches] )
  f64 q         ( the slide's fret offset from p0, semitones )
  f64 sl-env    ( slide noise: fret crossings and finger speed )
  f64 sl-rng
  f64 sl-hp  f64 sl-lp
  f64 vib-t     ( finger vibrato depth asked for, 0..1 [expression slide] )
  f64 vib       ( the depth, smoothed )
  f64 vib-ph
  ( pickups and bridge [string_body.fy] )
  f64 si        ( string the note is on, 0 = lowest )
  f64 z         ( string impedance relative to the low string: ref-hz / open hz )
  f64 pn1 f64 pn2   ( neck pickup taps, samples )
  f64 pb1 f64 pb2   ( bridge pickup taps )
  f64 xn f64 xb     ( string displacement over each pickup, for HEIGHT )
  f64 nw        ( this sample's ring write, for the pickup stage )
  f64 wc        ( the index it was written at )
  f64 yb        ( the wave arriving at the bridge this sample )
  f64 fade      ( the old note's read, fading out )
  ( the frets [BUZZ] )
  f64 yc        ( string displacement over the last fret, velocity-samples )
  f64 cd        ( that fret's comb delay, samples )
  f64 ch        ( the gap to it )
  f64 cl        ( displacement leak: the string's rest position is found again )
  f64 tg        ( thumb: the pulse's drive, x a finger's )
  f64 el        ( thumb: how far it carries the string before the fret stops it )
  f64 e1 f64 e2 ( thumb: how far the pulse and its echo have carried it )
  f64 pg        ( pluck: its level with frets in reach, x the free pluck's )
  f64 shp       ( this note's SHAPE: 1 when SLAP pops it )
;

ustruct: StringParams
  ( user-facing )
  f64 decay      ( s: T60 of the low partials at E1, key-tracked )
  f64 hf-decay   ( s: T60 of the partials above the knee at E1 )
  f64 knee       ( harmonic where the decay turns from DECAY to HF DEC )
  f64 stiff      ( inharmonicity B at D1, x 1e-4 )
  f64 release    ( s: T60 once the note is released [finger mute] )
  f64 pos        ( pluck point, fraction of the open string from the bridge )
  f64 soft       ( ms: excitation rise time at mid velocity )
  f64 shape      ( 0 pulse [finger] .. 1 step [pick, pop] )
  f64 noise      ( finger noise into the string )
  f64 pickup     ( pickup point, fraction of the open string from the bridge )
  f64 hand       ( fretting-hand position, fret 0..12: picks the string )
  f64 tone       ( Hz: pickup resonance )
  f64 res        ( pickup resonance peak 0..1 )
  f64 thump      ( tension modulation 0..1 )
  f64 buzz       ( fret buzz 0..1 )
  f64 level
  f64 motion     ( 0 AUTO, 1 BEND, 2 SLIDE: what a note's pitch curve does )
  f64 slide      ( 0..1 slide noise: the finger on the windings, fret ticks )
  f64 vib-rate   ( Hz: finger vibrato )
  f64 vib-depth  ( semitones at full depth: how far the finger bends the string )
  f64 sel        ( pickup selector: 0 NECK, 1 BOTH, 2 BRIDGE, 3 BOTH out of phase )
  f64 pickup-b   ( bridge pickup point, fraction of the open string from the bridge )
  f64 type-n     ( neck pickup: 0 SINGLE, 1 WIDE [P-90], 2 HUMBUCK, 3 SPLIT )
  f64 type-b     ( bridge pickup )
  f64 height     ( 0..1 how close the magnets sit: output and magnetic pull )
  f64 tpot       ( tone pot 0..1; 1 is open and unloaded )
  f64 vol        ( volume pot 0..1 )
  f64 body       ( body: index into this instrument's bodies )
  f64 couple     ( bridge coupling, x the body's own )
  f64 air        ( the body's radiated sound, mixed in )
  f64 piezo      ( an under-saddle piezo: the bridge force, mixed in )
  f64 symp       ( the open strings ringing in sympathy, 0..1 )
  f64 slap       ( 0..1 a thumb's weight behind the pulse: it drives the string onto the frets )
  ( the instrument, set by the machine [const-f64] )
  f64 ref-hz     ( the pitch HF DEC, SOFT and THUMP are stated at: the low string )
  f64 b-ref      ( the pitch STIFF's B is stated at )
  f64 hf-track   ( HF DEC scales as [ref-hz / f]^hf-track: 0.75 a bass, 0 a guitar )
  f64 out-g      ( output gain: LEVEL 0.55 sits with the other instruments )
  f64 o1 f64 o2 f64 o3 f64 o4 f64 o5 f64 o6   ( open strings, low to high, Hz; unused 1e9 )
  f64 n-str      ( strings on the instrument )
  f64 body-base  ( this instrument's first body in the body tables )
  f64 coil-k     ( pickup coil widths and spacing, x the guitar's: the scale's share )
  f64 l-coil     ( H: a single coil's inductance )
  f64 r-coil     ( ohm: its resistance )
  f64 c-tone     ( F: the tone capacitor )
  ( derived — string-block-prepare )
  f64 sr
  f64 inv-sr
  f64 pk-g
  f64 pk-d
  f64 tens-a
  f64 sl-hpa  f64 sl-lpa  f64 sl-dec
  f64 vib-inc  f64 vib-a
  f64 on1 f64 on2 f64 ob1 f64 ob2   ( tap offsets per pickup, fraction of the string )
  f64 split-n f64 split-b           ( 1 if that pickup is a split coil )
  f64 wn f64 wb       ( selector weights: each pickup's share of the output )
  f64 ht-k f64 ht-a   ( HEIGHT: magnetic pull per displacement, displacement leak )
  f64 l-eff           ( the selected coils' inductance, x a single coil's )
;


( The body every string shares [string_body.fy]: the bridge, the body's
  modes, the wiring and the open strings.  Voices add their bridge force
  and pickup signal; the body word [period 1] reads them, steps, and
  clears them. )
:: BM 48 ;       ( body modes: 8 measured-style low modes, 40 dense )
:: BMF 48.0 ;
:: SYM-N 6 ;     ( open strings ringing in sympathy, at most )
:: SYM-RL 4096 ; ( cells per open string's ring )
:: SYM-RLF 4096.0 ;
ustruct: FwBody
  f64 f      ( bridge force this step: voices and open strings add )
  f64 pu     ( pickup signal this step: voices and open strings add )
  f64 vb     ( bridge velocity the last step left )
  f64 vba    ( bridge velocity being summed )
  f64 rada   ( radiated sound being summed )
  f64 mute 8 ( a note is on that string: its open ring stops )
  f64 q 48  f64 v 48   ( body modes: displacement, velocity at the bridge )
  f64 mc 48  f64 msw 48  f64 mws 48  f64 mrho 48  f64 mb1 48  f64 mb2 48
  f64 mal 48 ( drive per unit force: 2 sigma x the mode's peak coupling )
  f64 mr 48  ( radiation weight )
  f64 ea1 f64 ea2 f64 ea3 f64 eb0 f64 eb1 f64 eb2 f64 eb3   ( wiring, tone pot down )
  f64 eg f64 ed   ( wiring, tone pot open: the pickup's resonance )
  f64 e1 f64 e2 f64 e3   ( wiring states )
  f64 s1 f64 s2
  f64 vl f64 va f64 vg   ( volume pot: cable lowpass state, coefficient, gain )
  f64 pz-lp f64 pz-a     ( piezo: DC block )
  f64 rf-lp f64 rf-a f64 rflat   ( the body's flat radiation above its modes )
  f64 rv     ( radiating velocity, the last step's )
  f64 air-g f64 pz-g f64 mag-g    ( output gains )
  f64 sw 8  f64 sd 8  f64 sg 8  f64 sla 8  f64 slp 8  f64 sz 8  f64 spn 8  f64 spb 8
  ( the open strings' rings follow the struct: SYM-N x SYM-RL cells,
    FW-RING-BYTES, at FwBody.size [a ustruct tops out at 64 KB] )
;
:: FW-RING-BYTES 196608 ;

( |x| <= 1: atan to ~1e-5 rad, enough for phase-delay tuning. )
dsp: st-atan-small | x -- y |
  x x f* | z |
  z -0.0117212 f* 0.05265332 f+ z f* -0.11643287 f+ z f* 0.19354346 f+
    z f* -0.33262347 f+ z f* 0.99997726 f+ x f*
;

dsp: st-atan | x -- y |
  x fabs 1.0 f> | big |
  big  1.0 x f/  x  select  st-atan-small | r |
  big
    x 0.0 f< -1.5707963267948966 1.5707963267948966 select r f-
    r
  select
;

( type -- offset : a coil type's taps either side of its centre, as a
  fraction of the guitar's open string: a wide P-90 bobbin's edges, a
  humbucker's two coils 18 mm apart; a single coil and a split coil are
  one point. )
dsp: st-coil-off | t -- o |
  t 0.5 f> t 1.5 f< and  0.018  t 1.5 f> t 2.5 f< and 0.014 0.0 select  select
;

( type -- l : a coil type's inductance, x a single coil's. )
dsp: st-coil-l | t -- l |
  t 0.5 f> t 1.5 f< and  1.8  t 1.5 f> t 2.5 f< and 1.8  t 2.5 f> 1.4 1.0 select  select  select
;

( HEIGHT: magnetic pull per unit displacement at full height )
:: HT-K 600.0 ;

dsp: st-prep-core | ctx:Ctx state params:StringParams |
  ctx.sr | sr |
  sr -> params.sr
  1.0 sr f/ -> params.inv-sr
  params.tone sr svf-g -> params.pk-g
  ( d 0.7 [flat] down to 0.12 [Q ~4] )
  0.7 params.res 0.64 f* f- -> params.pk-d
  ( THUMP follower: ~8 ms )
  sr 20.0 svf-dc-coeff -> params.tens-a
  ( slide noise: the windings' rasp, 700 Hz - 5 kHz, a 15 ms tick )
  sr 700.0 svf-dc-coeff -> params.sl-hpa
  sr 5000.0 svf-dc-coeff -> params.sl-lpa
  -1.0 0.015 sr f* f/ exp -> params.sl-dec
  params.vib-rate params.inv-sr f* -> params.vib-inc
  ( vibrato depth follows its curve over ~30 ms: the 32-sample steps vanish )
  sr 5.0 svf-dc-coeff -> params.vib-a
  ( the pickups: each type's tap offsets, inductance and output, then
    the selector.  Two coils in parallel split the signal by inductance:
    each is heard in the share of the other's. )
  params.type-n st-coil-off params.coil-k f* | on |
  on fneg -> params.on1  on -> params.on2
  params.type-b st-coil-off params.coil-k f* | ob |
  ob fneg -> params.ob1  ob -> params.ob2
  params.type-n 2.5 f> mask>f -> params.split-n
  params.type-b 2.5 f> mask>f -> params.split-b
  params.type-n st-coil-l | ln |  params.type-b st-coil-l | lb |
  1.0 params.height 0.5 f* f+ | hg |
  ln fsqrt hg f* | sn |  lb fsqrt hg f* | sb |
  ln lb f+ | lt |
  params.sel | sel |
  sel 0.5 f< | neck |  sel 1.5 f> sel 2.5 f< and | bridge |
  sel 2.5 f> 1.0 -1.0 select | ph |
  neck  sn  bridge 0.0  sn lb f* lt f/  select  select -> params.wn
  neck  0.0  bridge sb  sb ln f* lt f/ ph f*  select  select -> params.wb
  neck  ln  bridge lb  ln lb f* lt f/  select  select -> params.l-eff
  params.height HT-K f* params.inv-sr f* -> params.ht-k
  1.0  sr 5.0 svf-dc-coeff f- -> params.ht-a
;

( params hz hand -- ratio : how much shorter than open the vibrating
  string is.  The note goes on the highest open string [o1..o6] it sits at
  or above the hand's fret on; below them all, the lowest.  Pickup and
  pluck sit at fixed distances from the bridge, so their share of the
  vibrating length grows by this ratio up the neck: the 12th fret puts a
  neck pickup a third of the way along, and the tone changes string to
  string the way it does on the instrument. )
dsp: st-fret | params:StringParams hz hand -- ratio |
  hand 0.08333333333333333 f* exp2 | h |
  hz params.o1 f/
  hz params.o2 h f* f>=  hz params.o2 f/  rot select
  hz params.o3 h f* f>=  hz params.o3 f/  rot select
  hz params.o4 h f* f>=  hz params.o4 f/  rot select
  hz params.o5 h f* f>=  hz params.o5 f/  rot select
  hz params.o6 h f* f>=  hz params.o6 f/  rot select
  1.0 fmax
;

( params hz hand -- i : the string st-fret puts the note on, 0 = lowest. )
dsp: st-string | params:StringParams hz hand -- i |
  hand 0.08333333333333333 f* exp2 | h |
  0.0
  hz params.o2 h f* f>=  1.0  rot select
  hz params.o3 h f* f>=  2.0  rot select
  hz params.o4 h f* f>=  3.0  rot select
  hz params.o5 h f* f>=  4.0  rot select
  hz params.o6 h f* f>=  5.0  rot select
;

( Per-note loop coefficients from hz and the knobs.  Runs at note-on, on
  note-expr, and every 64 samples [control!] so the knobs act live.

  Loss is a first-order shelf, y = g-hi x + g-dif LP[x], LP a one-pole at
  KNEE x f0: partials below it lose DECAY's share per period, partials
  above HF DEC's.  Measured basses [tools/fit/string_fit.py] turn from
  slow to fast decay around the 5th-8th harmonic at any pitch, which a
  plain one-pole in the loop [loss rising as f^2] can't follow.  The
  shelf is normalized so the fundamental's per-period gain is exact.

  Dispersion: AP-N first-order allpasses, all at c = -r.  At low w each
  section's phase delay falls as g0 r w^2 / [3 [1-r]^2], and a stiff
  string needs N B n^2 / 2 less delay at its n-th partial; both go as
  w^2, so r solves r[1+r] / [1-r]^3 = 3 B N^3 / [8 pi^2 AP-N], exact in
  the low partials and saturating above w ~ [1-r] / sqrt r. )
:: THUMP-K 10.0 ;
:: FRET-END 0.3 ;        ( a 20-fret neck ends 0.315 of the scale from the bridge )
:: FRET-GAP 0.045 ;      ( gap at BUZZ 0+, x the period, in velocity-samples: a hard finger pluck swings 0.03 )
:: FRET-GAP-SPAN 0.035 ; ( how much of it BUZZ 1 closes )
:: THUMB-STOP 0.3 ;      ( the stop takes this share of what is left each sample: flesh over bone, ~70 us )
:: POP-SOFT 0.15 ;       ( ms: a popped string leaves the finger this fast )
:: POP-REACH 0.4 ;       ( with frets in reach a pluck pulls the string this many gaps from rest, soft.. )
:: POP-REACH-V 9.0 ;     ( ..and this many more at full velocity, as its square )
:: FRET-HARD 0.9 ;      ( share of the overshoot stopped each sample: 1 a rigid fret that sends the wave back whole, 0.5 one that swallows it )
:: THUMB-K 1.0 ;         ( SLAP 1: the thumb moves the string this much faster than a finger, +1 )
:: THUMB-REACH 0.5 ;     ( a thumb carries the string this share of the gap past rest, soft.. )
:: THUMB-REACH-V 0.6 ;   ( ..and this much more at full velocity: the string bends over the fret )
:: AP-N 16 ;
:: AP-NF 16.0 ;
dsp: string-tune | state:StringState params:StringParams -- |
  params.sr | sr |
  state.hz 20.0 4000.0 fclamp | hz |
  sr hz f/ | n |
  6.283185307179586 hz f* sr f/ | w0 |
  w0 cos | cw |  w0 sin | sw |
  ( per-period gains: low partials, upper partials, released )
  params.decay | t0 |
  -6.907755278982137 t0 hz f* f/ exp | glo |
  params.hf-decay  params.ref-hz hz f/ log2 params.hf-track f* exp2  f*  t0 fmin | t1 |
  -6.907755278982137 t1 hz f* f/ exp | ghi |
  -6.907755278982137 params.release hz f* f/ exp | grel |
  -6.283185307179586 params.knee f* hz f* sr f/ exp 0.0 0.9999 fclamp | a |
  ( the shelf at w0: H = ghi + [glo - ghi] [1-a] / [1 - a e^-jw] )
  1.0 a cw f* f- | dr |  a sw f* | di |
  dr dr f* di di f* f+ | den |
  glo ghi f- 1.0 a f- f* den f/ | k |
  ghi k dr f* f+ | re |
  k di f* | im |
  glo  re re f* im im f* f+ fsqrt  f/ | norm |
  ghi norm f* 0.99999 fmin -> state.g-hi
  glo ghi f- norm f* -> state.g-dif
  grel -> state.g-rel
  a -> state.la
  im re f/ st-atan w0 f/ | pdl |
  ( dispersion coefficient from B, key-tracked like a real set of strings )
  params.stiff 0.0001 f*  params.b-ref hz f/ fsqrt  f* | b |
  3.0 b f* n f* n f* n f*  78.95683520871486 AP-NF f* f/ 0.000000001 fmax | kk |
  2.0 kk f/ log2 0.3333333333333333 f* exp2 0.001 1.0 fclamp
  8 [ | u |  1.0 u f- 2.0 u f- f* kk f/ log2 0.3333333333333333 f* exp2 0.001 1.0 fclamp ] times
  | u |
  ( keep the chain's delay under 60% of the period so the line stays long )
  0.6 n f* AP-NF f/ 1.0 fmax | q |
  1.0 u f-  0.0  q 1.0 f- q 1.0 f+ f/ 0.97 fmin  fclamp fneg | ac |
  ac -> state.apc
  1.0  ac sw f*  1.0 ac cw f* f+  f/ st-atan 2.0 f* w0 f/  f- | pda |
  n pdl f- pda AP-NF f* f-  4.0  state.buf-len 16.0 f-  fclamp -> state.dl-tgt
  params hz params.hand st-fret | ratio |
  params.pickup ratio f* 0.5 fmin n f* 1.0 fmax -> state.pk
  ( the pickups' taps: each coil sees the string at its own point, a
    humbucker's two coils or a wide coil's edges either side of it, a
    split coil's half nearer the neck under the low strings )
  params hz params.hand st-string | si |
  si -> state.si
  hz ratio f/ | fo |
  params.ref-hz fo f/ -> state.z
  si params.n-str 0.5 f* f< 1.0 -1.0 select | side |
  params.pickup  params.split-n side f* 0.012 f* params.coil-k f* f+ | cn |
  params.pickup-b  params.split-b side f* 0.012 f* params.coil-k f* f+ | cb |
  cn params.on1 f+ ratio f* 0.5 fmin n f* 1.0 fmax -> state.pn1
  cn params.on2 f+ ratio f* 0.5 fmin n f* 1.0 fmax -> state.pn2
  cb params.ob1 f+ ratio f* 0.5 fmin n f* 1.0 fmax -> state.pb1
  cb params.ob2 f+ ratio f* 0.5 fmin n f* 1.0 fmax -> state.pb2
  ( the frets: the last one sits FRET-END of the open string from the
    bridge; the gap closes as BUZZ rises.  Displacement here is summed
    velocity, so a gap is a share of the period. )
  FRET-END ratio f* 0.5 fmin n f* 2.0 fmax -> state.cd
  FRET-GAP  params.buzz FRET-GAP-SPAN f* f-  n f* -> state.ch
  1.0  1.5707963267948966 hz f* sr f/  f- -> state.cl
  ( THUMP: pitch rises with displacement squared, velocity / f )
  params.ref-hz hz f/ dup f*  params.thump f* THUMP-K f* -> state.th-k
;

( A note-on plucks the string.  A legato one [ctx.legato, the host's
  poly legato, docs/08] doesn't: the finger lands on a fret of the string
  that is ringing [a hammer-on, upward] or leaves one [a pull-off,
  downward], so the loop takes the new length at once, the string keeps
  its sound and its filters their state, and a small excitation from the
  finger joins it, softer and wider than a pluck; a pull-off plucks a
  little as the finger lets go. )
:: HAMMER-AMP 0.3 ;
:: PULL-AMP 0.5 ;
dsp: string-note-on | ctx:Ctx state:StringState params:StringParams -- |
  ctx.legato 0.5 f> | leg |
  ctx.pitch state.p0 f> | up |
  ctx.hz -> state.hz
  ctx.pitch -> state.p0
  params.motion 1.5 f> mask>f -> state.slid
  0.0 -> state.q
  ctx.vel -> state.vel
  leg state.age 0.0 select -> state.age
  0.0 -> state.et
  1.0 -> state.gate
  state params string-tune
  state.dl-tgt -> state.dl
  leg state.clear-n state.dl-tgt 2.0 f+ select -> state.clear-n
  leg state.lp1 0.0 select -> state.lp1
  state.apx& | xs |  state.apy& | ys |
  0.0 AP-N [ | i |  leg xs i f@i 0.0 select xs i f!i  leg ys i f@i 0.0 select ys i f!i  i 1.0 f+ ] times drop
  leg state.tens 0.0 select -> state.tens
  leg state.xn 0.0 select -> state.xn
  leg state.xb 0.0 select -> state.xb
  leg state.yc 0.0 select -> state.yc
  ( SLAP plays the instrument's upper strings popped, a finger under the
    string, and the lower ones with the thumb: HAND decides which string
    a note is on, so it decides this too )
  params.buzz 0.0 f>  params.slap 0.0 f>  and | slapping |
  slapping  state.si params.n-str 0.5 f* f>=  and | pop |
  pop 1.0 params.shape select -> state.shp
  ( a thumb is heavy: a soft slap is slower, but not by as much as a soft pluck )
  slapping pop not and | thumb |
  thumb  params.slap THUMB-K f* 1.0 f+  ctx.vel 0.05 1.0 fclamp log2 -0.7 f* exp2 f*  1.0 select -> state.tg
  ctx.vel THUMB-REACH-V f* THUMB-REACH f+ state.ch f* -> state.el
  0.0 -> state.e1  0.0 -> state.e2
  leg state.vib-t 0.0 select -> state.vib-t
  leg state.vib 0.0 select -> state.vib
  ctx.vel 0.0001 1.0 fclamp log2 1.3 f* exp2 | a |
  leg  a  up HAMMER-AMP PULL-AMP select f*  a  select -> state.amp
  ( width: soft at low velocity, sharp at high; a fingertip twice as soft )
  pop POP-SOFT params.soft select 0.001 f* params.sr f*  params.ref-hz ctx.hz 20.0 4000.0 fclamp f/ fsqrt f*
    1.4 ctx.vel 0.8 f* f-  f*  leg 2.0 1.0 select f*  1.0 fmax | wid |
  1.0 wid f/ -> state.inv-w
  2.0 params.soft f/ fsqrt 0.5 4.0 fclamp -> state.pu-g
  ctx.hz 20.0 4000.0 fclamp | hz |
  params.pos params hz params.hand st-fret f* 0.5 fmin  params.sr hz f/ f* -> state.pd
  ( a pluck with frets in reach [a pop] is as far as a finger can pull,
    counted in gaps, never more than the free pluck )
  params.buzz 0.0 f>
    ctx.vel dup f* POP-REACH-V f* POP-REACH f+ state.ch f*  state.pd state.amp f* 0.000001 fmax f/  1.0 fmin
    1.0
  select -> state.pg
  leg 0.3 1.0 select -> state.nz-env
  -1.0  0.002 wid params.inv-sr f* f+  params.sr f*  f/ exp -> state.nz-k
  state.rng& ctx.chan 3.0 f+ rand-seed-once
  state.sl-rng& ctx.chan 11.0 f+ rand-seed-once
;

dsp: string-note-off | ctx state:StringState params -- |
  0.0 -> state.gate
;

( Per-note expression [docs/22]: the note's pitch curve moves the string.
  As a BEND the pitch follows the curve.  As a SLIDE it moves fret by
  fret: the offset from the note's start rounds to semitones, each step
  glides in about 10 ms [the loop's delay glide], and each fret crossed
  ticks the slide noise.  AUTO is a bend until the curve goes further
  than a bend can, more than BEND-MAX up or any way below where the note
  started, and a slide from then on. )
:: BEND-MAX 3.5 ;
dsp: string-note-expr | ctx:Ctx state:StringState params:StringParams -- |
  ctx.pitch state.p0 f- | d |
  d BEND-MAX f>  d -0.25 f<  or mask>f  state.slid fmax | auto |
  params.motion 0.5 f<  auto  params.motion 1.5 f> mask>f  select | sl |
  sl -> state.slid
  d 0.5 f+ floor | q |
  sl 0.5 f>  q d select | e |
  ( fret ticks: a step in q while sliding )
  q state.q f- fabs 1.0 fmin  sl f* 0.6 f*  state.sl-env f+ 1.5 fmin -> state.sl-env
  q -> state.q
  state.p0 e f+ 69.0 f- 0.08333333333333333 f* exp2 440.0 f* -> state.hz
  ctx.slide 0.0 1.0 fclamp -> state.vib-t
  state params string-tune
;

dsp: string-control | ctx state:StringState params:StringParams -- |
  state params string-tune
;

( buf len pos -- y : 4-tap Lagrange read at fractional ring index pos. )
dsp: st-read | buf len pos -- y |
  pos floor | i |  pos i f- | d |
  1.0 len f/ | il |
  buf  i 1.0 f- dup il f* floor len f* f-  f@i | xm |
  buf  i dup il f* floor len f* f-  f@i | x0 |
  buf  i 1.0 f+ dup il f* floor len f* f-  f@i | x1 |
  buf  i 2.0 f+ dup il f* floor len f* f-  f@i | x2 |
  d 1.0 f- | dm1 |  d 2.0 f- | dm2 |  d 1.0 f+ | dp1 |
  d dm1 f* dm2 f* -0.16666666666666666 f* xm f*
  dp1 dm1 f* dm2 f* 0.5 f* x0 f*  f+
  dp1 d f* dm2 f* -0.5 f* x1 f*  f+
  dp1 d f* dm1 f* 0.16666666666666666 f* x2 f*  f+
;

( state params -- n : the slide's noise, into the string: the finger
  rasping over the windings while the pitch moves, and a tick at each
  fret crossed.  0 unless the note is sliding. )
dsp: st-slide-noise | state:StringState params:StringParams -- n |
  state.dl-tgt state.dl f- fabs state.dl f/ 3000.0 f* 1.0 fmin | speed |
  state.sl-env params.sl-dec f* -> state.sl-env
  state.sl-env speed f+  state.slid f*  params.slide f*  state.amp f* | a |
  state.sl-rng& rand-b | w |
  state.sl-hp  w state.sl-hp f- params.sl-hpa f* f+ | hl |
  hl -> state.sl-hp
  w hl f- | hp |
  state.sl-lp  hp state.sl-lp f- params.sl-lpa f* f+ | lp |
  lp -> state.sl-lp
  lp a f* 0.01 f*
;

( Smoothed step 0 -> 1 over the width, and a raised-cosine pulse, at
  sample x of the excitation [x < 0: not started]. )
dsp: st-step | x iw -- s |  x iw f* 0.0 1.0 fclamp cospi -0.5 f* 0.5 f+ ;
dsp: st-pulse | x iw -- s |  x iw f* 0.0 1.0 fclamp 2.0 f* cospi -0.5 f* 0.5 f+ ;

dsp: string-excite | state:StringState params:StringParams -- e |
  state.et | t |  t state.pd f- | td |  state.inv-w | iw |
  t iw st-step  td iw st-step f- | pl |
  ( a thumb [SLAP]: a heavy pulse that stops dead when it has carried the
    string to the fret; the stop is the click.  The echo stops the same. )
  state.pu-g state.tg f* | tg |
  t iw st-pulse tg f*  state.el state.e1 f- 0.0 fmax THUMB-STOP f*  fmin | ta |
  td iw st-pulse tg f*  state.el state.e2 f- 0.0 fmax THUMB-STOP f*  fmin | tb |
  state.e1 ta f+ -> state.e1  state.e2 tb f+ -> state.e2
  state.tg 1.0 f>  ta tb f-  t iw st-pulse td iw st-pulse f- state.pu-g f*  select | pu |
  pl state.pg f* pu f- state.shp f* pu f+  state.amp f*
  state.rng& rand-b state.nz-env f* params.noise f* state.amp f*  f+
  state.nz-env state.nz-k f* -> state.nz-env
;

dsp: st-loop | io ctx:Ctx state:StringState params:StringParams -- |
  state.buf& p@64 | buf |  state.buf-len 4.0 f- | len |
  state.age | t |
  t state.clear-n f>= | live |
  ( loop delay: glide toward the target, shortened by tension )
  state.dl  state.dl-tgt state.dl f- 0.002 f* f+ | dl |
  dl -> state.dl
  ( finger vibrato: the finger pushes the string sharp and lets it back,
    never below the note; a smoothstep of a triangle, near a sine )
  state.vib  state.vib-t state.vib f- params.vib-a f* f+ | vd |
  vd -> state.vib
  state.vib-ph params.vib-inc f+ ffrac | vph |
  vph -> state.vib-ph
  1.0  vph 2.0 f* 1.0 f- fabs f- | tri |
  tri tri f*  3.0 2.0 tri f* f-  f* | vw |
  1.0  vd params.vib-depth f* vw f* 0.057762265046662105 f*  f- | vm |
  dl vm f*  1.0 state.tens state.tens f* state.th-k f* 0.1 fmin f-  f* | d |
  state.w | w |
  buf len  w d f- len f+  st-read | r |
  live r 0.0 select | rr |
  ( loss )
  state.la | a |
  state.gate 0.5 f> | held |
  held state.g-hi state.g-rel select | gh |
  held state.g-dif 0.0 select | gd |
  1.0 a f- rr f*  a state.lp1 f* f+ | s |
  s -> state.lp1
  rr gh f*  s gd f* f+ | lp |
  ( dispersion )
  state.apc | c |  state.apx& | xs |  state.apy& | ys |
  lp 0.0 AP-N [ | x i |
    xs i f@i | x1 |  ys i f@i | y1 |
    c x f* x1 f+ c y1 f* f- | y |
    x xs i f!i  y ys i f!i
    y i 1.0 f+
  ] times drop | y |
  state params string-excite  state params st-slide-noise f+ | e |
  ( the bridge: the string pushes on it with the wave arriving there, and
    moves with it [string_body.fy] )
  ctx.shared& p@64 | body:FwBody |
  body.vb | vb |
  body.f  y 2.0 f* vb f+ state.z f* f-  -> body.f
  y e f+ vb f+ | nw0 |
  ( the frets [BUZZ]: the string's displacement over the last fret is the
    sum of its velocity there, this sample's write less the wave that
    passed cd samples back.  It cannot pass the fret: what would carry it
    past is taken out of the wave leaving the fret one way and given to
    the wave leaving the other, a reflection, the string rattling.  The
    two waves trade the same amount, so the knock can only lose energy,
    and FRET-HARD sets how much.  A
    thumb or a finger pushes the string toward the frets; a pluck [SHAPE
    past half] lets it go from the far side, so it meets them half a
    period on. )
  state.cd floor  d 4.0 f- floor  fmin 1.0 fmax | cdi |
  w cdi f-  dup 0.0 f< len 0.0 select f+ | ci |
  buf ci f@i | rc |
  state.shp 0.5 f> -1.0 1.0 select | side |
  state.yc state.cl f*  nw0 rc f- side f*  f+ | yf |
  params.buzz 0.0 f>  state.ch yf f- 0.0 fmin FRET-HARD f*  0.0 select  side f* | x |
  nw0 x f+ | nw |
  rc x f-  buf ci f!i
  yf  x side f* f+ -> state.yc
  nw buf w f!i
  nw -> state.nw
  w -> state.wc
  w 1.0 f+ dup len f>= 0.0 rot select -> state.w
  ( a thumb's pulse is fast, not far: it counts for no more than a hard pluck )
  state.tens  nw fabs 1.5 fmin state.tens f- params.tens-a f* f+ -> state.tens
  ( old note fading out while the ring refills )
  r  1.0 t 0.015625 f* f- 0.0 fmax f*  live 0.0 rot select -> state.fade
  t 1.0 f+ -> state.age
  state.et 1.0 f+ -> state.et
;

( buf len w nw d -- y : the string seen d samples back along the ring
  from this sample's write: the pickup comb, a linear tap. )
dsp: st-tap | buf len w nw d -- y |
  w d f- len f+ | pp |
  pp floor | pi |  pp pi f- | pf |
  buf  pi dup len f>= len 0.0 select f-  f@i | p0 |
  buf  pi 1.0 f+ dup len f>= len 0.0 select f-  f@i | p1 |
  nw  p1 p0 f- pf f* p0 f+  f-
;

( x y k -- y' : a pickup's magnetic pull.  The string swinging toward the
  magnet sees more flux than swinging away, so the coil's output is the
  string's velocity times 1 / [1 - k x]^2, x its displacement there:
  even harmonics that grow with the swing [Horton and Moore 2009]. )
dsp: st-magnet | x y k -- o |
  1.0  x k f* -0.5 0.5 fclamp  f- | g |
  y g g f* f/
;

( io ctx state params -- : the pickups.  Each coil sees the string at its
  taps; the selector mixes them as the wiring would; the result joins the
  other strings' on the body's pickup line, ahead of the shared wiring. )
dsp: st-pickup | io ctx:Ctx state:StringState params:StringParams -- |
  ctx.shared& p@64 | body:FwBody |
  state.buf& p@64 | buf |  state.buf-len 4.0 f- | len |
  state.wc | w |  state.nw | nw |
  buf len w nw state.pn1 st-tap  buf len w nw state.pn2 st-tap  f+ 0.5 f* | yn |
  buf len w nw state.pb1 st-tap  buf len w nw state.pb2 st-tap  f+ 0.5 f* | yb |
  params.height 0.0 f>
    [ state.xn params.ht-a f* yn f+ | xn |  xn -> state.xn
      state.xb params.ht-a f* yb f+ | xb |  xb -> state.xb
      xn yn params.ht-k st-magnet  xb yb params.ht-k st-magnet ]
    [ yn yb ]
  ifte | yn yb |
  body.pu  yn params.wn f*  yb params.wb f* f+  state.fade f+  f+ -> body.pu
  1.0 body.mute& state.si f!i
;

( io ctx state params -- : one voice sample.  It is heard through the
  body word: its pickup signal and bridge force go there. )
dsp: k-string-voice | io ctx state params |
  io ctx state params call: st-loop
  io ctx state params call: st-pickup
;
