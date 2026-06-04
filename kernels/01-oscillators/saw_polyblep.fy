( saw_polyblep.fy - compatibility suite for all current polyBLEP oscillators.

  Renderable oscillator kernels live one per file.  Keep this suite only so
  older probe commands that point at saw_polyblep.fy still load the same words. )

include "saw_rising_polyblep.fy"
include "saw_falling_polyblep.fy"
include "saw_cap_polyblep.fy"
include "saw_topcut_polyblep.fy"
include "square_polyblep.fy"
include "pulse_polyblep.fy"
