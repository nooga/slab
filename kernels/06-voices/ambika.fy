( ambika.fy - Ambika: one voicecard of Mutable Instruments' Ambika
  polysynth [Emilie Gillet, 2012, firmware GPL-3.0-or-later], ported from the
  voicecard firmware in pichenettes/ambika.  docs/48-ambika.md is the study.

    OSC 1 ---- cross-mod [sum, sync, ring, xor, fold, bits] ---- OSC 2
        |                                                      |
        '---- balance ---- + SUB / TRANSIENT ---- + NOISE ---- FUZZ ---- CRUSH
                                       12-bit DAC -> analog VCF [SMR4 4-pole or SVF] -> VCA

  The digital half runs as the firmware does: at 20 MHz / 510 = 39.2 kHz, in
  integers.  Phases are 16 bits, samples 8; a sample is read from the same
  tables and mixed with the same shifts, so the aliasing and the grit are the
  unit's.  It is run here as a native tick, ahead of the host's rate by a
  fractional accumulator, and the DAC's last value is held between ticks: what
  the hardware's output stage does too.  The firmware's tables [waveforms,
  wavetables, the LFO and envelope curves] are in assets/tables.wav, packed by
  tools/ambika/gen_tables.py, and read at the offsets of ambika_tables.fy.

  Control runs every 40 native ticks [980 Hz]: the envelopes, the voice LFO,
  the modifiers, the 14-slot matrix, the pitch.  The host calls k-amb-control
  once per CTL-P samples.  The filter and the VCA are the analog part; they
  take the control values smoothed, as the PWM-and-RC stages on the board do.

  Values are the firmware's: parameters 0..127, amounts -63..63, signals 0..255
  [bipolar ones 128 centered], pitch in 1/128 semitones. )

include "../00-primitives/ctx.fy"
include "../00-primitives/math.fy"
include "../00-primitives/rand.fy"
include "../04-filters/ota_cascade.fy"
include "ambika_tables.fy"

