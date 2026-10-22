( acid.fy - Squelch 33: a TB-303-style bassline synth on the HOT/WET
  lowpass that used to be the SM-24 Mono's.

  The DSP is kernels/06-voices/acid_voice.fy; this file declares the
  machine.  It is mono: an overlapping note slides, a loud one
  [velocity over 0.8] is accented. )

include "../../kernels/00-primitives/ctx.fy"  ( kernel ABI: Ctx, Io )
include "../../kernels/06-voices/acid_voice.fy"
include "../lib/manifest.fy"

( ctx state params -- : a block's coefficients. )
dsp: acid-block-prepare | ctx:Ctx state params:AcidParams -- |
  ctx.inv-sr -> params.inv-sample-rate
  ctx.sr 4.0 f* | osr |
  osr -> params.osr
  ( the MEG: decay only, falling on after key-up at the same rate )
  params.meg-co&  0.003 params.decay 0.0 params.decay 0.0 0.0 ctx.inv-sr env-rc-coefs
  params.mega-co&  0.003 0.2 0.0 0.2 0.0 0.0 ctx.inv-sr env-rc-coefs
  params.vca-co&  0.002 3.0 0.0 0.008 0.0 0.0 ctx.inv-sr env-rc-coefs
  ( slide: an RC covering 3 time constants in SLIDE )
  1.0  -3.0  params.slide ctx.sr f* f/  exp  f- -> params.slide-c
  params.tune 0.08333333333333333 f* exp2 -> params.tune-ratio
  params.env-mod 5.0 f* -> params.env-oct
  ( the accent RC: 15 ms, 60 ms at full RES, where accents stack )
  1.0  -1.0  0.015 params.resonance 0.045 f* f+  ctx.sr f* f/  exp  f- -> params.acc-c
  params.lpf-pr&  params.drive  params.resonance 1.6 f*  params.mode osr ms20-lpf-set
  params.lpf-pr&  0.15 ms20-lpf-set-offs
;

: manifest
  "Squelch 33" voice-sample machine*
  "k-acid-voice-sample" render!
  "acid-note-on"  note-on!
  "acid-note-expr" note-expr!
  "acid-note-off" note-off!
  "acid-block-prepare" block-prepare!
  AcidState.size  state-size!
  AcidParams.size params-size!
  560.0 panel-w!

  ( module label id offset min max default curve )
  "VCO" "TUNE" "tune" AcidParams.tune -12.0 12.0 0.0 curve-lin knob
  "VCO" "WAVE" "wave" AcidParams.wave 0 switch
    "SAW" 0.0 opt  "SQR" 1.0 opt

  "VCF" "CUT"  "cutoff"    AcidParams.cutoff    30.0 8000.0 260.0 curve-exp knob
  "VCF" "RES"  "resonance" AcidParams.resonance 0.0 1.0 0.6 curve-lin knob
  "VCF" "ENV"  "env-mod"   AcidParams.env-mod   0.0 1.0 0.5 curve-lin knob
  "VCF" "DEC"  "decay"     AcidParams.decay     0.2 2.0 0.5 curve-exp knob

  "PLAY" "ACC"   "accent" AcidParams.accent 0.0 1.0 0.7 curve-lin knob
  "PLAY" "SLIDE" "slide"  AcidParams.slide  0.02 0.3 0.06 curve-exp knob

  "DRIVE" "DRV"  "drive" AcidParams.drive 0.25 4.0 1.0 curve-exp knob
  "DRIVE" "MODE" "mode"  AcidParams.mode  0 switch
    "HOT" 0.0 opt  "WET" 1.0 opt

  "OUT" "LVL" "level" AcidParams.level 0.0 1.0 0.68 curve-pow knob

  "VCO" 2 strip
  "VCF" 4 strip
  "PLAY" 2 strip
  "DRIVE" 2 strip
  "OUT" 1 strip

  1.0 row
    2.0 cell  "VCO" 1.0 item
    4.0 cell  "VCF" 1.0 item
    2.0 cell  "PLAY" 1.0 item
    2.0 cell  "DRIVE" 1.0 item
    1.0 cell  "OUT" 1.0 item

  machine-desc
;
