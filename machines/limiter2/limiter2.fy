( limiter2.fy - lookahead brickwall limiter with LUFS metering.

  DSP in kernels/07-effects/limiter.fy.  The host feeds a stereo-linked
  detector trace [max abs of both inputs] for identical L/R gain, and a
  per-channel lookahead ring.  The K-weighting biquad coefficients are
  BS.1770-4 values for 48 kHz, supplied as constants. )

include "../../kernels/07-effects/limiter.fy"
include "../lib/manifest.fy"

: manifest
  "Limiter" effect-block machine*
  "k-lim-tick"          render!
  "lim-prepare"         prepare!
  "lim-block-prepare"   block-prepare!
  LimState.size  state-size!
  LimParams.size params-size!
  LimParams.lat latency!
  240.0 panel-w!

  ( 12 ms lookahead ring per channel; LOOK tops out at 10 ms )
  "look" LimState.dline LimState.dline-len 0.012 buffer

  ( stereo-linked detector: host writes the max-abs-both-channels trace )

  ( K-weighting [BS.1770-4 @ 48 kHz] - stage 1 high shelf )
  LimParams.k1b0  1.53512485958697   const-f64
  LimParams.k1b1 -2.69169618940638   const-f64
  LimParams.k1b2  1.19839281085285   const-f64
  LimParams.k1a1 -1.69065929318241   const-f64
  LimParams.k1a2  0.73248077421585   const-f64
  ( stage 2 RLB high-pass )
  LimParams.k2b0  1.0                const-f64
  LimParams.k2b1 -2.0                const-f64
  LimParams.k2b2  1.0                const-f64
  LimParams.k2a1 -1.99004745483398   const-f64
  LimParams.k2a2  0.99007225036621   const-f64

  "LIM" "GAIN" "lim-gain"  LimParams.gain-db 0.0   24.0 0.0   curve-lin knob
  "LIM" "CEIL" "lim-ceil"  LimParams.ceil-db -24.0 0.0  -0.3  curve-lin knob
  "LIM" "LOOK" "lim-look"  LimParams.look-ms 0.1   10.0 2.0   curve-exp knob
  "LIM" "REL"  "lim-rel"   LimParams.rel-s   0.01  1.0  0.2   curve-exp knob
  "LIM" 4 strip

  ( big L2-style meter: GR band + I/O bars + LUFS readouts.  Offsets in
    fixed order: gain-min, in-peak, out-peak, ms-momentary, ms-short,
    ms-integrated-sum, integrated-count. )
  "METER" LimState.gmin LimState.ipk LimState.opk
          LimState.msm  LimState.mss LimState.msum LimState.mn meter-display

  4.0 row  1.0 cell  "METER" 1.0 item
  2.0 row  1.0 cell  "LIM"   1.0 item

  machine-desc
;
