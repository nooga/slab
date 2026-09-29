( multi2.fy - three-band compressor machine [docs/24 §multi2].

  LR4 crossovers at XLO and XHI [flat when nothing compresses], a
  compressor per band with its own THRESH, RATIO and GAIN, and shared
  ATK / REL [the low band runs at twice them, the high band at half].
  UP adds upward compression below each band's threshold, for the quiet
  detail a downward compressor can't bring up.  The knee is fixed at
  4 dB and the detectors are PEAK.  Keyed, each band's detector hears
  the key's own band [a kick ducking only the bass's lows].  The DSP is
  kernels/07-effects/multi.fy. )

include "../../kernels/07-effects/multi.fy"
include "../lib/manifest.fy"

: manifest
  "Multi" effect-block machine*
  "k-multi-tick-key" render!
  "k-multi-tick" MultiParams.keyed render-lite!   ( unkeyed: the cheaper word )
  MultiParams.keyed key-flag!
  "k-multi-prepare" block-prepare!
  MultiState.size  state-size!
  MultiParams.size params-size!
  420.0 panel-w!
  stereo
  sidechain

  "LOW" "THRESH" "mlo-thresh" MultiParams.lo MbBandP.thresh-db + -48.0 0.0 -18.0 curve-lin knob
  "LOW" "RATIO"  "mlo-ratio"  MultiParams.lo MbBandP.ratio +      1.0 10.0 2.0 curve-pow knob
  "LOW" "GAIN"   "mlo-gain"   MultiParams.lo MbBandP.gain-db +  -12.0 12.0 0.0 curve-lin knob
  "MID" "THRESH" "mmid-thresh" MultiParams.mid MbBandP.thresh-db + -48.0 0.0 -18.0 curve-lin knob
  "MID" "RATIO"  "mmid-ratio"  MultiParams.mid MbBandP.ratio +      1.0 10.0 2.0 curve-pow knob
  "MID" "GAIN"   "mmid-gain"   MultiParams.mid MbBandP.gain-db +  -12.0 12.0 0.0 curve-lin knob
  "HIGH" "THRESH" "mhi-thresh" MultiParams.hi MbBandP.thresh-db + -48.0 0.0 -18.0 curve-lin knob
  "HIGH" "RATIO"  "mhi-ratio"  MultiParams.hi MbBandP.ratio +      1.0 10.0 2.0 curve-pow knob
  "HIGH" "GAIN"   "mhi-gain"   MultiParams.hi MbBandP.gain-db +  -12.0 12.0 0.0 curve-lin knob
  "XOVER" "LO"  "multi-xlo" MultiParams.xlo-hz 40.0  400.0  120.0  curve-exp knob
  "XOVER" "HI"  "multi-xhi" MultiParams.xhi-hz 1000.0 8000.0 2500.0 curve-exp knob
  "TIME" "ATK"  "multi-atk" MultiParams.atk-s 0.0005 0.1 0.01 curve-exp knob
  "TIME" "REL"  "multi-rel" MultiParams.rel-s 0.02   1.0 0.15 curve-exp knob
  "OUT" "UP"    "multi-up"  MultiParams.up     0.0   1.0 0.0 curve-lin knob
  "OUT" "MIX"   "multi-mix" MultiParams.mix    0.0   1.0 1.0 curve-pow knob
  "OUT" "OUT"   "multi-out" MultiParams.out-db -12.0 12.0 0.0 curve-lin knob
  "LOW" 3 strip
  "MID" 3 strip
  "HIGH" 3 strip
  "XOVER" 2 strip
  "TIME" 2 strip
  "OUT" 3 strip
  "C-LOW"  "mlo"  MultiState.lo  MbBand.gr-db + MultiState.lo  MbBand.lvl + dyn-display
  "C-MID"  "mmid" MultiState.mid MbBand.gr-db + MultiState.mid MbBand.lvl + dyn-display
  "C-HIGH" "mhi"  MultiState.hi  MbBand.gr-db + MultiState.hi  MbBand.lvl + dyn-display

  ( a curve over each band's knobs; crossover, timing and output below )
  2.2 row
    1.0 cell  "C-LOW" 1.3 item  "LOW" 1.0 item
    1.0 cell  "C-MID" 1.3 item  "MID" 1.0 item
    1.0 cell  "C-HIGH" 1.3 item  "HIGH" 1.0 item
  1.0 row
    0.67 cell  "XOVER" 1.0 item
    0.67 cell  "TIME" 1.0 item
    1.0 cell  "OUT" 1.0 item

  machine-desc
;
