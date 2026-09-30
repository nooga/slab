( vco.fy - the analog VCO's imperfections, as waveform primitives.

  Every Slab synth started from the same ideal polyBLEP waves.  A real
  saw core charges a capacitor through a current source that sags as the
  voltage rises, so the ramp bows; each voice's parts bow it differently.
  vco-saw blends the straight ramp toward the capacitor curve
  [cap-ramp-raw, p[2-p]*2-1]: both jump by 2 at the reset, so one polyBLEP
  corrects either.  The curve adds a DC offset of curve/3, and a little
  even-harmonic tilt; the voice's droop highpass [the output coupling
  capacitor that also tilts the pulse tops] takes the DC out.

  droop-hp is that capacitor: a one-pole highpass at ~20-40 Hz on the
  oscillator mix, before the filter.  On a low pulse the flat tops sag
  toward zero between edges, the tell of a DC-blocked VCO output. )

include "blep.fy"

( ph dt curve -- y : a rising saw, bowed toward the capacitor ramp by
  curve 0..1. )
dsp: vco-saw | ph dt curve -- y |
  ph saw-rising-raw | r |
  r  ph cap-ramp-raw r f- curve f*  f+
  ph dt polyblep f-
;

( x xp yp a -- y : one-pole highpass step, y = a [yp + x - xp];
  a = 1 / [1 + 2 pi f / rate]. )
dsp: droop-hp | x xp yp a -- y |
  yp x f+ xp f- a f*
;
