( reverb.fy - Dattorro plate tank on one packed host buffer.

  Topology [Dattorro 1997, Effect Design part 1]: predelay -> bandwidth
  lowpass -> 4 series input diffusion allpasses -> figure-8 tank of two
  branches, each: decay-diffusion allpass with a slow modulated read tap,
  long delay, damping lowpass, decay gain, second allpass, second delay.
  Each branch is fed the diffused input plus decay times the other
  branch's final delay.  Output is seven taps summed off the tank rings.

  The whole structure lives in ONE host-allocated buffer per channel,
  carved into fixed-capacity regions sized for 96 kHz; the EFFECTIVE
  ring lengths scale with the actual sample rate at block-prepare so the
  reverb sounds identical at any rate.  All region base offsets below
  are compile-time literals - the capacity table:

    region        offset   cap     base-len at 29761 Hz
    predelay      0        12288   knob, up to 128 ms
    in-ap1        12288    480     142   g 0.75
    in-ap2        12768    360     107   g 0.75
    in-ap3        13128    1248    379   g 0.625
    in-ap4        14376    912     277   g 0.625
    a-ap1         15288    2304    672   g 0.70, modulated
    a-d1          17592    14400   4453
    a-ap2         31992    5824    1800  g 0.50
    a-d2          37816    12032   3720
    b-ap1         49848    3072    908   g 0.70, modulated
    b-d1          52920    13632   4217
    b-ap2         66552    8576    2656  g 0.50
    b-d2          75128    10240   3163
    total         85368             -> 0.9 s buffer at 96 kHz

  Dual mono with decorrelation: the host channel-cell drives a per
  channel LFO phase and rate offset plus the L/R output tap sets, so the
  two tanks drift apart and the tail goes wide.  Probe case:
  reverb-render - impulse, RT60 + echo density ratchets, WAV. )

include "../05-drums/sine.fy"

ustruct: VerbState
  f64 buf        ( host-injected ring base pointer )
  f64 buf-len    ( host-injected element count )
  f64 chan       ( host-injected channel index, 0 L / 1 R )
  f64 diff       ( stage scratch: diffused input )
  f64 ta         ( stage scratch: branch A first-delay output )
  f64 tb         ( stage scratch: branch B first-delay output )
  f64 mlfo-a     ( stage scratch: branch A mod offset, samples )
  f64 mlfo-b     ( stage scratch: branch B mod offset, samples )
  f64 lfo-phase
  f64 seeded     ( 0 fresh state, 1 after first prepare )
  f64 in-lpf     ( bandwidth filter state )
  f64 damp-a-z   ( branch A damping state )
  f64 damp-b-z   ( branch B damping state )
  f64 mod-inc-ch ( per-channel LFO increment )
  f64 pre-pos
  f64 inap1-pos  f64 inap2-pos  f64 inap3-pos  f64 inap4-pos
  f64 a-ap1-pos  f64 a-d1-pos   f64 a-ap2-pos  f64 a-d2-pos
  f64 b-ap1-pos  f64 b-d1-pos   f64 b-ap2-pos  f64 b-d2-pos
  f64 tap-1  f64 tap-2  f64 tap-3  f64 tap-4
  f64 tap-5  f64 tap-6  f64 tap-7
;

ustruct: VerbParams
  ( user-facing )
  f64 predelay-s
  f64 decay      ( tank feedback gain, 0.3..0.97 )
  f64 damp-hz    ( tank damping lowpass cutoff )
  f64 bw-hz      ( input bandwidth lowpass cutoff )
  f64 mix
  f64 mod-depth  ( excursion in reference samples, const ~10 )
  f64 mod-rate   ( Hz, const ~1.2 )
  ( derived - filled by verb-block-prepare )
  f64 scale      ( sr / 29761 )
  f64 pre-len
  f64 inap1-len  f64 inap2-len  f64 inap3-len  f64 inap4-len
  f64 a-ap1-len  f64 a-d1-len   f64 a-ap2-len  f64 a-d2-len
  f64 b-ap1-len  f64 b-d1-len   f64 b-ap2-len  f64 b-d2-len
  f64 bw-a
  f64 damp-a
  f64 mod-inc
  f64 mod-depth-spl
;

( --- ring helpers: inlined into each stage ------------------------- )

