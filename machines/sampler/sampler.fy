( sampler.fy — polyphonic sample-playback machine.

  The voice lives in the kernels rig [kernels/06-voices/sampler.fy].
  The host loads assets/default.wav into the asset arena at create
  [manifest `asset`] and injects its pointer/length/native-sr into the
  shared params; the eight voices all read that one buffer.  Phase B
  will add runtime file loading; for now the bundled pluck proves the
  whole pipeline end to end.

  ROOT is the pitch the bundled sample was recorded at [220 Hz / A3], so
  playing A3 reproduces it at speed and other notes transpose. )

include "../../kernels/06-voices/sampler.fy"
include "../lib/manifest.fy"

: manifest
  "sampler" voice-sample machine*
  "k-sampler-voice"       render!
  "sampler-note-on"       note-on!
  "sampler-note-off"      note-off!
  "sampler-block-prepare" block-prepare!
  8 voices!
  SamplerState.size  state-size!
  SamplerParams.size params-size!
  440.0 panel-w!

  "smp" SamplerParams.smp-ptr SamplerParams.smp-len SamplerParams.smp-sr "assets/default.wav" asset

  "PITCH" "TUNE" "smp-tune" SamplerParams.tune -24.0 24.0 0.0 curve-lin knob
  "PITCH" "ROOT" "smp-root" SamplerParams.root-hz 55.0 880.0 220.0 curve-exp knob
  "PITCH" "START" "smp-start" SamplerParams.start 0.0 1.0 0.0 curve-lin knob

  "LOOP" "MODE" "smp-loop" SamplerParams.loop-on 0.0 switch
    "1SHOT" 0.0 opt  "LOOP" 1.0 opt
  "LOOP" "BEG" "smp-loop-start" SamplerParams.loop-start 0.0 1.0 0.0 curve-lin knob
  "LOOP" "END" "smp-loop-end" SamplerParams.loop-end 0.0 1.0 1.0 curve-lin knob

  "ENV" "ATK" "smp-atk" SamplerParams.atk 0.001 3.0 0.002 curve-exp knob
  "ENV" "DEC" "smp-dec" SamplerParams.dec 0.01 4.0 0.6 curve-exp knob
  "ENV" "SUS" "smp-sus" SamplerParams.sus 0.0 1.0 1.0 curve-lin knob
  "ENV" "REL" "smp-rel" SamplerParams.rel 0.01 5.0 0.3 curve-exp knob

  "AMP" "LEVEL" "smp-level" SamplerParams.level 0.0 1.0 0.7 curve-pow knob

  "PITCH" 1 strip
  "LOOP" 1 strip
  "ENV" 1 strip
  "AMP" 1 strip

  "ENV ADSR" "ENV" adsr-display

  machine-desc
;
