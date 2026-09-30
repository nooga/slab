( sem_svf.fy - the Oberheim SEM's 12 dB state-variable filter.

  A TPT SVF [tpt_svf.fy] whose two integrators saturate as they store,
  the way the SEM's OTA integrators run out of current.  The curve is
  lopsided, tanh[s + OFFS] - tanh[OFFS] at unit slope, so a hot filter
  grows even harmonics.  Run at 2x.

  The SEM's MODE knob crossfades lowpass -> notch -> highpass,
  y = [1 - m] lp + m hp, the notch sitting at the middle where the two
  halves cancel at the cutoff; BP is its own switch.  Damping reaches
  1/64 [Q 32]: past that the saturation holds a barely-sustained
  whistle, near where the hardware gives out. )

include "../00-primitives/math.fy"

ustruct: SemSvf
  f64 s1  f64 s2
;

:: SEM-OFFS 0.2 ;
:: SEM-TOFFS 0.197375320224904 ;    ( tanh 0.2 )
:: SEM-SLOPE 1.0405356560802877 ;   ( 1 / [1 - tanh^2 0.2] )

( s -- y : the integrators' saturation. )
dsp: sem-sat | s -- y |
  s SEM-OFFS f+ tanh-fast SEM-TOFFS f-  SEM-SLOPE f*
;

( cutoff osr res -- g d : cutoff clamped to 20 Hz .. 0.23 osr. )
dsp: sem-coeffs | cutoff osr res -- g d |
  cutoff  20.0  osr 0.23 f*  fclamp  3.141592653589793 f* osr f/ tan
  res -6.0 f* exp2
;

( f x g d lpw hpw bpw -- y : one 2x step; the output is lpw lp + hpw hp
  + bpw bp. )
dsp: sem-step | f:SemSvf x g d lpw hpw bpw -- y |
  f.s1 | s1 |
  f.s2 | s2 |
  2.0 d f* g f+ | a |
  1.0  1.0  2.0 d f* g f*  f+  g g f*  f+  f/ | h |
  x  a s1 f*  f-  s2 f-  h f* | hp |
  g hp f* | ghp |
  ghp s1 f+ | bp |
  g bp f* | gbp |
  gbp s2 f+ | lp |
  ghp bp f+ sem-sat -> f.s1
  gbp lp f+ sem-sat -> f.s2
  lp lpw f*  hp hpw f* f+  bp bpw f* f+
;