( buf off posp len x g -- y : one allpass ring tick.
  v = ring out, w = x - g*v written back, y = v + g*w. )
dsp2: vb-ap
  | buf off posp len x g |
  posp f@64 | p |
  off p f+ | idx |
  buf idx f@i | v |
  x g v f* f- | w |
  w buf idx f!i
  p 1.0 f+ | p1 |
  p1 len  p1  p1 len f-  fsel-lt posp f!64
  v g w f* f+
  nip nip nip nip nip nip nip nip nip nip nip
;

( buf off posp len x g m -- y : allpass with a modulated fractional
  read tap.  The oldest sample sits just ahead of the write head, so the
  tap reads at p+1+m for an effective delay of len-1-m - the chorusing
  inside the tank. )
dsp2: vb-apm
  | buf off posp len x g m |
  posp f@64 | p |
  p 1.0 f+ m f+ | r0 |
  r0 len  r0  r0 len f-  fsel-lt | r |
  buf off r f+ f@i | s0 |
  r 1.0 f+ | r1 |
  r1 len  r1  r1 len f-  fsel-lt | rw |
  buf off rw f+ f@i | s1 |
  s0  s1 s0 f-  r ffrac f*  f+ | v |
  x g v f* f- | w |
  w  buf off p f+  f!i
  p 1.0 f+ | p1 |
  p1 len  p1  p1 len f-  fsel-lt posp f!64
  v g w f* f+
  nip nip nip nip nip nip nip nip nip nip nip nip nip nip nip nip nip
;

( buf off posp len x -- y : plain delay ring tick. )
dsp2: vb-dl
  | buf off posp len x |
  posp f@64 | p |
  off p f+ | idx |
  buf idx f@i | v |
  x buf idx f!i
  p 1.0 f+ | p1 |
  p1 len  p1  p1 len f-  fsel-lt posp f!64
  v
  nip nip nip nip nip nip nip nip nip
;

( buf off pos len tap -- v : static read tap behind the write head. )
dsp2: vb-tap
  | buf off pos len tap |
  pos tap f- | i |
  i 0.0  i len f+  i fsel-lt | iw |
  buf  off iw f+  f@i
  nip nip nip nip nip nip nip
;

( --- block-rate fills ----------------------------------------------- )

( params sample-rate -- : effective ring lengths + coefficients. )
dsp2: verb-block-prepare
  | params sr |
  sr 0.000033601021471 f* | scale |
  scale params VerbParams.scale-p f!64
  params VerbParams.predelay-s@ sr f* 1.0 12287.0 fclamp
  dup ffrac f- params VerbParams.pre-len-p f!64
  142.0 scale f* dup ffrac f- params VerbParams.inap1-len-p f!64
  107.0 scale f* dup ffrac f- params VerbParams.inap2-len-p f!64
  379.0 scale f* dup ffrac f- params VerbParams.inap3-len-p f!64
  277.0 scale f* dup ffrac f- params VerbParams.inap4-len-p f!64
  672.0 scale f* dup ffrac f- params VerbParams.a-ap1-len-p f!64
  4453.0 scale f* dup ffrac f- params VerbParams.a-d1-len-p f!64
  1800.0 scale f* dup ffrac f- params VerbParams.a-ap2-len-p f!64
  3720.0 scale f* dup ffrac f- params VerbParams.a-d2-len-p f!64
  908.0 scale f* dup ffrac f- params VerbParams.b-ap1-len-p f!64
  4217.0 scale f* dup ffrac f- params VerbParams.b-d1-len-p f!64
  2656.0 scale f* dup ffrac f- params VerbParams.b-ap2-len-p f!64
  3163.0 scale f* dup ffrac f- params VerbParams.b-d2-len-p f!64
  params VerbParams.bw-hz@ 6.2831853 f* sr f/ 0.0 1.0 fclamp
  params VerbParams.bw-a-p f!64
  params VerbParams.damp-hz@ 6.2831853 f* sr f/ 0.0 1.0 fclamp
  params VerbParams.damp-a-p f!64
  params VerbParams.mod-rate@ sr f/ params VerbParams.mod-inc-p f!64
  params VerbParams.mod-depth@ scale f* params VerbParams.mod-depth-spl-p f!64
  drop2 drop
;

