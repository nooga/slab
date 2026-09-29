( char.fy - character compressor [docs/24 §Character modes]: three
  bundles of the survey's knobs, not circuit models.

         knee   detector  release                          colour
    FET   2 dB  PEAK      REL                              odd-leaning
    OPTO 12 dB  RMS       half 60 ms, half REL - and REL   even, light
                          stretches to 3x after long squash
    VARI 24 dB  PEAK      deeper of REL and a slow branch  even, heavy
                          [charge 0.5 s, release 5 x REL]

  VARI's 24 dB knee is the vari-mu curve: the ratio rises with level
  over two dozen dB before it reaches RATIO.  OPTO's two stages are the
  LA-2A's "half back in 60 ms, the rest over seconds"; its memory is a
  3 s follower of how hard it has been squashing.  No feedback topology:
  a digital loop with a fast attack at a high ratio is unstable [docs/24
  §bus2 as built], and what the hardware's feedback buys - softer,
  program-dependent timing - is what the modes set directly.

  The detector and gain computer are comp.fy's; the colour is bus.fy's
  2x shaper, growing with the gain reduction, with per-mode 2nd / 3rd
  weights scaled by DRIVE.  DRIVE 0 is clean, and the host runs the
  cheaper k-char-tick-clean for those blocks [render-lite].

  Layout: CompState then CharState; CompParams then CharParams. The
  derive word sets comp.fy's knee and detector from MODE before
  block-prepare reads them. )

include "bus.fy"   ( comp.fy, Up2 / Dec2, BusDc, bus-color, bus-out )

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
;

ustruct: CharParams  ( after CompParams )
  ( user-facing )
  f64 mode     ( 0 FET, 1 OPTO, 2 VARI )
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
;

:: CHAR-OPTO-FAST 0.06 ;
:: CHAR-OPTO-MEM 3.0 ;       ( the memory's time constant )
:: CHAR-OPTO-STRETCH 3.0 ;   ( slow release x this at full memory )
:: CHAR-OPTO-FULL 0.16666666666666666 ;   ( memory fills towards 1 at 6 dB GR )
:: CHAR-VARI-CHARGE 0.5 ;
:: CHAR-VARI-SLOW 5.0 ;      ( slow release, x REL )

( m f o v -- x : the FET, OPTO or VARI value for mode m. )
dsp: char-pick | m f o v -- x |
  m 0.5 f  m 1.5 o v fsel-lt  fsel-lt
;

( ctx state params -- : the mode's knee and detector into comp.fy's
  params [derive runs before block-prepare]. )
dsp: char-derive | ctx state params:CompParams |
  params CompParams.size ptr+ f@64 | m |
  m 2.0 12.0 24.0 char-pick -> params.knee-db
  m 0.0 1.0 0.0 char-pick -> params.det
;

( sr atk rel thresh knee cs cp -- : the followers, memory and colour. )
dsp: char-prepare | sr atk rel thresh knee cs:CharState cp:CharParams |
  cp.mode | m |
  knee -> cs.knee
  atk sr comp-tau-coeff -> cp.atk-c
  m rel CHAR-OPTO-FAST rel char-pick  sr comp-tau-coeff -> cp.rel-c
  m atk atk CHAR-VARI-CHARGE char-pick  sr comp-tau-coeff -> cp.satk-c
  m rel rel  rel CHAR-VARI-SLOW f*  char-pick | srel |
  srel sr comp-tau-coeff -> cp.srel-c
  m srel  srel CHAR-OPTO-STRETCH f*  srel char-pick  sr comp-tau-coeff -> cp.srel3-c
  m 0.0 0.5 0.0 char-pick -> cp.blend
  m 0.0 0.0 1.0 char-pick -> cp.use-min
  CHAR-OPTO-MEM sr comp-tau-coeff -> cp.mem-c
  m 0.08 0.25 0.4 char-pick  cp.drive f* -> cp.k2
  m 0.35 0.04 0.1 char-pick  cp.drive f* -> cp.k3
  thresh db>lin | t |
  t -> cp.t-lin
  1.0 t f/ -> cp.inv-t
;

( ctx state params -- )
dsp: char-block-prepare | ctx:Ctx state params:CompParams |
  ctx state params comp-block-prepare
  ctx.sr params.atk-s params.rel-s params.thresh-db params.knee-db
  state CompState.size ptr+  params CompParams.size ptr+  char-prepare
;

( cs cp gt -- g : both followers, the mode's mix of them [log2], the
  meter cell and the OPTO memory. )
dsp: char-follow | cs:CharState cp:CharParams gt -- g |
  cs.gf | f0 |
  gt f0 cp.atk-c cp.rel-c fsel-lt | cf |
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
  io state params comp-detect comp-level
  params swap comp-knee | gt |
  state CompState.size ptr+ | cs:CharState |
  params CompParams.size ptr+ | cp:CharParams |
  cs cp gt char-follow | g |
  g exp2 | gain |
  g -6.0205999132796239 f*  BUS-COLOR-FULL f* 0.0 1.0 fclamp | amt |
  cp.k2 amt f* | a2 |
  cp.k3 amt f* | a3 |
  cp.t-lin | t |
  cp.inv-t | it |
  cs.ul& cs.dl& cs.dcl&  io.in-l gain f*  a2 a3 t it bus-color | yl |
  cs.ur& cs.dr& cs.dcr&  io.in-r gain f*  a2 a3 t it bus-color | yr |
  io params yl yr bus-out
;

( io ctx state params -- : the same at DRIVE 0, without the colour
  stage [render-lite]. )
dsp: k-char-tick-clean | io:Io ctx state params:CompParams -- |
  io state params comp-detect comp-level
  params swap comp-knee | gt |
  state CompState.size ptr+  params CompParams.size ptr+  gt char-follow exp2 | gain |
  io params  io.in-l gain f*  io.in-r gain f*  bus-out
;
