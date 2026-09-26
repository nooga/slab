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

include "../00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../03-envelopes/primitives/segments.fy"
include "../00-primitives/pow2.fy"

ustruct: SamplerState
  f64 phase      ( fractional sample index into the asset )
  f64 inc        ( advance per host sample, set at note-on )
  f64 age        ( seconds since note-on )
  f64 gate-time  ( age at release; huge while held )
  f64 vel
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

( ctx state params -- : resampling ratio, tune, loop/start in samples. )
dsp: sampler-block-prepare
  | ctx:Ctx state params:SamplerParams |
  ctx.sr | sr |
  1.0 sr f/ -> params.inv-sr
  params.smp-sr sr f/ -> params.sr-ratio
  params.tune 0.083333333333 f* exp2-approx -> params.tune-mult
  params.smp-len | len |
  params.start len f* -> params.start-spl
  params.loop-start len f* | ls |
  ls -> params.loop-start-spl
  params.loop-end len f*  ls 1.0 f+  len  fclamp | le |
  le -> params.loop-end-spl
  le ls f- -> params.loop-len-spl
;

( ctx state params -- : trigger playback from the start point. )
dsp: sampler-note-on
  | ctx:Ctx state:SamplerState params:SamplerParams |
  ctx.hz ctx.vel | hz velocity |
  params.sr-ratio params.tune-mult f*
  hz f* params.root-hz f/
  -> state.inc
  params.start-spl -> state.phase
  0.0 -> state.age
  1000000000.0 -> state.gate-time
  velocity -> state.vel
;

( ctx state params -- : release the amp envelope. )
dsp: sampler-note-off
  | ctx state:SamplerState params |
  state.age -> state.gate-time
;

( Interpolated read at phase, then advance with loop wrap or one-shot
  park.  The read index is clamped to a valid range and the output gated
  past the sample end, so an empty/exhausted asset is silent rather than
  an out-of-bounds dereference. )
dsp: smp-read | state:SamplerState params:SamplerParams -- smp |
  params.smp-ptr& p@64 | buf |
  params.smp-len | len |
  len 2.0 f- 0.0 268435456.0 fclamp | hi |
  state.phase | ph |
  ph 0.0 hi fclamp | rp |
  buf rp f@i | s0 |
  buf rp 1.0 f+ f@i | s1 |
  s0  s1 s0 f-  rp ffrac f*  f+
  ph len 1.0 0.0 fsel-lt  f*
  ph state.inc f+ | ph2 |
  ph2 params.loop-end-spl  ph2  ph2 params.loop-len-spl f-  fsel-lt | ph-loop |
  ph2 len  ph2  len  fsel-lt | ph-shot |
  params.loop-on 0.5  ph-shot  ph-loop  fsel-lt
  -> state.phase
;

( Cap-ADSR amp, accumulate into out. )
dsp: smp-amp | out state:SamplerState params:SamplerParams smp -- |
  state.age params.inv-sr f+ | age |
  age -> state.age
  age
  params.atk params.dec params.sus
  state.gate-time params.rel
  adsr-cap | env |
  out f@64
  smp env f*  state.vel f*  params.level f*
  f+
  out f!64
;

( io ctx state params -- : one sampler voice tick. )
dsp: k-sampler-voice | io ctx state params -- |
  state params smp-read | smp |
  io state params smp smp-amp
;
