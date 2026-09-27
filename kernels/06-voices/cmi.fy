( cmi.fy - a Fairlight CMI Series II / IIx voice card over a keymap.

  After the CMI-01A channel card [MAME src/mame/fairlight/cmi01a.cpp]:

  Voice RAM   the zone's sample as the CMI stored it: sampled at RATE,
              unsigned 8-bit, at most 16,384 bytes [128 segments of 128].
  Clock       no interpolation: the card steps through the RAM on its own
              clock, (0x800 | pitch<<1) * mosc / 4096 / 16, divided by an
              octave register [2 .. 256, or not at all].  The note's rate
              lands on that grid: a 10-bit pitch inside the octave.  The
              grain and the aliasing move with the note.
  Loop        whole segments, LOOP BEG .. LOOP END, held or not.
  Filter      two fixed-Q 2-pole lowpasses [an SSM2045 pair], the second
              1.22x the first, corner 6410 * 1.02162^[octave*32 + FILTER
              - 256] Hz, top 14 kHz: it follows the octave register, so
              it moves in whole octaves while the pitch moves in notes.
  Envelope    an 8-bit counter up at attack, down at damping, times the
              8-bit volume.
  Vibrato     Page 7's VIB DEPTH and SPEED, a sine on the pitch.
  Start       Page 7's START SEG: the note starts that many segments in.

  MAME's stream takes the first filter stage only; the card has both, and
  this voice runs both.  Steps onto new stored samples are polyBLEPed at
  their true times, as in the sampler's CLOCK engine. )

include "sampler.fy"

ustruct: CmiState
  f64 start  f64 end  f64 ls  f64 le  f64 loop-on  f64 oneshot
  f64 gain  f64 off-by  f64 seq  f64 choked
  ( playback, in pool samples )
  f64 ph  f64 inc  f64 kr
  f64 held  f64 pend  f64 i-prev
  ( filter: the two stages' coefficients and states )
  f64 g1  f64 g2  f64 f1  f64 f2  f64 f3  f64 f4
  ( envelope )
  f64 age  f64 gate-time  f64 egate  f64 vel
  f64 fade  f64 fade-k
  ( vibrato phase, cycles )
  f64 vph
;

ustruct: CmiParams
  ( keymap - injected by the host )
  f64 pool  f64 zones  f64 zone-count  f64 edits
  ( user-facing )
  f64 rate       ( the sampling rate of the voice RAM, Hz )
  f64 root       ( MIDI note for zones whose files carry no root )
  f64 tune       ( semitones )
  f64 loop-mode  ( 0 OFF / 1 ON )
  f64 loop-start ( segment 0..127 )
  f64 loop-end   ( segment 0..127, inclusive )
  f64 filter     ( the filter latch, 0..255 )
  f64 atk        ( seconds, 0 -> full )
  f64 damp       ( seconds, full -> 0 )
  f64 vol        ( 0..1, the volume latch )
  f64 vel-amt
  f64 vib-depth  ( semitones, peak )
  f64 vib-rate   ( Hz )
  f64 start-seg  ( segment 0..127 the note starts at )
  ( shared )
  f64 inv-sr
  f64 note-seq
  f64 choke 16
  f64 rr-count 128
;

( The master oscillator, 34.291712 MHz / 2 scaled by the master-tune
  register [0xf00 | 0x80], over 4096 * 16: an undivided voice clock is
  [2048 + 2 pitch] * CMI-BASE. )
:: CMI-BASE 253.451904296875 ;
( the two stages' damping d = 1/[2Q], from the card's capacitor ratios )
:: CMI-DA 0.908295106229245 ;
:: CMI-DB 0.741619848709565 ;
( log2 1.02162: filter steps are 1.02162x, 32 to the octave )
:: CMI-FSTEP 0.030851727 ;

dsp: cmi-block-prepare | ctx:Ctx state params:CmiParams |
  1.0 ctx.sr f/ -> params.inv-sr
;

( want -- rq n : the nearest rate the card's clock makes, and the octave
  divide exponent [0 undivided .. 8]. )
dsp: cmi-quantize-rate | want -- rq n |
  want CMI-BASE f/ 2048.0 f/ | x |
  0.0 x log2 floor f- 0.0 8.0 fclamp | n |
  x n exp2 f* 1.0 f- 1024.0 f* 0.5 f+ floor 0.0 1023.0 fclamp | p |
  p 2.0 f* 2048.0 f+ CMI-BASE f*  0.0 n f- exp2 f*
  n
;

dsp: cmi-note-on | ctx:Ctx state:CmiState params:CmiParams |
  params.zones& p@64 | zt |
  ctx.pitch | key |
  key 0.0 127.0 fclamp floor | kk |
  params.rr-count& kk f@i | cnt |
  cnt 1.0 f+  params.rr-count& kk f!i
  zt key ctx.vel 127.0 f* cnt 0.0 zone-find | k |
  k 0.0 f>= | hit |
  k 0.0 fmax 19.0 f* | c |
  hit  zt c f@i  4.0  select | start |
  hit  zt c 1.0 f+ f@i  0.0  select | len |
  ( a zone of rate 0 is voice RAM from a .VC file: it plays at RATE )
  zt c 2.0 f+ f@i | zsr0 |
  zsr0 0.5 f<  params.rate  zsr0  select | zsr |
  zt c 7.0 f+ f@i | zroot |
  params.edits& p@64 | ed:ZoneEdits |
  k 0.0 fmax | k0 |
  zt c 8.0 f+ f@i  ed.level& k0 f@i db>lin  f* -> state.gain
  zt c 9.0 f+ f@i 1.5 f> mask>f -> state.oneshot
  ( the voice RAM: RATE, never above the file's own, 16,384 samples )
  params.rate zsr fmin | srate |
  srate zsr f/ 0.001 1.0 fclamp | kr |
  kr -> state.kr
  len kr f* 16384.0 fmin floor | slen |
  start -> state.start
  start  slen kr f/  f+ -> state.end
  ( the segment loop )
  params.loop-start 128.0 f* slen fmin | lss |
  params.loop-end 1.0 f+ 128.0 f* slen fmin | les |
  start  lss kr f/  f+ -> state.ls
  start  les kr f/  f+ -> state.le
  params.loop-mode 0.5 f>  les lss f>  and mask>f -> state.loop-on
  ( pitch on the card's grid )
  zroot 0.0  params.root zroot fsel-lt | root |
  key params.tune f+  ed.tune& k0 f@i f+  root f- 0.08333333333333333 f* exp2 | ratio |
  srate ratio f* cmi-quantize-rate | rq n |
  rq ctx.sr f/ kr f/ 16.0 fmin -> state.inc
  params.start-seg 128.0 f* slen 128.0 f- 0.0 fmax fmin floor kr f/ start f+ -> state.ph
  0.0 -> state.vph
  0.0 -> state.held  0.0 -> state.pend  -1.0 -> state.i-prev
  ( the filter follows the octave register: [8 - n] 32 steps )
  8.0 n f- 32.0 f*  params.filter f+  ed.tone& k0 f@i 32.0 f* f+  256.0 f-  CMI-FSTEP f* exp2  6410.0 f*
    14000.0 fmin | fc |
  fc ctx.sr svf-g -> state.g1
  fc 1.224744871391589 f* ctx.sr svf-g -> state.g2
  0.0 -> state.f1  0.0 -> state.f2  0.0 -> state.f3  0.0 -> state.f4
  ( envelope; DECAY from the zone list fades on top )
  0.0 -> state.age
  1000000000.0 -> state.gate-time
  0.0 -> state.egate
  0.0 -> state.choked
  ctx.vel -> state.vel
  ed.decay& k0 f@i | dcy |
  1.0 -> state.fade
  dcy 0.0 f>  -6.907755278982137 dcy ctx.sr f* 0.000000001 fmax f/ exp  1.0  select -> state.fade-k
  ( choke and the zone list's lights, as the sampler )
  ed.cut& k0 f@i | cut |
  cut 0.5 f> | own |
  own  cut 1.0 f-  zt c 12.0 f+ f@i  select | cg |
  own  cut 1.0 f-  zt c 13.0 f+ f@i  select -> state.off-by
  params.note-seq 1.0 f+ | seq |
  seq -> params.note-seq
  seq -> state.seq
  cg 0.0 15.0 fclamp | g |
  params.choke& g f@i | old |
  cg 0.5 f>  seq  old  select  params.choke& g f!i
  ed.hit& k0 f@i | oldhit |
  hit  seq  oldhit  select  ed.hit& k0 f!i
  hit  k0  ed.last  select -> ed.last
;

( age atk -- e : the attack ramp, 0..1 )
dsp: cmi-attack | age atk -- e |
  age atk 0.0001 fmax f/ 1.0 fmin
;

dsp: cmi-note-off | ctx state:CmiState params:CmiParams |
  state.oneshot 0.5 f< | rel |
  rel  state.age params.atk cmi-attack  state.egate  select -> state.egate
  state.oneshot 0.5  state.age  state.gate-time  fsel-lt -> state.gate-time
;

( state buf -- y : the stored sample under the read position, 8-bit,
  held, its step polyBLEPed at its true time. )
dsp: cmi-clock | state:CmiState buf -- y |
  state.ph state.start f-  state.kr f* | sp |
  sp floor | j |
  buf  j state.kr f/ state.start f+  smp-hermite
    128.0 f* 0.5 f+ floor -128.0 127.0 fclamp 0.0078125 f* | q |
  j state.i-prev f= not | ev |
  j -> state.i-prev
  sp j f-  state.inc state.kr f* f/  0.0 1.0 fclamp | t |
  state.held | h |
  ev  q h f-  0.0  select | delta |
  ev  q  h  select | h2 |
  h2 -> state.held
  state.pend  delta t t f* f* 0.5 f*  f+ | y |
  1.0 t f- | u |
  h2  delta u u f* f* 0.5 f*  f-  -> state.pend
  y
;

dsp: k-cmi-voice | out:Io ctx state:CmiState params:CmiParams -- |
  params.pool& p@64 | buf |
  state.ph | ph |
  ph state.end f< mask>f | alive |
  state buf cmi-clock | x |
  state.f1& state.f2& x state.g1 CMI-DA tpt-svf-lp-step | a |
  state.f3& state.f4& a state.g2 CMI-DB tpt-svf-lp-step | y |
  ( advance: segment loop, else park at the end )
  state.vph params.vib-rate params.inv-sr f* f+ ffrac | vp |
  vp -> state.vph
  vp sin2pi params.vib-depth f* 0.08333333333333333 f* exp2 | vm |
  ph state.inc vm f* f+ | p2 |
  state.loop-on 0.5 f>  p2 state.le f>=  and | wrap |
  wrap  p2 state.le state.ls f- f-  p2  select  state.end fmin -> state.ph
  ( envelope: attack while held, damping down from where it stood; a
    choke damps in 4 ms )
  state.age params.inv-sr f+ | age |
  age -> state.age
  params.choke& state.off-by f@i state.seq f>  state.off-by 0.5 f>  and | choked |
  age state.gate-time f< | held |
  age params.atk cmi-attack | e-up |
  choked held and  e-up  state.egate  select -> state.egate
  choked held and  age  state.gate-time  select -> state.gate-time
  choked mask>f state.choked fmax -> state.choked
  state.choked 0.5 f>  0.004  params.damp  select 0.0001 fmax | dmp |
  state.egate  age state.gate-time f- dmp f/  f-  0.0 fmax | e-down |
  age state.gate-time f<  e-up  e-down  select | e |
  ( the 8-bit counter )
  e 255.0 f* floor 0.00392156862745098 f* | env |
  1.0 params.vel-amt f-  state.vel params.vel-amt f*  f+ | va |
  state.fade | fade |
  fade state.fade-k f* -> state.fade
  out f@64
  y env f*  va f*  state.gain f*  fade f*  params.vol f*  alive f*
  f+
  out f!64
;
