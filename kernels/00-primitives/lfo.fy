( lfo.fy - a low-frequency oscillator read at a phase the caller keeps.

  The caller owns the phase [free-running, or the transport's beat over a
  division], so one word serves a free LFO, a synced one, and a stereo
  pair offset in phase.  The Lfo cell remembers the last phase so it can
  see the wrap, where S&H draws a new value and the smooth random starts
  its next glide.

    shape  0 SINE  1 TRI  2 SAW UP  3 SAW DOWN  4 SQUARE  5 S&H  6 RANDOM

  Every shape is unipolar 0..1 and starts at 0 at phase 0 [the sine is
  0.5 - 0.5 cos], so a filter swept by depth x lfo opens from its cutoff
  upwards and a synced wobble starts closed on the beat.  A zeroed Lfo is
  a valid start. )

include "math.fy"
include "rand.fy"

ustruct: Lfo
  f64 last    ( the phase last read, for the wrap )
  f64 held    ( S&H: the value drawn at the last wrap )
  f64 prev    ( RANDOM: the value before it, where the glide starts )
  f64 seed    ( rand.fy state )
;

( s ph shape -- w : the LFO at phase ph [any real; its fraction is
  used], 0..1. )
dsp: lfo-at | s:Lfo ph shape -- w |
  ph ffrac | p |
  p s.last f< | wrap |
  p -> s.last
  s.seed rand-next | nseed |
  wrap nseed s.seed select -> s.seed
  wrap s.held s.prev select | prev |
  prev -> s.prev
  wrap nseed s.held select | held |
  held -> s.held
  0.5  p 0.25 f- sin2pi 0.5 f*  f+ | sine |
  1.0  p 2.0 f* 1.0 f- fabs  f- | tri |
  p 0.5 1.0 0.0 fsel-lt | sq |
  prev  held prev f-  0.5  p cospi 0.5 f* f-  f*  f+ | smooth |
  shape 0.5 sine
  shape 1.5 tri
  shape 2.5 p
  shape 3.5 1.0 p f-
  shape 4.5 sq
  shape 5.5 held smooth
  fsel-lt fsel-lt fsel-lt fsel-lt fsel-lt fsel-lt
;
