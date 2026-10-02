( tape.fy - tape2: a cassette deck or a VCR's audio, new or worn out
  [docs/25].  Built from the shared kernels:

    in -> DRIVE -> record EQ -> [2x hysteresis] -> playback EQ          tone.fy, hysteresis.fy
       -> transport: wow, flutter, drift, azimuth                     wow.fy
       -> dropouts                                                    dropout.fy
       -> + hiss, hum, head-switch buzz                               hum.fy
       -> head bump -> tape bandwidth -> coupling cap                 tone.fy, lofi.fy
       -> noise reduction out of alignment                            compand.fy
       -> [VHS linear: mono] -> OUT, MIX

  MODE sets the format, WEAR how far gone it is.  The derive word maps
  both [and the knobs] onto each stage's settings once a block:

    MODE        band      emphasis     hiss  sens  bump      wow  NR
    CASS I      12 kHz    1.3 k +6 dB  -52   +3    80 Hz +2  .15  B
    CASS II     15 kHz    2.3 k +6     -57    0    80    +2  .12  B
    CASS IV     17 kHz    2.3 k +5     -60   -4    70  +1.5  .10  B
    VHS LINEAR  8 kHz     1.3 k +4     -44   +2   100    +1  .50  B,
                mono, HP 60 Hz
    VHS HI-FI   20 kHz    -            -78   -6    -         .03  compander,
                head-switch buzz, dropouts burst into hiss  always

    WEAR  0 -> 1:  band x 0.4 [Hi-Fi x 0.75], hiss +10 dB, bump +1.5 dB,
                   wow +0.4, flutter +0.4, randomness 0.2 -> 1,
                   dropouts [6 [DROPS + 0.6 WEAR]^2 a second], azimuth
                   skew up to 1.5 samples, head magnetization [even
                   harmonics], coupling cap x 4 [not Hi-Fi],
                   NR mistrack deeper.

  Record EQ boosts the highs into the curve and playback cuts them back
  [sat2 TAPE's trick: the highs saturate first, and a hot cymbal
  compresses before a kick].  Hiss goes in before the band limit, so the
  tape shapes it; hiss and hum are gated by a 0.7 s follower of the input,
  so a silent track still goes idle.  Each optional stage is behind an
  ifte on its own param. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../00-primitives/oversample.fy"
include "../02-shapers/hysteresis.fy"
include "../04-filters/tone.fy"
include "lofi.fy"      ( lofi-lp-step, lofi-cap, lofi-rand )
include "wow.fy"
include "dropout.fy"
include "hum.fy"
include "compand.fy"

ustruct: TapeState
  Pole prel  Pole prer      ( record EQ )
  Pole postl Pole postr     ( playback EQ )
  Up2 ul  Up2 ur
  Dec2 dl Dec2 dr
  HystState hl
  HystState hr
  WowState wow
  DropState drop
  HumState hum
  CompandState nr
  BellSt bumpl  BellSt bumpr
  f64 lp1l  f64 lp2l  f64 lp1r  f64 lp2r   ( tape bandwidth )
  f64 capl  f64 capr                       ( coupling cap )
  f64 nzl   f64 nzr                        ( hiss generators )
  f64 nenv                                 ( hiss gate )
;

ustruct: TapeParams
  ( user-facing )
  f64 mode      ( 0 CASS I, 1 CASS II, 2 CASS IV, 3 VHS LINEAR, 4 VHS HI-FI )
  f64 wear      ( 0..1 )
  f64 drive-db  ( -12..18 )
  f64 bias      ( 0..1, under- to over-biased )
  f64 wow       ( 0..1, 0.25 = the format's own )
  f64 flutter   ( 0..1, 0.25 = the format's own )
  f64 drops     ( 0..1 )
  f64 hiss      ( 0..1, 0.5 = the format's own, 0 off )
  f64 hum       ( 0..1, 0 off )
  f64 mains     ( Hz: 50 or 60 )
  f64 nr        ( 0 off, 1 on )
  f64 out-db
  f64 mix
  ( derived - tape-derive: the stages' own settings )
  f64 g-db
  f64 off
  f64 bias-eff  ( Hi-Fi records FM: no loop, no dead zone )
  f64 emph-hz
  f64 emph-db
  f64 band-hz
  f64 bump-hz
  f64 bump-db
  f64 cap-hz
  f64 hiss-db
  f64 burst     ( hiss x [1 + burst e] in a dropout )
  f64 mono
  f64 nr-on
  f64 drops-on
  f64 noise-on
  ( derived - tape-block-prepare )
  HystParams hy
  Shelf pre
  Shelf post
  Bell bump
  f64 band-g
  f64 cap-G
  f64 hiss-lvl
  f64 nenv-c
  f64 out-lin
  WowParams wp
  DropParams dp
  HumParams hp
  CompandParams np
;

:: TAPE-OPEN 16.0 ;   ( the hiss gate is fully open above -24 dBFS )

( m a b c d e -- x : the value for MODE m of five. )
dsp: tape-pick | m a b c d e -- x |
  m 0.5 a  m 1.5 b  m 2.5 c  m 3.5 d e  fsel-lt fsel-lt fsel-lt fsel-lt
;

( ctx state params -- : MODE, WEAR and the knobs onto each stage. )
dsp: tape-derive | ctx:Ctx state params:TapeParams |
  params.mode | m |
  params.wear 0.0 1.0 fclamp | w |
  params.wp& | wp:WowParams |
  params.dp& | dp:DropParams |
  params.hp& | hp:HumParams |
  params.np& | np:CompandParams |
  ( 0 dBFS sits 6 dB over the curve's knee at DRIVE 0 )
  params.drive-db -6.0 f+  m 3.0 0.0 -4.0 2.0 -6.0 tape-pick  f+ -> params.g-db
  m 1.0 1.0 1.0 1.0 0.0 tape-pick | lossy |
  0.02 w 0.12 f* f+  lossy f* -> params.off
  lossy 0.5 f>  params.bias  1.0  select -> params.bias-eff
  m 1300.0 2300.0 2300.0 1300.0 3000.0 tape-pick -> params.emph-hz
  m 6.0 6.0 5.0 4.0 0.0 tape-pick -> params.emph-db
  m 12000.0 15000.0 17000.0 8000.0 20000.0 tape-pick
  1.0  w  lossy 0.6 f*  1.0 lossy f- 0.25 f*  f+  f*  f-  f*
  1.15 params.bias 0.3 f* f-  f* -> params.band-hz
  m 80.0 80.0 70.0 100.0 60.0 tape-pick -> params.bump-hz
  m 2.0 2.0 1.5 1.0 0.0 tape-pick  w  lossy 1.5 f*  1.0 lossy f- 0.5 f*  f+  f*  f+ -> params.bump-db
  m 7.0 7.0 7.0 60.0 7.0 tape-pick  1.0 w 3.0 f* lossy f* f+  f* -> params.cap-hz
  m -52.0 -57.0 -60.0 -44.0 -78.0 tape-pick  params.hiss 0.5 f- 24.0 f* f+  w 10.0 f* f+ -> params.hiss-db
  m 3.0 3.0 3.0 3.0 30.0 tape-pick -> params.burst
  m 2.5 f<  0.0  m 3.5 f< 1.0 0.0 select  select -> params.mono
  ( transport )
  m 0.15 0.12 0.1 0.5 0.03 tape-pick  params.wow 4.0 f* f*  w 0.4 f* f+ -> wp.depth
  m 0.1 0.08 0.06 0.3 0.02 tape-pick  params.flutter 4.0 f* f*  w 0.4 f* f+ -> wp.flutter
  m 0.9 0.9 0.9 0.5 0.5 tape-pick -> wp.rate
  0.2 w 0.8 f* f+ -> wp.rnd
  m 1.0 1.0 1.0 0.0 0.0 tape-pick  0.05 w 1.5 f* f+  f*  ctx.sr f*  0.00002083333333333333 f* -> wp.skew
  ( dropouts )
  params.drops w 0.6 f* f+ | dr |
  6.0 dr f* dr f* -> dp.rate
  0.4  0.6 dr 1.0 fmin f*  f+ -> dp.depth
  0.0 dr f< 1.0 0.0 select -> params.drops-on
  ( hum and buzz )
  0.0 params.hum f<  params.hum 40.0 f* -80.0 f+ w 6.0 f* f+ db>lin  0.0  select -> hp.lvl
  m 2.5 f<  0.0  w 22.0 f* -68.0 f+ db>lin  select -> hp.sw
  params.mains -> hp.mains
  0.0 params.hiss f<  0.0 params.hum f<  or  m 2.5 f< not  or  1.0 0.0 select -> params.noise-on
  ( noise reduction: Dolby B when switched on, the Hi-Fi compander always )
  params.nr 0.5 f>  m 3.5 f> or  1.0 0.0 select -> params.nr-on
  m 3.5 f<  1500.0 30.0 select -> np.split
  m 3.5 f<  0.05 w 0.35 f* f+  0.03 w 0.2 f* f+  select  0.0 swap f- -> np.amt
  m 3.5 f<  -38.0 -45.0 select -> np.ref-db
;

( ctx state params -- )
dsp: tape-block-prepare | ctx:Ctx state params:TapeParams |
  ctx.sr | sr |
  params.hy& params.g-db db>lin params.bias-eff params.off hyst-set
  params.pre&  params.emph-hz params.emph-db 1.0 sr shelf-set
  params.post& params.emph-hz  0.0 params.emph-db f-  1.0 sr shelf-set
  params.bump& params.bump-hz params.bump-db 1.2 sr bell-set
  params.band-hz 200.0 20000.0 fclamp sr svf-g -> params.band-g
  params.cap-hz sr pole-G -> params.cap-G
  0.0 params.hiss f<  params.hiss-db db>lin  0.0  select -> params.hiss-lvl
  -1.0  0.7 sr f*  f/ exp -> params.nenv-c
  params.out-db db>lin -> params.out-lin
  sr params.wp& wow-prepare
  sr params.dp& drop-prepare
  sr params.hp& hum-prepare
  sr params.np& compand-prepare
;

( ctx state params -- : start the oscillators. )
dsp: tape-seed | ctx state:TapeState params |
  state.wow& wow-seed
  state.hum& hum-seed
;

( up dn st hp x -- y : the hysteresis at 2x. )
dsp: tape-hyst | up:Up2 dn:Dec2 st:HystState hp:HystParams x -- y |
  up x up2 | x0 x1 |
  st hp x0 hyst-tick | y0 |
  st hp x1 hyst-tick | y1 |
  dn y0 y1 dec2
;

( io ctx state params -- : one stereo tape2 sample. )
dsp: k-tape-tick | io:Io ctx state:TapeState params:TapeParams -- |
  io.in-l | il |
  io.in-r | ir |
  ( record: emphasis into the curve and back out )
  params.pre& il state.prel& shelf-hi | al |
  params.pre& ir state.prer& shelf-hi | ar |
  state.ul& state.dl& state.hl& params.hy& al tape-hyst | bl |
  state.ur& state.dr& state.hr& params.hy& ar tape-hyst | br |
  params.post& bl state.postl& shelf-hi | cl |
  params.post& br state.postr& shelf-hi | cr |
  ( transport )
  state.wow& params.wp& cl cr wow-run | dl dr |
  params.drops-on 0.5 f<
  [ dl dr 0.0 ]
  [ state.drop& params.dp& dl dr drop-tick ]
  ifte | el er e |
  ( hiss, hum, buzz )
  params.noise-on 0.5 f<
  [ el er ]
  [ il fabs ir fabs fmax | lvl |
    state.nenv | n0 |
    lvl  n0 params.nenv-c f*  fmax | n1 |
    n1 1.0e-7 f<  0.0 n1 select -> state.nenv
    n0 TAPE-OPEN f* 1.0 fmin  params.hiss-lvl f*  1.0 params.burst e f* f+  f* | na |
    state.hum& params.hp& lvl hum-tick | h |
    el  state.nzl& 0.31337 lofi-rand na f*  f+  h f+
    er  state.nzr& 0.71993 lofi-rand na f*  f+  h f+ ]
  ifte | fl fr |
  ( playback head: bump, bandwidth, coupling cap )
  state.bumpl& params.bump& fl bell-tick | gl |
  state.bumpr& params.bump& fr bell-tick | gr |
  state.lp1l& state.lp2l& gl params.band-g lofi-lp-step | hl |
  state.lp1r& state.lp2r& gr params.band-g lofi-lp-step | hr |
  state.capl& hl params.cap-G lofi-cap | kl |
  state.capr& hr params.cap-G lofi-cap | kr |
  params.nr-on 0.5 f<
  [ kl kr ]
  [ state.nr& params.np& kl kr compand-tick ]
  ifte | ml mr |
  params.mono 0.5 f<
  [ ml mr ]
  [ ml mr f+ 0.5 f* | mm |  mm mm ]
  ifte | yl yr |
  params.out-lin params.mix f* | wet |
  1.0 params.mix f- | dry |
  yl wet f*  il dry f*  f+ -> io.out-l
  yr wet f*  ir dry f*  f+ -> io.out-r
;
