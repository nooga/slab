( delay.fy - stereo-per-channel digital delay on a host-allocated ring.

  The ring buffer is requested from the host via the manifest `buffer`
  word; the host writes the base pointer and element count into each
  channel's state, and the kernel reads them back with p@64 / f@64 and
  indexes with f@i / f!i.  Per sample: linear-interpolated read at
  wpos - time, a one-pole lowpass in the feedback path, write
  in + fb * damped, dry/wet mix to out.

  The delay time is slewed toward its target with a one-pole so TIME
  knob moves produce tape-style pitch bends instead of clicks.

  Probe case: delay-render - impulse train against a Zig reference
  mirror, WAV + CSV + ratcheted stats. )

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
ustruct: DelayState
  f64 buf       ( host-injected ring base pointer )
  f64 buf-len   ( host-injected element count )
  f64 wpos      ( write head, 0..len )
  f64 time-z    ( slewed delay time in samples )
  f64 damp-z    ( feedback lowpass state )
;

ustruct: DelayParams
  ( user-facing )
  f64 time-s    ( delay time, s — used when sync is off )
  f64 feedback  ( 0..0.9 )
  f64 mix       ( dry/wet 0..1 )
  f64 damp-hz   ( feedback lowpass cutoff )
  f64 sync      ( switch: 0 free / 1 tempo-synced )
  f64 div       ( switch option value: beat multiplier, quarter = 1.0 )
  ( derived - filled by delay-block-prepare )
  f64 time-spl  ( effective time * sr )
  f64 damp-a    ( one-pole coefficient, 0..1 )
;

( ctx state params -- : block-rate derived fill.  Effective delay time is
  the TIME knob when free, or 60/bpm * div when SYNC is on; selected
  branchlessly via the sync flag (dsp2 has no if/then).  bpm is clamped to
  20..999 first so a zero/garbage tempo can't produce inf*0 = NaN. )
dsp: delay-block-prepare
  | ctx:Ctx state params:DelayParams |
  ctx.sr | sr |
  60.0 ctx.tempo 20.0 999.0 fclamp f/
  params.div f*
  0.02 1.5 fclamp
  params.sync f*
  params.time-s 1.0 params.sync f- f*
  f+
  sr f*
  -> params.time-spl
  params.damp-hz 6.2831853 f* sr f/ 0.0 1.0 fclamp
  -> params.damp-a
;

( ctx state params -- : runs every block.  Seeds the time slew at
  the target on the first run after reset - a live tz is always >= 2, so
  tz < 1 means fresh state and we skip the silent ramp-from-zero chirp. )
dsp: delay-prepare
  | ctx:Ctx state:DelayState params:DelayParams |
  ctx.sr | sr |
  state.time-z 1.0
  params.time-spl
  state.time-z
  fsel-lt
  -> state.time-z
;

( io ctx state params -- : one delay tick.  Reads happen at wpos - time
  which is always at least one cell behind the buf write [indexed f!i
  stores land at the end of the word]. )
dsp: k-delay-tick
  | out:Io ctx state:DelayState params:DelayParams |
  state.buf& p@64 | buf |
  state.buf-len | len |
  ( slew the delay time, clamped into the ring with headroom )
  params.time-spl 2.0 len 4.0 f- fclamp | dt |
  state.time-z | tz0 |
  tz0  dt tz0 f- 0.0008 f*  f+ | tz |
  tz -> state.time-z
  ( interpolated read at wpos - tz, wrapped into 0..len )
  state.wpos | w |
  w tz f- | rp0 |
  rp0 0.0  rp0 len f+  rp0 fsel-lt | rp |
  buf rp f@i | s0 |
  rp 1.0 f+ | rp1 |
  rp1 len  rp1  rp1 len f-  fsel-lt | rpw |
  buf rpw f@i | s1 |
  s0  s1 s0 f-  rp ffrac f*  f+ | rd |
  ( feedback damping one-pole )
  state.damp-z | dz0 |
  dz0  rd dz0 f-  params.damp-a f*  f+ | dz |
  dz -> state.damp-z
  ( ring write and write-head advance )
  out.in-l | x |
  x  dz params.feedback f*  f+  buf w f!i
  w 1.0 f+ | w1 |
  w1 len  w1  w1 len f-  fsel-lt
  -> state.wpos
  ( dry/wet )
  x  1.0 params.mix f-  f*
  rd params.mix f*  f+
  out f!64
;
