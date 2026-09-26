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
  | ctx state params |
  ctx Ctx.sr@ | sr |
  60.0 ctx Ctx.tempo@ 20.0 999.0 fclamp f/
  params DelayParams.div@ f*
  0.02 1.5 fclamp
  params DelayParams.sync@ f*
  params DelayParams.time-s@ 1.0 params DelayParams.sync@ f- f*
  f+
  sr f*
  params DelayParams.time-spl-p f!64
  params DelayParams.damp-hz@ 6.2831853 f* sr f/ 0.0 1.0 fclamp
  params DelayParams.damp-a-p f!64
;

( ctx state params -- : runs every block.  Seeds the time slew at
  the target on the first run after reset - a live tz is always >= 2, so
  tz < 1 means fresh state and we skip the silent ramp-from-zero chirp. )
dsp: delay-prepare
  | ctx state params |
  ctx Ctx.sr@ | sr |
  state DelayState.time-z@ 1.0
  params DelayParams.time-spl@
  state DelayState.time-z@
  fsel-lt
  state DelayState.time-z-p f!64
;

( io ctx state params -- : one delay tick.  Reads happen at wpos - time
  which is always at least one cell behind the deferred buf write. )
dsp: k-delay-tick
  | out ctx state params |
  state DelayState.buf-p p@64 | buf |
  state DelayState.buf-len@ | len |
  ( slew the delay time, clamped into the ring with headroom )
  params DelayParams.time-spl@ 2.0 len 4.0 f- fclamp | dt |
  state DelayState.time-z@ | tz0 |
  tz0  dt tz0 f- 0.0008 f*  f+ | tz |
  tz state DelayState.time-z-p f!64
  ( interpolated read at wpos - tz, wrapped into 0..len )
  state DelayState.wpos@ | w |
  w tz f- | rp0 |
  rp0 0.0  rp0 len f+  rp0 fsel-lt | rp |
  buf rp f@i | s0 |
  rp 1.0 f+ | rp1 |
  rp1 len  rp1  rp1 len f-  fsel-lt | rpw |
  buf rpw f@i | s1 |
  s0  s1 s0 f-  rp ffrac f*  f+ | rd |
  ( feedback damping one-pole )
  state DelayState.damp-z@ | dz0 |
  dz0  rd dz0 f-  params DelayParams.damp-a@ f*  f+ | dz |
  dz state DelayState.damp-z-p f!64
  ( ring write and write-head advance )
  out Io.in-l@ | x |
  x  dz params DelayParams.feedback@ f*  f+  buf w f!i
  w 1.0 f+ | w1 |
  w1 len  w1  w1 len f-  fsel-lt
  state DelayState.wpos-p f!64
  ( dry/wet )
  x  1.0 params DelayParams.mix@ f-  f*
  rd params DelayParams.mix@ f*  f+
  out f!64
;
