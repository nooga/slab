( ms20_svf.fy - full "g-wet" MS-20-style nonlinear lowpass voice filter.

  This is the canonical filter: the exact topology that the Python listening
  oracle (tools/audio_probe/render_ms20_sweeps.py, profile g-wet) renders, now
  living in fy as a fused `dsp:` primitive `fms20-svf`. Both the kernel/voice
  rig and the DAW machine path call this same word, so authoring in the rig and
  using it in the DAW yield identical audio.

  Per sample the primitive runs four oversampled substeps of:
    fb_dc   += fb_dc_coeff * (ic2 - fb_dc)
    feedback = clip((ic2 - fb_dc) * resonance * fb_gain, fb_clip)
    driven   = clip(input*drive - feedback, 1.0)
    TPT SVF core -> bp, lp with leak on the integrators
    colored  = clip(lp + 0.20*bp, out_clip)
    out_dc  += out_dc_coeff * (colored - out_dc)
    out      = colored - out_dc
  where clip(x,a) = rational-tanh(x*a).

  Coefficients (g, damping, the two DC-block coeffs) are computed OUTSIDE the
  sample loop, in fy, from raw controls (cutoff Hz, resonance, profile). The
  host/DAW does not compute them - see the coeff word (added next) so the rig
  and DAW share one source of truth. )

( layout mirrored by the fms20-svf primitive - do not reorder. )
ustruct: SvfState
  f64 ic1
  f64 ic2
  f64 fb-dc
  f64 out-dc
;

ustruct: SvfParams
  f64 g
  f64 damping
  f64 drive
  f64 resonance
  f64 fb-gain
  f64 fb-clip
  f64 out-clip
  f64 leak
  f64 fb-dc-coeff
  f64 out-dc-coeff
;

( out state params input g damping -- : write one filtered sample to out.
  g and damping are the per-sample coefficients (so a voice can envelope-
  modulate cutoff); the static profile is read from params. )
dsp: k-ms20-svf
  4 pick 4 pick 4 pick 4 pick 4 pick fms20-svf
  6 pick f!64
  drop2 drop2 drop2
;

( params cutoff resonance os-rate -- : compute g-wet coefficients in fy and
  fill SvfParams. No host/Zig math, no libm: over the coefficient input ranges
  the transcendentals reduce to tiny-argument polynomials.

  - theta = pi * clamp(cutoff,20,20160) / os-rate  is in [0, ~0.33], so
    tan(theta) ~ theta + theta^3/3 + 2 theta^5/15 + 17 theta^7/315  (err ~1e-6).
  - the DC-block args a = 2pi*f/os-rate are ~6e-4, so
    1 - exp(-a) ~ a - a^2/2 + a^3/6.
  Profile values (drive, fb-gain, fb-clip, out-clip, leak, damping shape) are
  the g-wet listening profile and will later become machine controls. )
( Coefficient math. dsp2 raw-entry words may only use arg locals, so the
  math (which needs mid-word locals) lives in inlined helper words; the
  raw-callable k-svf-coeffs-* words just push args, call helpers, and store.
  These three together replace the old Zig coefficient derive. )

( cutoff os-rate -- g : g = th*(1 + p*(1/3 + p*(2/15 + p*17/315))),
  p = th^2, th = pi*clamp(cutoff,20,20160)/osr. Tiny-angle tan series. )
dsp: svf-g
  | cutoff osr |
  cutoff 20.0 20160.0 fclamp 3.141592653589793 f* osr f/
  | th |
  th th f* | p |
  0.1333333333333333  p 0.05396825396825397 f*  f+
  p f* 0.3333333333333333 f+
  p f* 1.0 f+
  th f*
  nip nip nip nip
;

( resonance -- damping : clamp(0.58/(1+resonance*6.2), 0.035, 100). )
dsp: svf-damping
  | resonance |
  0.58  1.0 resonance 6.2 f* f+  f/  0.035 100.0 fclamp
  nip
;

( os-rate f -- coeff : 1 - exp(-2pi*f/osr) ~ a*(1 + a*(-1/2 + a/6)). )
dsp: svf-dc-coeff
  | osr f |
  6.283185307179586 f f* osr f/
  | a |
  -0.5  a 0.1666666666666667 f*  f+
  a f* 1.0 f+
  a f*
  nip nip nip
;

( params cutoff resonance os-rate -- : filter g and damping. )
dsp: k-svf-coeffs-tone
  | params cutoff resonance osr |
  cutoff osr svf-g       params SvfParams.g-p f!64
  resonance svf-damping  params SvfParams.damping-p f!64
  drop2 drop2
;

( params os-rate -- : the two DC-block coefficients. )
dsp: k-svf-coeffs-dc
  | params osr |
  osr 18.0 svf-dc-coeff  params SvfParams.fb-dc-coeff-p f!64
  osr 10.0 svf-dc-coeff  params SvfParams.out-dc-coeff-p f!64
  drop2
;

( params resonance -- : g-wet profile constants. )
dsp: k-svf-coeffs-profile
  | params resonance |
  1.90      params SvfParams.drive-p f!64
  resonance params SvfParams.resonance-p f!64
  5.4       params SvfParams.fb-gain-p f!64
  2.70      params SvfParams.fb-clip-p f!64
  2.10      params SvfParams.out-clip-p f!64
  0.99988   params SvfParams.leak-p f!64
  drop2
;
