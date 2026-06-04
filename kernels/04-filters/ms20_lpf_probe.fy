( ms20_lpf_probe.fy - workbench fixture for the MS-20-ish low-pass probe.

  The current probe renders from src/kernel_probe.zig so we can tune the
  nonlinear model, resonance sweep, WAV output, and spectrogram report before
  freezing a stateful fy dsp2 filter ABI. )

( -- : loadable placeholder while the filter model is a Zig-side oracle. )
: ms20-lpf-probe-placeholder ;
