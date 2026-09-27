( sampler.fy - polyphonic multisample voice over a host-loaded keymap.

  The host loads a keymap [src/keymap.zig: a WAV, an SFZ, or a folder]
  into one f64 pool with zero guards around each sample, plus a table of
  MAX-ZONES zones, and injects both pointers into params [manifest
  `keymap`].  Unused zones have an impossible key range.

  note-on picks the first zone whose key and velocity ranges hold the
  note [an unrolled `times` scan], and copies what the voice needs.  The
  pitch is TUNE plus the distance from the zone's root [or ROOT when the
  file didn't say].  Two engines:

    CLEAN  4-point Hermite interpolation between stored samples
    CLOCK  drop-sample playback: the voice's own sample clock steps
           through the stored samples with no interpolation, quantized
           to BITS - the Fairlight / Emulator / SP-1200 way, where the
           grain and the aliasing move with the note.  Steps are
           polyBLEPed onto their true times, so the host's grid adds no
           aliasing of its own.

  Then a 4-pole lowpass whose corner can follow the pitch [TRK: 1 moves
  it with the voice's clock like the CMI's output filter], the cap-ADSR,
  and velocity.

  Choke groups: every note-on takes a sequence number; a note in group
  g > 0 writes it into params.choke[g], and a voice whose off-by names a
  group that has seen a newer note releases in 4 ms. One-shot zones
  [drums] ignore note-off and play to the end. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../03-envelopes/primitives/segments.fy"
include "../00-primitives/math.fy"
include "../04-filters/coeffs.fy"
include "../04-filters/tpt_svf.fy"
include "../09-digital/digital.fy"

( One keymap zone: 16 f64 cells, mirrored by Zone in src/keymap.zig. )
ustruct: Zone
  f64 start  f64 len  f64 sr
  f64 lo-key  f64 hi-key  f64 lo-vel  f64 hi-vel
  f64 root  f64 gain  f64 loop-mode  f64 loop-start  f64 loop-end
  f64 group  f64 off-by  f64 pan  f64 pad
;

:: MAX-ZONES 128 ;

( Per-zone edits over the knobs, host-owned: src/keymap.zig ZoneEdits.
  The voice reads its zone's cells at note-on and writes hit / last,
  which the panel's zone list reads to light the zone that played. )
ustruct: ZoneEdits
  f64 level 128   ( dB )
  f64 tune 128    ( semitones )
  f64 decay 128   ( seconds to -60 dB; 0 = off )
  f64 tone 128    ( filter offset, octaves )
  f64 hit 128     ( sequence number of the zone's newest note )
  f64 last        ( the zone of the newest note )
;


ustruct: SamplerState
  ( the zone, copied at note-on; positions are pool indices )
  f64 start
  f64 end
  f64 ls         ( loop start )
  f64 le         ( loop end, exclusive )
  f64 loop-on
  f64 oneshot
  f64 gain
  f64 off-by
  f64 seq        ( this note's sequence number, for choke )
  ( playback )
  f64 ph         ( read position in the pool )
  f64 inc        ( advance per host sample )
  f64 held       ( CLOCK: the value on the output, before its BLEP )
  f64 pend       ( CLOCK: next output, naive + after-step correction )
  f64 i-prev     ( CLOCK: the stored sample index last read )
  f64 fg         ( filter coefficient for this note )
  f64 fade       ( per-zone DECAY: the level it has faded to )
  f64 fade-k     ( and its per-sample factor, 1 = none )
  f64 f1  f64 f2  f64 f3  f64 f4
  ( envelope )
  f64 age
  f64 gate-time
  f64 vel
;

ustruct: SamplerParams
  ( keymap - injected by the host )
  f64 pool       ( pointer to the sample pool )
  f64 zones      ( pointer to MAX-ZONES zones )
  f64 zone-count
  f64 edits      ( pointer to ZoneEdits )
  ( user-facing )
  f64 tune       ( semitones )
  f64 root       ( MIDI note for zones whose files carry no root )
  f64 start      ( playback start, 0..1 of the zone's length )
  f64 loop-mode  ( 0 AUTO [the file's] / 1 OFF / 2 ON [BEG..END] )
  f64 loop-start ( 0..1 )
  f64 loop-end   ( 0..1 )
  f64 engine     ( 0 CLEAN / 1 CLOCK )
  f64 bits       ( CLOCK quantizer, 1..16 )
  f64 filter-hz  ( lowpass corner at the zone's root )
  f64 trk        ( 0..1: how far the corner follows the pitch )
  f64 res        ( 0..1 )
  f64 atk
  f64 dec
  f64 sus
  f64 rel
  f64 vel-amt    ( 0..1: velocity to level )
  f64 level
  ( derived / shared - block-prepare and note-on )
  f64 inv-sr
  f64 step       ( CLOCK quantizer step )
  f64 fd2        ( second filter stage's damping )
  f64 note-seq   ( note-ons so far )
  f64 choke 16  ( per group 0..15: the sequence number of its newest note )
;

:: BW-D1 0.9238795325112867 ;

( ctx state params -- )
dsp: sampler-block-prepare | ctx:Ctx state params:SamplerParams |
  1.0 ctx.sr f/ -> params.inv-sr
  1.0 params.bits 1.0 16.0 fclamp f- exp2 -> params.step
  0.3826834323650898  1.0 params.res 0.0 1.0 fclamp 0.92 f* f-  f* -> params.fd2
;

( zt key vel -- k : the first zone holding key and vel [0..127], or -1.
  Unrolled over every zone; `best 0.0 f<` keeps the first match. )
dsp: zone-find | zt key vel -- k |
  -1.0 0.0 MAX-ZONES [ | best i |
    i 16.0 f* | c |
    zt c 3.0 f+ f@i key f<=   key zt c 4.0 f+ f@i f<=  and
    zt c 5.0 f+ f@i vel f<=  and   vel zt c 6.0 f+ f@i f<=  and
    best 0.0 f<  and
    i best select
    i 1.0 f+ ] times
  drop
;

( ctx state params -- : find the zone, set up playback, take a sequence
  number and choke the note's group.  No zone: len 0, silent. )
dsp: sampler-note-on | ctx:Ctx state:SamplerState params:SamplerParams |
  params.zones& p@64 | zt |
  ctx.pitch | key |
  zt key ctx.vel 127.0 f* zone-find | k |
  k 0.0 f>= | hit |
  k 0.0 fmax 16.0 f* | c |
  ( a miss plays an empty zone at pool index 4: guard zeros )
  hit  zt c f@i  4.0  select | start |
  hit  zt c 1.0 f+ f@i  0.0  select | len |
  zt c 2.0 f+ f@i | zsr |
  zt c 7.0 f+ f@i | zroot |
  zt c 9.0 f+ f@i | zmode |
  zt c 10.0 f+ f@i | zls |
  zt c 11.0 f+ f@i | zle |
  zt c 12.0 f+ f@i | group |
  start -> state.start
  start len f+ -> state.end
  params.edits& p@64 | ed:ZoneEdits |
  k 0.0 fmax | k0 |
  zt c 8.0 f+ f@i  ed.level& k0 f@i db>lin  f* -> state.gain
  zt c 13.0 f+ f@i -> state.off-by
  ( loop: AUTO takes the file's mode and points, ON forces a loop,
    one-shot zones never loop )
  zmode 1.5 f> | oneshot |
  oneshot mask>f -> state.oneshot
  zle zls f> | has-pts |
  params.loop-mode 0.5  zmode 0.5 f> mask>f  params.loop-mode 1.5 0.0 1.0 fsel-lt  fsel-lt | lon |
  oneshot 0.0 lon select -> state.loop-on
  params.loop-mode 1.5 f<  has-pts and | use-file |
  use-file  zls  params.loop-start len f*  select  start f+ | ls |
  use-file  zle  params.loop-end len f*  select  start f+  ls 1.0 f+ fmax | le |
  ls -> state.ls
  le -> state.le
  ( pitch: semitones from the root; the clock ratio includes the rates )
  zroot 0.0  params.root zroot fsel-lt | root |
  key params.tune f+  ed.tune& k0 f@i f+  root f- 0.08333333333333333 f* exp2 | ratio |
  zsr ctx.sr f/ ratio f* 16.0 fmin -> state.inc
  start  params.start len f* f+ -> state.ph
  0.0 -> state.held
  0.0 -> state.pend
  -1.0 -> state.i-prev
  ( filter corner follows the pitch by TRK octaves per octave )
  ratio log2 params.trk f*  ed.tone& k0 f@i f+  exp2 params.filter-hz f* ctx.sr svf-g -> state.fg
  ( DECAY: -60 dB over the zone's decay time, on top of the envelope )
  ed.decay& k0 f@i | dcy |
  1.0 -> state.fade
  dcy 0.0 f>  -6.907755278982137 dcy ctx.sr f* 0.000000001 fmax f/ exp  1.0  select -> state.fade-k
  0.0 -> state.f1  0.0 -> state.f2  0.0 -> state.f3  0.0 -> state.f4
  0.0 -> state.age
  1000000000.0 -> state.gate-time
  ctx.vel -> state.vel
  ( choke bookkeeping )
  params.note-seq 1.0 f+ | seq |
  seq -> params.note-seq
  seq -> state.seq
  group 0.0 15.0 fclamp | g |
  params.choke& g f@i | old |
  group 0.5 f>  seq  old  select  params.choke& g f!i
  ( the panel's hit lights )
  ed.hit& k0 f@i | oldhit |
  hit  seq  oldhit  select  ed.hit& k0 f!i
  hit  k0  ed.last  select -> ed.last
;

( ctx state params -- : release, unless the zone is a one-shot. )
dsp: sampler-note-off | ctx state:SamplerState params |
  state.oneshot 0.5  state.age  state.gate-time  fsel-lt -> state.gate-time
;

( buf ph -- y : 4-point Hermite at ph between the stored samples. )
dsp: smp-hermite | buf ph -- y |
  ph floor | i0 |
  ph i0 f- | u |
  buf i0 1.0 f- f@i | xm |
  buf i0 f@i | x0 |
  buf i0 1.0 f+ f@i | x1 |
  buf i0 2.0 f+ f@i | x2 |
  x1 xm f- 0.5 f* | c1 |
  xm  x0 2.5 f* f-  x1 2.0 f* f+  x2 0.5 f* f- | c2 |
  x2 xm f- 0.5 f*  x0 x1 f- 1.5 f*  f+ | c3 |
  c3 u f* c2 f+ u f* c1 f+ u f* x0 f+
;

( state buf params -- y : drop-sample read, quantized, with the step onto
  a new stored sample polyBLEPed at its true time: the crossing was
  frac[ph]/inc host samples ago.  Above the host rate [inc > 1] several
  crossings share one sample; the BLEP covers the last. )
dsp: smp-clock | state:SamplerState buf params:SamplerParams -- y |
  state.ph | ph |
  ph floor | i0 |
  buf i0 f@i params.step quantize-round | q |
  i0 state.i-prev f= not | ev |
  i0 -> state.i-prev
  ph i0 f- state.inc f/ 0.0 1.0 fclamp | t |
  state.held | h |
  ev  q h f-  0.0  select | delta |
  ev  q  h  select | h2 |
  h2 -> state.held
  state.pend  delta t t f* f* 0.5 f*  f+ | y |
  1.0 t f- | u |
  h2  delta u u f* f* 0.5 f*  f-  -> state.pend
  y
;

( io ctx state params -- : one sampler voice tick. )
dsp: k-sampler-voice | out:Io ctx state:SamplerState params:SamplerParams -- |
  params.pool& p@64 | buf |
  state.ph | ph |
  ph state.end f< mask>f | alive |
  params.engine 0.5  buf ph smp-hermite  state buf params smp-clock  fsel-lt | x |
  state.f1& state.f2& x state.fg BW-D1 tpt-svf-lp-step | a |
  state.f3& state.f4& a state.fg params.fd2 tpt-svf-lp-step | y |
  ( advance: wrap inside the loop, else park at the end )
  ph state.inc f+ | p2 |
  state.loop-on 0.5 f>  p2 state.le f>=  and | wrap |
  wrap  p2 state.le state.ls f- f-  p2  select  state.end fmin -> state.ph
  ( choke: a newer note in the group this voice is off-by )
  params.choke& state.off-by f@i state.seq f>  state.off-by 0.5 f>  and | choked |
  state.age params.inv-sr f+ | age |
  age -> state.age
  choked  state.gate-time age fmin  state.gate-time  select | gt |
  gt -> state.gate-time
  age params.atk params.dec params.sus gt  choked 0.004 params.rel select  adsr-cap | env |
  1.0 params.vel-amt f-  state.vel params.vel-amt f*  f+ | va |
  state.fade | fade |
  fade state.fade-k f* -> state.fade
  out f@64
  y env f*  va f*  state.gain f*  fade f*  params.level f*  alive f*
  f+
  out f!64
;