( state params sample-rate -- : per-channel decorrelation, runs every
  block.  Seeds the LFO phase once, picks the L or R output tap set, and
  detunes the modulation rate on the right channel. )
dsp2: verb-prepare
  | state params sr |
  state VerbState.chan@ | chan |
  params VerbParams.scale@ | scale |
  state VerbState.seeded@ 0.5
    0.123 chan 0.39 f* f+
    state VerbState.lfo-phase@
  fsel-lt state VerbState.lfo-phase-p f!64
  1.0 state VerbState.seeded-p f!64
  params VerbParams.mod-inc@ 1.0 chan 0.17 f* f+ f*
  state VerbState.mod-inc-ch-p f!64
  chan 0.5 266.0  353.0  fsel-lt scale f* state VerbState.tap-1-p f!64
  chan 0.5 2974.0 3627.0 fsel-lt scale f* state VerbState.tap-2-p f!64
  chan 0.5 1913.0 1228.0 fsel-lt scale f* state VerbState.tap-3-p f!64
  chan 0.5 1996.0 2673.0 fsel-lt scale f* state VerbState.tap-4-p f!64
  chan 0.5 1990.0 2111.0 fsel-lt scale f* state VerbState.tap-5-p f!64
  chan 0.5 187.0  335.0  fsel-lt scale f* state VerbState.tap-6-p f!64
  chan 0.5 1066.0 121.0  fsel-lt scale f* state VerbState.tap-7-p f!64
  drop2 drop2 drop
;

( --- per-sample stages ----------------------------------------------- )

( state params in -- : predelay ring + bandwidth lowpass -> diff. )
dsp2: verb-pre
  | state params in |
  state VerbState.buf-p p@64 | buf |
  in f@64 | x |
  buf 0.0 state VerbState.pre-pos-p params VerbParams.pre-len@ x vb-dl | v |
  state VerbState.in-lpf@ | z |
  z  v z f-  params VerbParams.bw-a@ f*  f+ | zn |
  zn state VerbState.in-lpf-p f!64
  zn state VerbState.diff-p f!64
  drop2 drop2 drop2 drop2
;

( state params -- : input diffusion allpasses 1+2, g 0.75. )
dsp2: verb-in-ap12
  | state params |
  state VerbState.buf-p p@64 | buf |
  buf 12288.0 state VerbState.inap1-pos-p params VerbParams.inap1-len@
    state VerbState.diff@ 0.75 vb-ap | y1 |
  buf 12768.0 state VerbState.inap2-pos-p params VerbParams.inap2-len@
    y1 0.75 vb-ap
  state VerbState.diff-p f!64
  drop2 drop2
;

( state params -- : input diffusion allpasses 3+4, g 0.625. )
dsp2: verb-in-ap34
  | state params |
  state VerbState.buf-p p@64 | buf |
  buf 13128.0 state VerbState.inap3-pos-p params VerbParams.inap3-len@
    state VerbState.diff@ 0.625 vb-ap | y3 |
  buf 14376.0 state VerbState.inap4-pos-p params VerbParams.inap4-len@
    y3 0.625 vb-ap
  state VerbState.diff-p f!64
  drop2 drop2
;

( state params -- : advance the tank LFO, derive both mod offsets. )
dsp2: verb-lfo
  | state params |
  state VerbState.lfo-phase@ state VerbState.mod-inc-ch@ f+ ffrac | ph |
  ph state VerbState.lfo-phase-p f!64
  params VerbParams.mod-depth-spl@ | dep |
  dep 0.5 0.5 ph sine-shape f* f+ f* state VerbState.mlfo-a-p f!64
  dep 0.5 0.5 ph 0.25 f+ sine-shape f* f+ f* state VerbState.mlfo-b-p f!64
  drop2 drop2
;

( state params -- : branch A front half - feedback from branch B's last
  delay, modulated decay-diffusion allpass, first long delay -> ta. )
dsp2: verb-tank-a-in
  | state params |
  state VerbState.buf-p p@64 | buf |
  buf 75128.0 state VerbState.b-d2-pos@ params VerbParams.b-d2-len@ 0.0 vb-tap
  params VerbParams.decay@ f*
  state VerbState.diff@ f+ | fba |
  buf 15288.0 state VerbState.a-ap1-pos-p params VerbParams.a-ap1-len@
    fba 0.70 state VerbState.mlfo-a@ vb-apm | y |
  buf 17592.0 state VerbState.a-d1-pos-p params VerbParams.a-d1-len@ y vb-dl
  state VerbState.ta-p f!64
  drop2 drop2 drop
