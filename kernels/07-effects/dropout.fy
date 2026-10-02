( dropout.fy - tape dropouts: oxide shed, a crease, a speck of dust
  lifting the tape off the head.  Events arrive at random [a Poisson
  process at RATE per second]; each one is 3-80 ms long, a raised-cosine
  dip of up to DEPTH, and takes the highs with it - the head-to-tape gap
  is a low-pass whose cutoff falls as the spacing grows [Wallace's
  spacing loss, exp(-2 pi d / wavelength), strongest on the highs].

    e     = depth_i sin^2[pi t / len_i]     0..1 during an event
    gain  = 1 - 0.95 e                      down to -26 dB
    a     = a_open + [a_shut - a_open] e    one-pole low-pass, 16 k -> 1.2 k

  Both channels dip together [one tape]; drop-tick also returns e, so
  the owner can add the burst of hiss a VHS Hi-Fi tracking loss makes.
  The owner skips it [ifte] at RATE 0, where it would be a pass. )

include "../00-primitives/math.fy"
include "../00-primitives/rand.fy"

ustruct: DropState
  f64 rng
  f64 t        ( samples into the event )
  f64 len      ( event length, samples; t >= len is idle )
  f64 dep      ( this event's depth )
  f64 yl       ( the gap's low-pass, per channel )
  f64 yr
;

ustruct: DropParams
  ( set by the owner )
  f64 rate     ( events per second )
  f64 depth    ( 0..1 )
  ( derived - drop-prepare )
  f64 p        ( chance per sample )
  f64 lmin     ( shortest event, and the spread, samples )
  f64 lspan
  f64 a-open
  f64 a-shut
;

( sr dp -- )
dsp: drop-prepare | sr dp:DropParams |
  dp.rate sr f/ -> dp.p
  0.003 sr f* -> dp.lmin
  0.077 sr f* -> dp.lspan
  1.0  -6.283185307179586 16000.0 f* sr f/ exp  f- -> dp.a-open
  1.0  -6.283185307179586 1200.0 f* sr f/ exp  f- -> dp.a-shut
;

( ds dp xl xr -- yl yr e : one stereo sample and the dip's depth. )
dsp: drop-tick | ds:DropState dp:DropParams xl xr -- yl yr e |
  ds.rng& rand-u | r |
  ds.t ds.len f>= | idle |
  idle  r dp.p f<  and | go |
  ( a trigger means r < p, so r / p is a fresh uniform draw - r itself
    is tiny then and would make every event the shortest, shallowest )
  r dp.p 1.0e-30 f+ f/ 0.0 1.0 fclamp | q |
  q 97.31 f* ffrac | r3 |
  go  0.0  ds.t 1.0 f+  select | t |
  go  dp.lmin q dp.lspan f* f+  ds.len  select | len |
  go  0.4 0.6 r3 f* f+ dp.depth f*  ds.dep  select | dep |
  t -> ds.t
  len -> ds.len
  dep -> ds.dep
  t len f/ 0.0 1.0 fclamp sinpi | sn |
  t len f<  sn sn f* dep f*  0.0  select | e |
  1.0 0.95 e f* f- | g |
  dp.a-open  dp.a-shut dp.a-open f-  e f*  f+ | a |
  ds.yl  xl ds.yl f-  a f*  f+ | yl |
  ds.yr  xr ds.yr f-  a f*  f+ | yr |
  yl -> ds.yl
  yr -> ds.yr
  yl g f*  yr g f*  e
;
