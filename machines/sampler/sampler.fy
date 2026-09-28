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
  220 Hz, A3 = 57].  ENGINE MODEL sets the converter knobs to a classic
  machine; CLOCK VARI plays the sample stored at RATE on the voice's own
  clock [Fairlight, Emulator], FIXED on a clock that doesn't follow the
  note [SP-1200, S900]; BITS and QUANT quantize it.  TRK 1 moves the
  filter with the pitch like the CMI's output filter. )

include "../../kernels/06-voices/sampler.fy"
include "../lib/manifest.fy"

: manifest
  "Sampler" voice-sample machine*
  "k-sampler-voice"       render!
  "sampler-note-on"       note-on!
  "sampler-note-off"      note-off!
  "sampler-note-expr"     note-expr!
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

  ( MODEL moves the engine knobs to a classic machine's converter:
    stored rate, bits, companding, clock, output filter.  Published
    figures where there are some, by ear where not; the knobs stay free. )
  "ENGINE" "MODEL" "smp-model" SamplerParams.model 0.0 switch
    "CLEAN" 0.0 opt  "smp-engine" 0.0 sets  "smp-rate" 48000.0 sets  "smp-bits" 16.0 sets  "smp-quant" 0.0 sets
      "smp-filter" 20000.0 sets  "smp-trk" 0.0 sets  "smp-res" 0.0 sets
    "CMI I" 1.0 opt  "smp-engine" 1.0 sets  "smp-rate" 16000.0 sets  "smp-bits" 8.0 sets  "smp-quant" 0.0 sets
      "smp-filter" 6000.0 sets  "smp-trk" 1.0 sets  "smp-res" 0.15 sets
    "CMI II" 2.0 opt  "smp-engine" 1.0 sets  "smp-rate" 24000.0 sets  "smp-bits" 8.0 sets  "smp-quant" 0.0 sets
      "smp-filter" 8000.0 sets  "smp-trk" 1.0 sets  "smp-res" 0.15 sets
    "EMU II" 3.0 opt  "smp-engine" 1.0 sets  "smp-rate" 27700.0 sets  "smp-bits" 8.0 sets  "smp-quant" 2.0 sets
      "smp-filter" 12000.0 sets  "smp-trk" 0.5 sets  "smp-res" 0.35 sets
    "MIRAGE" 4.0 opt  "smp-engine" 1.0 sets  "smp-rate" 30000.0 sets  "smp-bits" 8.0 sets  "smp-quant" 0.0 sets
      "smp-filter" 11000.0 sets  "smp-trk" 0.5 sets  "smp-res" 0.3 sets
    "LINNDRM" 5.0 opt  "smp-engine" 1.0 sets  "smp-rate" 28000.0 sets  "smp-bits" 8.0 sets  "smp-quant" 2.0 sets
      "smp-filter" 13000.0 sets  "smp-trk" 0.0 sets  "smp-res" 0.0 sets
    "DMX" 6.0 opt  "smp-engine" 1.0 sets  "smp-rate" 25000.0 sets  "smp-bits" 8.0 sets  "smp-quant" 2.0 sets
      "smp-filter" 12000.0 sets  "smp-trk" 0.0 sets  "smp-res" 0.0 sets
    "S612" 7.0 opt  "smp-engine" 1.0 sets  "smp-rate" 32000.0 sets  "smp-bits" 12.0 sets  "smp-quant" 0.0 sets
      "smp-filter" 14000.0 sets  "smp-trk" 0.0 sets  "smp-res" 0.0 sets
    "S900" 8.0 opt  "smp-engine" 2.0 sets  "smp-rate" 40000.0 sets  "smp-bits" 12.0 sets  "smp-quant" 0.0 sets
      "smp-filter" 16000.0 sets  "smp-trk" 0.0 sets  "smp-res" 0.0 sets
    "SP-1200" 9.0 opt  "smp-engine" 2.0 sets  "smp-rate" 26040.0 sets  "smp-bits" 12.0 sets  "smp-quant" 0.0 sets
      "smp-filter" 11000.0 sets  "smp-trk" 0.0 sets  "smp-res" 0.1 sets
    "SP OPEN" 10.0 opt  "smp-engine" 2.0 sets  "smp-rate" 26040.0 sets  "smp-bits" 12.0 sets  "smp-quant" 0.0 sets
      "smp-filter" 20000.0 sets  "smp-trk" 0.0 sets  "smp-res" 0.0 sets
    "MPC60" 11.0 opt  "smp-engine" 2.0 sets  "smp-rate" 40000.0 sets  "smp-bits" 12.0 sets  "smp-quant" 0.0 sets
      "smp-filter" 18000.0 sets  "smp-trk" 0.0 sets  "smp-res" 0.0 sets
    "SK-1" 12.0 opt  "smp-engine" 1.0 sets  "smp-rate" 9380.0 sets  "smp-bits" 8.0 sets  "smp-quant" 1.0 sets
      "smp-filter" 9000.0 sets  "smp-trk" 0.0 sets  "smp-res" 0.0 sets
    as-display
  "ENGINE" "CLOCK" "smp-engine" SamplerParams.engine 0.0 switch
    "CLEAN" 0.0 opt  "VARI" 1.0 opt  "FIXED" 2.0 opt
  "ENGINE" "RATE" "smp-rate" SamplerParams.rate 4000.0 48000.0 48000.0 curve-exp knob
  "ENGINE" "BITS" "smp-bits" SamplerParams.bits 1.0 16.0 16.0 curve-lin knob
  "ENGINE" "QUANT" "smp-quant" SamplerParams.qmode 0.0 switch
    "LIN" 0.0 opt  "TRUNC" 1.0 opt  "MU" 2.0 opt
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
  "ENGINE" 4 strip
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