;

( state params -- : branch A back half - damping, decay, second
  allpass, second delay. )
dsp2: verb-tank-a-out
  | state params |
  state VerbState.buf-p p@64 | buf |
  state VerbState.damp-a-z@ | z |
  z  state VerbState.ta@ z f-  params VerbParams.damp-a@ f*  f+ | zn |
  zn state VerbState.damp-a-z-p f!64
  buf 31992.0 state VerbState.a-ap2-pos-p params VerbParams.a-ap2-len@
    zn params VerbParams.decay@ f* 0.50 vb-ap | y |
  buf 37816.0 state VerbState.a-d2-pos-p params VerbParams.a-d2-len@ y vb-dl
  drop
  drop2 drop2 drop2
;

( state params -- : branch B front half, fed from branch A's last delay. )
dsp2: verb-tank-b-in
  | state params |
  state VerbState.buf-p p@64 | buf |
  buf 37816.0 state VerbState.a-d2-pos@ params VerbParams.a-d2-len@ 0.0 vb-tap
  params VerbParams.decay@ f*
  state VerbState.diff@ f+ | fbb |
  buf 49848.0 state VerbState.b-ap1-pos-p params VerbParams.b-ap1-len@
    fbb 0.70 state VerbState.mlfo-b@ vb-apm | y |
  buf 52920.0 state VerbState.b-d1-pos-p params VerbParams.b-d1-len@ y vb-dl
  state VerbState.tb-p f!64
  drop2 drop2 drop
;

( state params -- : branch B back half. )
dsp2: verb-tank-b-out
  | state params |
  state VerbState.buf-p p@64 | buf |
  state VerbState.damp-b-z@ | z |
  z  state VerbState.tb@ z f-  params VerbParams.damp-a@ f*  f+ | zn |
  zn state VerbState.damp-b-z-p f!64
  buf 66552.0 state VerbState.b-ap2-pos-p params VerbParams.b-ap2-len@
    zn params VerbParams.decay@ f* 0.50 vb-ap | y |
  buf 75128.0 state VerbState.b-d2-pos-p params VerbParams.b-d2-len@ y vb-dl
  drop
  drop2 drop2 drop2
;

( out state params in -- : seven output taps, dry/wet mix. )
dsp2: verb-out
  | out state params in |
  state VerbState.buf-p p@64 | buf |
  buf 52920.0 state VerbState.b-d1-pos@ params VerbParams.b-d1-len@
    state VerbState.tap-1@ vb-tap
  buf 52920.0 state VerbState.b-d1-pos@ params VerbParams.b-d1-len@
    state VerbState.tap-2@ vb-tap f+
  buf 66552.0 state VerbState.b-ap2-pos@ params VerbParams.b-ap2-len@
    state VerbState.tap-3@ vb-tap f-
  buf 75128.0 state VerbState.b-d2-pos@ params VerbParams.b-d2-len@
    state VerbState.tap-4@ vb-tap f+
  buf 17592.0 state VerbState.a-d1-pos@ params VerbParams.a-d1-len@
    state VerbState.tap-5@ vb-tap f-
  buf 31992.0 state VerbState.a-ap2-pos@ params VerbParams.a-ap2-len@
    state VerbState.tap-6@ vb-tap f-
  buf 37816.0 state VerbState.a-d2-pos@ params VerbParams.a-d2-len@
    state VerbState.tap-7@ vb-tap f-
  0.6 f* | wet |
  in f@64 | x |
  x  1.0 params VerbParams.mix@ f-  f*
  wet params VerbParams.mix@ f*  f+
  out f!64
  drop2 drop2 drop2 drop
;

( out state params in -- : the full plate tick, staged. )
dsp2: k-verb-tick
  | out state params in |
  state params in call: verb-pre
  state params call: verb-in-ap12
  state params call: verb-in-ap34
  state params call: verb-lfo
  state params call: verb-tank-a-in
  state params call: verb-tank-a-out
  state params call: verb-tank-b-in
  state params call: verb-tank-b-out
  out state params in call: verb-out
;
