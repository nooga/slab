( funk.fy - FUNK OVERLOAD machine.

  One knob: bypass at 0, a touch wah, then squeeze and resonance, then
  the MS-20 HOT lowpass screaming at the top.  RANGE puts the filter
  where the part lives: BASS 180 Hz, GTR 400 Hz, KEYS 700 Hz [thinner,
  a bandpass quack].  The response follows how hard each note hits
  against the part's own running level, not the track's volume, and an
  auto-gain holds the loudness.  The DSP is kernels/07-effects/funk.fy. )

include "../../kernels/07-effects/funk.fy"
include "../lib/manifest.fy"

: manifest
  "Funk Overload" effect-block machine*
  "k-funk-tick"        render!
  "funk-block-prepare" block-prepare!
  "k-funk-tick-thru" FunkParams.funk render-lite!
  FunkState.size  state-size!
  FunkParams.size params-size!
  160.0 panel-w!
  stereo

  "FUNK" "OVERLOAD" "funk-macro" FunkParams.funk 0.0 1.0 0.35 curve-lin knob
  "FUNK" "RANGE" "funk-range" FunkParams.range 1.0 switch
    "BASS" 0.0 opt  "GTR" 1.0 opt  "KEYS" 2.0 opt

  "FUNK" 2 strip
  1.0 row
    1.0 cell  "FUNK" 1.0 item

  machine-desc
;
