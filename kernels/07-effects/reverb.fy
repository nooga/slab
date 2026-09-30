( reverb.fy - stereo reverb on one packed host buffer: a Dattorro plate
  and an 8-line FDN for rooms and halls.

  One true-stereo pass [manifest `stereo`].  The input runs LOW CUT [two
  one-pole highpasses] and HI CUT [a one-pole lowpass, the plate's
  bandwidth filter], then a predelay ring per side.  Early reflections
  and the late tank read those rings.

  ALGO:
    PLATE  Dattorro 1997 [Effect Design part 1].  The mono sum runs 4
           input diffusion allpasses into a figure-8 tank of two branches,
           each: modulated decay-diffusion allpass, long delay, damping
           lowpass, decay gain, second allpass, second delay, fed from
           the other branch's end.  The left output is Dattorro's left tap
           set and the right his right set, off the one tank.
    ROOM   the FDN with short lines [11-27 ms].
    HALL   the FDN with long lines [30-80 ms].
  The FDN: L into the even lines, R into the odd, each through four
  diffusion allpasses; 8 delay lines, a Hadamard mix, per-line decay gain
  and damping; lines 1 and 6 modulated.  L out from the even lines, R
  from the odd.

  DECAY is the time in seconds for the low-mid band to fall 60 dB.  Each
  loop's gain comes from its own length [10^(-3 len / (DECAY sr))], so a
  SIZE change keeps the time.  BASS multiplies the time below XOVER
  [a one-pole split in each loop; at 1.0 it is skipped].  DAMP is the
  lowpass inside each loop, so highs die sooner.  The plate applies its
  decay twice per half-loop, as Dattorro does, so each takes the square
  root.

  EARLY adds 8 reflection taps per side off the predelay rings, spaced by
  ALGO and SIZE [a plate's are closest].  WIDTH is mid/side on the wet.
  GATE [the 80s non-linear program, AMS RMX16 NonLin2 and the SSL gated
  room]: the dry input, both channels linked [io.det], or a sidechain key
  [docs/23], opens a gate on the wet signal.  A hit over THRESH opens it;
  it stays open HOLD seconds after the last such sample, shaped over that
  window by SHAPE [-1 decaying, 0 flat, +1 rising - the 'reverse'
  program], then shuts in about 10 ms.

  Every switch is an ifte on params [docs/05 §Branching], so only the
  chosen algorithm runs.  The buffer regions are sized for SIZE 1.5 at
  96 kHz; ring lengths scale with the sample rate and SIZE at
  block-prepare, and every read and position is clamped to its region,
  so a SIZE move scrambles the tank for a moment but never reads outside
  it.

    region   offset   cap          region   offset   cap
    pre-l         0   24000        f0       157214   4345
    pre-r     24000   24000        f1       161559   5507  modulated
    inap1     48000     692        f2       167066   6211
    inap2     48692     522        f3       173277   7201
    inap3     49214    1838        f4       180478   8251
    inap4     51052    1345        f5       188729   9253
    a-ap1     52397    3416        f6       197982  10547  modulated
    a-d1      55813   21551        f7       208529  11503
    a-ap2     77364    8714        fap-l1   220032    637
    a-d2      86078   18004        fap-l2   220669    997
    b-ap1    104082    4558        fap-r1   221666    721
    b-d1     108640   20409        fap-r2   222387   1105
    b-ap2    129049   12856        total    223492  -> 2.33 s at 96 kHz
    b-d2     141905   15309        fap-l0   223492    343
                                   fap-l3   223835   1351
                                   fap-r0   225186    385
                                   fap-r3   225571   1441
                                   total    227012  -> 2.37 s at 96 kHz )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../00-primitives/math.fy"

:: PRE-LEN 24000.0 ;
:: PRE-R 24000.0 ;

ustruct: VerbState
  f64 buf        ( host-injected ring base pointer )
  f64 buf-len    ( host-injected element count )
  f64 seeded     ( 0 fresh state, 1 after first prepare )
  f64 lfo-s      ( tank modulation, magic-circle quadrature pair )
  f64 lfo-c
  f64 pre-pos
  f64 lc-l1  f64 lc-l2  f64 lc-r1  f64 lc-r2  ( LOW CUT states )
  f64 hc-l   f64 hc-r                         ( HI CUT states )
  ( plate )
  f64 inap1-pos  f64 inap2-pos  f64 inap3-pos  f64 inap4-pos
  f64 a-ap1-pos  f64 a-d1-pos   f64 a-ap2-pos  f64 a-d2-pos
  f64 b-ap1-pos  f64 b-d1-pos   f64 b-ap2-pos  f64 b-d2-pos
  f64 damp-a-z   f64 damp-b-z   f64 xo-a-z     f64 xo-b-z
  ( FDN )
  f64 fap-l0-pos f64 fap-l1-pos f64 fap-l2-pos f64 fap-l3-pos
  f64 fap-r0-pos f64 fap-r1-pos f64 fap-r2-pos f64 fap-r3-pos
  f64 fpos 8     ( line write heads )
  f64 fxo 8      ( BASS split states )
  f64 fdz 8      ( damping states )
  ( gate )
  f64 gate-t     ( samples since the last sample over the threshold )
  f64 gate-g     ( smoothed wet gain in GATED mode )
;

ustruct: VerbParams
  ( user-facing )
  f64 predelay-s
  f64 decay      ( seconds, low-mid RT60 )
  f64 damp-hz    ( lowpass inside the loops )
  f64 bw-hz      ( HI CUT on the input )
  f64 mix
  f64 mod-depth  ( tank modulation, reference samples )
  f64 mod-rate   ( Hz )
  f64 mode       ( 0 off, 1 gated )
  f64 gate-thr-db
  f64 gate-hold-s
  f64 gate-shape ( -1 decaying .. 0 flat .. +1 rising )
  f64 algo       ( 0 PLATE, 1 ROOM, 2 HALL )
  f64 space      ( SIZE 0.5 .. 1.5 [not `size`: that names the struct's size] )
  f64 pre-sync   ( switch option value: predelay in beats, 0 = free )
  f64 lowcut-hz
  f64 bass       ( decay multiplier below xover )
  f64 xover-hz
  f64 diff       ( input diffusion 0..1 )
  f64 early      ( early reflections level )
  f64 width
  ( derived - filled by verb-block-prepare )
  f64 sr
  f64 scale      ( plate: sr / 29761 * size )
  f64 pre-spl    ( predelay, samples )
  f64 inap1-len  f64 inap2-len  f64 inap3-len  f64 inap4-len
  f64 a-ap1-len  f64 a-d1-len   f64 a-ap2-len  f64 a-d2-len
  f64 b-ap1-len  f64 b-d1-len   f64 b-ap2-len  f64 b-d2-len
  f64 tl 7       ( plate left output taps, samples )
  f64 tr 7       ( plate right output taps )
  f64 ga  f64 gb           ( plate per-multiply decay gains, branch A / B )
  f64 ga-lo  f64 gb-lo     ( the second multiply's gain below xover )
  f64 flen 8     ( FDN line lengths )
  f64 fg 8       ( FDN line gains )
  f64 fg-lo 8    ( FDN line gains below xover )
  f64 fap-len 8  ( L 0..3, R 4..7 )
  f64 fout       ( FDN output gain: level-matched to the plate )
  f64 lc-a  f64 bw-a  f64 damp-a  f64 xo-a
  f64 mod-k      ( oscillator step, 2 pi f / sr )
  f64 mod-spl
  f64 ap-g1  f64 ap-g2  f64 fap-g   ( input diffusion gains )
  f64 er-tl 8    ( early reflection taps, samples )
  f64 er-tr 8
  f64 gate-thr   ( linear )
  f64 gate-hold  ( samples )
  f64 gate-atk   ( one-pole coefficients )
  f64 gate-rel
;

( --- ring helpers ------------------------------------------------------ )

( p len -- p1 : advance a ring position; a position past a ring that
  just shrank restarts at 0. )
dsp: vb-next | p len -- p1 |
  p 1.0 f+ | q |
  q len  q  0.0  fsel-lt
;

( buf off posp len x g -- y : one allpass ring tick.
  v = ring out, w = x - g*v written back, y = v + g*w. )
dsp: vb-ap
  | buf off posp len x g |
  posp f@64 | p |
  off p f+ | idx |
  buf idx f@i | v |
  x g v f* f- | w |
  w buf idx f!i
  p len vb-next posp f!64
  v g w f* f+
;

( buf off posp len x g m -- y : allpass with a modulated fractional
  read tap.  The oldest sample sits just ahead of the write head, so the
  tap reads at p+1+m for an effective delay of len-1-m - the chorusing
  inside the tank. )
dsp: vb-apm
  | buf off posp len x g m |
  posp f@64 | p |
  p 1.0 f+ m f+ | r0 |
  r0 len  r0  r0 len f-  fsel-lt  0.0 len 2.0 f- fclamp | r |
  buf off r f+ f@i | s0 |
  r 1.0 f+ | r1 |
  r1 len  r1  r1 len f-  fsel-lt | rw |
  buf off rw f+ f@i | s1 |
  s0  s1 s0 f-  r ffrac f*  f+ | v |
  x g v f* f- | w |
  w  buf off p f+  f!i
  p len vb-next posp f!64
  v g w f* f+
;

( buf off posp len x -- y : plain delay ring tick. )
dsp: vb-dl
  | buf off posp len x |
  posp f@64 | p |
  off p f+ | idx |
  buf idx f@i | v |
  x buf idx f!i
  p len vb-next posp f!64
  v
;

( buf off pos len tap -- v : static read tap behind the write head. )
dsp: vb-tap
  | buf off pos len tap |
  pos tap f- | i |
  i 0.0  i len f+  i fsel-lt  0.0 len 1.0 f- fclamp | iw |
  buf  off iw f+  f@i
;

( --- block-rate fills ------------------------------------------------- )

( len rt sr -- g : the gain that takes a loop of `len` samples down 60 dB
  in `rt` seconds, 10^[-3 len / (rt sr)]. )
dsp: vb-loop-g | len rt sr -- g |
  -9.965784284662087 len f* rt sr f* f/ exp2 0.99995 fmin
;

( base -- len : a plate length at the current scale, whole samples, capped
  by its region. )
dsp: vb-plen | params:VerbParams base cap -- len |
  base params.scale f* 2.0 cap fclamp floor
;

( ctx state params -- : effective ring lengths, taps, gains, coefficients. )
dsp: verb-block-prepare
  | ctx:Ctx state params:VerbParams |
  ctx.sr | sr |
  sr -> params.sr
  params.space | size |
  sr 0.000033601021471 f* size f* -> params.scale
  ( predelay: free seconds, or a synced division )
  params.pre-sync 0.0 f>
    60.0 ctx.tempo 20.0 999.0 fclamp f/ params.pre-sync f*
    params.predelay-s
  select sr f* 1.0 23990.0 fclamp floor -> params.pre-spl
  ( plate rings; the modulated allpasses leave room for the excursion )
  params 142.0 688.0 vb-plen -> params.inap1-len
  params 107.0 518.0 vb-plen -> params.inap2-len
  params 379.0 1834.0 vb-plen -> params.inap3-len
  params 277.0 1341.0 vb-plen -> params.inap4-len
  params 672.0 3252.0 vb-plen -> params.a-ap1-len
  params 4453.0 21547.0 vb-plen -> params.a-d1-len
  params 1800.0 8710.0 vb-plen -> params.a-ap2-len
  params 3720.0 18000.0 vb-plen -> params.a-d2-len
  params 908.0 4394.0 vb-plen -> params.b-ap1-len
  params 4217.0 20405.0 vb-plen -> params.b-d1-len
  params 2656.0 12852.0 vb-plen -> params.b-ap2-len
  params 3163.0 15305.0 vb-plen -> params.b-d2-len
  ( Dattorro's output taps: left off branch B mostly, right off A )
  params.scale | sc |
  266.0 sc f* params.tl& 0.0 f!i
  2974.0 sc f* params.tl& 1.0 f!i
  1913.0 sc f* params.tl& 2.0 f!i
  1996.0 sc f* params.tl& 3.0 f!i
  1990.0 sc f* params.tl& 4.0 f!i
  187.0 sc f* params.tl& 5.0 f!i
  1066.0 sc f* params.tl& 6.0 f!i
  353.0 sc f* params.tr& 0.0 f!i
  3627.0 sc f* params.tr& 1.0 f!i
  1228.0 sc f* params.tr& 2.0 f!i
  2673.0 sc f* params.tr& 3.0 f!i
  2111.0 sc f* params.tr& 4.0 f!i
  335.0 sc f* params.tr& 5.0 f!i
  121.0 sc f* params.tr& 6.0 f!i
  ( plate gains: two multiplies per half-loop, each the square root )
  params.decay 0.05 fmax | rt |
  rt params.bass f* | rtl |
  params.a-ap1-len params.a-d1-len f+ params.a-ap2-len f+ params.a-d2-len f+ | la |
  params.b-ap1-len params.b-d1-len f+ params.b-ap2-len f+ params.b-d2-len f+ | lb |
  la 0.5 f* rt sr vb-loop-g | ga |
  lb 0.5 f* rt sr vb-loop-g | gb |
  ga -> params.ga
  gb -> params.gb
  la rtl sr vb-loop-g ga f/ 0.99995 fmin -> params.ga-lo
  lb rtl sr vb-loop-g gb f/ 0.99995 fmin -> params.gb-lo
  ( FDN lines: room or hall lengths at 48 kHz, scaled by rate and SIZE )
  sr 0.000020833333333 f* size f* | fs |
  params.algo 1.5 f< | room |
  room 523.0 1447.0 select fs f* 2.0 4341.0 fclamp floor | l0 |
  room 613.0 1781.0 select fs f* 2.0 5343.0 fclamp floor | l1 |
  room 719.0 2069.0 select fs f* 2.0 6207.0 fclamp floor | l2 |
  room 827.0 2399.0 select fs f* 2.0 7197.0 fclamp floor | l3 |
  room 947.0 2749.0 select fs f* 2.0 8247.0 fclamp floor | l4 |
  room 1061.0 3083.0 select fs f* 2.0 9249.0 fclamp floor | l5 |
  room 1193.0 3461.0 select fs f* 2.0 10383.0 fclamp floor | l6 |
  room 1319.0 3833.0 select fs f* 2.0 11499.0 fclamp floor | l7 |
  l0 params.flen& 0.0 f!i  l1 params.flen& 1.0 f!i
  l2 params.flen& 2.0 f!i  l3 params.flen& 3.0 f!i
  l4 params.flen& 4.0 f!i  l5 params.flen& 5.0 f!i
  l6 params.flen& 6.0 f!i  l7 params.flen& 7.0 f!i
  l0 rt sr vb-loop-g params.fg& 0.0 f!i  l1 rt sr vb-loop-g params.fg& 1.0 f!i
  l2 rt sr vb-loop-g params.fg& 2.0 f!i  l3 rt sr vb-loop-g params.fg& 3.0 f!i
  l4 rt sr vb-loop-g params.fg& 4.0 f!i  l5 rt sr vb-loop-g params.fg& 5.0 f!i
  l6 rt sr vb-loop-g params.fg& 6.0 f!i  l7 rt sr vb-loop-g params.fg& 7.0 f!i
  l0 rtl sr vb-loop-g params.fg-lo& 0.0 f!i  l1 rtl sr vb-loop-g params.fg-lo& 1.0 f!i
  l2 rtl sr vb-loop-g params.fg-lo& 2.0 f!i  l3 rtl sr vb-loop-g params.fg-lo& 3.0 f!i
  l4 rtl sr vb-loop-g params.fg-lo& 4.0 f!i  l5 rtl sr vb-loop-g params.fg-lo& 5.0 f!i
  l6 rtl sr vb-loop-g params.fg-lo& 6.0 f!i  l7 rtl sr vb-loop-g params.fg-lo& 7.0 f!i
  113.0 fs f* 2.0 339.0 fclamp floor params.fap-len& 0.0 f!i
  211.0 fs f* 2.0 633.0 fclamp floor params.fap-len& 1.0 f!i
  331.0 fs f* 2.0 993.0 fclamp floor params.fap-len& 2.0 f!i
  449.0 fs f* 2.0 1347.0 fclamp floor params.fap-len& 3.0 f!i
  127.0 fs f* 2.0 381.0 fclamp floor params.fap-len& 4.0 f!i
  239.0 fs f* 2.0 717.0 fclamp floor params.fap-len& 5.0 f!i
  367.0 fs f* 2.0 1101.0 fclamp floor params.fap-len& 6.0 f!i
  479.0 fs f* 2.0 1437.0 fclamp floor params.fap-len& 7.0 f!i
  ( measured at DECAY 2 s: ROOM sits 5.5 dB and HALL 8.4 dB under the
    plate's level without this )
  room 1.9 2.6 select -> params.fout
  ( filters: exact one-pole coefficients )
  1.0  -6.2831853 params.lowcut-hz f* sr f/ exp  f- -> params.lc-a
  1.0  -6.2831853 params.bw-hz f* sr f/ exp  f- -> params.bw-a
  1.0  -6.2831853 params.damp-hz f* sr f/ exp  f- -> params.damp-a
  1.0  -6.2831853 params.xover-hz f* sr f/ exp  f- -> params.xo-a
  params.mod-rate 6.2831853 f* sr f/ -> params.mod-k
  params.mod-depth params.scale f* -> params.mod-spl
  params.diff 0.75 f* -> params.ap-g1
  params.diff 0.625 f* -> params.ap-g2
  params.diff 0.6 f* -> params.fap-g
  ( early taps in ms, spread by the algorithm and SIZE )
  params.algo 0.5 f<  0.6  room 0.7 1.25 select  select
  size f* sr f* 0.001 f* | es |
  4.3 es f* params.er-tl& 0.0 f!i   6.1 es f* params.er-tr& 0.0 f!i
  11.7 es f* params.er-tl& 1.0 f!i  13.3 es f* params.er-tr& 1.0 f!i
  17.9 es f* params.er-tl& 2.0 f!i  19.7 es f* params.er-tr& 2.0 f!i
  23.3 es f* params.er-tl& 3.0 f!i  27.1 es f* params.er-tr& 3.0 f!i
  31.1 es f* params.er-tl& 4.0 f!i  33.9 es f* params.er-tr& 4.0 f!i
  39.7 es f* params.er-tl& 5.0 f!i  41.9 es f* params.er-tr& 5.0 f!i
  47.3 es f* params.er-tl& 6.0 f!i  51.7 es f* params.er-tr& 6.0 f!i
  57.1 es f* params.er-tl& 7.0 f!i  61.3 es f* params.er-tr& 7.0 f!i
  params.gate-thr-db db>lin -> params.gate-thr
  params.gate-hold-s sr f* 1.0 fmax -> params.gate-hold
  ( ~1 ms open, ~10 ms shut: 1 - e^[-1/tau] ~ 1/tau at these rates )
  1.0 sr 0.001 f* f/ -> params.gate-atk
  1.0 sr 0.01 f* f/ -> params.gate-rel
;

( ctx state params -- : runs every block.  Seeds the oscillator and a
  fresh gate once. )
dsp: verb-prepare
  | ctx state:VerbState params:VerbParams |
  state.seeded 0.5 f< | fresh |
  fresh 1.0 state.lfo-c select -> state.lfo-c
  ( a fresh gate starts shut, not as if hit at sample 0 )
  fresh 1.0e9 state.gate-t select -> state.gate-t
  1.0 -> state.seeded
;

( --- the plate -------------------------------------------------------- )

( Input diffusion: four allpasses on the mono sum. )
dsp: verb-plate-in | state:VerbState params:VerbParams buf x -- d |
  buf 48000.0 state.inap1-pos& params.inap1-len x params.ap-g1 vb-ap | y1 |
  buf 48692.0 state.inap2-pos& params.inap2-len y1 params.ap-g1 vb-ap | y2 |
  buf 49214.0 state.inap3-pos& params.inap3-len y2 params.ap-g2 vb-ap | y3 |
  buf 51052.0 state.inap4-pos& params.inap4-len y3 params.ap-g2 vb-ap
;

( The second decay multiply, with BASS: a one-pole split below XOVER. )
dsp: verb-plate-decay | params:VerbParams zp g glo zn -- v |
  params.bass 1.0 f=
  [ zn g f* ]
  [ zp f@64 | z0 |
    z0  zn z0 f-  params.xo-a f*  f+ | lo |
    lo zp f!64
    lo glo f*  zn lo f- g f*  f+ ]
  ifte
;

( Branch A: fed from branch B's end; modulated allpass, delay, damping,
  decay, allpass, delay. )
dsp: verb-plate-a | state:VerbState params:VerbParams buf d m -- |
  buf 141905.0 state.b-d2-pos params.b-d2-len 0.0 vb-tap params.ga f*
  d f+ | fba |
  buf 52397.0 state.a-ap1-pos& params.a-ap1-len fba 0.70 m vb-apm | y |
  buf 55813.0 state.a-d1-pos& params.a-d1-len y vb-dl | ta |
  state.damp-a-z | z |
  z  ta z f-  params.damp-a f*  f+ | zn |
  zn -> state.damp-a-z
  params state.xo-a-z& params.ga params.ga-lo zn verb-plate-decay | v |
  buf 77364.0 state.a-ap2-pos& params.a-ap2-len v 0.50 vb-ap | y2 |
  buf 86078.0 state.a-d2-pos& params.a-d2-len y2 vb-dl
  drop
;

( Branch B, fed from branch A's end. )
dsp: verb-plate-b | state:VerbState params:VerbParams buf d m -- |
  buf 86078.0 state.a-d2-pos params.a-d2-len 0.0 vb-tap params.gb f*
  d f+ | fbb |
  buf 104082.0 state.b-ap1-pos& params.b-ap1-len fbb 0.70 m vb-apm | y |
  buf 108640.0 state.b-d1-pos& params.b-d1-len y vb-dl | tb |
  state.damp-b-z | z |
  z  tb z f-  params.damp-a f*  f+ | zn |
  zn -> state.damp-b-z
  params state.xo-b-z& params.gb params.gb-lo zn verb-plate-decay | v |
  buf 129049.0 state.b-ap2-pos& params.b-ap2-len v 0.50 vb-ap | y2 |
  buf 141905.0 state.b-d2-pos& params.b-d2-len y2 vb-dl
  drop
;

( Dattorro's output taps, read before this sample's writes land. )
dsp: verb-plate-out | state:VerbState params:VerbParams buf -- wl wr |
  buf 108640.0 state.b-d1-pos params.b-d1-len params.tl& 0.0 f@i vb-tap
  buf 108640.0 state.b-d1-pos params.b-d1-len params.tl& 1.0 f@i vb-tap f+
  buf 129049.0 state.b-ap2-pos params.b-ap2-len params.tl& 2.0 f@i vb-tap f-
  buf 141905.0 state.b-d2-pos params.b-d2-len params.tl& 3.0 f@i vb-tap f+
  buf 55813.0 state.a-d1-pos params.a-d1-len params.tl& 4.0 f@i vb-tap f-
  buf 77364.0 state.a-ap2-pos params.a-ap2-len params.tl& 5.0 f@i vb-tap f-
  buf 86078.0 state.a-d2-pos params.a-d2-len params.tl& 6.0 f@i vb-tap f-
  0.6 f*
  buf 55813.0 state.a-d1-pos params.a-d1-len params.tr& 0.0 f@i vb-tap
  buf 55813.0 state.a-d1-pos params.a-d1-len params.tr& 1.0 f@i vb-tap f+
  buf 77364.0 state.a-ap2-pos params.a-ap2-len params.tr& 2.0 f@i vb-tap f-
  buf 86078.0 state.a-d2-pos params.a-d2-len params.tr& 3.0 f@i vb-tap f+
  buf 108640.0 state.b-d1-pos params.b-d1-len params.tr& 4.0 f@i vb-tap f-
  buf 129049.0 state.b-ap2-pos params.b-ap2-len params.tr& 5.0 f@i vb-tap f-
  buf 141905.0 state.b-d2-pos params.b-d2-len params.tr& 6.0 f@i vb-tap f-
  0.6 f*
;

( state params buf xl xr ma mb -- wl wr : one plate sample. )
dsp: verb-plate | state:VerbState params:VerbParams buf xl xr ma mb -- wl wr |
  state params buf verb-plate-out | wl wr |
  state params buf  xl xr f+ 0.5 f*  verb-plate-in | d |
  state params buf d ma verb-plate-a
  state params buf d mb verb-plate-b
  wl wr
;

( --- the FDN ---------------------------------------------------------- )

( state params buf i -- v : line i's oldest sample. )
dsp: fdn-rd | state:VerbState params:VerbParams buf off i -- v |
  buf  off state.fpos& i f@i f+  f@i
;

( state params buf off i m -- v : line i read m samples early, linear. )
dsp: fdn-rdm | state:VerbState params:VerbParams buf off i m -- v |
  params.flen& i f@i | len |
  state.fpos& i f@i 1.0 f+ m f+ | r0 |
  r0 len  r0  r0 len f-  fsel-lt  0.0 len 2.0 f- fclamp | r |
  buf off r f+ f@i | s0 |
  r 1.0 f+ | r1 |
  r1 len  r1  r1 len f-  fsel-lt | rw |
  buf off rw f+ f@i | s1 |
  s0  s1 s0 f-  r ffrac f*  f+
;

( state params i v -- d : line i's decay [BASS split when it isn't 1] and
  damping. )
dsp: fdn-dec | state:VerbState params:VerbParams i v -- d |
  params.fg& i f@i | g |
  params.bass 1.0 f=
  [ v g f* ]
  [ state.fxo& i f@i | z0 |
    z0  v z0 f-  params.xo-a f*  f+ | lo |
    lo state.fxo& i f!i
    lo params.fg-lo& i f@i f*  v lo f- g f*  f+ ]
  ifte | u |
  state.fdz& i f@i | z |
  z  u z f-  params.damp-a f*  f+ | zn |
  zn state.fdz& i f!i
  zn
;

( state params buf off i x -- : write line i and advance its head. )
dsp: fdn-wr | state:VerbState params:VerbParams buf off i x -- |
  state.fpos& i f@i | p |
  x  buf off p f+  f!i
  p params.flen& i f@i vb-next state.fpos& i f!i
;

( state params buf xl xr ma mb -- wl wr : one FDN sample. )
dsp: verb-fdn | state:VerbState params:VerbParams buf xl xr ma mb -- wl wr |
  ( input diffusion, per side )
  buf 223492.0 state.fap-l0-pos& params.fap-len& 0.0 f@i xl params.fap-g vb-ap | al0 |
  buf 220032.0 state.fap-l1-pos& params.fap-len& 1.0 f@i al0 params.fap-g vb-ap | al1 |
  buf 220669.0 state.fap-l2-pos& params.fap-len& 2.0 f@i al1 params.fap-g vb-ap | al2 |
  buf 223835.0 state.fap-l3-pos& params.fap-len& 3.0 f@i al2 params.fap-g vb-ap | il |
  buf 225186.0 state.fap-r0-pos& params.fap-len& 4.0 f@i xr params.fap-g vb-ap | ar0 |
  buf 221666.0 state.fap-r1-pos& params.fap-len& 5.0 f@i ar0 params.fap-g vb-ap | ar1 |
  buf 222387.0 state.fap-r2-pos& params.fap-len& 6.0 f@i ar1 params.fap-g vb-ap | ar2 |
  buf 225571.0 state.fap-r3-pos& params.fap-len& 7.0 f@i ar2 params.fap-g vb-ap | ir |
  ( read, decay, damp )
  state params 0.0  state params buf 157214.0 0.0 fdn-rd  fdn-dec | d0 |
  state params 1.0  state params buf 161559.0 1.0 ma fdn-rdm  fdn-dec | d1 |
  state params 2.0  state params buf 167066.0 2.0 fdn-rd  fdn-dec | d2 |
  state params 3.0  state params buf 173277.0 3.0 fdn-rd  fdn-dec | d3 |
  state params 4.0  state params buf 180478.0 4.0 fdn-rd  fdn-dec | d4 |
  state params 5.0  state params buf 188729.0 5.0 fdn-rd  fdn-dec | d5 |
  state params 6.0  state params buf 197982.0 6.0 mb fdn-rdm  fdn-dec | d6 |
  state params 7.0  state params buf 208529.0 7.0 fdn-rd  fdn-dec | d7 |
  ( outputs from the damped lines, before the mix )
  d0 d2 f+ d4 f- d6 f- 0.5 f* params.fout f*
  d1 d3 f+ d5 f- d7 f- 0.5 f* params.fout f* | wl wr |
  ( Hadamard 8, three butterfly stages, 1/sqrt 8 )
  d0 d1 f+ | a0 |  d0 d1 f- | a1 |  d2 d3 f+ | a2 |  d2 d3 f- | a3 |
  d4 d5 f+ | a4 |  d4 d5 f- | a5 |  d6 d7 f+ | a6 |  d6 d7 f- | a7 |
  a0 a2 f+ | b0 |  a1 a3 f+ | b1 |  a0 a2 f- | b2 |  a1 a3 f- | b3 |
  a4 a6 f+ | b4 |  a5 a7 f+ | b5 |  a4 a6 f- | b6 |  a5 a7 f- | b7 |
  il 0.5 f* | jl |
  ir 0.5 f* | jr |
  state params buf 157214.0 0.0  b0 b4 f+ 0.35355339059327373 f* jl f+  fdn-wr
  state params buf 161559.0 1.0  b1 b5 f+ 0.35355339059327373 f* jr f+  fdn-wr
  state params buf 167066.0 2.0  b2 b6 f+ 0.35355339059327373 f* jl f+  fdn-wr
  state params buf 173277.0 3.0  b3 b7 f+ 0.35355339059327373 f* jr f+  fdn-wr
  state params buf 180478.0 4.0  b0 b4 f- 0.35355339059327373 f* jl f+  fdn-wr
  state params buf 188729.0 5.0  b1 b5 f- 0.35355339059327373 f* jr f+  fdn-wr
  state params buf 197982.0 6.0  b2 b6 f- 0.35355339059327373 f* jl f+  fdn-wr
  state params buf 208529.0 7.0  b3 b7 f- 0.35355339059327373 f* jr f+  fdn-wr
  wl wr
;

( --- early reflections, gate, output ---------------------------------- )

( state params buf -- el er : 8 taps a side off the predelay rings. )
dsp: verb-er | state:VerbState params:VerbParams buf -- el er |
  state.pre-pos | p |
  buf 0.0 p PRE-LEN params.er-tl& 0.0 f@i vb-tap 0.84 f*
  buf 0.0 p PRE-LEN params.er-tl& 1.0 f@i vb-tap -0.71 f* f+
  buf 0.0 p PRE-LEN params.er-tl& 2.0 f@i vb-tap 0.62 f* f+
  buf 0.0 p PRE-LEN params.er-tl& 3.0 f@i vb-tap -0.55 f* f+
  buf 0.0 p PRE-LEN params.er-tl& 4.0 f@i vb-tap 0.47 f* f+
  buf 0.0 p PRE-LEN params.er-tl& 5.0 f@i vb-tap -0.40 f* f+
  buf 0.0 p PRE-LEN params.er-tl& 6.0 f@i vb-tap 0.33 f* f+
  buf 0.0 p PRE-LEN params.er-tl& 7.0 f@i vb-tap -0.27 f* f+
  params.early f* 0.5 f*
  buf PRE-R p PRE-LEN params.er-tr& 0.0 f@i vb-tap 0.84 f*
  buf PRE-R p PRE-LEN params.er-tr& 1.0 f@i vb-tap -0.71 f* f+
  buf PRE-R p PRE-LEN params.er-tr& 2.0 f@i vb-tap 0.62 f* f+
  buf PRE-R p PRE-LEN params.er-tr& 3.0 f@i vb-tap -0.55 f* f+
  buf PRE-R p PRE-LEN params.er-tr& 4.0 f@i vb-tap 0.47 f* f+
  buf PRE-R p PRE-LEN params.er-tr& 5.0 f@i vb-tap -0.40 f* f+
  buf PRE-R p PRE-LEN params.er-tr& 6.0 f@i vb-tap 0.33 f* f+
  buf PRE-R p PRE-LEN params.er-tr& 7.0 f@i vb-tap -0.27 f* f+
  params.early f* 0.5 f*
;

( The GATED mode's wet gain for this sample, keyed by `key`: io.det, the
  max of |L| |R| of the dry input, or of a sidechain key's when the host
  sets one [docs/23].  Either way both channels open together. )
dsp: verb-gate | state:VerbState params:VerbParams key -- g |
  key params.gate-thr  state.gate-t 1.0 f+  0.0  fsel-lt | t |
  t -> state.gate-t
  t params.gate-hold f/ | u |
  params.gate-shape | sh |
  ( ramp over the window: 1 - u decaying, u rising )
  sh 0.0  1.0 u f-  u  fsel-lt | r |
  1.0  sh fabs  r 1.0 f-  f*  f+ | w |
  u 1.0 w 0.0 fsel-lt | target |
  state.gate-g | g |
  g target params.gate-atk params.gate-rel fsel-lt | k |
  g  target g f-  k f*  f+ | gn |
  gn -> state.gate-g
  gn
;

( z1p z2p a x -- y : LOW CUT, two one-pole highpasses. )
dsp: verb-lowcut | z1p z2p a x -- y |
  z1p f@64 | z1 |
  z1  x z1 f-  a f*  f+ | l1 |
  l1 z1p f!64
  x l1 f- | h1 |
  z2p f@64 | z2 |
  z2  h1 z2 f-  a f*  f+ | l2 |
  l2 z2p f!64
  h1 l2 f-
;

( io ctx state params -- : one stereo reverb sample.  Ring writes [f!i]
  land at the end of the word; every read sits at least one sample behind
  the write heads, so that ordering is unobservable. )
dsp: k-verb-tick | io:Io ctx state:VerbState params:VerbParams -- |
  state.buf& p@64 | buf |
  io.in-l | xl |
  io.in-r | xr |
  ( LOW CUT, HI CUT, then the predelay rings )
  state.lc-l1& state.lc-l2& params.lc-a xl verb-lowcut | fl0 |
  state.lc-r1& state.lc-r2& params.lc-a xr verb-lowcut | fr0 |
  state.hc-l | hl0 |
  hl0  fl0 hl0 f-  params.bw-a f*  f+ | fl |
  fl -> state.hc-l
  state.hc-r | hr0 |
  hr0  fr0 hr0 f-  params.bw-a f*  f+ | fr |
  fr -> state.hc-r
  state.pre-pos | p |
  buf 0.0 p PRE-LEN params.pre-spl vb-tap | dl |
  buf PRE-R p PRE-LEN params.pre-spl vb-tap | dr |
  ( the tank LFO: a magic-circle pair, s += k c, c -= k s )
  state.lfo-s params.mod-k state.lfo-c f* f+ | ls |
  state.lfo-c params.mod-k ls f* f- | lc |
  ls -> state.lfo-s
  lc -> state.lfo-c
  ls 1.0 f+ 0.5 f* params.mod-spl f* | ma |
  lc 1.0 f+ 0.5 f* params.mod-spl f* | mb |
  ( the late tank )
  params.algo 0.5 f<
  [ state params buf dl dr ma mb verb-plate ]
  [ state params buf dl dr ma mb verb-fdn ]
  ifte | tl tr |
  ( early reflections )
  params.early 0.0 f>
  [ state params buf verb-er | el er |  tl el f+  tr er f+ ]
  [ tl tr ]
  ifte | wl0 wr0 |
  ( the gate leaves the wet path untouched, bit for bit, when off )
  params.mode 0.5 f<
  [ wl0 wr0 ]
  [ state params io.det verb-gate | gg |  wl0 gg f*  wr0 gg f* ]
  ifte | wl wr |
  ( predelay ring writes and head )
  fl buf p f!i
  fr  buf PRE-R p f+  f!i
  p PRE-LEN vb-next -> state.pre-pos
  ( WIDTH, mid/side, and the mix )
  wl wr f+ 0.5 f* | m |
  wl wr f- 0.5 f* params.width f* | s |
  1.0 params.mix f- | dg |
  xl dg f*  m s f+ params.mix f*  f+ -> io.out-l
  xr dg f*  m s f- params.mix f*  f+ -> io.out-r
;
