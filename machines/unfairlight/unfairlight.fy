( unfairlight.fy - Unfairlight CIA: a Fairlight CMI Series II / IIx voice.

  Eight voice cards [kernels/06-voices/cmi.fy]: any WAV, SFZ or folder
  of samples becomes CMI voice RAM - sampled at RATE, 8-bit, 16,384
  bytes at most, so a long sample is cut where the RAM runs out, as it
  was.  Each note plays on the card's own clock with no interpolation,
  the loop is whole 128-sample segments, and the SSM filter follows the
  octave register in whole-octave steps.  FILTER is the card's filter
  latch [0..255, 32 steps an octave]. )

include "../../kernels/06-voices/cmi.fy"
include "../lib/manifest.fy"

: manifest
  "Unfairlight CIA" voice-sample machine*
  "k-cmi-voice"       render!
  "cmi-note-on"       note-on!
  "cmi-note-off"      note-off!
  "cmi-block-prepare" block-prepare!
  8 voices!
  CmiState.size  state-size!
  CmiParams.size params-size!
  880.0 panel-w!

  "voice" CmiParams.pool CmiParams.zones CmiParams.zone-count CmiParams.edits "../sampler/assets/default.wav" keymap

  "VOICE" "RATE" "cmi-rate" CmiParams.rate 4000.0 32000.0 24000.0 curve-exp knob
  "VOICE" "ROOT" "cmi-root" CmiParams.root 24.0 96.0 57.0 curve-lin knob
  "VOICE" "TUNE" "cmi-tune" CmiParams.tune -24.0 24.0 0.0 curve-lin knob
  "VOICE" "START" "cmi-start" CmiParams.start-seg 0.0 127.0 0.0 int-step

  "LOOP" "MODE" "cmi-loop" CmiParams.loop-mode 0.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt
  "LOOP" "BEG" "cmi-loop-start" CmiParams.loop-start 0.0 127.0 0.0 int-step
  "LOOP" "END" "cmi-loop-end" CmiParams.loop-end 0.0 127.0 127.0 int-step

  "FILTER" "FILTER" "cmi-filter" CmiParams.filter 0.0 255.0 160.0 int-step

  "ENV" "ATTACK" "cmi-atk" CmiParams.atk 0.0 16.0 0.002 curve-pow knob as-fader
  "ENV" "DAMP" "cmi-damp" CmiParams.damp 0.005 60.0 0.3 curve-exp knob as-fader

  "VIB" "DEPTH" "cmi-vib-depth" CmiParams.vib-depth 0.0 2.0 0.0 curve-pow knob
  "VIB" "SPEED" "cmi-vib-rate" CmiParams.vib-rate 0.0 12.0 5.5 curve-lin knob

  "OUT" "VEL" "cmi-vel" CmiParams.vel-amt 0.0 1.0 0.0 curve-lin knob
  "OUT" "VOL" "cmi-vol" CmiParams.vol 0.0 1.0 0.8 curve-pow knob as-fader

  "WAVE" "voice" waveform-display
  "ZONES" "voice" zone-display
  "VOICE" 4 strip
  "LOOP" 3 strip
  "FILTER" 1 strip
  "ENV" 2 strip
  "VIB" 2 strip
  "OUT" 2 strip

  1.0 row
    2.0 cell  "WAVE" 1.0 item
    1.0 cell  "ZONES" 1.0 item
  0.0 row
    4.0 cell  "VOICE" 1.0 item
    3.0 cell  "LOOP" 1.0 item
    1.0 cell  "FILTER" 1.0 item
    2.0 cell  "ENV" 1.0 item
    2.0 cell  "VIB" 1.0 item
    2.0 cell  "OUT" 1.0 item
  machine-desc
;