:: AMB-SRN 39215.68627450980 ;       ( native tick rate: 20 MHz / 510 )
:: AMB-CTL 40.0 ;                    ( native ticks per control step )
:: CTL-P 49.0 ;                      ( host samples per control step, ~ 48000 / 980 )
:: AMB-IN 0.5 ;                      ( DAC full scale -> filter input: an OTA's tanh bends it )
:: AMB-W 257.0 ;                     ( samples in one slot of the waveform table )

( --- state ------------------------------------------------------------------ )

ustruct: AmbOsc
  f64 ph  f64 carry  f64 sec
  f64 q0  f64 q1  f64 q2               ( quad saw's three phases )
  f64 lp  f64 par  f64 hold            ( noise's low-pass; half-rate pair toggle and held value )
  f64 vi0  f64 vi1  f64 vi2            ( vowel: formant increments )
  f64 vp0  f64 vp1  f64 vp2            ( formant phases )
  f64 va0  f64 va1  f64 va2  f64 va3   ( formant amplitudes; va3 is the noise modulation )
  f64 vupd  f64 vph
;

ustruct: AmbEnv
  f64 stage  f64 phase  f64 a  f64 b  f64 value
  f64 inc                              ( current segment's phase increment )
  f64 ia  f64 id  f64 ir  f64 sus      ( stage increments and the sustain level, from the last control step )
;

ustruct: AmbState
  AmbOsc o1
  AmbOsc o2
  f64 acc  f64 go                      ( native ticks owed; one falls in this sample )
  f64 sub-ph
  f64 tr-count  f64 tr-gain  f64 tr-dec  f64 tr-rng
  f64 nz                               ( the mixer's noise: x * 73 + 1 )
  f64 held  f64 crush-n                ( the DAC's value; ticks since it was written )
  f64 v1  f64 v2                       ( the oscillators' last values )
  f64 tick                             ( ticks since the last control step )
  AmbEnv e1
  AmbEnv e2
  AmbEnv e3
  f64 l4-ph  f64 l4-sh  f64 l4-lo      ( voice LFO )
  f64 ls 3                             ( the part LFOs' S&H values )
  f64 lpv 3                            ( their last phases, to catch the wrap )
  f64 rng
  f64 t                                ( this voice's sample clock, per control step )
  f64 t0                               ( clock at note-on )
  f64 pitch  f64 target  f64 pinc      ( 1/128 semitones; glide )
  f64 gate  f64 vel  f64 rnd  f64 prs  ( note-on values )
  f64 ms 28                            ( modulation sources, 0..255 )
  f64 mv 28                            ( the panel's copy of them: 0..1, or -1..1 for the centered ones )
  f64 ds 19                            ( destinations, firmware units )
  f64 inc1  f64 inc2  f64 note1  f64 note2
  f64 prm1  f64 prm2  f64 fm1  f64 fm2
  f64 g-bal  f64 g-mixp  f64 g-sub  f64 g-nz  f64 g-fuzz  f64 crush
  f64 vca-t  f64 cut-t  f64 res-t      ( control targets )
  f64 vca-s  f64 cut-s  f64 res-s      ( smoothed )
  f64 alive
  f64 mod-vca                          ( the matrix's VCA product )
  OtaCascade vcf
  f64 sv1  f64 sv2
  f64 dc-x  f64 dc-y
;

ustruct: AmbParams
  f64 tbl                              ( the table asset's base pointer )
  f64 tbl-len  f64 tbl-sr
  ( oscillators )
  f64 o1-shape  f64 o1-prm  f64 o1-range  f64 o1-tune
  f64 o2-shape  f64 o2-prm  f64 o2-range  f64 o2-tune
  ( mixer )
  f64 balance  f64 op  f64 mixprm  f64 sub-shape  f64 sub-lvl  f64 noise  f64 fuzz  f64 crush-p
  ( filter )
  f64 cutoff  f64 reso  f64 fmode  f64 board  f64 env2  f64 lfo2
  ( envelopes and LFOs 1..3: attack decay sustain release, shape rate trigger )
  f64 ea 3  f64 ed 3  f64 es 3  f64 er 3
  f64 lshape 3  f64 lrate 3  f64 ltrig 3
  f64 vl-shape  f64 vl-rate
  ( matrix )
  f64 m-src 14  f64 m-dst 14  f64 m-amt 14
  f64 md-in1 4  f64 md-in2 4  f64 md-op 4
  ( part )
  f64 volume  f64 legato  f64 porta  f64 octave  f64 tune
  f64 bend  f64 mwhl  f64 whl2  f64 pdal
  f64 gain  f64 sm  f64 hpa  f64 dca
  ( shared: the host clock, for the part LFOs )
  f64 clk0
  f64 lph0 3  f64 linc 3
  f64 ksc                              ( control-rate scale: native 980.4 Hz / the host's )
  f64 sr-r                             ( native ticks per host sample )
  f64 osr2
;

( --- bit work on 8-bit values ---------------------------------------------- )

( a b -- a&b : 8-bit and, bit by bit from the low end. )
dsp: u8-and | a b -- c |
  0.0 1.0 a b 8 [ | s w x y |
    x 2.0 f/ floor | xh |  x xh 2.0 f* f- | xb |
    y 2.0 f/ floor | yh |  y yh 2.0 f* f- | yb |
    s xb yb f* w f* f+   w 2.0 f*   xh yh
  ] times | s w x y |
  s
;

( a b -- a^b )
dsp: u8-xor | a b -- c |  a b f+  a b u8-and 2.0 f* f- ;

( v k -- v & ~[2^k - 1] : clear the low k bits. )
dsp: u8-hi | v k -- w |  k fexp2i | m |  v m f/ floor m f* ;

( x m -- r : x modulo m, for x >= 0. )
dsp: fmod-w | x m -- r |  x  x m f/ floor m f*  f- ;

( --- table reads -------------------------------------------------------------- )

( off i -- v : the cell at tables.wav offset off + i. )
dsp: amb-at | params:AmbParams off i -- v |  params.tbl& p@64  off i f+  f@i ;

( off ph -- v : the firmware's InterpolateSample over a table whose cells are
  a byte apart in a 16-bit phase: cell ph >> 8, blended by the low byte. )
dsp: amb-lerp | params:AmbParams off ph -- v |
  ph floor | pi |
  pi 256.0 f/ floor | i |
  pi i 256.0 f* f-  256.0 f/ | fr |
  params off i amb-at | a |
  params off i 1.0 f+ amb-at | b |
  b a f- fr f* floor a f+
;

( slot -- off : a slot of the firmware's waveform table [sine, squares, saws, triangles]. )
dsp: amb-slot  AMB-W f* AMB-WTAB f+ ;

( --- the oscillators [oscillator.cc] -------------------------------------------- )

( o inc sync -- ph : advance the 16-bit phase; sync resets it first.  carry is
  set when it wraps. )
dsp: amb-adv | o:AmbOsc inc sync -- ph |
  sync 0.5 f>  0.0  o.ph  select  inc f+ | p |
  p 65536.0 f>= | wrap |
  wrap  p 65536.0 f-  p  select | pw |
  pw -> o.ph
  wrap 1.0 0.0 select -> o.carry
  pw
;

( the CZ resonant waves: a sine of PARA x the pitch, windowed by the wave and
  reset by the carry.  type 0..3 saw, 4..7 pulse, 8 triangle; type & 3 picks the
  reset phase and type & 2 the signed form. )
dsp: amb-czreso | o:AmbOsc params:AmbParams shape prm inc sync -- v |
  shape 6.0 f- | type |
  o inc sync amb-adv | ph |
  inc  inc prm f* 4.0 f/ floor  f+ | inc2 |
  type 4.0 f<  0.0  type 8.0 f<  1.0  2.0  select  select | kind |
  type 4.0 fmod-w | tl |                            ( type & 3 )
  tl 2.0 f/ floor | thi |                            ( bit 1 of type & 3 )
  o.carry 0.5 f>
    [ params AMB-CZ-RESET tl amb-at ]
    [ o.sec ]
  ifte | p2a |
  p2a inc2 f+  65536.0 fmod-w | p2 |
  p2 -> o.sec
  params AMB-WTAB p2 256.0 f/ floor amb-at | c0 |
  ph 256.0 f/ floor | phi |
  ( windows )
  255.0 phi f- | wsaw |
  ph 16384.0 f<  255.0
    ph 32768.0 f<  255.0 ph 16384.0 f- 64.0 f/ floor f-  0.0  select
  select | wpls |
  ph 32768.0 f>=  255.0 ph 128.0 f/ floor 256.0 fmod-w f-  ph 128.0 f/ floor  select | wtri |
  kind 0.5 f<  wsaw  kind 1.5 f<  wpls  wtri  select  select | w |
  type 5.0 f=  c0 2.0 f/ floor 128.0 f+  c0  select | c |
  thi 0.5 f>  c 128.0 f- w f* 256.0 f/ floor 128.0 f+  c w f* 256.0 f/ floor  select
;

( --- the oscillators, in groups ------------------------------------------------------------
  fy picks a path once per call when a guard reads only params, and falls back to running every
  arm past 32 paths in a word.  An oscillator has four groups [the CZ resonant waves, the small
  algorithms and the vowel, the band-limited PWM, and everything that is a table read] and the
  shape inside a group is a select, so two oscillators and the mixer's two arms stay at 32. )

( o inc sync en -- ph : advance the phase when en; sync resets it first.  carry is set when it
  wraps. )
dsp: amb-advg | o:AmbOsc inc sync en -- ph |
  sync 0.5 f>  0.0  o.ph  select  inc f+ | p |
  p 65536.0 f>= | wrap |
  wrap  p 65536.0 f-  p  select | pw |
  en  pw  o.ph  select -> o.ph
  en  wrap 1.0 0.0 select  o.carry  select -> o.carry
  pw
;

( params shape prm note ph -- v : none, the band-limited saw, square, triangle and sine, the CZ
  saw, the wavetables and the wavequence.  Each is a blend of two table reads at a phase, so one
  pair of reads serves them all; the shape picks the tables, the blend and the phase. )
dsp: amb-tcore | params:AmbParams shape prm note ph -- v |
  note 16.0 f/ floor | z |
  note z 16.0 f* f-  16.0 f* | g2 |
  255.0 g2 f- | g1 |
  z 1.0 f+ 6.0 fmin | zb |
  shape 4.0 f= | sin |
  sin 0.0  shape 1.0 f=  8.0  shape 2.0 f=  1.0  15.0  select  select  select | fam |
  sin 0.0 z select | za |
  sin 0.0 zb select | zc |
  shape 0.5 f>  shape 4.5 f< and | simp |
  shape 20.5 f>  shape 36.5 f< and | wt |
  shape 36.5 f> | wq |
  AMB-WAVETABLES  shape 21.0 36.0 fclamp 21.0 f- 18.0 f* f+ | wd |
  params wd 0.0 amb-at | steps |
  prm 2.0 f* 255.0 fmin  steps f* | wp |
  wp 256.0 f/ floor | idx |
  wp idx 256.0 f* f- | gain |
  params wd 1.0 idx f+ amb-at | w1 |
  params wd 2.0 idx f+ amb-at | w2 |
  prm 79.0 fmin 129.0 f* AMB-WAVES f+ | wqo |
  fam za f+ amb-slot | oa |
  fam zc f+ amb-slot | ob |
  wt  w1 129.0 f* AMB-WAVES f+  wq wqo oa select  select | off1 |
  wt  w2 129.0 f* AMB-WAVES f+  wq wqo ob select  select | off2 |
  wt  255.0 gain f-  wq 256.0 g1 select  select | gg1 |
  wt  gain  wq 0.0 g2 select  select | gg2 |
  wt wq or  ph 2.0 f/ floor  ph  select | phx |
  params off1 phx amb-lerp | a |
  params off2 phx amb-lerp | b |
  a gg1 f*  b gg2 f* f+  256.0 f/ floor | s |
  shape 3.0 f=  s prm fmax  s prm f<  s prm 2.0 f/ floor f+  s  select  select | shaped |
  ( the CZ saw: the sine read through a phase bent by PARA )
  ph 256.0 f/ floor | phi |
  phi 32.0 f<  phi 8.0 f*  255.0  select | cl |
  phi  cl phi f- prm 2.0 f* f* 256.0 f/ floor  f+  0.0 255.0 fclamp floor | ix |
  params AMB-WTAB ix amb-at | cz |
  shape 4.5 f>  shape 5.5 f< and | czs |
  shape 0.5 f<  128.0  czs cz  simp shaped s select  select  select
;

( the band-limited PWM: two saws a PARA apart, at half rate [each value twice].  en says it is
  the shape in use; otherwise nothing is stored. )
dsp: amb-pwm | o:AmbOsc params:AmbParams prm note inc sync en -- v |
  o.par 0.5 f<  en and | act |
  sync 0.5 f>  0.0  o.ph  select  inc 2.0 f* f+ | p |
  p 65536.0 f>= | wrap |
  wrap  p 65536.0 f-  p  select | pw |
  note 16.0 f/ floor | z |
  note z 16.0 f* f-  16.0 f* | g2 |
  255.0 g2 f- | g1 |
  9.0 z f+ | s1 |
  9.0 z 1.0 f+ 5.0 fmin f+ | s2 |
  prm 128.0 f+ 256.0 f* | shift |
  192.0 prm 2.0 f/ floor f- | sc0 |
  note 52.0 f>
    sc0  102.0 sc0 f-  note 52.0 f- 4.0 f* 255.0 fmin 256.0 f/ f*  f+
    sc0  select | sc |
  params s1 amb-slot pw amb-lerp | a1 |
  params s2 amb-slot pw amb-lerp | a2 |
  a1 g1 f*  a2 g2 f* f+  256.0 f/ floor  sc f* 256.0 f/ floor | a |
  pw shift f+ 65536.0 f>=  65536.0 0.0 select | w |
  pw shift f+ w f- | pb |
  params s1 amb-slot pb amb-lerp | b1 |
  params s2 amb-slot pb amb-lerp | b2 |
  b1 g1 f*  b2 g2 f* f+  256.0 f/ floor  sc f* 256.0 f/ floor | b |
  a b f- 128.0 f+ | v |
  act  pw  o.ph  select -> o.ph
  act  wrap 1.0 0.0 select  o.carry  select -> o.carry
  act  v  o.hold  select -> o.hold
  en  1.0 o.par f-  o.par  select -> o.par
  act v o.hold select
;

( the small algorithms and the vowel: the quad saw pad, FM, 8 bits, dirty PWM, filtered noise,
  and the vowel, which renders at half rate with the unshifted increment so it sounds an octave
  under the key [kept].  Three formants through the amplitude-modulated sine and square tables,
  windowed by a falling saw that also restarts them; their increments and amplitudes are worked
  out in control [amb-vowel-set]. )
dsp: amb-gm | o:AmbOsc params:AmbParams st:AmbState shape prm fm inc sync -- v |
  shape 19.5 f> | isv |
  isv not  o.par 0.5 f<  or | act |
  o inc sync amb-adv | ph |
  ( pad )
  inc prm f* 8192.0 f/ floor 1.0 f+ | sp |
  o.q0 inc sp f+ f+ 65536.0 fmod-w | qa |
  o.q1 inc sp 2.0 f* f+ f+ 65536.0 fmod-w | qb |
  o.q2 inc sp 3.0 f* f+ f+ 65536.0 fmod-w | qc |
  qa -> o.q0  qb -> o.q1  qc -> o.q2
  ph 1024.0 f/ floor  qa 1024.0 f/ floor f+  qb 1024.0 f/ floor f+  qc 1024.0 f/ floor f+ | vpad |
  ( FM )
  fm 24.0 f<  0.0  fm 48.0 f>  24.0  fm 24.0 f-  select  select | off |
  params AMB-FM-RATIO off amb-at 256.0 f/ inc f* | inc2 |
  o.sec inc2 f+ 65536.0 fmod-w | p2 |
  p2 -> o.sec
  params AMB-WTAB p2 amb-lerp | mo |
  mo  prm 2.0 f* 255.0 fmin  f* 65536.0 fmod-w | md |
  params AMB-WTAB  ph md f+ 65536.0 fmod-w  amb-lerp | vfm |
  ( 8 bits )
  ph 256.0 f/ floor  prm 2.0 f* 255.0 fmin  u8-xor | x |
  x  255.0 prm f-  u8-and  prm 2.0 f/ floor  f+ | v8 |
  ( dirty PWM )
  ph 256.0 f/ floor  127.0 prm f+  f<  0.0 255.0 select | vd |
  ( filtered noise )
  st.tr-rng& rand-u 256.0 f* floor | n |
  prm 4.0 f* 256.0 fmod-w | c0 |
  c0 4.0 f<=  4.0  c0  select | cc |
  o.lp  n o.lp f-  cc f* 256.0 f/ floor  f+ | l |
  l -> o.lp
  prm 64.0 f>=  n l f- 128.0 f+ 256.0 fmod-w  l  select | vn |
  ( the vowel )
  o.vph 65536.0 f+ inc f- 65536.0 fmod-w | pv |
  o.vp0 o.vi0 f+ 65536.0 fmod-w | f0 |
  o.vp1 o.vi1 f+ 65536.0 fmod-w | f1 |
  o.vp2 o.vi2 f+ 65536.0 fmod-w | f2 |
  params AMB-FORMANT-SINE  f0 4096.0 f/ floor 16.0 f* o.va0 f+  amb-at
  params AMB-FORMANT-SINE  f1 4096.0 f/ floor 16.0 f* o.va1 f+  amb-at f+
  params AMB-FORMANT-SQUARE f2 4096.0 f/ floor 16.0 f* o.va2 f+ amb-at f+ | r |
  st.tr-rng& rand-b 127.0 f* o.va3 f* | pn |
  r  pv 256.0 f/ floor  f* 256.0 f/ floor | rw |
  pv pn f+ inc f< | rs |
  rw 4.0 f* -127.0 127.0 fclamp 128.0 f+ | vv |
  isv act and  pv  o.vph  select -> o.vph
  isv act and  rs 0.0 f0 select  o.vp0  select -> o.vp0
  isv act and  rs 0.0 f1 select  o.vp1  select -> o.vp1
  isv act and  rs 0.0 f2 select  o.vp2  select -> o.vp2
  isv act and  vv  o.hold  select -> o.hold
  isv  1.0 o.par f-  o.par  select -> o.par
  shape 15.5 f<  vpad  shape 16.5 f<  vfm  shape 17.5 f<  v8  shape 18.5 f<  vd
  shape 19.5 f<  vn  isv act and  vv  o.hold  select  select
  select select select select
;

( o params st shape prm vowel : the vowel's formants, from the table at the vowel PARA. )
dsp: amb-vowel-set | o:AmbOsc params:AmbParams prm |
  prm 16.0 f/ floor 7.0 f* | o1 |
  o1 7.0 f+ | o2 |
  prm prm 16.0 f/ floor 16.0 f* f- | bal |
  params AMB-VOWEL o1 amb-at  16.0 bal f-  f*  params AMB-VOWEL o2 amb-at bal f* f+  8.0 f* -> o.vi0
  params AMB-VOWEL o1 1.0 f+ amb-at  16.0 bal f-  f*  params AMB-VOWEL o2 1.0 f+ amb-at bal f* f+  8.0 f* -> o.vi1
  params AMB-VOWEL o1 2.0 f+ amb-at  16.0 bal f-  f*  params AMB-VOWEL o2 2.0 f+ amb-at bal f* f+  8.0 f* -> o.vi2
  params AMB-VOWEL o1 3.0 f+ amb-at  16.0 bal f-  f*  params AMB-VOWEL o2 3.0 f+ amb-at bal f* f+  16.0 f/ floor -> o.va0
  params AMB-VOWEL o1 4.0 f+ amb-at  16.0 bal f-  f*  params AMB-VOWEL o2 4.0 f+ amb-at bal f* f+  16.0 f/ floor -> o.va1
  params AMB-VOWEL o1 5.0 f+ amb-at  16.0 bal f-  f*  params AMB-VOWEL o2 5.0 f+ amb-at bal f* f+  16.0 f/ floor -> o.va2
  params AMB-VOWEL o1 6.0 f+ amb-at  16.0 bal f-  f*  params AMB-VOWEL o2 6.0 f+ amb-at bal f* f+  16.0 f/ floor -> o.va3
;

( --- the mixer's stages [voice.cc, sub_oscillator.h, transient_generator.h] ---------- )

( st shape buf amount inc -- out : the sub-oscillator, square or triangle or pulse, 1 or 2 octaves
  below OSC 1, crossfaded in by U8Mix. )
dsp: amb-sub | st:AmbState shape buf amount inc -- out |
  shape 2.5 f>  inc 4.0 f/  inc 2.0 f/  select | i |
  shape 2.5 f>  shape 3.0 f-  shape  select | sh |
  st.sub-ph i f+ 65536.0 fmod-w | ph |
  ph -> st.sub-ph
  ph 128.0 f/ floor 256.0 fmod-w | tri |
  ph 32768.0 f>=  tri  255.0 tri f-  select | tv |
  sh 0.5 f=  128.0  64.0  select | pw |
  ph 256.0 f/ floor  pw f<  0.0  255.0  select | sq |
  sh 1.5 f<  sh 0.5 f> and  tv  sq  select | v |
  buf 255.0 amount f- f*  v amount f* f+  256.0 f/ floor
;

( s a b c d e -- v : by the transient's shape, 6 click .. 10 pop. )
dsp: pick5 | s a b c d e -- v |
  s 6.5 f<  a  s 7.5 f<  b  s 8.5 f<  c  s 9.5 f<  d  e  select select select select ;

( st shape buf amount -- out : the transient generator: click, glitch, blow, metal, pop,
  each for the 255 steps after a note starts. )
dsp: amb-trans | st:AmbState shape buf amount -- out |
  st.tr-count | c |
  c 1.0 f- | c1 |
  st.tr-rng 73.0 f* c1 f+ 256.0 fmod-w | r1 |
  st.tr-dec 2.0 f+ 256.0 fmod-w | d1 |
  d1 16.0 f>= | dw |
  dw  d1 17.0 f- 256.0 fmod-w  d1  select | d2 |
  dw  st.tr-rng 73.0 f* c f+ 256.0 fmod-w  st.tr-rng  select | rb |
  dw d2 0.5 f< and | dz |
  dz  c1  c  select | cb |
  c1 128.0 f>=  255.0 c1 f-  c1  select | gb |
  shape  c1 32.0 f< 255.0 0.0 select  r1  rb  c1 57.0 f* 256.0 fmod-w  0.0  pick5 | value |
  shape  c  c  dz gb st.tr-gain select  c1 64.0 f>= 255.0 c1 4.0 f* select  c1 0.5 f> 255.0 0.0 select  pick5 | gain |
  c 0.5 f>
    [ shape  c1 c1 cb c1 c1 pick5 -> st.tr-count ]
    [ ]
  ifte
  c 0.5 f>
    [ shape  st.tr-rng r1 rb st.tr-rng st.tr-rng pick5 -> st.tr-rng ]
    [ ]
  ifte
  c 0.5 f>
    [ shape  st.tr-dec st.tr-dec d2 st.tr-dec st.tr-dec pick5 -> st.tr-dec ]
    [ ]
  ifte
  c 0.5 f>
    [ gain -> st.tr-gain ]
    [ ]
  ifte
  gain amount f* 256.0 f/ floor | amp |
  c 0.5 f>
    [ buf  value buf f- amp f* 256.0 f/ floor  f+ ]
    [ buf ]
  ifte
;

( --- one native tick: the digital half of the voicecard ------------------------------- )

( The tick is outlined into stages that write through memory: the oscillators' shape
  dispatch is large, and fy's single-frame composition fails on a body this size. )

( io ctx st params -- : whether a native tick falls in this host sample. )
dsp: amb-s-go | io ctx st:AmbState params:AmbParams |
  st.acc params.sr-r f+ | a |
  a 1.0 f>=  st.alive 0.5 f> and | go |
  go  a 1.0 f-  a 1.0 fmin  select -> st.acc
  go 1.0 0.0 select -> st.go
;

( o -- c : the oscillator's wrap flag from its last step. )
dsp: amb-carry | o:AmbOsc -- c |  o.carry ;

( OSC 1: a group per path, so fy picks the path once per call; the native-tick gate is inside. )
dsp: amb-osc-1 | io ctx st:AmbState params:AmbParams |
  params.o1-shape 5.5 f>  params.o1-shape 14.5 f< and
    [ st.go 0.5 f>
        [ st.o1& params params.o1-shape st.prm1 st.inc1 0.0 amb-czreso -> st.v1 ]
        [ ]
      ifte ]
    [ params.o1-shape 14.5 f>  params.o1-shape 20.5 f< and
        [ st.go 0.5 f>
            [ st.o1& params st params.o1-shape st.prm1 st.fm1 st.inc1 0.0 amb-gm -> st.v1 ]
            [ ]
          ifte ]
        [ params.o1-shape 1.5 f>  params.o1-shape 2.5 f< and
            [ st.go 0.5 f>
                [ st.prm1 0.5 f> | pwm |
                  st.o1& st.inc1 0.0 pwm not amb-advg | ph |
                  pwm  st.o1& params st.prm1 st.note1 st.inc1 0.0 pwm amb-pwm  params 2.0 st.prm1 st.note1 ph amb-tcore  select -> st.v1 ]
                [ ]
              ifte ]
            [ st.go 0.5 f>
                [ st.o1& st.inc1 0.0 1.0 1.0 f= amb-advg | ph |
                  params params.o1-shape st.prm1 st.note1 ph amb-tcore -> st.v1 ]
                [ ]
              ifte ]
          ifte ]
      ifte ]
  ifte
;

( OSC 2: a group per path, so fy picks the path once per call; the native-tick gate is inside. )
dsp: amb-osc-2 | io ctx st:AmbState params:AmbParams |
  params.o2-shape 5.5 f>  params.o2-shape 14.5 f< and
    [ st.go 0.5 f>
        [ st.o2& params params.o2-shape st.prm2 st.inc2 params.op 1.0 f=  st.o1& amb-carry 0.5 f>  and  1.0 0.0 select amb-czreso -> st.v2 ]
        [ ]
      ifte ]
    [ params.o2-shape 14.5 f>  params.o2-shape 20.5 f< and
        [ st.go 0.5 f>
            [ st.o2& params st params.o2-shape st.prm2 st.fm2 st.inc2 params.op 1.0 f=  st.o1& amb-carry 0.5 f>  and  1.0 0.0 select amb-gm -> st.v2 ]
            [ ]
          ifte ]
        [ params.o2-shape 1.5 f>  params.o2-shape 2.5 f< and
            [ st.go 0.5 f>
                [ st.prm2 0.5 f> | pwm |
                  st.o2& st.inc2 params.op 1.0 f=  st.o1& amb-carry 0.5 f>  and  1.0 0.0 select pwm not amb-advg | ph |
                  pwm  st.o2& params st.prm2 st.note2 st.inc2 params.op 1.0 f=  st.o1& amb-carry 0.5 f>  and  1.0 0.0 select pwm amb-pwm  params 2.0 st.prm2 st.note2 ph amb-tcore  select -> st.v2 ]
                [ ]
              ifte ]
            [ st.go 0.5 f>
                [ st.o2& st.inc2 params.op 1.0 f=  st.o1& amb-carry 0.5 f>  and  1.0 0.0 select 1.0 1.0 f= amb-advg | ph |
                  params params.o2-shape st.prm2 st.note2 ph amb-tcore -> st.v2 ]
                [ ]
              ifte ]
          ifte ]
      ifte ]
  ifte
;

( io ctx st params -- : the cross-mod, SUB or TRANSIENT, NOISE, FUZZ; the CRUSH hold decides
  when the DAC takes the value. )
dsp: amb-s-mix | io ctx st:AmbState params:AmbParams |
  st.go 0.5 f>
    [ st.v1 | a |
      st.v2 | b |
      st.g-bal | g2 |
      255.0 g2 f- | g1 |
      st.g-mixp | wet |
      255.0 wet f- | dry |
      a g1 f*  b g2 f* f+  256.0 f/ floor | mix |
      params.op | op |
      a 128.0 f- b 128.0 f- f* 256.0 f/ floor 128.0 f+ | r |
      a b u8-xor | x |
      mix 128.0 f+ 256.0 fmod-w | f |
      op 1.5 f<  mix
        op 2.5 f<  mix dry f*  r wet f* f+  256.0 f/ floor
          op 3.5 f<  mix dry f*  x wet f* f+  256.0 f/ floor
            op 4.5 f<  mix dry f*  f wet f* f+  256.0 f/ floor
              mix  wet 32.0 f/ floor  u8-hi
            select
          select
        select
      select | m |
      ( SUB or TRANSIENT )
      st.g-sub | sg |
      params.sub-shape 5.5 f<
        [ st params.sub-shape m sg st.inc1 amb-sub ]
        [ st params.sub-shape m sg 2.0 f* 256.0 fmod-w amb-trans ]
      ifte | m2 |
      ( NOISE, FUZZ )
      st.nz 73.0 f* 1.0 f+ 256.0 fmod-w | n |
      n -> st.nz
      st.g-nz | ng |
      m2 255.0 ng f- f*  n ng f* f+  256.0 f/ floor | sn |
      st.g-fuzz | fw |
      sn 255.0 fw f- f*  params AMB-DISTORTION sn amb-at  fw f* f+  256.0 f/ floor | u |
      ( CRUSH: the DAC takes a value every CRUSH ticks )
      st.crush-n 1.0 f+ | cn |
      cn st.crush f>=
        [ u -> st.held  0.0 -> st.crush-n ]
        [ cn -> st.crush-n ]
      ifte
    ]
    [ ]
  ifte
;

( --- envelopes [envelope.h] and LFOs [lfo.h] ---------------------------------------------- )

( e -- v : one control step.  A stage runs its phase to 65536 through the exponential curve,
  then the next stage starts from where the value is. )
dsp: amb-env | e:AmbEnv params:AmbParams -- v |
  e.phase e.inc f+ | p |
  e.inc 0.5 f>  p 65536.0 f>=  and | wrap |
  e.stage 1.0 f+ | s2 |
  wrap  s2  e.stage  select | st |
  wrap  e.b  e.a  select | a |
  ( the target and the increment of the stage a wrap enters )
  s2 1.5 f<  e.sus
    s2 2.5 f<  e.sus
      s2 3.5 f<  0.0  0.0  select
    select
  select | tgt |
  s2 0.5 f<  e.ia
    s2 1.5 f<  e.id
      s2 2.5 f<  0.0
        s2 3.5 f<  e.ir  0.0  select
      select
    select
  select | inc2 |
  wrap  tgt  e.b  select | b |
  wrap  inc2 e.inc select | inc |
  wrap  0.0  p  select | ph |
  inc 0.5 f>
    [ a  b a f-  params AMB-ENV-EXPO ph amb-lerp f*  255.0 f/  f+ ]
    [ wrap a e.value select ]
  ifte | v0 |
  st -> e.stage  a -> e.a  b -> e.b  inc -> e.inc  ph -> e.phase
  v0 floor | v |
  v -> e.value
  v
;

( e stage -- : start a stage from the current value. )
dsp: amb-env-go | e:AmbEnv stage |
  stage -> e.stage
  e.value -> e.a
  0.0 -> e.phase
  stage 0.5 f<  255.0
    stage 1.5 f<  e.sus
      stage 2.5 f<  e.sus  0.0
      select
    select
  select -> e.b
  stage 0.5 f<  e.ia
    stage 1.5 f<  e.id
      stage 2.5 f<  0.0
        stage 3.5 f<  e.ir  0.0  select
      select
    select
  select -> e.inc
;

( params shape ph sh -- v : an LFO's value 0..255 from its 16-bit phase. )
dsp: amb-lfo | params:AmbParams shape ph sh -- v |
  ph 128.0 f/ floor 256.0 fmod-w | h |
  shape 0.5 f<  ph 32768.0 f>=  h 255.0 h f-  select
    shape 1.5 f<  ph 32768.0 f>=  255.0 0.0 select
      shape 2.5 f<  sh
        shape 3.5 f<  ph 256.0 f/ floor
          params  AMB-LFO-WAVES shape 4.0 f- 257.0 f* f+  ph  amb-lerp
        select
      select
    select
  select
;

( --- control rate [voice.cc LoadSources .. UpdateDestinations] --------------------------- )

( v lo hi -- v' )
dsp: clip14  0.0 16383.0 fclamp ;

( op r1 .. r10 -- v : a modifier's result by operator 1..10. )
dsp: pick10 | op r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 -- v |
  op 1.5 f<  r1  op 2.5 f<  r2  op 3.5 f<  r3  op 4.5 f<  r4  op 5.5 f<  r5
  op 6.5 f<  r6  op 7.5 f<  r7  op 8.5 f<  r8  op 9.5 f<  r9  r10
  select select select select select select select select select ;

( e params i am dm rm -- : an envelope's stage rates from the knobs and the matrix's
  ATTACK, DECAY and RELEASE offsets. )
dsp: amb-env-rates | e:AmbEnv params:AmbParams i am dm rm |
  params AMB-ENV-INC  params.ea& i f@i am f+ 0.0 127.0 fclamp  amb-at  params.ksc f* -> e.ia
  params AMB-ENV-INC  params.ed& i f@i dm f+ 0.0 127.0 fclamp  amb-at  params.ksc f* -> e.id
  params AMB-ENV-INC  params.er& i f@i rm f+ 0.0 127.0 fclamp  amb-at  params.ksc f* -> e.ir
  params.es& i f@i 2.0 f* -> e.sus
;

( st params k -- : the part LFO k, 0..2: on the host clock [shared by every voice], or from the
  note when RETRIG.  The S&H takes a new value when the phase wraps. )
dsp: amb-lfo-n | st:AmbState params:AmbParams k |
  params.linc& k f@i | inc |
  params.ltrig& k f@i 0.5 f>
    [ st.t st.t0 f- inc f* ]
    [ params.lph0& k f@i  st.t params.clk0 f- inc f* f+ ]
  ifte ffrac 65536.0 f* floor | ph |
  ph  st.lpv& k f@i  f< | wrap |
  ph st.lpv& k f!i
  wrap  st.rng& rand-u 255.0 f* floor  st.ls& k f@i  select | sh |
  sh st.ls& k f!i
  params params.lshape& k f@i ph sh amb-lfo  st.ms& 3.0 k f+ f!i
;

( st params i -- : the modulator i, 0..3. )
dsp: amb-modifier | st:AmbState params:AmbParams i |
  params.md-op& i f@i | op |
  st.ms& params.md-in1& i f@i f@i | x |
  st.ms& params.md-in2& i f@i f@i | y |
  st.ms& 7.0 i f+ f@i | old |
  x 2.0 f/ floor  y 2.0 f/ floor  f+ | r1 |
  x y f* 256.0 f/ floor | r2 |
  x 128.0 f- y f* 256.0 f/ floor 128.0 f+ | r3 |
  x y fmax | r4 |
  x y fmin | r5 |
  x y u8-xor | r6 |
  x y f>  255.0 0.0 select | r7 |
  x y f>  0.0 255.0 select | r8 |
  y 0.5 f<  0.0  x  8.0 y flog2i 1.0 f+ f-  u8-hi  select | r9 |
  y 4.0 f/ floor 1.0 f+ | yy |
  256.0 yy f- old f*  yy x f* f+  256.0 f/ floor | r10 |
  op  r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 pick10 | v |
  op 0.5 f>  v old select  st.ms& 7.0 i f+ f!i
;

( st params i : the matrix slot i adds its source to its destination. )
dsp: amb-slot-add | st:AmbState params:AmbParams i |
  params.m-amt& i f@i | amt0 |
  i 12.5 f>  amt0 st.ms& 14.0 f@i f* 256.0 f/ floor  amt0  select | amt |
  params.m-src& i f@i | src |
  params.m-dst& i f@i | dst |
  st.ms& src f@i | sv |
  src 2.5 f>  src 6.5 f< and  src 13.0 f= or  src 17.0 f= or | ac |
  st.ds& dst f@i | cur |
  cur  ac  amt sv 128.0 f- f*  amt sv f*  select  f+  clip14 | plain |
  amt 0.0 f<  amt fneg amt  select | ma |
  amt 0.0 f<  255.0 sv f-  sv  select | sv2 |
  ma 63.0 f=  sv2  255.0 sv2 255.0 f- ma 4.0 f* f* 256.0 f/ floor f+  select | sv3 |
  cur sv3 f* 256.0 f/ floor | vca |
  dst 18.0 f=  vca plain  select  st.ds& dst f!i
;

( ph inc-index -- : nothing; the cutoff, in octaves over 20 Hz, from the 14-bit CV. )
dsp: amb-osc-pitch | params:AmbParams shape range detune base dst -- inc note |
  base  shape 16.0 f=  0.0  range 128.0 f*  select  f+  detune f+  dst 8192.0 f- 4.0 f/ floor f+
  15360.0 fmin 0.0 fmax | p |
  p 128.0 f/ 69.0 f- 12.0 f/ 8.78135971352466 f+ exp2 | hz |
  hz 65536.0 f* AMB-SRN f/ 65535.0 fmin
  p 128.0 f/ floor 12.0 f- 0.0 fmax
;

( ctx st params -- : one control step, ~ 980 Hz. )
dsp: k-amb-control | ctx:Ctx st:AmbState params:AmbParams |
  st.t CTL-P f+ -> st.t
  ( the envelopes, the LFOs )
  st.e1& params amb-env  st.ms& 0.0 f!i
  st.e2& params amb-env  st.ms& 1.0 f!i
  st.e3& params amb-env  st.ms& 2.0 f!i
  st params 0.0 amb-lfo-n
  st params 1.0 amb-lfo-n
  st params 2.0 amb-lfo-n
  ( the voice LFO: its rate from the last step's matrix )
  st.ds& 17.0 f@i 128.0 f/ floor | ri |
  params AMB-LFO-INC ri amb-at params.ksc f* | inc4 |
  st.l4-ph inc4 f+ | p4 |
  p4 65536.0 f>= | w4 |
  w4  p4 65536.0 f-  p4  select | ph4 |
  ph4 -> st.l4-ph
  w4  st.rng& rand-u 255.0 f* floor  st.l4-sh  select | sh4 |
  sh4 -> st.l4-sh
  params params.vl-shape ph4 floor sh4 amb-lfo  st.ms& 6.0 f!i
  ( the other sources )
  st.pitch 64.0 f/ floor  st.ms& 17.0 f!i
  st.gate  st.ms& 18.0 f!i
  st.rng& rand-u 255.0 f* floor  st.ms& 19.0 f!i
  st.vel  st.ms& 11.0 f!i
  st.prs 255.0 f* floor  st.ms& 12.0 f!i
  128.0 params.bend 127.0 f* f+ floor  st.ms& 13.0 f!i
  params.mwhl 255.0 f* floor  st.ms& 14.0 f!i
  params.whl2 255.0 f* floor  st.ms& 15.0 f!i
  params.pdal 255.0 f* floor  st.ms& 16.0 f!i
  st.rnd  st.ms& 20.0 f!i
  255.0 st.ms& 21.0 f!i  128.0 st.ms& 22.0 f!i  64.0 st.ms& 23.0 f!i  32.0 st.ms& 24.0 f!i
  16.0 st.ms& 25.0 f!i  8.0 st.ms& 26.0 f!i  4.0 st.ms& 27.0 f!i
  ( the dock's meters and the matrix bars read the sources scaled for display )
  0.0 21 [ | i |
    st.ms& i f@i | v |
    i 2.5 f>  i 6.5 f< and  i 12.5 f> i 13.5 f< and or  i 16.5 f> i 17.5 f< and or | bip |
    bip  v 128.0 f- 0.0078125 f*  v 0.00392156862745098 f*  select  st.mv& i f!i
    i 1.0 f+
  ] times drop
  0.0 4 [ | i |  st params i amb-modifier  i 1.0 f+ ] times drop
  ( the destinations start from the patch )
  params.o1-prm 128.0 f*  st.ds& 0.0 f!i
  params.o2-prm 128.0 f*  st.ds& 1.0 f!i
  8192.0 st.ds& 2.0 f!i  8192.0 st.ds& 3.0 f!i  8192.0 st.ds& 4.0 f!i  8192.0 st.ds& 5.0 f!i
  params.balance 256.0 f*  st.ds& 6.0 f!i
  params.mixprm 256.0 f*  st.ds& 7.0 f!i
  params.noise 256.0 f*  st.ds& 8.0 f!i
  params.sub-lvl 256.0 f*  st.ds& 9.0 f!i
  params.fuzz 256.0 f*  st.ds& 10.0 f!i
  params.crush-p 256.0 f*  st.ds& 11.0 f!i
  params.cutoff 128.0 f*  st.pitch f+ 8192.0 f- clip14  st.ds& 12.0 f!i
  params.reso 256.0 f*  st.ds& 13.0 f!i
  8192.0 st.ds& 14.0 f!i  8192.0 st.ds& 15.0 f!i  8192.0 st.ds& 16.0 f!i
  params.vl-rate 128.0 f*  st.ds& 17.0 f!i
  params.volume 2.0 f*  st.ds& 18.0 f!i
  0.0 14 [ | i |  st params i amb-slot-add  i 1.0 f+ ] times drop
  ( the hardwired filter modulations )
  st.ds& 12.0 f@i  params.env2 st.ms& 1.0 f@i f* f+  clip14
    params.lfo2 st.ms& 4.0 f@i 128.0 f- f* f+  clip14 | cut |
  cut 64.0 f/ floor 24.0 f/ | cexp |
  st.ds& 13.0 f@i clip14 64.0 f/ floor | rraw |
  ( the filter's coefficients are worked out at the control rate; the audio rate smooths them )
  cexp exp2 20.0 f* params.osr2 rraw 255.0 f/ ota-coeffs | gt kt |
  gt -> st.cut-t  kt -> st.res-t
  ( a released voice whose ENV 3 has run out is silent whatever the matrix routes to the VCA: a
    patch without ENV 3 on the VCA would drone forever, and the host retires a voice only once
    its output is silent )
  st.gate 0.5 f<  st.e3& 0.0 f@i 3.5 f>  and ( stage is the first field of AmbEnv )
    0.0  st.ds& 18.0 f@i 0.0 255.0 fclamp  select -> st.vca-t
  st.vca-t 1.5 f>  1.0 0.0 select -> st.alive
  ( the digital half's gains )
  st.ds& 6.0 f@i 64.0 f/ floor -> st.g-bal
  st.ds& 7.0 f@i 64.0 f/ floor -> st.g-mixp
  st.ds& 8.0 f@i 128.0 f/ floor -> st.g-nz
  st.ds& 9.0 f@i 128.0 f/ floor -> st.g-sub
  st.ds& 10.0 f@i 64.0 f/ floor -> st.g-fuzz
  st.ds& 11.0 f@i 256.0 f/ floor 1.0 f+ -> st.crush
  st.ds& 0.0 f@i 128.0 f/ floor -> st.prm1
  st.ds& 1.0 f@i 128.0 f/ floor -> st.prm2
  st.o1& params st.prm1 amb-vowel-set
  st.o2& params st.prm2 amb-vowel-set
  params.o1-range 36.0 f+ -> st.fm1
  params.o2-range 36.0 f+ -> st.fm2
  ( the envelopes' stage rates, with the matrix's ATTACK, DECAY, RELEASE moving all three )
  st.ds& 14.0 f@i 128.0 f/ floor 64.0 f- | am |
  st.ds& 15.0 f@i 128.0 f/ floor 64.0 f- | dm |
  st.ds& 16.0 f@i 128.0 f/ floor 64.0 f- | rm |
  st.e1& params 0.0 am dm rm amb-env-rates
  st.e2& params 1.0 am dm rm amb-env-rates
  st.e3& params 2.0 am dm rm amb-env-rates
  ( portamento, then each oscillator's increment )
  st.pinc 0.5 f>  st.pitch st.pinc f+ st.target f>=  and
    st.pinc fneg 0.5 f> st.pitch st.pinc f+ st.target f<= and  or | hit |
  hit  st.target  st.pitch st.pinc f+  select | pv |
  hit 0.0 st.pinc select -> st.pinc
  pv -> st.pitch
  pv  st.ds& 4.0 f@i 8192.0 f- 16.0 f/ floor f+  st.ds& 5.0 f@i 8192.0 f- 128.0 f/ floor f+ | base |
  params params.o1-shape params.o1-range params.o1-tune base st.ds& 2.0 f@i amb-osc-pitch | i1 n1 |
  i1 -> st.inc1  n1 -> st.note1
  params params.o2-shape params.o2-range params.o2-tune base st.ds& 3.0 f@i amb-osc-pitch | i2 n2 |
  i2 -> st.inc2  n2 -> st.note2
;

( --- the voice -------------------------------------------------------------------- )

( io ctx st params -- : the filter and the VCA, on the DAC's held value. )
dsp: amb-s-out | io ctx st:AmbState params:AmbParams |
  st.cut-s  st.cut-t st.cut-s f- params.sm f*  f+ | cs |
  st.res-s  st.res-t st.res-s f- params.sm f*  f+ | rs |
  st.vca-s  st.vca-t st.vca-s f- params.sm f*  f+ | vs |
  cs -> st.cut-s  rs -> st.res-s  vs -> st.vca-s
  st.held 128.0 f- 0.0078125 f* | xr |
  st.dc-y params.dca f*  xr st.dc-x f- f+ | xd |
  xr -> st.dc-x  xd -> st.dc-y
  xd AMB-IN f* | x |
  cs | g |  rs | k |
  st.vcf&  x g k params.hpa ota-step | y |
  1.0 k 0.3 f* f+  y f*  2.0833333333333335 f* | yo |
  yo vs f* 0.00392156862745098 f* params.gain f* | o |
  io f@64  o  f+  io f!64
;

( io ctx st params -- : one output sample.  Native ticks: the digital half runs at 39.2 kHz and
  the DAC holds its value between them; the analog half takes the CVs smoothed. )
dsp: k-amb-voice | io ctx st:AmbState params:AmbParams |
  io ctx st params amb-s-go
  io ctx st params amb-osc-1
  io ctx st params amb-osc-2
  io ctx st params amb-s-mix
  io ctx st params amb-s-out
;

( --- note hooks ------------------------------------------------------------------- )

( ctx st params -- )
dsp: k-amb-note-on | ctx:Ctx st:AmbState params:AmbParams |
  ctx.pitch 128.0 f* params.octave 1536.0 f* f+ params.tune 1.28 f* f+ | note |
  note -> st.target
  ctx.legato 0.5 f<  params.legato 0.5 f< or | fresh |
  st.pitch 0.5 f<  params.legato 0.5 f>  ctx.legato 0.5 f< and  or | snap |
  snap  note  st.pitch  select -> st.pitch
  note st.pitch f- | delta |
  params AMB-ENV-INC params.porta amb-at 65536.0 f/ delta f* | pi |
  pi 0.0 f=  0.0
    pi 0.0 f<  pi -1.0 fmin  pi 1.0 fmax  select
  select -> st.pinc
  ctx.clock -> st.t  fresh  ctx.clock  st.t0  select -> st.t0
  fresh  ctx.vel 255.0 f* floor  st.vel  select  -> st.vel
  fresh  st.rng& rand-u 255.0 f* floor  st.rnd  select -> st.rnd
  st.rng& ctx.chan 7.0 f+ rand-seed-once
  255.0 -> st.gate
  fresh
    [ 255.0 -> st.tr-count  st.e1& 0.0 amb-env-go  st.e2& 0.0 amb-env-go  st.e3& 0.0 amb-env-go ]
    [ ]
  ifte
  1.0 -> st.alive
  st.vca-s 0.0 f=  st.vca-t  st.vca-s  select -> st.vca-s
;

( ctx st params -- : a retuned note.  Pressure rides along. )
dsp: k-amb-note-expr | ctx:Ctx st:AmbState params:AmbParams |
  ctx.pitch 128.0 f* params.octave 1536.0 f* f+ params.tune 1.28 f* f+ | note |
  st.pitch note st.target f- f+ -> st.pitch
  note -> st.target
  ctx.pressure -> st.prs
;

( ctx st params -- )
dsp: k-amb-note-off | ctx:Ctx st:AmbState params:AmbParams |
  0.0 -> st.gate
  st.e1& 3.0 amb-env-go  st.e2& 3.0 amb-env-go  st.e3& 3.0 amb-env-go
;

( ctx state params -- : per block: the shared LFO clock and the constants that follow the host rate. )
dsp: k-amb-block-prepare | ctx:Ctx st params:AmbParams |
  ctx.sr | sr |
  ctx.clock params.clk0 f- 0.0 fmax | dt |
  0.0 3 [ | k |
    params.lph0& k f@i  dt params.linc& k f@i f* f+ ffrac  params.lph0& k f!i
    k 1.0 f+ ] times drop
  ctx.clock -> params.clk0
  0.0 3 [ | k |
    params AMB-LFO-INC  params.lrate& k f@i  amb-at
      65536.0 f/ 980.3921568627451 f* sr f/  params.linc& k f!i
    k 1.0 f+ ] times drop
  980.3921568627451 CTL-P f* sr f/ -> params.ksc
  AMB-SRN sr f/ -> params.sr-r
  sr -> params.osr2
  1.0  -1.0 0.0007 sr f* f/ exp  f- -> params.sm
  3.0 sr 2.0 f* ota-hp-coef -> params.hpa
  1.0 31.4 sr f/ f- -> params.dca
;
