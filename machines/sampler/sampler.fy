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
  "Sampler" voice-sample machine*
  "k-sampler-voice"       render!
  "sampler-note-on"       note-on!
  "sampler-note-off"      note-off!
  "sampler-block-prepare" block-prepare!
  8 voices!
  SamplerState.size  state-size!
  SamplerParams.size params-size!
  560.0 panel-w!

  "smp" SamplerParams.smp-ptr SamplerParams.smp-len SamplerParams.smp-sr "assets/default.wav" asset

  "PITCH" "TUNE" "smp-tune" SamplerParams.tune -24.0 24.0 0.0 curve-lin knob
  "PITCH" "ROOT" "smp-root" SamplerParams.root-hz 55.0 880.0 220.0 curve-exp knob
  "PITCH" "START" "smp-start" SamplerParams.start 0.0 1.0 0.0 curve-lin knob

  "LOOP" "MODE" "smp-loop" SamplerParams.loop-on 0.0 switch
    "1SHOT" 0.0 opt  "LOOP" 1.0 opt
  "LOOP" "BEG" "smp-loop-start" SamplerParams.loop-start 0.0 1.0 0.0 curve-lin knob
  "LOOP" "END" "smp-loop-end" SamplerParams.loop-end 0.0 1.0 1.0 curve-lin knob

  "ENV" "ATK" "smp-atk" SamplerParams.atk 0.001 3.0 0.002 curve-exp knob as-fader
  "ENV" "DEC" "smp-dec" SamplerParams.dec 0.01 4.0 0.6 curve-exp knob as-fader
  "ENV" "SUS" "smp-sus" SamplerParams.sus 0.0 1.0 1.0 curve-lin knob as-fader
  "ENV" "REL" "smp-rel" SamplerParams.rel 0.01 5.0 0.3 curve-exp knob as-fader

  "AMP" "LEVEL" "smp-level" SamplerParams.level 0.0 1.0 0.7 curve-pow knob as-fader

  "WAVE" "smp" waveform-display
  "PITCH" 3 strip
  "LOOP" 3 strip
  "ENV" 4 strip
  "AMP" 1 strip

  ( oscillogram across the top, taking the spare height; one row of
    control strips below )
  1.0 row
    1.0 cell  "WAVE" 1.0 item
  0.0 row
    1.0 cell  "PITCH" 1.0 item
    1.0 cell  "LOOP" 1.0 item
    1.0 cell  "ENV" 1.0 item
    1.0 cell  "AMP" 1.0 item
  machine-desc
;
