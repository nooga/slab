( modal.fy - building blocks for modal physical models: struck strings,
  membranes, bars and plates [docs/41].

  A vibrating body is a bank of independent damped oscillators, one per
  mode:  q'' + 2 sigma q' + w^2 q = f,  where q is the mode's amplitude
  in metres [the mode shape is a unit sine or Bessel profile], f its
  modal force per unit modal mass, and sigma its decay rate [1/s].

  modal-step advances one mode by one sample exactly for a force held
  over the sample [zero-order hold]: the undamped oscillator's closed
  form, then the decay factor rho = exp[-sigma h].  Because the step is
  exact, a mode near Nyquist is as stable as a mode at 50 Hz, and the
  decay rate is the one asked for at any pitch.  Every coefficient
  depends only on w, h and sigma, so a voice computes them once per note
  [zoh-coefs] and the render only multiplies and adds.

    q' = rho [ c q + s/w v ] + B1 f      c = cos wh,  s = sin wh
    v' = rho [ -w s q + c v ] + B2 f     B1 = [1 - c]/w^2 = 2 sin^2[wh/2]/w^2
                                         B2 = s/w

  contact-solve is the striker: a felt or wooden mass pressed into the
  body with the power-law Hunt-Crossley force

    F = K e^p [1 + alpha de/dt],  e > 0 the compression

  solved implicitly.  Over one sample the compression responds linearly
  to the force it creates, e = e_free - D F, with D the striker's and the
  body's compliance at the contact point.  Newton on that scalar
  equation from e_free converges from above in a few steps and stays
  stable for the stiff felt of a treble hammer, where an explicit force
  would blow up.

  The derivations are textbook: modal synthesis [Adrien 1991], the
  power-law felt [Hall 1986; Stulov 1995], Hunt-Crossley damping [Hunt
  and Crossley 1975], and the implicit contact solve follows Bilbao,
  Numerical Sound Synthesis [2009], ch. 4. )

include "../00-primitives/math.fy"

( T60 seconds -- sigma : the amplitude decay rate that falls 60 dB in T60. )
dsp: t60>sigma | t60 -- s |  6.907755278982137 t60 0.0001 fmax f/ ;

( w h -- c s/w w*s B1 B2 : the exact ZOH coefficients of one undamped
  mode at angular frequency w over a step h.  B1 uses the half-angle form
  so it keeps its precision at low w h. )
dsp: zoh-coefs | w h -- c sw ws b1 b2 |
  w h f* | wh |
  wh cos | c |
  wh sin | s |
  wh 0.5 f* sin | sh |
  w w f* | w2 |
  c  s w f/  w s f*  2.0 sh f* sh f* w2 f/  s w f/
;

( q v c sw ws rho f b1 b2 -- q' v' : one mode, one sample, force f held. )
dsp: modal-step | q v c sw ws rho f b1 b2 -- qn vn |
  c q f*  sw v f* f+  rho f*  b1 f f* f+
  ws q f* fneg  c v f* f+  rho f*  b2 f f* f+
;

( e^p and its derivative p e^[p-1] for e > 0 - the felt's law. )
dsp: felt-pow | e p -- ep dep |
  e 1.0e-12 fmax | ec |
  ec log2 p f* exp2 | ep |
  ep  ep p f* ec f/
;

( ef eold D K p alpha inv-h -- e F : the implicit power-law Hunt-Crossley
  contact.  ef is the compression the next sample would have with no
  contact force, eold this sample's compression, D the compliance [m/N]
  mapping force to compression change, K [N/m^p] and p the felt, alpha
  [s/m] its hysteresis, inv-h the sample rate.

  Solves g[e] = e + D F[e] - ef = 0 with
    F[e] = K e^p max[0, 1 + alpha [e - eold] inv-h]
  by four Newton steps from e = ef.  g is increasing and convex for
  e > 0, so the iterates fall monotonically toward the root and never
  cross into e < 0.  Out of contact [ef <= 0] the force is zero and the
  compression is ef. )
dsp: contact-newton | e ef eold D K p alpha inv-h -- en |
  e p felt-pow | ep dep |
  1.0 e eold f- alpha f* inv-h f* f+ 0.0 fmax | hc |
  K ep f* hc f* | f |
  K dep f* hc f*  K ep f* alpha f* inv-h f*  f+ | df |
  e  e D f f* f+ ef f-  1.0 D df f* f+ f/  f-  1.0e-12 fmax
;

dsp: contact-solve | ef eold D K p alpha inv-h -- e F |
  ef 1.0e-12 fmax | e |
  e ef eold D K p alpha inv-h contact-newton | e |
  e ef eold D K p alpha inv-h contact-newton | e |
  e ef eold D K p alpha inv-h contact-newton | e |
  e ef eold D K p alpha inv-h contact-newton | e |
  e p felt-pow | ep dep |
  K ep f*  1.0 e eold f- alpha f* inv-h f* f+ 0.0 fmax f* | f |
  ef 0.0 f> | in |
  in e ef select
  in f 0.0 select
;
