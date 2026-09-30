( ms20_lpf.fy - the MS-20 lowpass: a driven, leaky SVF with a clipped
  feedback loop.  The topology of the June listening probe
  [tools/audio_probe/render_ms20_sweeps.py, profiles f-hot and g-wet],
  the sound the machine is judged against.

  Per substep [run it 4x]:

    fbdc    += cdc  [ic2 - fbdc]                feedback DC tracker
    fb       = tanh[fb-amt [ic2 - fbdc]]        lowpass back, DC-blocked, clipped
    driven   = tanh[drive x - fb]               input stage, driven into the clip
    TPT SVF core [g, damping] -> hp bp lp, both integrators leak
    colored  = tanh[out-clip [lp + 0.2 bp]]     a fifth of the bandpass: bark
    out      = colored - its DC

  Where the character comes from: the integrators stay linear [the
  failed dirty prototype clipped them and latched], and all the grit
  lives in two places - the input stage, where the clipped lowpass is
  subtracted from a hot input, and the output shaper.  The feedback is a
  near-square version of the lowpass, so the resonance ridge comes out
  broad and full of harmonics instead of a thin sine, and the SVF's own
  damping supplies the peak.  fb-amt is resonance * fb-gain * fb-clip.

  Coefficients come once per block from ms20-lpf-set; g per sample from
  the cutoff [svf-g at the 4x rate].

  ms20-lpf-set-offs makes the feedback clip lopsided, the real diodes'
  mismatch: tanh[a + off] - tanh[off], rescaled to unit slope.  The DC it
  makes goes back through the input stage and shifts its operating
  point, so a screaming filter grows even harmonics; the fb DC tracker
  is the loop's coupling cap.  The fields default to zero, symmetric,
  which is the June probe exactly. )

include "../02-shapers/rational.fy"   ( tanh-rational )
include "../00-primitives/math.fy"

ustruct: Ms20Lpf
  f64 ic1
  f64 ic2
  f64 fb-dc
  f64 out-dc
;

ustruct: Ms20LpfProfile
  f64 drive      ( input stage gain )
  f64 fb-amt     ( resonance * fb-gain * fb-clip )
  f64 out-clip   ( output shaper gain )
  f64 leak       ( integrator leak per substep )
  f64 damping    ( SVF damping, from resonance )
  f64 fb-dc-c    ( feedback DC tracker, 18 Hz at the 4x rate )
  f64 out-dc-c   ( output DC blocker, 10 Hz at the 4x rate )
  f64 fb-off     ( feedback clip offset: 0 symmetric )
  f64 fb-toff    ( its clip, subtracted so fb[0] = 0 )
  f64 fb-dnorm   ( slope correction - 1, so 0 is exact unity )
;

( pr drive res mode osr -- : one block's constants.  mode 0 HOT [f-hot],
  1 WET [g-wet]; drive scales the profile's own input gain. )
dsp: ms20-lpf-set | pr:Ms20LpfProfile drive res mode osr -- |
  mode 0.5  2.10 1.90  fsel-lt  drive f* -> pr.drive
  mode 0.5  10.125 14.58  fsel-lt  res f* -> pr.fb-amt
  mode 0.5  1.85 2.10  fsel-lt -> pr.out-clip
  mode 0.5  0.99990 0.99988  fsel-lt -> pr.leak
  mode 0.5  0.62 0.58  fsel-lt
    1.0  res  mode 0.5 5.2 6.2 fsel-lt  f* f+  f/  0.035 fmax -> pr.damping
  1.0  -6.283185307179586 18.0 f* osr f/ exp  f- -> pr.fb-dc-c
  1.0  -6.283185307179586 10.0 f* osr f/ exp  f- -> pr.out-dc-c
;

( pr off -- : the diodes' mismatch. )
dsp: ms20-lpf-set-offs | pr:Ms20LpfProfile off -- |
  off -> pr.fb-off
  off tanh-rational | t |
  t -> pr.fb-toff
  1.0  1.0 t t f* f-  f/  1.0 f- -> pr.fb-dnorm
;

( f pr x g -- y : one substep. )
dsp: ms20-lpf-step | f:Ms20Lpf pr:Ms20LpfProfile x g -- y |
  f.ic1 | ic1 |
  f.ic2 | ic2 |
  f.fb-dc  ic2 f.fb-dc f-  pr.fb-dc-c f*  f+ | fbdc |
  ic2 fbdc f-  pr.fb-amt f*  pr.fb-off f+  tanh-rational  pr.fb-toff f- | fb0 |
  fb0  fb0 pr.fb-dnorm f*  f+ | fb |
  x pr.drive f*  fb f-  tanh-rational | d |
  pr.damping 2.0 f* | dd |
  d  dd g f+ ic1 f* f-  ic2 f-
    1.0  dd g f* f+  g g f* f+  f/ | hp |
  g hp f* | ghp |
  ghp ic1 f+ | bp |
  g bp f* | gbp |
  gbp ic2 f+ | lp |
  lp 0.2 bp f* f+  pr.out-clip f*  tanh-rational | c |
  f.out-dc  c f.out-dc f-  pr.out-dc-c f*  f+ | odc |
  ghp bp f+  pr.leak f* -> f.ic1
  gbp lp f+  pr.leak f* -> f.ic2
  fbdc -> f.fb-dc
  odc -> f.out-dc
  c odc f-
;
