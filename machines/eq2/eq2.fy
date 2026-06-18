( eq2.fy — 5-band parametric mixing EQ machine.

  DSP lives in the kernels rig [kernels/07-effects/eq.fy]; this file
  declares the machine.  The host runs the render word once per channel
  against per-channel state (independent biquad state per L/R), shares
  one params block, runs `eq-derive` each block to fill the biquad
  coefficients from the controls, and `eq-block-prepare` to stash the
  sample-rate the derive stages read.

  The panel shows a live frequency-response curve [the `.response`
  display recomputes the composite magnitude from the controls] above
  five band columns: switchable high-pass, low shelf, two parametric
  peaks, high shelf. )

include "../../kernels/07-effects/eq.fy"
include "../lib/manifest.fy"

: manifest
  "EQ" effect-block machine*
  "k-eq-tick"        render!
  "eq-block-prepare" block-prepare!
  "eq-derive"        derive!
  EqState.size  state-size!
  EqParams.size params-size!
  420.0 panel-w!

  "HPF" "FREQ" "eq-hpf-hz" EqParams.hpf-hz 20.0 1000.0 20.0 curve-exp knob
  "HPF" "ON"   "eq-hpf-on" EqParams.hpf-on 0.0 switch
    "OFF" 0.0 opt  "ON" 1.0 opt
  "HPF" 1 strip

  "LO" "FREQ" "eq-ls-hz" EqParams.ls-hz 30.0  500.0 100.0 curve-exp knob
  "LO" "GAIN" "eq-ls-db" EqParams.ls-db -18.0 18.0  0.0   curve-lin knob
  "LO" 1 strip

  "LO-MID" "FREQ" "eq-p1-hz" EqParams.p1-hz 100.0 4000.0 500.0 curve-exp knob
  "LO-MID" "GAIN" "eq-p1-db" EqParams.p1-db -18.0 18.0   0.0   curve-lin knob
  "LO-MID" "Q"    "eq-p1-q"  EqParams.p1-q  0.3   4.0    0.9   curve-exp knob
  "LO-MID" 1 strip

  "HI-MID" "FREQ" "eq-p2-hz" EqParams.p2-hz 500.0 16000.0 3000.0 curve-exp knob
  "HI-MID" "GAIN" "eq-p2-db" EqParams.p2-db -18.0 18.0    0.0    curve-lin knob
  "HI-MID" "Q"    "eq-p2-q"  EqParams.p2-q  0.3   4.0     0.9    curve-exp knob
  "HI-MID" 1 strip

  "HI" "FREQ" "eq-hs-hz" EqParams.hs-hz 1500.0 18000.0 8000.0 curve-exp knob
  "HI" "GAIN" "eq-hs-db" EqParams.hs-db -18.0  18.0    0.0    curve-lin knob
  "HI" 1 strip

  "CURVE" response-display

  3.0 row  1.0 cell  "CURVE" 1.0 item
  4.0 row
    1.0 cell  "HPF"    1.0 item
    1.0 cell  "LO"     1.0 item
    1.0 cell  "LO-MID" 1.0 item
    1.0 cell  "HI-MID" 1.0 item
    1.0 cell  "HI"     1.0 item

  machine-desc
;
