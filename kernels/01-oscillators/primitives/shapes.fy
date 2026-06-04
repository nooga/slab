( shapes.fy - raw oscillator shape helpers before anti-alias correction. )

( phase -- sample : convert normalized phase to a rising bipolar saw. )
dsp2: saw-rising-raw
  dup f+ 1.0 f-
;

( phase -- sample : convert normalized phase to a falling bipolar saw. )
dsp2: saw-falling-raw
  1.0 swap dup f+ f-
;

( phase -- sample : convert normalized phase to a convex capacitor-like ramp. )
dsp2: cap-ramp-raw
  fcapramp
;

( sample -- sample' : apply an asymmetric hard top cut. )
dsp2: top-cut
  -1.0 0.65 fclamp
;
