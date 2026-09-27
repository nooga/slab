( sampler.fy - polyphonic multisample machine.

  The voice lives in the kernels rig [kernels/06-voices/sampler.fy].
  The zone list edits each zone over the knobs [LEVEL, TUNE, DECAY,
  TONE, kept by zone name in presets and projects], and a kit's keys
  get its zones' names in the piano roll.

  The host loads a keymap - one WAV, an SFZ, or a folder of WAVs [note
  names in the file names make a multisample, a folder without them a
  drum kit] - and injects the sample pool and zone table [manifest
  `keymap`, src/keymap.zig].  LOAD on the waveform swaps it while
  playing; the bundled pluck is the default.

  ROOT is the pitch of a sample whose file doesn't say [the pluck is
  220 Hz, A3 = 57].  ENGINE CLOCK plays each stored sample on the
  voice's own clock at BITS, the way the Fairlight and the SP-1200 did;
  TRK 1 moves the filter with the pitch like the CMI's output filter. )

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
  760.0 panel-w!

  "smp" SamplerParams.pool SamplerParams.zones SamplerParams.zone-count SamplerParams.edits "assets/default.wav" keymap

  "PITCH" "TUNE" "smp-tune" SamplerParams.tune -24.0 24.0 0.0 curve-lin knob
  "PITCH" "ROOT" "smp-root" SamplerParams.root 24.0 96.0 57.0 curve-lin knob
  "PITCH" "START" "smp-start" SamplerParams.start 0.0 1.0 0.0 curve-lin knob

  "LOOP" "MODE" "smp-loop" SamplerParams.loop-mode 0.0 switch
    "AUTO" 0.0 opt  "OFF" 1.0 opt  "ON" 2.0 opt
  "LOOP" "BEG" "smp-loop-start" SamplerParams.loop-start 0.0 1.0 0.0 curve-lin knob
  "LOOP" "END" "smp-loop-end" SamplerParams.loop-end 0.0 1.0 1.0 curve-lin knob

  "ENGINE" "MODE" "smp-engine" SamplerParams.engine 0.0 switch
    "CLEAN" 0.0 opt  "CLOCK" 1.0 opt
  "ENGINE" "BITS" "smp-bits" SamplerParams.bits 1.0 16.0 16.0 curve-lin knob
  "ENGINE" "FILTER" "smp-filter" SamplerParams.filter-hz 200.0 20000.0 20000.0 curve-exp knob
  "ENGINE" "TRK" "smp-trk" SamplerParams.trk 0.0 1.0 0.0 curve-lin knob
  "ENGINE" "RES" "smp-res" SamplerParams.res 0.0 1.0 0.0 curve-lin knob

  "ENV" "ATK" "smp-atk" SamplerParams.atk 0.001 3.0 0.002 curve-exp knob as-fader
  "ENV" "DEC" "smp-dec" SamplerParams.dec 0.01 4.0 0.6 curve-exp knob as-fader
  "ENV" "SUS" "smp-sus" SamplerParams.sus 0.0 1.0 1.0 curve-lin knob as-fader
  "ENV" "REL" "smp-rel" SamplerParams.rel 0.01 5.0 0.3 curve-exp knob as-fader

  "AMP" "VEL" "smp-vel" SamplerParams.vel-amt 0.0 1.0 1.0 curve-lin knob
  "AMP" "LEVEL" "smp-level" SamplerParams.level 0.0 1.0 0.7 curve-pow knob as-fader

  "WAVE" "smp" waveform-display
  "ZONES" "smp" zone-display
  "PITCH" 3 strip
  "LOOP" 3 strip
  "ENGINE" 5 strip
  "ENV" 4 strip
  "AMP" 2 strip

  ( the selected zone's oscillogram and the zone list across the top,
    taking the spare height; one row of control strips below )
  1.0 row
    2.0 cell  "WAVE" 1.0 item
    1.0 cell  "ZONES" 1.0 item
  0.0 row
    3.0 cell  "PITCH" 1.0 item
    3.0 cell  "LOOP" 1.0 item
    5.0 cell  "ENGINE" 1.0 item
    4.0 cell  "ENV" 1.0 item
    2.0 cell  "AMP" 1.0 item
  machine-desc
;
