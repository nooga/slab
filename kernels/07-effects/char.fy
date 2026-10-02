( char.fy - character compressor [docs/24 §Character modes]: four
  bundles of the survey's knobs, not circuit models, and a LO-FI / WOW
  stage after them.

         knee   detector  attack       release                    color
    FET   2 dB  PEAK      ATK          REL                        odd-leaning
    OPTO 12 dB  RMS       ATK          half 60 ms, half REL - and even, light
                                       REL stretches to 3x after
                                       long squash
    VARI 24 dB  PEAK      ATK          deeper of REL and a slow   even, heavy
                                       branch [charge 0.5 s,
                                       release 5 x REL]
    SMUSH  3 dB  PEAK      faster the   REL; auto makeup brings    odd + even
                          further over the room up between hits

  VARI's 24 dB knee is the vari-mu curve: the ratio rises with level
  over two dozen dB before it reaches RATIO.  OPTO's two stages are the
  LA-2A's "half back in 60 ms, the rest over seconds"; its memory is a
  3 s follower of how hard it has been squashing.  No feedback topology:
  a digital loop with a fast attack at a high ratio is unstable [docs/24
  §bus2 as built], and what the hardware's feedback buys - softer,
  program-dependent timing - is what the modes set directly.

  SMUSH is the Boss SP-303 "Vinyl Sim" squash as Goodhertz's Vulf
  Compressor extends it [docs/24 §SMUSH]: no fixed attack time - the
  attack step grows with how far the target is below the gain,
  c' = c - [1 - c] * k * over, so a hit 12 dB over clamps 3x faster than
  the knob says and a small one breathes at ATK - and automatic makeup
  of half the static reduction at 0 dBFS, so the gaps between hits
  [room, tails, the LO-FI noise] come up as the gain recovers.

  After the color, in every mode: WOW [wow.fy - wow and flutter at the
  record's RPM], then LO-FI [lofi.fy - ANALOG / 90s / 80s].  LO-FI's
  NOISE goes in before the gain, gated by the detector, so the
  compression pumps it.

  The detector and gain computer are comp.fy's; the color is bus.fy's
  2x shaper, growing with the gain reduction, with per-mode 2nd / 3rd
  weights scaled by DRIVE.  DRIVE 0, LOFI 0 and WOW 0 are each clean and
  each skipped [ifte on params, docs/05 §Branching].

  Layout: CompState then CharState; CompParams then CharParams. The
  derive word sets comp.fy's knee and detector from MODE before
  block-prepare reads them. )

include "bus.fy"   ( comp.fy, Up2 / Dec2, BusDc, bus-color )
include "lofi.fy"
include "wow.fy"

ustruct: CharState   ( after CompState )
  f64 gf       ( fast follower, log2 )
  f64 gs       ( slow follower, log2 )
  f64 mem      ( OPTO memory: 3 s follower of GR / 6 dB, 0..1 )
  f64 gr-db    ( meter feed )
  f64 knee     ( the mode's knee, dB - display feed )
  Up2 ul
  Up2 ur
  Dec2 dl
  Dec2 dr
  BusDc dcl
  BusDc dcr
  LofiState lofi
  WowState wow
;

ustruct: CharParams  ( after CompParams )
  ( user-facing )
  f64 mode     ( 0 FET, 1 OPTO, 2 VARI, 3 SMUSH )
  f64 drive    ( 0..1 )
  ( derived )
  f64 atk-c
  f64 rel-c    ( fast release )
  f64 satk-c   ( slow branch attack )
  f64 srel-c   ( slow branch release )
  f64 srel3-c  ( ... with a full memory [OPTO] )
  f64 blend    ( weight of the slow branch in the gain )
  f64 use-min  ( 1: the deeper of the two instead [VARI] )
  f64 mem-c
  f64 k2
  f64 k3
  f64 t-lin
  f64 inv-t
  f64 atk-k    ( SMUSH: attack speed-up per log2 unit over )
  f64 auto-lin ( SMUSH: automatic makeup, linear [1 otherwise] )
  LofiParams lofi
  WowParams wow
;

:: CHAR-OPTO-FAST 0.06 ;
:: CHAR-OPTO-MEM 3.0 ;       ( the memory's time constant )
:: CHAR-OPTO-STRETCH 3.0 ;   ( slow release x this at full memory )
:: CHAR-OPTO-FULL 0.16666666666666666 ;   ( memory fills towards 1 at 6 dB GR )
:: CHAR-VARI-CHARGE 0.5 ;
:: CHAR-VARI-SLOW 5.0 ;      ( slow release, x REL )
:: CHAR-SMUSH-K 1.0 ;         ( attack 1 + k*over times faster, over in log2 [6 dB] )
:: CHAR-SMUSH-AUTO 0.5 ;      ( share of the static GR at 0 dBFS made up )

( m f o v -- x : the FET, OPTO or VARI value for mode m. )
dsp: char-pick | m f o v -- x |
  m 0.5 f  m 1.5 o v fsel-lt  fsel-lt
;

( m f o v u -- x : the FET, OPTO, VARI or SMUSH value for mode m. )
dsp: char-pick4 | m f o v u -- x |
  m 0.5 f  m 1.5 o  m 2.5 v u fsel-lt  fsel-lt  fsel-lt
;

( ctx state params -- : the mode's knee and detector into comp.fy's
  params [derive runs before block-prepare]. )
dsp: char-derive | ctx state params:CompParams |
  params CompParams.size ptr+ f@64 | m |
  m 2.0 12.0 24.0 3.0 char-pick4 -> params.knee-db
  m 0.0 1.0 0.0 0.0 char-pick4 -> params.det
;

( sr atk rel thresh knee ratio cs cp -- : the followers, memory, color
  and SMUSH's attack and makeup. )
dsp: char-prepare | sr atk rel thresh knee ratio cs:CharState cp:CharParams |
  cp.mode | m |
  knee -> cs.knee
  atk sr comp-tau-coeff -> cp.atk-c
  m rel CHAR-OPTO-FAST rel rel char-pick4  sr comp-tau-coeff -> cp.rel-c
  m atk atk CHAR-VARI-CHARGE atk char-pick4  sr comp-tau-coeff -> cp.satk-c
  m rel rel  rel CHAR-VARI-SLOW f*  rel char-pick4 | srel |
  srel sr comp-tau-coeff -> cp.srel-c
  m srel  srel CHAR-OPTO-STRETCH f*  srel srel char-pick4  sr comp-tau-coeff -> cp.srel3-c
  m 0.0 0.5 0.0 0.0 char-pick4 -> cp.blend
  m 0.0 0.0 1.0 0.0 char-pick4 -> cp.use-min
  CHAR-OPTO-MEM sr comp-tau-coeff -> cp.mem-c
  m 0.08 0.25 0.4 0.15 char-pick4  cp.drive f* -> cp.k2
  m 0.35 0.04 0.1 0.25 char-pick4  cp.drive f* -> cp.k3
  thresh db>lin | t |
  t -> cp.t-lin
  1.0 t f/ -> cp.inv-t
  m 0.0 0.0 0.0 CHAR-SMUSH-K char-pick4 -> cp.atk-k
  0.0 thresh f-  1.0 1.0 ratio f/ f-  f*  CHAR-SMUSH-AUTO f* | auto-db |
  m 0.0 0.0 0.0 auto-db char-pick4 db>lin -> cp.auto-lin
;

( ctx state params -- )
dsp: char-block-prepare | ctx:Ctx state params:CompParams |
  ctx state params comp-block-prepare
  ctx.sr params.atk-s params.rel-s params.thresh-db params.knee-db params.ratio
  state CompState.size ptr+  params CompParams.size ptr+  char-prepare
  params CompParams.size ptr+ | cp:CharParams |
  ctx.sr cp.lofi& lofi-prepare
  ctx.sr cp.wow& wow-prepare
;

( ctx state params -- : starts the wow oscillators at [0, 1]. )
dsp: char-seed | ctx state params |
  state CompState.size ptr+ | cs:CharState |
  cs.wow& wow-seed
;

( cs cp gt -- g : both followers, the mode's mix of them [log2], the
  meter cell and the OPTO memory. )
dsp: char-follow | cs:CharState cp:CharParams gt -- g |
  cs.gf | f0 |
  gt f0 cp.atk-c cp.rel-c fsel-lt | c0 |
  ( SMUSH: the attack step grows with the distance to go; atk-k is 0 in
    the other modes, where this is c0 exactly )
  c0  1.0 c0 f-  cp.atk-k f*  f0 gt f- 0.0 fmax  f*  f-  0.0 fmax | cf |
  gt  f0 gt f-  cf f*  f+ | gf |
  gf -> cs.gf
  cs.mem | mem |
  cp.srel-c  cp.srel3-c cp.srel-c f-  mem f*  f+ | rs |
  cs.gs | s0 |
  gt s0 cp.satk-c rs fsel-lt | cs0 |
  gt  s0 gt f-  cs0 f*  f+ | gs |
  gs -> cs.gs
  gf  gs gf f-  cp.blend f*  f+ | gb |
  cp.use-min 0.5  gb  gf gs fmin  fsel-lt | g |
  g -6.0205999132796239 f* | gr |
  gr -> cs.gr-db
  gr CHAR-OPTO-FULL f* 0.0 1.0 fclamp | amt |
  amt  mem amt f-  cp.mem-c f*  f+ -> cs.mem
  g
;

( io ctx state params -- : one stereo char2 sample. )
dsp: k-char-tick | io:Io ctx state params:CompParams -- |
  io state params comp-detect | lvl |
  lvl comp-level  params swap comp-knee | gt |
  state CompState.size ptr+ | cs:CharState |
  params CompParams.size ptr+ | cp:CharParams |
  cs cp gt char-follow | g |
  g exp2 | gain |
  ( LO-FI noise goes in before the gain, so it pumps )
  cs.lofi& cp.lofi& lvl io.in-l io.in-r lofi-noise | xl xr |
  xl gain f* | wl |
  xr gain f* | wr |
  cp.k2 0.0 f>  cp.k3 0.0 f>  or
  [ g -6.0205999132796239 f*  BUS-COLOR-FULL f* 0.0 1.0 fclamp | amt |
    cp.k2 amt f* | a2 |
    cp.k3 amt f* | a3 |
    cp.t-lin | t |
    cp.inv-t | it |
    cs.ul& cs.dl& cs.dcl&  wl a2 a3 t it bus-color
    cs.ur& cs.dr& cs.dcr&  wr a2 a3 t it bus-color ]
  [ wl wr ]
  ifte | cl cr |
  cs.wow& cp.wow& cl cr wow-run | vl vr |
  cs.lofi& cp.lofi& vl vr lofi-run | yl yr |
  params.makeup-lin cp.auto-lin f*  params.mix f* | wet |
  1.0 params.mix f- | dry |
  yl wet f*  io.in-l dry f*  f+ -> io.out-l
  yr wet f*  io.in-r dry f*  f+ -> io.out-r
;
