( segments.fy - reusable envelope segment models. )

( time attack decay sustain gate release -- amp : evaluate a linear ADSR envelope at time. )
dsp: adsr-linear | time atk dec sus gate rel -- amp |
  time atk f/ 0.0 1.0 fclamp | a |
  time atk  a  1.0  time atk f- dec f/  1.0 sus f- f*  f-  fsel-lt | a |
  time atk dec f+  a  sus  fsel-lt | a |
  time gate  a  1.0 time gate f- rel f/ f- sus f*  fsel-lt | a |
  time gate rel f+  a  0.0  fsel-lt
;

( time attack decay sustain gate release -- amp : evaluate a capacitor-like ADSR envelope at time. )
dsp: adsr-cap | time atk dec sus gate rel -- amp |
  ( attack: 1 - [1-t]^4 )
  1.0 time atk f/ 0.0 1.0 fclamp f- | q | q q f* | q2 |
  1.0 q2 q2 f* f- | a |
  ( decay: sus + [1-sus][1-t]^4 )
  1.0 time atk f- dec f/ f- | q | q q f* | q2 |
  time atk  a  sus  q2 q2 f*  1.0 sus f- f*  f+  fsel-lt | a |
  time atk dec f+  a  sus  fsel-lt | a |
  ( release: sus [1-t]^4 from the gate time )
  1.0 time gate f- rel f/ f- | q | q q f* | q2 |
  time gate  a  sus  q2 q2 f* f*  fsel-lt | a |
  time gate rel f+  a  0.0  fsel-lt
;
