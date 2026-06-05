( ms20_lpf_profiles.fy - documentation fixture for MS-20-style lowpass profiles.

  The nonlinear filter step now lives in `ms20_lpf.fy` as `k-ms20-lpf4`.
  The tuned listening profiles still live in the Zig/Python probe rig because
  `dsp2:` cannot yet express the coefficient path (`tan`, exponential cutoff
  sweep mapping) directly. This file documents the two profiles we keep:

  - f-hot: balanced driven lowpass with audible feedback character.
  - g-wet: hotter, wetter profile that is aggressive enough to keep as a
    character option.

  Remaining promotion path:
  1. Add `dsp2:` builtins or IR lowering for cutoff-to-coefficient math.
  2. Ratchet profile-specific coefficient mappings against `ms20-lpf-grid`.
  3. Fuse oscillator, envelope, filter, VCA, and DC block into a voice kernel
     or buffer kernel so the voice rig does not cross the host/JIT boundary per
     sample. )
