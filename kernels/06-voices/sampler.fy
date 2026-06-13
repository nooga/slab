( sampler.fy - polyphonic sample-playback voice on a host-loaded asset.

  The audio lives in the asset arena [manifest `asset`; host loads a WAV
  into params as ptr/len/native-sr].  Each voice reads the SAME shared
  read-only buffer with p@64 / f@i, plays it back at a pitch-derived
  rate, shapes it with a cap-ADSR, and accumulates into the host-zeroed
  out buffer [polyphony contract in src/machines/fy_raw_machine.zig].

  Playback rate per host sample:
    inc = (native-sr / host-sr) * 2^(TUNE/12) * note-hz / ROOT-hz
  so the sample plays at its recorded speed when note == ROOT, and
  transposes by pitch.  One-shot or looped [branchless wrap]; the read
  index is clamped and the output gated so an unloaded or exhausted
  sample is silent, never an out-of-bounds read.

  Probe case: sampler-render. )

include "../03-envelopes/primitives/segments.fy"
include "../00-primitives/pow2.fy"

ustruct: SamplerState
  f64 phase      ( fractional sample index into the asset )
  f64 inc        ( advance per host sample, set at note-on )
  f64 age        ( seconds since note-on )
  f64 gate-time  ( age at release; huge while held )
  f64 vel
  f64 samp       ( stage scratch: interpolated sample )
;

ustruct: SamplerParams
  ( asset arena - injected by the host )
  f64 smp-ptr
  f64 smp-len
  f64 smp-sr
  ( user-facing )
  f64 tune       ( semitones )
  f64 root-hz    ( pitch the sample was recorded at )
  f64 start      ( playback start, 0..1 of length )
  f64 loop-on    ( 0/1 )
  f64 loop-start ( 0..1 )
  f64 loop-end   ( 0..1 )
  f64 atk
  f64 dec
  f64 sus
  f64 rel
  f64 level
  ( derived - filled by sampler-block-prepare )
  f64 inv-sr
  f64 sr-ratio
  f64 tune-mult
  f64 start-spl
  f64 loop-start-spl
  f64 loop-end-spl
  f64 loop-len-spl
;

( params sample-rate -- : resampling ratio, tune, loop/start in samples. )
dsp2: sampler-block-prepare
  | params sr |
  1.0 sr f/ params SamplerParams.inv-sr-p f!64
  params SamplerParams.smp-sr@ sr f/ params SamplerParams.sr-ratio-p f!64
  params SamplerParams.tune@ 0.083333333333 f* exp2-approx params SamplerParams.tune-mult-p f!64
  params SamplerParams.smp-len@ | len |
  params SamplerParams.start@ len f* params SamplerParams.start-spl-p f!64
  params SamplerParams.loop-start@ len f* | ls |
  ls params SamplerParams.loop-start-spl-p f!64
  params SamplerParams.loop-end@ len f*  ls 1.0 f+  len  fclamp | le |
  le params SamplerParams.loop-end-spl-p f!64
  le ls f- params SamplerParams.loop-len-spl-p f!64
  drop2 drop2 drop
;

( state params hz velocity -- : trigger playback from the start point. )
dsp2: sampler-note-on
  | state params hz velocity |
  params SamplerParams.sr-ratio@ params SamplerParams.tune-mult@ f*
  hz f* params SamplerParams.root-hz@ f/
  state SamplerState.inc-p f!64
  params SamplerParams.start-spl@ state SamplerState.phase-p f!64
  0.0 state SamplerState.age-p f!64
  1000000000.0 state SamplerState.gate-time-p f!64
  velocity state SamplerState.vel-p f!64
  drop2 drop2
;

( state params -- : release the amp envelope. )
dsp2: sampler-note-off
  | state params |
  state SamplerState.age@ state SamplerState.gate-time-p f!64
  drop2
;

( state params -- : interpolated read at phase, then advance with loop
  wrap or one-shot park.  The read index is clamped to a valid range and
  the output gated past the sample end, so an empty/exhausted asset is
  silent rather than an out-of-bounds dereference. )
dsp2: smp-read
  | state params |
  params SamplerParams.smp-ptr-p p@64 | buf |
  params SamplerParams.smp-len@ | len |
  len 2.0 f- 0.0 268435456.0 fclamp | hi |
  state SamplerState.phase@ | ph |
  ph 0.0 hi fclamp | rp |
  buf rp f@i | s0 |
  buf rp 1.0 f+ f@i | s1 |
  s0  s1 s0 f-  rp ffrac f*  f+ | smp |
  smp  ph len 1.0 0.0 fsel-lt  f*
  state SamplerState.samp-p f!64
  ph state SamplerState.inc@ f+ | ph2 |
  ph2 params SamplerParams.loop-end-spl@  ph2  ph2 params SamplerParams.loop-len-spl@ f-  fsel-lt | ph-loop |
  ph2 len  ph2  len  fsel-lt | ph-shot |
  params SamplerParams.loop-on@ 0.5  ph-shot  ph-loop  fsel-lt
  state SamplerState.phase-p f!64
  drop2 drop2 drop2 drop2 drop2 drop2 drop
;

( out state params -- : cap-ADSR amp, accumulate into out. )
dsp2: smp-amp
  | out state params |
  state SamplerState.age@ params SamplerParams.inv-sr@ f+ | age |
  age state SamplerState.age-p f!64
  age
  params SamplerParams.atk@ params SamplerParams.dec@ params SamplerParams.sus@
  state SamplerState.gate-time@ params SamplerParams.rel@
  adsr-cap | env |
  out f@64
  state SamplerState.samp@ env f*  state SamplerState.vel@ f*  params SamplerParams.level@ f*
  f+
  out f!64
  drop2 drop2 drop
;

( out state params -- : one sampler voice tick, staged. )
dsp2: k-sampler-voice
  | out state params |
  state params call: smp-read
  out state params call: smp-amp
;
