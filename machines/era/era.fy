( era.fy - sample-era converter effect: rate, bits, companding, filters.

  DSP in the kernels rig [kernels/07-effects/era.fy]; the converter
  primitives it strings together are kernels/09-digital/digital.fy.
  The presets are the machines' converters: SP-1200, Emulator, CMI,
  Mirage, SK-1, MPC60 and the rest. )

include "../../kernels/07-effects/era.fy"
include "../lib/manifest.fy"

: manifest
  "Era" effect-block machine*
  "k-era-tick"        render!
  "era-block-prepare" block-prepare!
  EraState.size  state-size!
  EraParams.size params-size!
  440.0 panel-w!

  "ADC" "IN"   "era-in"   EraParams.in-db -12.0 24.0 0.0 curve-lin knob
  "ADC" "AA"   "era-aa"   EraParams.aa 0.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt
  "ADC" "RATE" "era-rate" EraParams.rate 1000.0 48000.0 26040.0 curve-exp knob
  "ADC" "BITS" "era-bits" EraParams.bits 1.0 16.0 12.0 curve-lin knob
  "ADC" "MODE" "era-mode" EraParams.mode 0.0 switch
    "ROUND" 0.0 opt  "TRUNC" 1.0 opt  "MULAW" 2.0 opt
  "ADC" 5 strip

  "DAC" "FILTER" "era-filter" EraParams.filter-hz 1000.0 20000.0 12000.0 curve-exp knob
  "DAC" "RES"    "era-res"    EraParams.res 0.0 1.0 0.0 curve-lin knob
  "DAC" "MIX"    "era-mix"    EraParams.mix 0.0 1.0 1.0 curve-pow knob
  "DAC" "OUT"    "era-out"    EraParams.out-db -24.0 24.0 0.0 curve-lin knob
  "DAC" 4 strip

  1.0 row
    5.0 cell  "ADC" 1.0 item
    4.0 cell  "DAC" 1.0 item

  machine-desc
;
