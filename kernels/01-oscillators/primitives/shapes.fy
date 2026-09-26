( shapes.fy - raw oscillator shape helpers before anti-alias correction. )

( phase -- sample : convert normalized phase to a rising bipolar saw. )
dsp: saw-rising-raw
  dup f+ 1.0 f-
;

( phase -- sample : convert normalized phase to a falling bipolar saw. )
dsp: saw-falling-raw
  1.0 swap dup f+ f-
;

( phase -- sample : convert normalized phase to a convex capacitor-like ramp. )
dsp: cap-ramp-raw
  fcapramp
;

( phase -- sample : naive bipolar triangle (1/n^2 harmonics alias far less
  than saw/pulse, so band-limiting is deferred). -1 at phase 0, +1 at 0.5. )
dsp: tri-raw
  | p |
  p 0.5
  p 4.0 f* 1.0 f-          ( up   = 4p - 1 )
  3.0 p 4.0 f* f-          ( down = 3 - 4p )
  fsel-lt                  ( p < 0.5 ? up : down )
;

( wave tri saw pul -- out : pick a waveform by index 0=tri 1=saw 2=pulse. )
dsp: wave-sel3
  | wave tri saw pul |
  wave 1.5 saw pul fsel-lt    ( wave < 1.5 ? saw : pul )
  | sawpul |
  wave 0.5 tri sawpul fsel-lt ( wave < 0.5 ? tri : sawpul )
;

( sample -- sample' : apply an asymmetric hard top cut. )
dsp: top-cut
  -1.0 0.65 fclamp
;
